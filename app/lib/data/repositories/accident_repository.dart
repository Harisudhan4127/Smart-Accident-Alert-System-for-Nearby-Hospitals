/// Accident records and the offline outbox.
///
/// ## The ordering guarantee
///
/// This repository's central promise is the sequence in [recordAccident]:
///
/// ```text
///   1. build the record        (in memory)
///   2. write to sqflite        ← durable, instant
///   3. attempt Firestore       ← may fail, retried later
/// ```
///
/// The local write comes **first** and unconditionally. That ordering is the
/// whole design: an accident detected in a tunnel, a basement car park or a
/// rural area with no signal must still exist on the phone the moment it is
/// detected, because it is the only copy anyone will ever have. Attempting the
/// network call first would mean the record exists only if the network
/// cooperated — losing precisely the accidents that happen where there is no
/// coverage.
///
/// [recordAccident] returns as soon as step 2 completes. Step 3 is fire and
/// forget, drained by [SyncOutboxUseCase] on reconnect.
///
/// ## Idempotence
///
/// The protocol retransmits events (§8), and the outbox retries, so the same
/// accident can be submitted many times. Three layers stop that becoming
/// duplicate records:
///
/// 1. [seenEventIds] de-duplicates in-flight BLE events by `(eventId, type)`;
/// 2. the outbox table has `UNIQUE(accident_id)` and `INSERT OR IGNORE`s;
/// 3. the Firestore write uses `set()` on an explicit document id, never
///    `add()`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/telemetry.dart';
import '../datasources/firestore_datasource.dart';
import '../datasources/local_datasource.dart';
import '../mappers/json_mappers.dart';

/// How an accident was detected.
enum AccidentSource {
  /// The fused sensor detector fired.
  auto('AUTO'),

  /// The physical SOS button on the node.
  manualSos('MANUAL_SOS'),

  /// The user pressed SOS in the app.
  appSos('APP_SOS'),

  /// A drill from the settings screen.
  test('TEST');

  const AccidentSource(this.wireName);
  final String wireName;
}

/// A live alert the app is currently handling.
@immutable
class PendingAlert {
  const PendingAlert({
    required this.record,
    required this.confirmWindowSec,
    required this.receivedAt,
    this.eventId,
  });

  final AccidentRecord record;
  final int confirmWindowSec;
  final DateTime receivedAt;

  /// The device-side event id, used to send CONFIRM/CANCEL for the right event.
  final String? eventId;

  /// When the countdown expires.
  DateTime deadlineAt(DateTime now) =>
      receivedAt.add(Duration(seconds: confirmWindowSec));

  /// Seconds left, never negative.
  int remainingSec(DateTime now) {
    final int s = deadlineAt(now).difference(now).inSeconds;
    return s < 0 ? 0 : s;
  }

  /// Progress in `0..1` for a countdown ring; 1 means "just fired".
  double progress(DateTime now) {
    final int total = confirmWindowSec <= 0 ? 1 : confirmWindowSec;
    return (1 - remainingSec(now) / total).clamp(0.0, 1.0);
  }
}

/// Persists accidents and drains the outbox.
class AccidentRepository {
  AccidentRepository({
    required LocalDatasource local,
    required FirestoreDatasource firestore,
    AppLogger? log,
    DateTime Function()? clock,
  })  : _local = local,
        _firestore = firestore,
        _log = log ?? AppLogger(),
        _clock = clock ?? DateTime.now;

  final LocalDatasource _local;
  final FirestoreDatasource _firestore;
  final AppLogger _log;
  final DateTime Function() _clock;

  /// De-duplication set for in-flight device events.
  ///
  /// Bounded because it only needs to cover the retry window (§8 tops out at
  /// three retries over ~6 s), not the whole drive. An unbounded set would be a
  /// slow memory leak in a car that is left on for hours.
  final Set<String> seenEventIds = <String>{};

  final StreamController<PendingAlert> _alerts =
      StreamController<PendingAlert>.broadcast();
  final StreamController<int> _pendingCount =
      StreamController<int>.broadcast();

  /// A new alert is pending a decision.
  Stream<PendingAlert> get alerts => _alerts.stream;

  /// Number of accidents still queued for upload.
  Stream<int> get pendingUploadCount => _pendingCount.stream;

  AccidentRecord? _current;

  /// The accident currently being handled, if any.
  AccidentRecord? get current => _current;

  /// Whether a BLE event has already been acted on.
  ///
  /// Keyed `type:eventId` so a device that reuses ids for different event
  /// types cannot cause a false duplicate.
  bool isDuplicate({required String? eventId, required String type}) {
    if (eventId == null || eventId.isEmpty) return false;
    return seenEventIds.contains('$type:$eventId');
  }

  /// Remember an event as handled.
  void markEventSeen({required String? eventId, required String type}) {
    if (eventId == null || eventId.isEmpty) return;
    seenEventIds.add('$type:$eventId');
    if (seenEventIds.length > 512) {
      // Drop the oldest half. `Set` preserves insertion order, so this evicts
      // the most stale entries, which are exactly the ones outside any retry
      // window.
      final List<String> keys = seenEventIds.toList(growable: false);
      seenEventIds
        ..clear()
        ..addAll(keys.sublist(keys.length ~/ 2));
    }
  }

