/// The accident record — the app's central domain entity.
///
/// This is the join between three sources that know different things:
///
/// * the node detected something (`EVENT`, §6.6) and knows *what* it felt;
/// * the phone knows *where* and *who* (GPS, Firebase Auth, paired devices);
/// * the user decides whether to escalate (the confirm countdown, §7).
///
/// The `status` here is the app's own lifecycle from §18 of the project plan,
/// and it is deliberately **not** the node's `DeviceState`. They are two clocks
/// running in parallel: the node can be re-armed and idle again while a phone
/// is still showing an unresolved alert, because a crash in a tunnel with no
/// signal is exactly the case that matters most. Collapsing the two would make
/// "alert resolved" depend on BLE staying connected, which is the wrong
/// dependency for a safety feature.
library;

import 'geo_point.dart';

/// The accident lifecycle from §18 of the project plan.
///
/// ```text
/// DETECTED ─┬─ CANCELLED
///           └─ CONFIRMED ── ALERT_SENT ── RESOLVED
/// ```
///
/// [fromName] reads the Firestore string; [canTransitionTo] is the single
/// source of truth for the arrows above, so no screen has to re-derive them and
/// a rule change cannot drift between the alert sheet and the history list.
enum AccidentStatus {
  /// The node reported a possible impact and the phone is showing the countdown.
  ///
  /// Also the state of a record the app has not yet heard about, in one
  /// direction: a node that detects while the app is closed is written as
  /// `DETECTED` and picked up on next sync.
  detected('DETECTED'),

  /// The user dismissed the countdown. Terminal.
  cancelled('CANCELLED'),

  /// The user confirmed it. The alert has not been sent yet.
  confirmed('CONFIRMED'),

  /// Emergency contacts have been notified. This is the state the UI is really
  /// about: once someone has been called, the record must not disappear.
  alertSent('ALERT_SENT'),

  /// Handled. Terminal.
  resolved('RESOLVED'),

  /// A status this build does not recognise, from a newer app version.
  ///
  /// A real member rather than a silent remap onto one of the five above. Both
  /// plausible remaps are dangerous: folding an unknown status into [detected]
  /// re-opens a countdown for a record that may have been closed hours ago, and
  /// folding it into [resolved] hides a live alert. Terminal and inert is the
  /// only safe reading — nothing prompts, nothing is sent, and the record still
  /// renders so the user can see that something is off.
  unknown('UNKNOWN');

  const AccidentStatus(this.wireName);

  /// The exact string stored in Firestore and shown in the history list.
  final String wireName;

  /// The status a new record starts in.
  static const AccidentStatus initial = AccidentStatus.detected;

  /// Parses [name] case-insensitively, or returns `null` when unknown.
  ///
  /// Returns `null` rather than throwing: a status written by a newer app
  /// version must not take down the history list, and [fromNameOrUnknown]
  /// exists for the callers that need a value.
  static AccidentStatus? fromName(String? name) {
    if (name == null) {
      return null;
    }
    final String upper = name.trim().toUpperCase();
    for (final AccidentStatus status in AccidentStatus.values) {
      if (status.wireName == upper) {
        return status;
      }
    }
    return null;
  }

  /// Like [fromName], but never `null`: an unrecognised or missing status
  /// becomes [unknown].
  static AccidentStatus fromNameOrUnknown(Object? name) =>
      fromName(name is String ? name : null) ?? unknown;

  /// Whether the plan's state machine allows `this → next`.
  ///
  /// [cancelled] and [resolved] are terminal; [detected] can only be cancelled
  /// or confirmed; [alertSent] can only be resolved. A false here means the
  /// transition is a bug or a replay, and [AccidentRecord.withStatus] will
  /// refuse it.
  bool canTransitionTo(AccidentStatus next) {
    if (this == next) {
      return false;
    }
    return switch (this) {
      AccidentStatus.detected =>
        next == AccidentStatus.cancelled || next == AccidentStatus.confirmed,
      AccidentStatus.confirmed => next == AccidentStatus.alertSent,
      AccidentStatus.alertSent => next == AccidentStatus.resolved,
      AccidentStatus.cancelled ||
      AccidentStatus.resolved ||
      AccidentStatus.unknown =>
        false,
    };
  }

