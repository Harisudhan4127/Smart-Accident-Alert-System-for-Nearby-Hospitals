/// Tests for the app-side domain entities.
///
/// Weighted towards the two places the logic can actually be wrong: the §18
/// accident state machine, and hospital ranking. Both encode decisions that a
/// screenshot will not reveal are wrong until someone is in an ambulance.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/domain/entities/accident.dart';
import 'package:smart_accident_alert/domain/entities/geo_point.dart';
import 'package:smart_accident_alert/domain/entities/hospital.dart';
import 'package:smart_accident_alert/domain/entities/paired_device.dart';
import 'package:smart_accident_alert/domain/entities/telemetry.dart';
import 'package:smart_accident_alert/domain/entities/user_profile.dart';

final DateTime _t0 = DateTime.utc(2026, 9, 27, 5);

AccidentRecord _record({
  AccidentStatus status = AccidentStatus.detected,
  List<String> notified = const <String>[],
}) =>
    AccidentRecord(
      id: 'a1',
      userId: 'u1',
      deviceId: 'd1',
      location: GeoPoint(
        latitude: 12.345678,
        longitude: 79.123456,
        accuracyM: 8,
        timestamp: _t0,
      ),
      occurredAt: _t0,
      impactValue: 4.82,
      impactG: 4.82,
      impactScore: 87,
      status: status,
      notifiedContactIds: notified,
    );