  /// Record an accident. **Local write first, always.**
  ///
  /// Returns as soon as the record is durable locally. The cloud upload is
  /// attempted afterwards and retried by the sync job; its outcome is exposed
  /// through [pendingUploadCount] rather than being allowed to fail this call,
  /// because the user needs the record recorded *now* and the cloud is strictly
  /// secondary.
  Future<Result<AccidentRecord>> recordAccident({
    required GeoPoint location,
    AccidentSource source = AccidentSource.auto,
    String? deviceId,
    double impactG = 0,
    int? impactScore,
    int confirmWindowSec = 10,
    String? eventId,
  }) async {
    final DateTime now = _clock().toUtc();
    final String userId = _firestore.currentUserId ?? 'anonymous';
    final String id = eventId == null || eventId.isEmpty
        ? 'acc-${now.millisecondsSinceEpoch}'
        : 'acc-$eventId';

    final AccidentRecord record = AccidentRecord(
      id: id,
      userId: userId,
      deviceId: deviceId,
      location: location,
      occurredAt: now,
      impactValue: impactG,
      impactG: impactG == 0 ? null : impactG,
      impactScore: impactScore,
      // MANUAL_SOS skips the countdown: a human pressed the button, so asking
      // them to confirm their own SOS is insulting and costs 10 seconds.
      status: source == AccidentSource.manualSos
          ? AccidentStatus.confirmed
          : AccidentStatus.detected,
      detectedDeviceState: DeviceState.alarm.name,
      isSynced: false,
    );

    // ---- step 2: durable local write, first and unconditional ----
    final Result<int> queued = await _local.enqueue(
      accidentId: record.id,
      payload: _documentFor(record),
      now: now,
    );

    if (queued is FailureResult<int>) {
      // A storage failure here is severe: the record exists nowhere. Return the
      // failure rather than pretending, so the UI can tell the user their phone
      // is out of space instead of losing the accident silently.
      _log.log(
        LogLevel.error,
        'accident',
        'local write failed — the record is only in memory',
        queued.failureOrNull,
      );
      return FailureResult<AccidentRecord>(
        failureOf(
          FailureKind.storage,
          'Could not save the accident on this phone',
          detail: 'Free some storage and report it again.',
          cause: queued.failureOrNull,
        ),
      );
    }

    _current = record;
    unawaited(_publish(record));
    unawaited(_emitPendingCount());
    markEventSeen(eventId: eventId, type: source.wireName);

    if (_alerts.hasListener) {
      _alerts.add(
        PendingAlert(
          record: record,
          confirmWindowSec: confirmWindowSec,
          receivedAt: now,
          eventId: eventId,
        ),
      );
    }
    _log.log(LogLevel.info, 'accident', 'recorded $id (${source.wireName})');
    return Ok<AccidentRecord>(record);
  }

  /// Attempt the cloud write for [record]. Retries are the outbox's job.
  Future<void> _publish(AccidentRecord record) async {
    final Result<void> written = await _firestore.writeAccident(record);
    if (written.isOk) return;
    // Left in the outbox; the sync job will pick it up. Nothing to repair here.
    _log.log(
      LogLevel.info,
      'accident',
      '${record.id} queued for retry: ${written.failureOrNull}',
    );
  }

  /// Promote the current accident to [status], updating the queued payload too.
  ///
  /// The status change is written back into the outbox row, so an accident
  /// uploaded *after* it was resolved carries `RESOLVED`, not `DETECTED`.
  /// Otherwise a slow connection would resurrect a closed incident in the
  /// cloud — a genuinely alarming failure mode for an emergency system.
  Future<Result<AccidentRecord>> transition(AccidentStatus status) async {
    final AccidentRecord? current = _current;
    if (current == null) {
      return FailureResult<AccidentRecord>(
        failureOf(FailureKind.validation, 'There is no accident in progress'),
      );
    }
    if (current.status == status) return Ok<AccidentRecord>(current);
    if (!current.status.canTransitionTo(status)) {
      return FailureResult<AccidentRecord>(
        failureOf(
          FailureKind.validation,
          'Cannot move an accident from ${current.status.wireName} to ${status.wireName}',
        ),
      );
    }

    final DateTime now = _clock().toUtc();
    final AccidentRecord next = current.withStatus(status, now: now);
    _current = next;

    // Best-effort local rewrite; the cloud copy is updated by [publish] below.
    await _local.enqueue(
      accidentId: next.id,
      payload: _documentFor(next),
      now: now,
    );
    await _firestore.writeAccident(next);
    _log.log(LogLevel.info, 'accident', '${next.id} -> ${status.wireName}');
    return Ok<AccidentRecord>(next);
  }

  /// Confirm a false alarm's counterpart: the user is hurt.
  Future<Result<AccidentRecord>> confirm() => transition(AccidentStatus.confirmed);

