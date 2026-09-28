/// Telemetry record conformance (§5) and the clamping/rounding edges that
/// `tools/protocol/golden.json` does not cover.
///
/// The expectations come from `tools/protocol/codec.js` via
/// `fixtures/telemetry_vectors.dart`, so a mismatch means the Dart and the
/// reference disagree — not that the test is wrong.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/core/result.dart';
import 'package:smart_accident_alert/data/protocol/ble_frame.dart';
import 'package:smart_accident_alert/data/protocol/telemetry.dart';
import 'package:smart_accident_alert/domain/entities/telemetry.dart';

import 'fixtures/telemetry_vectors.dart';

Uint8List _hex(String s) {
  final String clean = s.replaceAll(' ', '');
  final Uint8List out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('jsRoundToInt matches JavaScript Math.round', () {
    // Dart's double.round() is half-away-from-zero; JS's is half-up. They agree
    // on positive halves and disagree on every negative half. This is the single
    // most likely place for the Dart port to silently diverge from the firmware
    // generator, so each case is named.
    final Map<double, int> cases = <double, int>{
      0.0: 0,
      0.4: 0,
      0.5: 1,
      1.5: 2,
      2.5: 3,
      -0.4: 0,
      -0.5: 0, // JS: -0. Dart: -1. The divergence.
      -1.5: -1, // JS: -1. Dart: -2.
      -2.5: -2, // JS: -2. Dart: -3.
      2.4: 2,
      -2.6: -3,
    };
    cases.forEach((double input, int expected) {
      test('Math.round($input) == $expected', () {
        expect(jsRoundToInt(input), expected);
      });
    });

    test('jsRound scales and rounds at the documented precisions', () {
      expect(jsRound2(4.824), 4.82);
      expect(jsRound2(-4.824), -4.82);
      expect(jsRound2(4.825), 4.83);
      expect(jsRound1(402.14), 402.1);
      expect(jsRound1(402.16), 402.2);
      expect(jsRound(1.0, 0), 1);
    });

    test('jsRound rejects an out-of-range precision', () {
      expect(() => jsRound(1.0, -1), throwsRangeError);
      expect(() => jsRound(1.0, 16), throwsRangeError);
    });
  });

  group('clamps mirror the reference', () {
    test('clampI16 saturates rather than wrapping', () {
      expect(clampI16(40000), 32767);
      expect(clampI16(-40000), -32768);
      expect(clampI16(32767), 32767);
      expect(clampI16(-32768), -32768);
      expect(clampI16(-0.5), 0, reason: 'JS rounding, then clamp');
    });

    test('clampU16 and clampByte saturate at zero, not at 65535/255', () {
      expect(clampU16(-5), 0);
      expect(clampU16(70000), 65535);
      expect(clampByte(-1), 0);
      expect(clampByte(300), 255);
    });

    test('clampU32 truncates like the reference `>>> 0`', () {
      expect(clampU32(0xFFFFFFFF), 0xFFFFFFFF);
      expect(clampU32(0x100000000), 0);
      expect(clampU32(0x100000005), 5);
    });
  });

  group('encodeTelemetryFields matches the reference byte for byte', () {
    for (final TelemetryVector vector in kExtraTelemetryVectors) {
      test(vector.name, () {
        final Uint8List payload = encodeTelemetryFields(
          tMs: vector.tMs,
          ax: vector.ax,
          ay: vector.ay,
          az: vector.az,
          magMg: vector.magMg,
          peakMg: vector.peakMg,
          flags: vector.flags,
          score: vector.score,
          batteryPct: vector.batteryPct,
          state: vector.state,
        );
        expect(
          _toHex(payload),
          vector.payloadHex,
          reason: '${vector.name}: ${vector.reason}',
        );
        expect(payload, hasLength(telemetryRecordBytes));
      });
    }
  });

  group('full frame encoding matches the reference', () {
    for (final TelemetryVector vector in kExtraTelemetryVectors) {
      test(vector.name, () {
        final Uint8List payload = encodeTelemetryFields(
          tMs: vector.tMs,
          ax: vector.ax,
          ay: vector.ay,
          az: vector.az,
          magMg: vector.magMg,
          peakMg: vector.peakMg,
          flags: vector.flags,
          score: vector.score,
          batteryPct: vector.batteryPct,
          state: vector.state,
        );
        final Uint8List frame =
            encodeFrame(typeCode: MessageType.telemetry.code, payload: payload);
        expect(_toHex(frame), vector.frameHex, reason: vector.name);
      });
    }
  });

  group('decode(encode(x)) == x', () {
    for (final TelemetryVector vector in kExtraTelemetryVectors) {
      test(vector.name, () {
        final Uint8List payload = encodeTelemetryFields(
          tMs: vector.tMs,
          ax: vector.ax,
          ay: vector.ay,
          az: vector.az,
          magMg: vector.magMg,
          peakMg: vector.peakMg,
          flags: vector.flags,
          score: vector.score,
          batteryPct: vector.batteryPct,
          state: vector.state,
        );
        final TelemetryRecord record = _mustDecode(payload);
        expect(record.tMs, vector.expectTMs, reason: 'tMs');
        expect(record.accX, vector.expectAx, reason: 'ax');
        expect(record.accY, vector.expectAy, reason: 'ay');
        expect(record.accZ, vector.expectAz, reason: 'az');
        expect(record.magMg, vector.expectMagMg, reason: 'magMg');
        expect(record.peakMg, vector.expectPeakMg, reason: 'peakMg');
        expect(record.flags.toByte(), vector.expectFlags, reason: 'flags');
        expect(record.impactScore, vector.expectScore, reason: 'score');
        expect(
          record.batteryPct,
          vector.expectBatteryPct,
          reason: 'batteryPct',
        );
        expect(record.state.byte, vector.expectState, reason: 'state');

        // And re-encoding the decoded record reproduces the same 18 bytes.
        expect(_toHex(TelemetryCodec.encode(record)), vector.payloadHex);
      });
    }
  });

  group('record <-> bytes round trip', () {
    test('a hand-built record survives encode/decode', () {
      const TelemetryRecord record = TelemetryRecord(
        tMs: 123456,
        accX: -1500,
        accY: 250,
        accZ: 998,
        magMg: 1004,
        peakMg: 4820,
        flags: TelemetryFlags(
          sw420: true,
          buzzer: false,
          ledRed: true,
          ledGreen: false,
          oledOk: true,
          sosButton: false,
          armed: true,
          charging: false,
        ),
        impactScore: 87,
        batteryPct: 41,
        state: DeviceState.alarm,
      );
      final Uint8List bytes = record.toBytes();
      expect(bytes, hasLength(18));
      expect(TelemetryCodec.tryDecode(bytes), record);
    });

    test('all 256 flag bytes round trip (§5.1 names every bit)', () {
      for (int value = 0; value <= 0xFF; value++) {
        final TelemetryFlags flags = TelemetryFlags.fromByte(value);
        expect(
          flags.toByte(),
          value,
          reason: 'flag byte 0x${value.toRadixString(16)}',
        );
        final TelemetryFlags rebuilt = TelemetryFlags(
          sw420: flags.sw420,
          buzzer: flags.buzzer,
          ledRed: flags.ledRed,
          ledGreen: flags.ledGreen,
          oledOk: flags.oledOk,
          sosButton: flags.sosButton,
          armed: flags.armed,
          charging: flags.charging,
        );
        expect(
          rebuilt.toByte(),
          value,
          reason: 'rebuild 0x${value.toRadixString(16)}',
        );
      }
    });

    test('every i16 axis value round trips', () {
      for (final int value in <int>[-32768, -32767, -1, 0, 1, 32766, 32767]) {
        final TelemetryRecord record = TelemetryRecord(
          tMs: 0,
          accX: value,
          accY: 0,
          accZ: 0,
          magMg: 0,
          peakMg: 0,
          flags: TelemetryFlags.none,
          impactScore: 0,
          batteryPct: 0,
          state: DeviceState.idle,
        );
        expect(TelemetryCodec.tryDecode(record.toBytes())!.accX, value);
      }
    });
  });

  group('length validation', () {
    test('tryDecode rejects a short payload with null', () {
      expect(TelemetryCodec.tryDecode(Uint8List(23)), isNull);
      expect(TelemetryCodec.tryDecode(Uint8List(25)), isNull);
      expect(TelemetryCodec.tryDecode(Uint8List(0)), isNull);
    });

    test('decode reports the length as a validation failure', () {
      final Result<TelemetryRecord> result =
          TelemetryCodec.decode(Uint8List(12));
      expect(result, isA<FailureResult<TelemetryRecord>>());
      final Failure? failure = result.failureOrNull;
      expect(failure, isNotNull);
      expect(failure!.kind, FailureKind.validation);
      expect(failure.message, contains('18 bytes'));
      expect(
        failure.retryable,
        isFalse,
        reason: 'a short read is not transient',
      );
    });
  });

  group('derived values', () {
    test('units are milli-g and tenths of a degree per second', () {
      const TelemetryRecord record = TelemetryRecord(
        tMs: 0,
        accX: 1500,
        accY: -250,
        accZ: 1000,
        magMg: 4820,
        peakMg: 4820,
        flags: TelemetryFlags.none,
        impactScore: 0,
        batteryPct: 0,
        state: DeviceState.idle,
      );
      expect(record.accXG, 1.5);
      expect(record.accYG, -0.25);
      expect(record.accZG, 1.0);
      expect(record.magG, 4.82);
      expect(record.peakG, 4.82);
    });

    test('battery 255 is the unknown sentinel, not 255%', () {
      const TelemetryRecord unknown = TelemetryRecord(
        tMs: 0,
        accX: 0,
        accY: 0,
        accZ: 0,
        magMg: 0,
        peakMg: 0,
        flags: TelemetryFlags.none,
        impactScore: 0,
        batteryPct: kBatteryUnknown,
        state: DeviceState.boot,
      );
      expect(unknown.batteryPct, 255);
      expect(unknown.batteryPctOrNull, isNull);
      expect(unknown.hasBattery, isFalse);
    });
  });

  group('DeviceState (§5.2)', () {
    test('every documented state maps to its byte and back', () {
      const Map<DeviceState, int> expected = <DeviceState, int>{
        DeviceState.boot: 0,
        DeviceState.idle: 1,
        DeviceState.pending: 2,
        DeviceState.alarm: 3,
        DeviceState.sos: 4,
        DeviceState.muted: 5,
        DeviceState.fault: 6,
      };
      expected.forEach((DeviceState state, int code) {
        expect(state.byte, code, reason: state.name);
        expect(DeviceState.fromByte(code), state, reason: '$code');
      });
    });

    test('an undocumented state decodes to unknown instead of throwing', () {
      expect(DeviceState.fromByte(7), DeviceState.unknown);
      expect(DeviceState.fromByte(200), DeviceState.unknown);
      expect(DeviceState.fromByte(255), DeviceState.unknown);
    });

    test('armed and emergency flags drive the UI correctly', () {
      expect(DeviceState.idle.isArmed, isTrue);
      expect(DeviceState.pending.isArmed, isTrue);
      expect(DeviceState.muted.isArmed, isTrue, reason: 'muted still detects');
      expect(DeviceState.boot.isArmed, isFalse);
      expect(DeviceState.fault.isArmed, isFalse);
      expect(DeviceState.alarm.isEmergency, isTrue);
      expect(DeviceState.sos.isEmergency, isTrue);
      expect(DeviceState.pending.isEmergency, isFalse);
      expect(DeviceState.pending.isCancellable, isTrue);
    });
  });

  group('telemetryToReferenceJson', () {
    test('produces the reference decoder shape', () {
      final Uint8List payload = _hex(
        kExtraTelemetryVectors.first.payloadHex,
      );
      final TelemetryRecord? maybe = TelemetryCodec.tryDecode(payload);
      final TelemetryRecord record = _mustHave(maybe);
      final Map<String, Object?> json = telemetryToReferenceJson(record);
      expect(json['tMs'], 0);
      expect(json['ax'], 0);
      expect(json['ay'], -1);
      expect(json['state'], 0);
      expect(json['stateName'], 'BOOT');
      expect(json['flags'], 0x00);
    });
  });
}

/// Decode [payload] or fail the test with the codec's own message.
TelemetryRecord _mustDecode(Uint8List payload) =>
    _mustHave(TelemetryCodec.tryDecode(payload));

/// Unwrap a value the test has already established is present.
///
/// Written as a function rather than `x!` because a bare `!` in a test hides
/// which assertion actually failed: this way the message says "expected a
/// telemetry record, got null" instead of "Null check operator used on a null
/// value" at a line number.
T _mustHave<T>(T? value, {String? because}) {
  if (value != null) {
    return value;
  }
  throw StateError(
    'expected a non-null $T${because == null ? '' : ': $because'}',
  );
}

String _toHex(Uint8List bytes) => bytes
    .map((int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join();