  /// Whether no further transition is possible.
  bool get isTerminal =>
      this == AccidentStatus.cancelled ||
      this == AccidentStatus.resolved ||
      this == AccidentStatus.unknown;

  /// Whether the user still has something to decide.
  ///
  /// Only [detected] is actionable. In particular [confirmed] is *not*:
  /// escalating to `ALERT_SENT` is the app's job, not the user's, and a UI that
  /// showed a "Send alert" button at that point would let one person dispatch
  /// an ambulance twice.
  bool get needsUserDecision => this == AccidentStatus.detected;
}

/// Thrown by [AccidentRecord.withStatus] for a transition §18 does not allow.
///
/// A domain exception, deliberately not a `Result`: the transition table is
/// programming-level truth, and a caller asking for an illegal transition has a
/// bug that a `Failure` return would only invite it to ignore. Repositories
/// catch it at the boundary.
final class InvalidStatusTransition implements Exception {
  /// Creates the exception for a refused [from] → [to] move.
  const InvalidStatusTransition(this.from, this.to);

  /// The status the record was in.
  final AccidentStatus from;

  /// The status that was requested.
  final AccidentStatus to;

  @override
  String toString() =>
      'InvalidStatusTransition: ${from.wireName} -> ${to.wireName} '
      'is not allowed by the §18 state machine';
}

/// One emergency contact from the user's profile (§17).
final class EmergencyContact {
  /// Creates a contact.
  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
    this.relationship,
  });

  /// Stable identifier, local to the user's profile.
  final String id;

  /// Display name, e.g. `Anitha`.
  final String name;

  /// Phone number in whatever form the user typed; formatting is a UI concern.
  final String phone;

  /// Free-text relationship, e.g. `spouse`. Shown as a subtitle when present.
  final String? relationship;

  /// Whether this is usable as a dialled number.
  bool get isCallable => phone.replaceAll(RegExp(r'[^\d+]'), '').isNotEmpty;

  /// A copy with the given fields replaced.
  EmergencyContact copyWith({
    String? id,
    String? name,
    String? phone,
    String? relationship,
  }) =>
      EmergencyContact(
        id: id ?? this.id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        relationship: relationship ?? this.relationship,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmergencyContact &&
          other.id == id &&
          other.name == name &&
          other.phone == phone &&
          other.relationship == relationship;

  @override
  int get hashCode => Object.hash(id, name, phone, relationship);

  @override
  String toString() => 'EmergencyContact($id, $name)';
}

/// An accident as the app stores it: one row in the `accidents` collection
/// (§17), enriched with the node's own reading of the impact.
///
/// Immutable, so a record can be handed to a countdown dialog, a notification
/// builder and a Firestore write at the same time without any of them being
/// able to change what the others see.
final class AccidentRecord {
  /// Creates a record.
  ///
  /// [occurredAt] is when the node detected the impact, not when the app
  /// received it: an alert that sat in the outbox for four minutes still has to
  /// show the right time in the SMS.
  const AccidentRecord({
    required this.id,
    required this.userId,
    required this.location,
    required this.occurredAt,
    required this.impactValue,
    this.deviceId,
    this.status = AccidentStatus.initial,
    this.impactG,
    this.impactScore,
    this.detectedDeviceState,
    this.confirmedAt,
    this.alertSentAt,
    this.resolvedAt,
    this.cancelledAt,
    this.hospitalId,
    this.hospitalName,
    this.notifiedContactIds = const <String>[],
    this.isSynced = false,
  });

  /// Client-generated identifier.
  ///
  /// Generated on the phone *before* the write is queued, so a record that is
  /// created while offline keeps the same id when it finally syncs and does not
  /// duplicate on the next app start.
  final String id;