void main() {
  group('AccidentStatus (§18 state machine)', () {
    test('a new record starts in DETECTED', () {
      expect(_record().status, AccidentStatus.detected);
      expect(_record().needsUserDecision, isTrue);
    });

    test('only the four documented transitions are legal', () {
      expect(
        AccidentStatus.detected.canTransitionTo(AccidentStatus.cancelled),
        isTrue,
      );
      expect(
        AccidentStatus.detected.canTransitionTo(AccidentStatus.confirmed),
        isTrue,
      );
      expect(
        AccidentStatus.confirmed.canTransitionTo(AccidentStatus.alertSent),
        isTrue,
      );
      expect(
        AccidentStatus.alertSent.canTransitionTo(AccidentStatus.resolved),
        isTrue,
      );
    });

    test('DETECTED cannot skip straight to ALERT_SENT', () {
      // The trap this guards: a fast confirmation path that writes ALERT_SENT
      // without a CONFIRMED in between loses the "user actually agreed" fact.
      expect(
        AccidentStatus.detected.canTransitionTo(AccidentStatus.alertSent),
        isFalse,
      );
    });

    test('a terminal status goes nowhere', () {
      for (final AccidentStatus from in <AccidentStatus>[
        AccidentStatus.cancelled,
        AccidentStatus.resolved,
        AccidentStatus.unknown,
      ]) {
        expect(from.isTerminal, isTrue, reason: from.wireName);
        for (final AccidentStatus to in AccidentStatus.values) {
          expect(
            from.canTransitionTo(to),
            isFalse,
            reason: '${from.wireName} -> ${to.wireName}',
          );
        }
      }
    });

    test('no status is its own successor', () {
      for (final AccidentStatus s in AccidentStatus.values) {
        expect(s.canTransitionTo(s), isFalse, reason: s.wireName);
      }
    });

    test('the only statuses that need the user are DETECTED', () {
      final Set<AccidentStatus> actionable = AccidentStatus.values
          .where((AccidentStatus s) => s.needsUserDecision)
          .toSet();
      expect(actionable, <AccidentStatus>{AccidentStatus.detected});
    });
  });

  group('AccidentRecord transitions', () {
    test('the happy path stamps the time of each step', () {
      final DateTime t1 = _t0.add(const Duration(seconds: 4));
      final DateTime t2 = _t0.add(const Duration(seconds: 9));
      final DateTime t3 = _t0.add(const Duration(hours: 2));

      final AccidentRecord confirmed = _record().confirm(now: t1);
      expect(confirmed.status, AccidentStatus.confirmed);
      expect(confirmed.confirmedAt, t1);

      final AccidentRecord alerted = confirmed.markAlertSent(now: t2);
      expect(alerted.status, AccidentStatus.alertSent);
      expect(alerted.alertSentAt, t2);
      expect(alerted.confirmedAt, t1, reason: 'earlier stamps survive');

      final AccidentRecord resolved = alerted.resolve(now: t3);
      expect(resolved.status, AccidentStatus.resolved);
      expect(resolved.resolvedAt, t3);
      expect(resolved.hasAlerted, isTrue);
    });

    test('cancelling stamps cancelledAt and nothing else', () {
      final DateTime t1 = _t0.add(const Duration(seconds: 4));
      final AccidentRecord cancelled = _record().cancel(now: t1);
      expect(cancelled.status, AccidentStatus.cancelled);
      expect(cancelled.cancelledAt, t1);
      expect(cancelled.confirmedAt, isNull);
      expect(cancelled.alertSentAt, isNull);
      expect(cancelled.hasAlerted, isFalse);
    });

    test('an illegal transition throws rather than silently moving', () {
      final AccidentRecord confirmed =
          _record().confirm(now: _t0.add(const Duration(seconds: 1)));
      expect(
        () => confirmed.cancel(now: _t0),
        throwsA(isA<InvalidStatusTransition>()),
      );
      expect(
        () => _record().resolve(now: _t0),
        throwsA(isA<InvalidStatusTransition>()),
      );
    });

    test('replaying the current status is a no-op that returns the same object',
        () {
      final AccidentRecord r = _record();
      final AccidentRecord again = r.withStatus(
        AccidentStatus.detected,
        now: _t0.add(const Duration(hours: 1)),
      );
      expect(
        identical(again, r),
        isTrue,
        reason: 'a duplicate sync must not rewrite anything',
      );
    });

    test('a record is immutable through a transition', () {
      final AccidentRecord before = _record();
      before.confirm(now: _t0);
      before.cancel(now: _t0);
      expect(before.status, AccidentStatus.detected);
      expect(before.confirmedAt, isNull);
    });

    test('the transition exception names both ends', () {
      const InvalidStatusTransition e = InvalidStatusTransition(
        AccidentStatus.detected,
        AccidentStatus.resolved,
      );
      expect(e.toString(), contains('DETECTED'));
      expect(e.toString(), contains('RESOLVED'));
    });
  });

  group('AccidentRecord notification bookkeeping', () {
    const EmergencyContact ani = EmergencyContact(
      id: 'c1',
      name: 'Anitha',
      phone: '+919876543210',
    );
    const EmergencyContact raj = EmergencyContact(
      id: 'c2',
      name: 'Raj',
      phone: '+919876543211',
    );

    test('a contact is notified once, however many times we try', () {
      final AccidentRecord r = _record();
      expect(r.needsNotificationOf(ani), isTrue);
      final AccidentRecord once = r.withNotifiedContact(ani);
      final AccidentRecord twice = once.withNotifiedContact(ani);
      expect(twice.notifiedContactIds, <String>['c1']);
      expect(identical(twice, once), isTrue, reason: 'a replay is free');
      expect(twice.needsNotificationOf(ani), isFalse);
      expect(twice.needsNotificationOf(raj), isTrue);
    });

    test('a contact with a blank number is not callable', () {
      const EmergencyContact bad =
          EmergencyContact(id: 'c3', name: 'Nobody', phone: '  ');
      expect(bad.isCallable, isFalse);
    });
  });

  group('AccidentStatus parsing', () {
    test('reads the stored names, tolerating case and padding', () {
      expect(AccidentStatus.fromName('DETECTED'), AccidentStatus.detected);
      expect(AccidentStatus.fromName(' alert_sent '), AccidentStatus.alertSent);
      expect(AccidentStatus.fromName('Resolved'), AccidentStatus.resolved);
    });

    test('a status from a future version becomes UNKNOWN, not DETECTED', () {
      // The dangerous remap: folding an unknown status into DETECTED would
      // re-open a countdown for a record closed hours ago.
      final AccidentStatus s = AccidentStatus.fromNameOrUnknown('TELEPORTED');
      expect(s, AccidentStatus.unknown);
      expect(s.needsUserDecision, isFalse);
      expect(s.isTerminal, isTrue);
      expect(AccidentStatus.fromNameOrUnknown(null), AccidentStatus.unknown);
      expect(AccidentStatus.fromNameOrUnknown(42), AccidentStatus.unknown);
    });
  });

  group('Hospital ranking', () {
    final GeoPoint crash = GeoPoint(
      latitude: 12.345678,
      longitude: 79.123456,
      accuracyM: 8,
      timestamp: _t0,
    );

    Hospital at(double metresNorth, {HospitalType? type, double? rating}) {
      // 1 degree of latitude is ~111.32 km; use a small fraction for metres.
      return Hospital(
        id: 'h${metresNorth}_${type?.wireName ?? 'none'}',
        name: 'H',
        address: 'A',
        location: GeoPoint(
          latitude: crash.latitude + metresNorth / 111320,
          longitude: crash.longitude,
          accuracyM: 5,
          timestamp: _t0,
        ),
        phone: '+91 44 0000 0000',
        type: type,
        rating: rating,
      );
    }

    test('the closest hospital wins when all are equivalent', () {
      final List<Hospital> ranked = <Hospital>[
        at(2000),
        at(200),
        at(900),
      ]..sort(
          (Hospital a, Hospital b) =>
              b.searchScore(crash).compareTo(a.searchScore(crash)),
        );
      expect(ranked.first.id, at(200).id);
    });

    test(
        'a further hospital with an emergency department beats a nearer one '
        'without', () {
      final Hospital nearClinic = at(300, type: HospitalType.clinic);
      final Hospital farEmergency = at(2500, type: HospitalType.emergency);
      expect(
        farEmergency.searchScore(crash),
        greaterThan(nearClinic.searchScore(crash)),
        reason: 'routing past an ambulance queue is worse than 2 km further',
      );
    });

    test('an unknown type is not penalised against a known emergency one', () {
      final Hospital unknown = at(1500);
      final Hospital emergency = at(1500, type: HospitalType.emergency);
      expect(unknown.takesEmergencies, isTrue);
      expect(emergency.searchScore(crash), unknown.searchScore(crash));
    });

    test('an explicit clinic type beats the hasEmergency default', () {
      // Contradictory data: the flag says yes, the type says no. The type is
      // the more specific statement, so the listing is not a destination.
      final Hospital odd = Hospital(
        id: 'h',
        name: 'H',
        address: 'A',
        location: crash,
        phone: '1',
        type: HospitalType.clinic,
        hasEmergency: true,
      );
      expect(odd.takesEmergencies, isFalse);
    });

    test('hasEmergency:false wins over an emergency type', () {
      final Hospital odd = Hospital(
        id: 'h',
        name: 'H',
        address: 'A',
        location: crash,
        phone: '1',
        type: HospitalType.emergency,
        hasEmergency: false,
      );
      expect(odd.takesEmergencies, isFalse);
    });

    test('distance still decides among equals', () {
      expect(
        at(100, rating: 4.5).searchScore(crash),
        greaterThan(at(900, rating: 4.5).searchScore(crash)),
      );
    });

    test('beyond the normalisation window distance stops mattering', () {
      // Both ~40 km out: the app has stopped ranking by metres, which is honest
      // for a road journey, and the type/rating decide instead.
      final Hospital a = at(40000, type: HospitalType.emergency);
      final Hospital b = at(45000, type: HospitalType.emergency);
      expect(
        (a.searchScore(crash) - b.searchScore(crash)).abs(),
        lessThan(1.0),
      );
    });
  });

  group('Hospital serialisation (§17)', () {
    test('writes the exact field names Firestore uses', () {
      final Hospital h = Hospital(
        id: 'h1',
        name: 'Government General Hospital',
        address: 'Park Town, Chennai',
        location: GeoPoint(
          latitude: 13.0872,
          longitude: 80.3162,
          accuracyM: 5,
          timestamp: _t0,
        ),
        phone: '+91 44 2530 5000',
        type: HospitalType.emergency,
        beds: 2000,
        rating: 4.2,
      );
      final Map<String, Object?> map = h.toMap();
      expect(map['name'], 'Government General Hospital');
      expect(map['address'], 'Park Town, Chennai');
      expect(map['latitude'], 13.0872);
      expect(map['longitude'], 80.3162);
      expect(map['phone'], '+91 44 2530 5000');
      expect(map['type'], 'EMERGENCY');
      expect(map['beds'], 2000);
      expect(map['hasEmergency'], isTrue);
      expect(map['rating'], 4.2);
    });

    test('a document with only the five §17 fields is valid', () {
      final Hospital bare = Hospital(
        id: 'h2',
        name: 'Clinic',
        address: 'Somewhere',
        location: GeoPoint(
          latitude: 1,
          longitude: 2,
          accuracyM: 5,
          timestamp: _t0,
        ),
        phone: '+91 44 0000 0001',
      );
      final Map<String, Object?> map = bare.toMap();
      expect(map.containsKey('type'), isFalse);
      expect(map.containsKey('beds'), isFalse);
      expect(map.containsKey('rating'), isFalse);
      expect(map['hasEmergency'], isTrue, reason: 'defaults to usable');
      expect(bare.takesEmergencies, isTrue);
    });

    test('hasEmergency:false is honoured, not overwritten by the default', () {
      final Hospital noEr = Hospital(
        id: 'h3',
        name: 'Clinic',
        address: 'Somewhere',
        location: GeoPoint(
          latitude: 1,
          longitude: 2,
          accuracyM: 5,
          timestamp: _t0,
        ),
        phone: '+91 44 0000 0002',
        hasEmergency: false,
      );
      expect(noEr.takesEmergencies, isFalse);
      expect(noEr.toMap()['hasEmergency'], isFalse);
    });
  });

  group('HospitalType parsing', () {
    test('reads the stored names and tolerates spaces', () {
      expect(HospitalType.fromName('EMERGENCY'), HospitalType.emergency);
      expect(
        HospitalType.fromName('multi specialty'),
        HospitalType.multiSpecialty,
      );
      expect(HospitalType.fromName('CLINIC'), HospitalType.clinic);
      expect(HospitalType.fromName('nope'), isNull);
      expect(HospitalType.fromName(null), isNull);
    });
  });

  group('UserProfile', () {
    const UserProfile p = UserProfile(
      id: 'u1',
      name: '  Harisudhan  ',
      phone: '+919876543210',
      vehicleNumber: 'TN 09 AB 1234',
      emergencyContacts: <EmergencyContact>[
        EmergencyContact(id: 'c1', name: 'Anitha', phone: '+919876543210'),
        EmergencyContact(id: 'c2', name: 'Blank', phone: ' '),
      ],
    );

    test('the app bar name is trimmed, with a fallback', () {
      expect(p.displayName, 'Harisudhan');
      expect(p.copyWith(name: '   ').displayName, 'Driver');
    });

    test('a callable contact is required before the alert button is live', () {
      expect(p.hasCallableContact, isTrue);
      expect(
        p.copyWith(
          emergencyContacts: const <EmergencyContact>[
            EmergencyContact(id: 'c2', name: 'Blank', phone: ' '),
          ],
        ).hasCallableContact,
        isFalse,
      );
      expect(p.copyWith().hasCallableContact, isTrue);
    });

    test('pendingContactsFor skips whoever was already called', () {
      final AccidentRecord r =
          _record(notified: const <String>['c1']).withNotifiedContact(
        p.emergencyContacts.first,
      );
      final List<EmergencyContact> pending = p.pendingContactsFor(r);
      expect(pending.map((EmergencyContact c) => c.id), <String>['c2']);
    });
  });

  group('PairedDevice', () {
    final PairedDevice d = PairedDevice(
      id: '24:6f:28:a1:b2:c3:d4',
      userId: 'u1',
      deviceName: 'SAAS-A1B2C3D4',
      mac: '24:6F:28:A1:B2:C3:D4',
      chipId: 'A1B2C3D4',
      firmwareVersion: '1.0.0',
      protocolVersion: 2,
      pairedAt: _t0,
      hardware: 'esp32-devkit-v1',
      hasOled: true,
      hasVibrationSensor: true,
      isCalibrated: true,
      sensorName: 'ADXL345',
      lastSeenAt: _t0,
    );

    test('the user label wins over the factory name', () {
      expect(d.displayName, 'SAAS-A1B2C3D4');
      expect(d.copyWith(label: 'Dad\'s car').displayName, "Dad's car");
      expect(d.copyWith(label: '   ').displayName, 'SAAS-A1B2C3D4');
    });

    test('an unpaired or version-mismatched node is not usable', () {
      expect(d.copyWith().isUsable, isTrue);
      expect(
        d.copyWith(linkState: DeviceLinkState.unpaired).isUsable,
        isFalse,
      );
      expect(
        d.copyWith(linkState: DeviceLinkState.incompatible).isUsable,
        isFalse,
        reason: 'retrying a protocol mismatch never helps',
      );
      for (final DeviceLinkState s in <DeviceLinkState>[
        DeviceLinkState.connected,
        DeviceLinkState.disconnected,
        DeviceLinkState.connecting,
      ]) {
        expect(d.copyWith(linkState: s).isUsable, isTrue, reason: s.name);
      }
    });

    test('silence is measured from the last hello, not the last frame', () {
      final DateTime now = _t0.add(const Duration(minutes: 12));
      expect(d.silenceAt(now), const Duration(minutes: 12));
      expect(
        d.silenceAt(_t0.subtract(const Duration(hours: 1))),
        Duration.zero,
        reason: 'a clock skew must not produce a negative silence',
      );
    });

    test('a device never heard from reports no silence, not a huge one', () {
      // `copyWith` cannot null a field — a null argument means "keep" — so the
      // never-heard case is a device built without one at all.
      final PairedDevice neverHeard = PairedDevice(
        id: d.id,
        userId: d.userId,
        deviceName: d.deviceName,
        mac: d.mac,
        chipId: d.chipId,
        firmwareVersion: d.firmwareVersion,
        protocolVersion: d.protocolVersion,
        pairedAt: d.pairedAt,
      );
      expect(neverHeard.lastSeenAt, isNull);
      expect(
        neverHeard.silenceAt(_t0.add(const Duration(days: 30))),
        Duration.zero,
        reason: 'there is no interval to report, not 30 days of it',
      );
    });

    test('a telemetry frame updates only what a frame can know', () {
      const TelemetryRecord sample = TelemetryRecord(
        tMs: 1000,
        accX: 0,
        accY: 0,
        accZ: 1000,
        magMg: 1000,
        peakMg: 4820,
        flags: TelemetryFlags(
          sw420: false,
          buzzer: false,
          ledRed: false,
          ledGreen: false,
          oledOk: true,
          sosButton: false,
          armed: true,
          charging: true,
        ),
        impactScore: 87,
        batteryPct: 15,
        state: DeviceState.pending,
      );
      final PairedDevice updated = d.withTelemetry(sample);
      expect(updated.lastKnownBatteryPct, 15);
      expect(updated.lastKnownState, DeviceState.pending);
      expect(updated.isCharging, isTrue, reason: 'bit 0x02 is CHARGING');
      expect(updated.isBatteryLow, isTrue);
      expect(
        updated.isCalibrated,
        isTrue,
        reason: 'a frame cannot un-calibrate a node',
      );
      expect(updated.isInEmergency, isFalse);
    });

    test('a frame with no battery leaves the last known value alone', () {
      const TelemetryRecord noBattery = TelemetryRecord(
        tMs: 2000,
        accX: 0,
        accY: 0,
        accZ: 1000,
        magMg: 1000,
        peakMg: 1000,
        flags: TelemetryFlags.none,
        impactScore: 0,
        batteryPct: kBatteryUnknown,
        state: DeviceState.idle,
      );
      expect(noBattery.hasBattery, isFalse);
      final PairedDevice withBattery = d.copyWith(lastKnownBatteryPct: 88);
      expect(
        withBattery.withTelemetry(noBattery).lastKnownBatteryPct,
        88,
        reason: '0xFF means "no battery", which is not 255%',
      );
    });

    test('a low-battery warning fires at 20%, not at 10%', () {
      expect(d.copyWith(lastKnownBatteryPct: 21).isBatteryLow, isFalse);
      expect(d.copyWith(lastKnownBatteryPct: 20).isBatteryLow, isTrue);
      expect(
        d.copyWith(lastKnownBatteryPct: null).isBatteryLow,
        isFalse,
        reason: 'unknown is not low',
      );
    });

    test('armed and emergency read straight off the last known state', () {
      // `idle` is the *armed* idle state in §5.2, not an unarmed one.
      expect(d.copyWith(lastKnownState: DeviceState.idle).isArmed, isTrue);
      expect(d.copyWith(lastKnownState: DeviceState.pending).isArmed, isTrue);
      expect(d.copyWith(lastKnownState: DeviceState.boot).isArmed, isFalse);
      expect(
        d.copyWith(lastKnownState: DeviceState.fault).isArmed,
        isFalse,
        reason: 'a dead MPU means the detector is not really running',
      );
      expect(
        d.copyWith(lastKnownState: DeviceState.alarm).isInEmergency,
        isTrue,
      );
      expect(d.copyWith(lastKnownState: DeviceState.sos).isInEmergency, isTrue);
      expect(
        d.copyWith(lastKnownState: DeviceState.idle).isInEmergency,
        isFalse,
      );
    });
  });

  group('entity equality', () {
    test('AccidentRecord compares by value, including the contact list', () {
      expect(_record(), _record());
      expect(
        _record().hashCode,
        _record().hashCode,
      );
      expect(
        _record().notifiedContactIds,
        isNot(_record(notified: const <String>['c1']).notifiedContactIds),
      );
      expect(
        _record(),
        isNot(_record().confirm(now: _t0)),
      );
      expect(
        _record().withNotifiedContact(
          const EmergencyContact(id: 'c1', name: 'A', phone: '1'),
        ),
        _record().withNotifiedContact(
          const EmergencyContact(id: 'c1', name: 'A', phone: '1'),
        ),
      );
    });
  });
}