  /// Dismiss a false alarm.
  Future<Result<AccidentRecord>> cancel() => transition(AccidentStatus.cancelled);

  /// Mark the alert as dispatched.
  Future<Result<AccidentRecord>> markAlertSent() => transition(AccidentStatus.alertSent);

  /// Record that [contact] was notified, so a retry cannot re-notify them.
  Future<Result<AccidentRecord>> notifyContact(EmergencyContact contact) async {
    final AccidentRecord? current = _current;
    if (current == null) {
      return FailureResult<AccidentRecord>(
        failureOf(FailureKind.validation, 'There is no accident in progress'),
      );
    }
    final AccidentRecord next = current.withNotifiedContact(contact);
    _current = next;
    await _firestore.writeAccident(next);
    return Ok<AccidentRecord>(next);
  }

  /// Which contacts still need telling.
  List<EmergencyContact> pendingContacts(List<EmergencyContact> all) =>
      all.where((EmergencyContact c) => _current?.needsNotificationOf(c) ?? true).toList(growable: false);

  /// Clear the in-progress accident.
  void clearCurrent() => _current = null;

  /// Drain the outbox.
  ///
  /// Bounded per call (20 entries) so a large backlog is drained over several
  /// ticks rather than in one burst that would starve the UI thread. Stops at
  /// the first failure so a genuinely offline device does not burn its whole
  /// battery attempting 20 doomed uploads.
  Future<Result<int>> syncOutbox() async {
    final DateTime now = _clock().toUtc();
    final Result<List<OutboxEntry>> due = await _local.dueEntries(now: now, limit: 20);
    if (due case final FailureResult<List<OutboxEntry>> failure) {
      return FailureResult<int>(failure.failure);
    }

    int delivered = 0;
    for (final OutboxEntry entry in due.valueOrNull ?? const <OutboxEntry>[]) {
      final bool ok = await _deliver(entry);
      if (!ok) break;
      delivered++;
    }
    await _emitPendingCount();
    return Ok<int>(delivered);
  }

  /// Try to publish one queued entry.
  Future<bool> _deliver(OutboxEntry entry) async {
    final String? userId = _firestore.currentUserId;
    if (userId == null) {
      await _local.markFailed(entry.id, error: 'not signed in', now: _clock().toUtc());
      return false;
    }
    final Result<void> written = await _firestore.writeAccident(
      _recordFrom(entry, userId),
    );
    if (written.isOk) {
      await _local.markDelivered(entry.id);
      _log.log(LogLevel.info, 'sync', 'uploaded ${entry.accidentId}');
      return true;
    }
    await _local.markFailed(
      entry.id,
      error: '${written.failureOrNull}',
      now: _clock().toUtc(),
    );
    return false;
  }

  /// Rebuild an [AccidentRecord] from a queued document.
  ///
  /// Round-trips through the JSON document rather than keeping a second copy in
  /// memory: a queue entry is often delivered much later — possibly after a
  /// restart — so it has to be reconstructible from what is on disk alone.
  AccidentRecord _recordFrom(OutboxEntry entry, String userId) {
    final Map<String, Object?> doc = jsonDecode(entry.payload) as Map<String, Object?>;
    final GeoPoint? point = GeoPointMapper.fromJson(
      doc,
      timestamp: DateTime.tryParse(doc.stringOrNull('timestamp') ?? '')?.toUtc() ??
          entry.createdAt,
    );
    return AccidentRecord(
      id: entry.accidentId,
      userId: doc.stringOrNull('userId') ?? userId,
      deviceId: doc.textOrNull('deviceId'),
      location: point ??
          GeoPoint(
            latitude: 0,
            longitude: 0,
            accuracyM: 9999,
            timestamp: entry.createdAt,
          ),
      occurredAt: entry.createdAt,
      impactValue: doc.doubleOrNull('impactValue') ?? 0,
      status: AccidentStatus.fromNameOrUnknown(doc.stringOrNull('status')),
      notifiedContactIds: doc.stringList('notifiedContactIds'),
      isSynced: true,
    );
  }

  /// The document written to both the outbox and Firestore.
  static Map<String, Object?> _documentFor(AccidentRecord record) =>
      <String, Object?>{
        'userId': record.userId,
        'latitude': record.location.latitude,
        'longitude': record.location.longitude,
        'accuracy': record.location.accuracyM,
        'timestamp': record.occurredAt.toUtc().toIso8601String(),
        'impactValue': record.impactValue,
        'status': record.status.wireName,
        'deviceId': record.deviceId,
        'notifiedContactIds': record.notifiedContactIds,
      };

  Future<void> _emitPendingCount() async {
    final Result<int> count = await _local.pendingCount();
    final int? pending = count.valueOrNull;
    if (pending != null && _pendingCount.hasListener) {
      _pendingCount.add(pending);
    }
  }

  /// Accidents stored in the cloud, newest first.
  Stream<List<AccidentRecord>> watchHistory({int limit = 50}) =>
      _firestore.watchAccidents(limit: limit);

  Future<void> dispose() async {
    await _alerts.close();
    await _pendingCount.close();
  }
}