  /// The Firebase Auth uid of the owner.
  final String userId;

  /// The paired node that reported it, when known.
  final String? deviceId;

  /// Where the accident happened.
  final GeoPoint location;

  /// When the node detected the impact.
  final DateTime occurredAt;

  /// The plan's single `impactValue` scalar, in g.
  ///
  /// Kept because §17 names it and the emergency SMS needs one number without
  /// understanding the node's telemetry; [impactG] is the same reading with its
  /// provenance, and the two are set from the same source.
  final double impactValue;

  /// Impact magnitude in g, when the node reported one (§6.6 `impact.magG`).
  final double? impactG;

  /// The node's 0–100 confidence score, when it reported one.
  final int? impactScore;

  /// The node's state at detection, for the audit trail.
  ///
  /// Nullable rather than defaulted: "the app guessed `PENDING`" and "the node
  /// said `PENDING`" are different facts, and only the second is evidence.
  final String? detectedDeviceState;

  /// The §18 lifecycle position.
  final AccidentStatus status;

  /// When the user confirmed, if they did.
  final DateTime? confirmedAt;

  /// When the last contact was notified.
  final DateTime? alertSentAt;

  /// When the record was closed out.
  final DateTime? resolvedAt;

  /// When the user dismissed the countdown.
  final DateTime? cancelledAt;

  /// The hospital the user sent this to, if any.
  final String? hospitalId;

  /// The hospital's name, denormalised.
  ///
  /// Kept on the record so a history entry can render without a second read;
  /// `hospitals/{id}` is the authority if the two ever disagree.
  final String? hospitalName;

  /// Ids of the [EmergencyContact]s already notified, so a retry cannot
  /// re-notify someone and a resumed sync cannot double-dial.
  final List<String> notifiedContactIds;

  /// Whether this record exists in Firestore yet.
  ///
  /// False for everything still sitting in the outbox. The UI uses it to show a
  /// "pending sync" marker; nothing else should care.
  final bool isSynced;

  /// Whether the user still has to confirm or cancel.
  bool get needsUserDecision => status.needsUserDecision;

  /// Whether anyone has actually been told.
  bool get hasAlerted =>
      status == AccidentStatus.alertSent || status == AccidentStatus.resolved;

  /// Whether the location is good enough to send to a hospital.
  ///
  /// §4 of the plan wants an accuracy figure on the record; a fix with 500 m of
  /// error is still worth sending, but the UI must say so rather than implying
  /// a precise pin.
  bool get isLocationPrecise => location.accuracyM <= 50;

  /// A copy with the given fields replaced.
  ///
  /// A `null` argument means "keep the current value", so this cannot clear a
  /// nullable field. [clear] exists for the one case that needs it.
  AccidentRecord copyWith({
    String? id,
    String? userId,
    String? deviceId,
    GeoPoint? location,
    DateTime? occurredAt,
    double? impactValue,
    double? impactG,
    int? impactScore,
    String? detectedDeviceState,
    AccidentStatus? status,
    DateTime? confirmedAt,
    DateTime? alertSentAt,
    DateTime? resolvedAt,
    DateTime? cancelledAt,
    String? hospitalId,
    String? hospitalName,
    List<String>? notifiedContactIds,
    bool? isSynced,
  }) =>
      AccidentRecord(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        deviceId: deviceId ?? this.deviceId,
        location: location ?? this.location,
        occurredAt: occurredAt ?? this.occurredAt,
        impactValue: impactValue ?? this.impactValue,
        impactG: impactG ?? this.impactG,
        impactScore: impactScore ?? this.impactScore,
        detectedDeviceState: detectedDeviceState ?? this.detectedDeviceState,
        status: status ?? this.status,
        confirmedAt: confirmedAt ?? this.confirmedAt,
        alertSentAt: alertSentAt ?? this.alertSentAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        cancelledAt: cancelledAt ?? this.cancelledAt,
        hospitalId: hospitalId ?? this.hospitalId,
        hospitalName: hospitalName ?? this.hospitalName,
        notifiedContactIds: notifiedContactIds ?? this.notifiedContactIds,
        isSynced: isSynced ?? this.isSynced,
      );

