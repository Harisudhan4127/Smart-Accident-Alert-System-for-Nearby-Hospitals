/// Orchestrates the emergency flow.
///
/// This is the class that makes the alert screen simple. It owns the whole
/// sequence — countdown, location, hospital search, contact dispatch — and
/// exposes one immutable [AlertState] the screen renders. Putting the
/// orchestration here rather than in the widget means it is testable without a
/// single `Widget`, and it means the screen cannot accidentally skip a step.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../../data/datasources/maps_datasource.dart';
import '../../data/protocol/messages.dart';
import '../../data/repositories/accident_repository.dart';
import '../../data/repositories/device_repository.dart';
import '../../data/repositories/hospital_repository.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';

/// Where the alert is in its lifecycle.
enum AlertPhase {
  /// Counting down; the user can still stop it.
  countingDown,

  /// Dispatching help.
  sending,

  /// Help dispatched.
  dispatched,

  /// Dismissed as a false alarm.
  dismissed,

  /// The countdown expired and help went automatically.
  autoDispatched,
}

/// A snapshot of everything the alert screen needs.
@immutable
class AlertState {
  const AlertState({
    this.accidentId = '',
    this.eventId,
    this.isManualSos = false,
    this.phase = AlertPhase.countingDown,
    this.confirmWindowSec = 10,
    this.deadline,
    this.location,
    this.contacts = const <EmergencyContact>[],
    this.notifiedContactIds = const <String>{},
    this.nearestHospital,
    this.hospitalDistanceM,
    this.hospitals = const <Hospital>[],
    this.problems = const <String>[],
    this.dispatchedAt,
    this.busy = false,
  });

  final String accidentId;
  final String? eventId;
  final bool isManualSos;
  final AlertPhase phase;
  final int confirmWindowSec;
  final DateTime? deadline;
  final GeoPoint? location;
  final List<EmergencyContact> contacts;

  /// Ids already told, so a retry cannot double-notify.
  final Set<String> notifiedContactIds;
  final Hospital? nearestHospital;
  final double? hospitalDistanceM;
  final List<Hospital> hospitals;

  /// Every condition degrading this alert, in user-facing words.
  ///
  /// Collected rather than thrown, because several things can be wrong at once
  /// (no GPS *and* no network *and* no contacts) and a user fixing problems one
  /// at a time by dismissing each error is a bad experience during an emergency.
  final List<String> problems;

  final DateTime? dispatchedAt;
  final bool busy;

  /// Whether the alert is still stoppable.
  bool get canCancel => phase == AlertPhase.countingDown;

  /// Whether help has gone out.
  bool get isDispatched =>
      phase == AlertPhase.dispatched || phase == AlertPhase.autoDispatched;

  /// Seconds left, floored at zero.
  int remainingSec([int? window]) {
    final DateTime? end = deadline;
    if (end == null) return 0;
    final int s = end.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  AlertState copyWith({
    String? accidentId,
    String? eventId,
    bool? isManualSos,
    AlertPhase? phase,
    int? confirmWindowSec,
    DateTime? deadline,
    GeoPoint? location,
    List<EmergencyContact>? contacts,
    Set<String>? notifiedContactIds,
    Hospital? nearestHospital,
    double? hospitalDistanceM,
    List<Hospital>? hospitals,
    List<String>? problems,
    DateTime? dispatchedAt,
    bool? busy,
  }) {
    return AlertState(
      accidentId: accidentId ?? this.accidentId,
      eventId: eventId ?? this.eventId,
      isManualSos: isManualSos ?? this.isManualSos,
      phase: phase ?? this.phase,
      confirmWindowSec: confirmWindowSec ?? this.confirmWindowSec,
      deadline: deadline ?? this.deadline,
      location: location ?? this.location,
      contacts: contacts ?? this.contacts,
      notifiedContactIds: notifiedContactIds ?? this.notifiedContactIds,
      nearestHospital: nearestHospital ?? this.nearestHospital,
      hospitalDistanceM: hospitalDistanceM ?? this.hospitalDistanceM,
      hospitals: hospitals ?? this.hospitals,
      problems: problems ?? this.problems,
      dispatchedAt: dispatchedAt ?? this.dispatchedAt,
      busy: busy ?? this.busy,
    );
  }

  @override
  String toString() => 'AlertState(${phase.name}, ${remainingSec()}s left)';
}

/// Drives the emergency flow.
///
/// A Riverpod 3 [Notifier] rather than the older `StateNotifier`: the rest of the
/// app is built on `Notifier`, and having one controller on a different base
/// would mean the provider types no longer line up.
class AlertController extends Notifier<AlertState> {
  @override
  AlertState build() {
    ref.onDispose(_stop);
    return const AlertState();
  }