  /// Moves to [next], stamping the timestamp the transition implies.
  ///
  /// Throws [InvalidStatusTransition] when §18 does not allow the move, and
  /// returns the *same instance* when already in [next] so an idempotent replay
  /// is free. The timestamps come from [now] rather than `DateTime.now()` so
  /// callers — and tests — control the clock.
  AccidentRecord withStatus(AccidentStatus next, {required DateTime now}) {
    if (next == status) {
      return this;
    }
    if (!status.canTransitionTo(next)) {
      throw InvalidStatusTransition(status, next);
    }
    return switch (next) {
      AccidentStatus.confirmed => copyWith(status: next, confirmedAt: now),
      AccidentStatus.alertSent => copyWith(status: next, alertSentAt: now),
      AccidentStatus.resolved => copyWith(status: next, resolvedAt: now),
      AccidentStatus.cancelled => copyWith(status: next, cancelledAt: now),
      // Unreachable: `canTransitionTo` refuses to leave a terminal state, and
      // `detected` is only ever an entry point, not a destination. Listed so a
      // future status is a compile error here rather than a silent no-op.
      AccidentStatus.detected ||
      AccidentStatus.unknown =>
        throw InvalidStatusTransition(status, next),
    };
  }

  /// The confirmed record, or throws.
  AccidentRecord confirm({required DateTime now}) =>
      withStatus(AccidentStatus.confirmed, now: now);

  /// The cancelled record, or throws.
  AccidentRecord cancel({required DateTime now}) =>
      withStatus(AccidentStatus.cancelled, now: now);

  /// The alerted record, or throws.
  AccidentRecord markAlertSent({required DateTime now}) =>
      withStatus(AccidentStatus.alertSent, now: now);

  /// The resolved record, or throws.
  AccidentRecord resolve({required DateTime now}) =>
      withStatus(AccidentStatus.resolved, now: now);

  /// Records that [contact] was notified, without re-adding a duplicate.
  AccidentRecord withNotifiedContact(EmergencyContact contact) {
    if (notifiedContactIds.contains(contact.id)) {
      return this;
    }
    return copyWith(
      notifiedContactIds: <String>[...notifiedContactIds, contact.id],
    );
  }

  /// Whether [contact] still needs to be called.
  bool needsNotificationOf(EmergencyContact contact) =>
      !notifiedContactIds.contains(contact.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccidentRecord &&
          other.id == id &&
          other.userId == userId &&
          other.deviceId == deviceId &&
          other.location == location &&
          other.occurredAt == occurredAt &&
          other.impactValue == impactValue &&
          other.impactG == impactG &&
          other.impactScore == impactScore &&
          other.detectedDeviceState == detectedDeviceState &&
          other.status == status &&
          other.confirmedAt == confirmedAt &&
          other.alertSentAt == alertSentAt &&
          other.resolvedAt == resolvedAt &&
          other.cancelledAt == cancelledAt &&
          other.hospitalId == hospitalId &&
          other.hospitalName == hospitalName &&
          _sameIds(other.notifiedContactIds, notifiedContactIds) &&
          other.isSynced == isSynced;

  @override
  int get hashCode => Object.hash(
        id,
        userId,
        deviceId,
        location,
        occurredAt,
        impactValue,
        impactG,
        impactScore,
        detectedDeviceState,
        status,
        confirmedAt,
        alertSentAt,
        resolvedAt,
        cancelledAt,
        hospitalId,
        hospitalName,
        Object.hashAll(notifiedContactIds),
        isSynced,
      );

  @override
  String toString() =>
      'AccidentRecord($id, ${status.wireName}, ${occurredAt.toIso8601String()}, '
      'impact=${impactValue.toStringAsFixed(2)}g)';
}

bool _sameIds(List<String> a, List<String> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