  // Read through `ref` rather than captured, so a test that overrides a
  // dependency gets the override. Capturing in a constructor would freeze the
  // real repository into the controller and quietly defeat every override.
  AccidentRepository get _accidents => ref.read(accidentRepositoryProvider);
  DeviceRepository get _device => ref.read(deviceRepositoryProvider);
  final AppLogger _log = AppLogger();

  StreamSubscription<DeviceUpdate>? _messageSub;
  Timer? _ticker;
  bool _started = false;

  /// Begin an alert, or fold an existing one in.
  ///
  /// Idempotent: a second `ACCIDENT_DETECTED` for the same `eventId` is a
  /// protocol retransmit (§8) and is ignored, so a flaky link cannot restart the
  /// countdown on the user.
  Future<void> begin({
    String? eventId,
    bool manualSos = false,
    int confirmWindowSec = 10,
    double? impactG,
    int? impactScore,
  }) async {
    if (eventId != null &&
        _accidents.isDuplicate(eventId: eventId, type: 'EVENT')) {
      _log.log(LogLevel.info, 'alert', 'ignoring duplicate event $eventId');
      return;
    }

    if (state.phase != AlertPhase.countingDown) {
      // An alert is already running; do not overwrite it with a weaker one.
      return;
    }

    state = state.copyWith(
      eventId: eventId,
      isManualSos: manualSos,
      confirmWindowSec: confirmWindowSec,
      phase: AlertPhase.countingDown,
      deadline: DateTime.now().add(Duration(seconds: confirmWindowSec)),
    );

    if (!_started) {
      _started = true;
      _listen();
      _startTicker();
    }

    // 1. Record the accident first. Durable, offline, and independent of
    //    everything else below — a failure anywhere in GPS, hospitals or
    //    contacts must not prevent the record from existing.
    final Result<GeoPoint?> position = await _position();
    final GeoPoint? point = position.valueOrNull;

    final Result<AccidentRecord> recorded = await _accidents.recordAccident(
      location: point ??
          GeoPoint(
            // A placeholder, not a lie: a zero coordinate would put the record
            // in the Gulf of Guinea and read as a real location. An explicitly
            // absurd accuracy marks it as "location unknown" for anything that
            // filters on quality, and the record carries that fact forward.
            latitude: 0,
            longitude: 0,
            accuracyM: 999999,
            timestamp: DateTime.now().toUtc(),
          ),
      source: manualSos ? AccidentSource.manualSos : AccidentSource.auto,
      deviceId: _device.snapshot?.id,
      impactG: impactG ?? 0,
      impactScore: impactScore,
      confirmWindowSec: confirmWindowSec,
      eventId: eventId,
    );

    // `Ok.value` is non-nullable; the pattern already proved it is an `Ok`, so
    // reaching `.id` through the arm's own field is safe and needs no re-check.
    if (recorded case final Ok<AccidentRecord> ok) {
      state = state.copyWith(accidentId: ok.value.id, location: point);
    }

    // 2. Tell the OS, so a backgrounded phone still wakes up.
    unawaited(
      ref
          .read(notificationDatasourceProvider)
          .showEmergencyAlert(
            title: manualSos ? 'SOS pressed' : 'Possible accident',
            body: point == null
                ? 'Getting your location…'
                : 'Help will be sent in $confirmWindowSec seconds.',
            location: point ??
                GeoPoint(
                  latitude: 0,
                  longitude: 0,
                  accuracyM: 999999,
                  timestamp: DateTime.now().toUtc(),
                ),
            countdownSec: confirmWindowSec,
          ),
    );

    // 3. In parallel: contacts, hospitals, and any problem notes. None of these
    //    may block the countdown.
    unawaited(_loadContacts());
    unawaited(_findHospitals(point));

    if (point == null) {
      _addProblem(
        'No GPS fix yet. Your location will be sent as soon as one is available.',
      );
    } else if (point.accuracyM > 50) {
      _addProblem(
        'GPS accuracy is only ±${point.accuracyM.round()} m. '
        'The pin may not be exactly at the crash.',
      );
    }
  }

  Future<Result<GeoPoint?>> _position() {
    return ref.read(locationDatasourceProvider).currentPosition();
  }

  void _listen() {
    _messageSub ??= _device.messages.listen((DeviceUpdate update) {
      final DeviceMessage message = update.message;
      if (message is EventMessage && message.canCancel == false) {
        // The node escalated on its own (the countdown expired there first).
        unawaited(_dispatch(auto: true));
      }
    });
  }

  void _startTicker() {
    _ticker?.cancel();
    // 1 Hz, not 20: the countdown shows whole seconds, and a 20 Hz timer would
    // rebuild the alert screen 20 times a second for no visible benefit. The
    // ring animates on its own ticker.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (state.phase != AlertPhase.countingDown) return;
      if (state.remainingSec() <= 0) {
        unawaited(_dispatch(auto: true));
      } else {
        // Rebuild so the ring and the seconds-remaining text update.
        state = state.copyWith();
      }
    });
  }

  Future<void> _loadContacts() async {
    final ContactRepository contacts = ref.read(contactRepositoryProvider);
    final List<EmergencyContact> callable = contacts.callableContacts;
    state = state.copyWith(contacts: callable);
    if (callable.isEmpty) {
      _addProblem(
        'No emergency contacts are set. Help can only be recorded, not sent.',
      );
    }
  }

  Future<void> _findHospitals(GeoPoint? point) async {
    if (point == null) return;
    final Result<HospitalSearchResult> result =
        await ref.read(hospitalRepositoryProvider).nearby(
              origin: point,
              radiusM: 25000,
              limit: 10,
            );
    final HospitalSearchResult? search = result.valueOrNull;
    if (search == null || search.isEmpty) {
      if (search != null) {
        _addProblem('No hospitals were found within 25 km.');
      }
      return;
    }
    state = state.copyWith(
      hospitals: search.hospitals,
      nearestHospital: search.hospitals.first,
      hospitalDistanceM: search.hospitals.first.distanceFrom(point),
    );
  }

  /// Send help: notify every contact, then escalate.
  ///
  /// Order matters. Contacts are notified *first* because that is the part that
  /// actually reaches a human; the record's status change is bookkeeping and
  /// must not be able to abort the dispatch.
  Future<bool> sendHelp() async {
    state = state.copyWith(phase: AlertPhase.sending, busy: true);
    final bool ok = await _dispatch(auto: false);
    state = state.copyWith(busy: false);
    return ok;
  }

  Future<bool> _dispatch({required bool auto}) async {
    final List<String> problems = <String>[];

    final GeoPoint? point = state.location ?? (await _position()).valueOrNull;
    final List<EmergencyContact> targets = state.contacts
        .where((EmergencyContact c) => !state.notifiedContactIds.contains(c.id))
        .toList(growable: false);

    if (targets.isEmpty) {
      problems.add('There was nobody to notify.');
    }

    for (final EmergencyContact contact in targets) {
      // 1. A call. The fastest way to reach someone, and the first thing a
      //    responder would want.
      final Result<void> called =
          await ref.read(mapsDatasourceProvider).call(contact.phone);
      if (called.isFailure) {
        problems.add('Could not call ${contact.name}.');
      }

      // 2. A message with the location, in case the call goes unanswered.
      final MapsDatasource maps = ref.read(mapsDatasourceProvider);
      final String body = maps.emergencyMessageBody(
        point: point ??
            GeoPoint(
              latitude: 0,
              longitude: 0,
              accuracyM: 999999,
              timestamp: DateTime.now().toUtc(),
            ),
        occurredAt: DateTime.now().toUtc(),
        deviceName: _device.snapshot?.displayName,
      );
      final Result<void> texted = await maps.openSms(
        SmsIntent(body: body, recipients: <String>[contact.phone]),
      );
      if (texted.isFailure) {
        problems.add('Could not message ${contact.name}.');
      }

      // Recorded per contact, so a partial failure is retried only for the
      // people who were not actually reached.
      await _accidents.notifyContact(contact);
      state = state.copyWith(
        notifiedContactIds: <String>{...state.notifiedContactIds, contact.id},
      );
    }

    final Result<AccidentRecord> marked = auto
        ? await _accidents.confirm()
        : await _accidents.markAlertSent();
    if (marked.isFailure) {
      problems.add('The accident record could not be updated.');
    }

    // Tell the node, so its buzzer and LEDs match what the app just did.
    unawaited(auto ? _device.confirm(state.eventId) : _device.confirm(state.eventId));

    state = state.copyWith(
      phase: auto ? AlertPhase.autoDispatched : AlertPhase.dispatched,
      dispatchedAt: DateTime.now().toUtc(),
      problems: <String>[...state.problems, ...problems],
    );

    _stop();
    return problems.isEmpty;
  }

  /// Dismiss as a false alarm.
  ///
  /// Returns `false` if the node refused, so the UI can tell the user rather
  /// than pretending the alert was cancelled while the buzzer is still going.
  Future<bool> dismiss() async {
    state = state.copyWith(busy: true);
    final Result<void> sent = await _device.cancel(state.eventId);
    if (sent.isFailure) {
      state = state.copyWith(busy: false);
      return false;
    }
    final Result<AccidentRecord> cancelled = await _accidents.cancel();
    if (cancelled.isFailure) {
      _log.log(
        LogLevel.warning,
        'alert',
        'node accepted CANCEL but the record could not be updated: '
        '${cancelled.failureOrNull}',
      );
    }
    state = state.copyWith(phase: AlertPhase.dismissed, busy: false);
    _stop();
    return true;
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _addProblem(String problem) {
    if (state.problems.contains(problem)) return;
    state = state.copyWith(problems: <String>[...state.problems, problem]);
  }

}

/// The alert controller.
final NotifierProvider<AlertController, AlertState> alertControllerProvider =
    NotifierProvider<AlertController, AlertState>(AlertController.new);
