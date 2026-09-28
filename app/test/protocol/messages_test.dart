/// Conformance for the §6 JSON message layer.
///
/// The load-bearing tests here are the two that read `tools/protocol/golden.json`:
/// every JSON vector in it must decode into the right typed message *and*
/// re-encode to the exact bytes the reference produced. Everything else is
/// schema/validation behaviour the golden file does not cover.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/core/result.dart';
import 'package:smart_accident_alert/data/protocol/ble_frame.dart';
import 'package:smart_accident_alert/data/protocol/messages.dart';
import 'package:smart_accident_alert/domain/entities/telemetry.dart';

/// Locates `tools/protocol/golden.json` from the package root, `app/`, or
/// `app/test/protocol/`, so the suite runs from any of them.
File? _locateGolden() {
  for (final String dir in <String>[
    Directory.current.path,
    '../',
    '../../',
  ]) {
    final File f = File('$dir/tools/protocol/golden.json');
    if (f.existsSync()) {
      return f;
    }
  }
  return null;
}

final File? _goldenFile = _locateGolden();

/// Skips a test group when the golden file cannot be found, rather than failing
/// every test in the file for an environmental reason.
final String? _skipReason = _goldenFile == null
    ? 'tools/protocol/golden.json not found from ${Directory.current.path}'
    : null;

List<Object?> _goldenVectors() {
  final File file = _goldenFile!;
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw StateError('golden.json is not a JSON object');
  }
  final Object? raw = decoded['vectors'];
  if (raw is! List<Object?>) {
    throw StateError('golden.json has no "vectors" array');
  }
  return raw;
}

Uint8List _hexBytes(String s) {
  final String clean = s.replaceAll(' ', '');
  final Uint8List out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// The JSON payload of [message], without the §3 frame header or CRC.
///
/// `toFrameBytes` is for the wire; the codec entry points take a bare payload,
/// and slicing a real frame is how a caller would get that.
Uint8List _payloadOf(DeviceMessage message) {
  final Uint8List frame = message.toFrameBytes();
  // LEN sits in the two bytes before the payload: A5 5A | VER | TYPE | LEN.
  final int len = frame[kHeaderBytes - 2] | (frame[kHeaderBytes - 1] << 8);
  return Uint8List.sublistView(frame, kHeaderBytes, kHeaderBytes + len);
}

String _toHex(Uint8List bytes) => bytes
    .map((int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join();

/// One §6.8 sample, used wherever the shape matters but the values do not.
const CalibrationSample _sample = CalibrationSample(
  tMs: 100,
  accX: 12,
  accY: -34,
  accZ: 1002,
  sw420: false,
);

void main() {
  group(
    'golden.json JSON vectors',
    () {
      test(
        'every JSON vector decodes to the right message type',
        () {
          final FrameScanner scanner = FrameScanner();
          final Map<String, DeviceMessage> byName = <String, DeviceMessage>{};
          for (final Object? raw in _goldenVectors()) {
            final Map<String, Object?> vector = raw! as Map<String, Object?>;
            final Object? json = vector['json'];
            if (json == null) {
              continue;
            }
            final String name = vector['name']! as String;
            final List<BleFrame> frames = scanner.scanToList(
              _hexBytes(vector['frameHex']! as String),
            );
            expect(frames, hasLength(1), reason: name);
            final Result<DeviceMessage> parsed = MessageCodec.parseFrame(
              frames.single,
            );
            expect(
              parsed.isOk,
              isTrue,
              reason: '$name: ${parsed.failureOrNull}',
            );
            byName[name] = parsed.valueOrNull as DeviceMessage;
          }

          expect(byName['hello'], isA<HelloMessage>());
          expect(byName['commandConfirm'], isA<CommandMessage>());
          final DeviceMessage? event = byName['eventAccident'];
          expect(event, isA<EventMessage>());
          final EventMessage accident = event! as EventMessage;
          expect(accident.eventType, EventType.accidentDetected);
          expect(accident.eventId, '8f3a1c22');
          expect(accident.seq, 7);
          expect(accident.tMs, 423119);
          expect(accident.score, 87);
          expect(accident.canCancel, isTrue);
          expect(accident.confirmWindowSec, 10);
          expect(accident.impact, isNotNull);
          expect(accident.impact!.magG, 4.82);
          expect(accident.impact!.peakAccMg, 4820);
          expect(accident.impact!.sw420, isTrue);
          expect(accident.impact!.preImpactSpeedKmh, 48.3);
        },
        skip: _skipReason,
      );

      test(
        'every JSON vector re-encodes to the golden bytes',
        () {
          for (final Object? raw in _goldenVectors()) {
            final Map<String, Object?> vector = raw! as Map<String, Object?>;
            if (vector['json'] == null) {
              continue;
            }
            final String name = vector['name']! as String;
            final Map<String, Object?> json =
                vector['json']! as Map<String, Object?>;
            final DeviceMessage message = MessageCodec.parseJson(
              MessageType.fromCode(vector['type']! as int)!,
              json,
            );
            expect(
              _toHex(message.toFrameBytes()),
              vector['frameHex'],
              reason: name,
            );
          }
        },
        skip: _skipReason,
      );
    },
    skip: _skipReason,
  );

  group('HELLO (§6.1)', () {
    const HelloMessage hello = HelloMessage(
      app: 'smart-accident-alert',
      appVersion: '1.0.0',
      proto: 1,
      capabilities: <String>[
        'telemetry',
        'config',
        'calibrate',
        'command',
        'diag',
      ],
      deviceName: 'My Car',
      locale: 'en-IN',
    );

    test('round trips', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.hello.code,
        _payloadOf(hello),
      );
      expect(parsed.isOk, isTrue, reason: '${parsed.failureOrNull}');
      final DeviceMessage back = parsed.valueOrNull!;
      expect(back, isA<HelloMessage>());
      expect((back as HelloMessage).deviceName, 'My Car');
      expect(back.toJson(), hello.toJson());
    });

    test('a missing required key names the key in the failure', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.hello.code,
        Uint8List.fromList(utf8.encode('{"app":"x"}')),
      );
      expect(parsed.isFailure, isTrue);
      final Failure? f = parsed.failureOrNull;
      expect(f!.kind, FailureKind.protocol);
      expect(f.retryable, isFalse);
      expect(f.cause, isA<MessageFormatException>());
      expect((f.cause! as MessageFormatException).field, 'appVersion');
    });

    test('capabilities must be strings', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.hello.code,
        Uint8List.fromList(
          utf8.encode('{"app":"x","appVersion":"1","proto":1,'
              '"capabilities":[1,2],"deviceName":"n","locale":"en-IN"}'),
        ),
      );
      expect(parsed.isFailure, isTrue);
      expect(
        (parsed.failureOrNull!.cause! as MessageFormatException).field,
        'capabilities',
      );
    });
  });

  group('CONFIG (§6.4)', () {
    test('a partial patch omits the keys it does not set', () {
      const ConfigPatch patch = ConfigPatch(accelThresholdMg: 2500);
      expect(patch.toJson(), <String, Object?>{'accelThresholdMg': 2500});
      expect(patch.changedKeys, <String>['accelThresholdMg']);
      expect(patch.isEmpty, isFalse);
      expect(const ConfigPatch().isEmpty, isTrue);
    });

    test('merging leaves absent keys alone', () {
      const ConfigPatch base = ConfigPatch(
        accelThresholdMg: 3000,
        telemetryHz: 50,
        autoArm: true,
      );
      const ConfigPatch patch = ConfigPatch(accelThresholdMg: 2500);
      final ConfigPatch merged = patch.mergedOnto(base);
      expect(merged.accelThresholdMg, 2500);
      expect(merged.telemetryHz, 50, reason: 'untouched key survives');
      expect(merged.autoArm, isTrue);
    });

    test('out-of-range values are clamped, matching the device', () {
      final DeviceConfig config = DeviceConfig(
        accelThresholdMg: 999999,
        vibrationRequired: true,
        debounceMs: 0,
        confirmWindowSec: 9999,
        minSpeedKmh: -20,
        detectorGain: 99,
        telemetryHz: 5000,
        buzzerEnabled: true,
        ledEnabled: true,
        muteUntil: -5,
        autoArm: true,
      );
      expect(config.accelThresholdMg, 16000, reason: '§6.4 upper bound');
      expect(config.debounceMs, 20, reason: '§6.4 lower bound');
      expect(config.confirmWindowSec, 120);
      expect(config.minSpeedKmh, 0);
      expect(config.detectorGain, 3.0);
      expect(config.telemetryHz, 100);
      expect(config.muteUntil, 0);
    });

    test('the §6.4 defaults are exactly the documented ones', () {
      final DeviceConfig d = DeviceConfig.defaults();
      expect(d.accelThresholdMg, 3000);
      expect(d.vibrationRequired, isTrue);
      expect(d.debounceMs, 60);
      expect(d.confirmWindowSec, 10);
      expect(d.minSpeedKmh, 5.0);
      expect(d.detectorGain, 1.0);
      expect(d.telemetryHz, 50);
      expect(d.buzzerEnabled, isTrue);
      expect(d.ledEnabled, isTrue);
      expect(d.muteUntil, 0);
      expect(d.autoArm, isTrue);
    });

    test('clampedFields explains what the device will do differently', () {
      // 20000 mg is past the 16000 ceiling (16 g, the ADXL345's full scale), so
      // this still exercises the clamp. 12000 no longer does: that was only
      // unreachable when the bound was the old part's 8000.
      const ConfigPatch requested = ConfigPatch(
        accelThresholdMg: 20000,
        telemetryHz: 50,
      );
      final DeviceConfig applied = DeviceConfig.fromPatch(requested);
      expect(
        DeviceConfig.clampedFields(
          requested,
          accelThresholdMg: applied.accelThresholdMg,
          debounceMs: applied.debounceMs,
          confirmWindowSec: applied.confirmWindowSec,
          minSpeedKmh: applied.minSpeedKmh,
          detectorGain: applied.detectorGain,
          telemetryHz: applied.telemetryHz,
        ),
        <String>['accelThresholdMg'],
        reason: 'only the key that actually moved is reported',
      );
    });

    test('an unknown key is ignored, not fatal', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.config.code,
        Uint8List.fromList(
          utf8.encode('{"accelThresholdMg":3000,"somethingNewer":true}'),
        ),
      );
      expect(parsed.isOk, isTrue);
      final ConfigMessage msg = parsed.valueOrNull! as ConfigMessage;
      expect(msg.patch.accelThresholdMg, 3000);
    });
  });

  group('COMMAND (§6.7)', () {
    test('every documented op parses and round trips', () {
      for (final CommandOp op in CommandOp.values) {
        final CommandMessage msg = CommandMessage(
          op: op,
          eventId: op.requiresEventId ? 'abc123' : null,
          untilUnixS: op == CommandOp.mute ? 1800000000 : null,
        );
        final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
          MessageType.command.code,
          _payloadOf(msg),
        );
        expect(parsed.isOk, isTrue, reason: op.wireName);
        expect(
          (parsed.valueOrNull! as CommandMessage).op,
          op,
          reason: op.wireName,
        );
      }
    });

    test('only CONFIRM and CANCEL require an eventId', () {
      expect(CommandOp.confirm.requiresEventId, isTrue);
      expect(CommandOp.cancel.requiresEventId, isTrue);
      expect(CommandOp.test.requiresEventId, isFalse);
      expect(CommandOp.selftest.requiresEventId, isFalse);
    });

    test('an unknown op is a protocol failure, not a crash', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.command.code,
        Uint8List.fromList(utf8.encode('{"op":"LAUNCH_ROCKET"}')),
      );
      expect(parsed.isFailure, isTrue);
      final MessageFormatException e =
          parsed.failureOrNull!.cause! as MessageFormatException;
      expect(e.field, 'op');
      expect(e.problem, contains('LAUNCH_ROCKET'));
    });
  });

  group('EVENT (§6.6)', () {
    test('an unknown discriminator fails loudly rather than dropping it', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.event.code,
        Uint8List.fromList(
          utf8.encode('{"type":"SOMETHING_NEW","eventId":"a","seq":1,'
              '"t_ms":0,"uptimeMs":0}'),
        ),
      );
      expect(parsed.isFailure, isTrue);
      expect(
        (parsed.failureOrNull!.cause! as MessageFormatException).field,
        'type',
      );
    });

    test('only the impact-bearing types declare hasImpact', () {
      expect(EventType.accidentDetected.hasImpact, isTrue);
      expect(EventType.manualSos.hasImpact, isTrue);
      expect(EventType.resolved.hasImpact, isFalse);
      expect(EventType.deviceFault.hasImpact, isFalse);
    });

    test('the impact block is optional', () {
      const EventMessage event = EventMessage(
        eventType: EventType.deviceFault,
        eventId: 'ff00',
        seq: 1,
        tMs: 5,
        uptimeMs: 5,
      );
      expect(event.toJson().containsKey('impact'), isFalse);
      expect(event.toJson().containsKey('score'), isFalse);
      final EventMessage back = EventMessage.fromJson(event.toJson());
      expect(back.impact, isNull);
    });
  });

  group('STATUS (§6.5)', () {
    test('decodes the full §6.5 example', () {
      const String payload = '''
      {
        "state": 2, "stateName": "PENDING", "sinceMs": 8123,
        "effectiveConfig": { "accelThresholdMg": 3000, "telemetryHz": 50 },
        "peakMagMg": 4820, "sw420": false, "sw420Hits": 3,
        "score": 72, "queueDepth": 4, "heapFree": 142336, "uptimeMs": 423119,
        "watchdogResets": 0, "loopOverageCount": 0
      }''';
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.status.code,
        Uint8List.fromList(utf8.encode(payload)),
      );
      expect(parsed.isOk, isTrue, reason: '${parsed.failureOrNull}');
      final StatusMessage s = parsed.valueOrNull! as StatusMessage;
      expect(s.state, DeviceState.pending);
      expect(s.sinceMs, 8123);
      expect(s.heapFree, 142336);
      expect(s.sw420, isFalse);
      expect(s.sw420Hits, 3);
      expect(s.effectiveConfig!.accelThresholdMg, 3000);
      expect(s.effectiveConfig!.telemetryHz, 50);
    });

    test('an undocumented state becomes unknown, not an exception', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.status.code,
        Uint8List.fromList(
          utf8.encode('{"state":99,"sinceMs":0,"uptimeMs":0}'),
        ),
      );
      expect(parsed.isOk, isTrue);
      expect((parsed.valueOrNull! as StatusMessage).state, DeviceState.unknown);
    });
  });

  group('HELLO_ACK (§6.2)', () {
    test('decodes the full §6.2 example including capability negotiation', () {
      const String payload = '''
      {
        "fwVersion": "1.0.0", "hw": "esp32-devkit-v1", "proto": 1,
        "chipId": "A1B2C3D4", "mac": "24:6F:28:A1:B2:C3:D4",
        "name": "SAAS-A1B2C3D4", "batteryMv": 4120, "batteryPct": 96,
        "charging": false, "uptimeMs": 123456,
        "sensor": {
          "part": "ADXL345",
          "present": true,
          "addr": "0x53",
          "deviceId": 229
        },
        "oled": { "present": true, "addr": "0x3C" },
        "sw420": true, "calibrated": true, "sensorRateHz": 50, "state": 1
      }''';
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.helloAck.code,
        Uint8List.fromList(utf8.encode(payload)),
      );
      expect(parsed.isOk, isTrue, reason: '${parsed.failureOrNull}');
      final HelloAckMessage h = parsed.valueOrNull! as HelloAckMessage;
      expect(h.chipId, 'A1B2C3D4');
      expect(h.mac, '24:6F:28:A1:B2:C3:D4');
      expect(h.batteryPct, 96);
      expect(h.state, DeviceState.idle);
      expect(h.sensor!.present, isTrue);
      expect(h.sensor!.part, 'ADXL345');
      expect(h.sensor!.addr, '0x53');
      expect(h.sensor!.deviceId, 229);
      expect(
        h.sensor!.isExpectedPart,
        isTrue,
        reason: '229 == 0xE5, the ADXL345 DEVID',
      );
      expect(h.oled!.present, isTrue);
      expect(h.sw420, isTrue);
      expect(h.calibrated, isTrue);
      expect(h.sensorRateHz, 50);
      expect(h.fullyEquipped, isTrue);
    });

    test('a node with no OLED still counts as usable', () {
      const String payload = '''
      {
        "fwVersion": "1.0.0", "hw": "esp32-devkit-v1", "proto": 1,
        "chipId": "A1B2C3D4", "mac": "24:6F:28:A1:B2:C3:D4",
        "name": "SAAS-A1B2C3D4", "batteryMv": 3900, "batteryPct": 80,
        "charging": false, "uptimeMs": 1000,
        "sensor": {
          "part": "ADXL345",
          "present": true,
          "addr": "0x53",
          "deviceId": 229
        },
        "sw420": true, "calibrated": false, "sensorRateHz": 50, "state": 1
      }''';
      final HelloAckMessage h = MessageCodec.parseJson(
        MessageType.helloAck,
        jsonDecode(payload) as Map<String, Object?>,
      ) as HelloAckMessage;
      expect(h.oled, isNull);
      expect(h.fullyEquipped, isTrue, reason: 'absent OLED is not a fault');
      expect(h.calibrated, isFalse);
    });

    test('a device ID that is not the ADXL345 is flagged, not trusted', () {
      final SensorInfo m = SensorInfo.fromJson(<String, Object?>{
        'present': true,
        'addr': '0x53',
        'deviceId': 0x2A,
      });
      expect(m.present, isTrue, reason: 'something did answer on the bus');
      expect(
        m.isExpectedPart,
        isFalse,
        reason: 'but it is not the part this firmware reads',
      );
    });

    test('a failed DEVID read is not the same as an absent sensor', () {
      final SensorInfo m = SensorInfo.fromJson(<String, Object?>{
        'present': true,
        'addr': '0x53',
      });
      expect(m.deviceId, isNull);
      expect(m.isExpectedPart, isFalse);
      expect(
        m.toJson().containsKey('deviceId'),
        isFalse,
        reason: 'an absent read is omitted, not sent as 0',
      );
    });

    test('the sensor object round trips through its JSON form', () {
      const SensorInfo m = SensorInfo(
        present: true,
        part: 'ADXL345',
        addr: '0x1D',
        deviceId: SensorInfo.expectedDeviceId,
      );
      expect(SensorInfo.fromJson(m.toJson()).toJson(), m.toJson());
    });
  });

  group('CALIB_LOG (§6.8) — the spec is self-contradictory', () {
    final Map<String, Object?> sample = <String, Object?>{
      't_ms': 100,
      'acc_x': 12,
      'acc_y': -34,
      'acc_z': 1002,
      'sw420': false,
    };

    test('accepts the envelope form', () {
      final CalibLogMessage log = CalibLogMessage.fromJson(<String, Object?>{
        'samples': <Object?>[sample, sample],
      });
      expect(log.samples, hasLength(2));
      expect(log.samples.first.accZ, 1002);
      expect(log.samples.first.tMs, 100);
    });

    test('accepts a bare array', () {
      final CalibLogMessage log = CalibLogMessage.fromDecoded(
        <Object?>[sample],
      );
      expect(log.samples, hasLength(1));
    });

    test('accepts one bare sample object', () {
      final CalibLogMessage log = CalibLogMessage.fromDecoded(sample);
      expect(log.samples, hasLength(1));
    });

    test('rejects a scalar payload', () {
      expect(
        () => CalibLogMessage.fromDecoded(42),
        throwsA(isA<MessageFormatException>()),
      );
    });

    test('re-encodes to the envelope form', () {
      const CalibLogMessage log = CalibLogMessage(<CalibrationSample>[
        CalibrationSample(
          tMs: 100,
          accX: 12,
          accY: -34,
          accZ: 1002,
          sw420: false,
        ),
      ]);
      expect(log.toJson().containsKey('samples'), isTrue);
      expect(log.type, MessageType.calibLog);
    });

    test('all three documented shapes survive the codec, not just the model',
        () {
      final String oneSample = jsonEncode(sample);
      final Result<DeviceMessage> envelope = MessageCodec.parsePayload(
        MessageType.calibLog.code,
        _payloadOf(const CalibLogMessage(<CalibrationSample>[_sample])),
      );
      final Result<DeviceMessage> bareArray = MessageCodec.parsePayload(
        MessageType.calibLog.code,
        Uint8List.fromList(utf8.encode('[$oneSample]')),
      );
      final Result<DeviceMessage> bareObject = MessageCodec.parsePayload(
        MessageType.calibLog.code,
        Uint8List.fromList(utf8.encode(oneSample)),
      );
      for (final Result<DeviceMessage> r in <Result<DeviceMessage>>[
        envelope,
        bareArray,
        bareObject,
      ]) {
        expect(r.isOk, isTrue, reason: '${r.failureOrNull}');
        final CalibLogMessage log = r.valueOrNull! as CalibLogMessage;
        expect(log.samples, hasLength(1));
        expect(log.samples.single.accZ, 1002);
      }
    });

    test('a JSON array where an object is required is rejected clearly', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.hello.code,
        Uint8List.fromList(utf8.encode('[1,2,3]')),
      );
      expect(parsed.isFailure, isTrue);
      expect(
        (parsed.failureOrNull!.cause! as MessageFormatException).problem,
        contains('expected a JSON object'),
        reason: 'the array must be named, not reported as a null payload',
      );
    });
  });

  group('DIAG (§6.9)', () {
    test('decodes the example and reports no faults', () {
      const String payload = '''
      {
        "uptimeMs": 423119, "cpuLoadPct": 18, "loopHz": 50,
        "heapFree": 142336, "heapMin": 138204, "stackHighWater": 4096,
        "queueDepth": 4, "droppedFrames": 0, "crcErrors": 0, "bleClients": 1,
        "sensorI2cErrors": 0, "oledOk": true, "brownoutCount": 0,
        "watchdogResets": 0, "batteryMv": 4120, "rssi": -58
      }''';
      final DiagMessage d = MessageCodec.parseJson(
        MessageType.diag,
        jsonDecode(payload) as Map<String, Object?>,
      ) as DiagMessage;
      expect(d.loopHz, 50);
      expect(d.faults, isEmpty);
    });

    test('surfaces the numbers that mean "fix something"', () {
      const DiagMessage d = DiagMessage(
        uptimeMs: 1,
        cpuLoadPct: 90,
        loopHz: 12,
        heapFree: 20000,
        watchdogResets: 2,
        brownoutCount: 1,
        sensorI2cErrors: 5,
        oledOk: false,
        droppedFrames: 3,
      );
      expect(d.faults, contains('watchdog reset x2'));
      expect(d.faults, contains('brownout x1'));
      expect(d.faults, contains('Sensor I2C errors x5'));
      expect(d.faults, contains('OLED not responding'));
      expect(d.faults, contains('3 telemetry frames dropped'));
      expect(d.faults, contains('low heap: 20000 bytes free'));
    });
  });

  group('ACK / ERROR (§6.10)', () {
    test('ACK derives ofName from of when absent', () {
      final AckMessage a = AckMessage.fromJson(<String, Object?>{
        'of': 6,
        'seq': 7,
        'op': 'CONFIRM',
      });
      expect(a.of, 6);
      expect(a.ofName, 'command');
      expect(a.seq, 7);
      expect(a.op, 'CONFIRM');
    });

    test('ERROR derives codeName from code when absent', () {
      final ErrorMessage e = ErrorMessage.fromJson(<String, Object?>{
        'code': 3,
        'message': 'cannot CONFIRM from state IDLE',
      });
      expect(e.code, 3);
      expect(e.codeName, isNull, reason: 'the device omitted it');
      expect(e.typedCode, ProtocolErrorCode.badState);
      expect(e.typedCode!.wireName, 'BAD_STATE');
    });

    test('a code this app predates stays renderable', () {
      final ErrorMessage e = ErrorMessage.fromJson(<String, Object?>{
        'code': 99,
        'message': 'from the future',
      });
      expect(e.typedCode, isNull);
      expect(e.message, 'from the future');
    });

    test('every §6.10 code maps to the documented name', () {
      const Map<ProtocolErrorCode, String> expected =
          <ProtocolErrorCode, String>{
        ProtocolErrorCode.badFrame: 'BAD_FRAME',
        ProtocolErrorCode.unsupported: 'UNSUPPORTED',
        ProtocolErrorCode.badArgs: 'BAD_ARGS',
        ProtocolErrorCode.badState: 'BAD_STATE',
        ProtocolErrorCode.notArmed: 'NOT_ARMED',
        ProtocolErrorCode.busy: 'BUSY',
        ProtocolErrorCode.internal: 'INTERNAL',
      };
      expected.forEach((ProtocolErrorCode code, String name) {
        expect(code.wireName, name);
        expect(ProtocolErrorCode.fromCode(code.code), code);
      });
    });
  });

  group('DEVICE_INFO (§6.3)', () {
    test('round trips', () {
      const DeviceInfoMessage info = DeviceInfoMessage(
        name: 'SAAS-A1B2C3D4',
        model: 'Smart Accident Alert Node v1',
        hw: 'esp32-devkit-v1',
        fwVersion: '1.0.0',
        fwBuild: 20260927,
        serial: 'A1B2C3D4E5F60718',
      );
      expect(DeviceInfoMessage.fromJson(info.toJson()).toJson(), info.toJson());
      expect(info.type, MessageType.deviceInfo);
    });
  });

  group('MessageCodec boundaries', () {
    test('an unknown type code is a protocol failure', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        0x7E,
        Uint8List.fromList(utf8.encode('{}')),
      );
      expect(parsed.isFailure, isTrue);
      expect(parsed.failureOrNull!.kind, FailureKind.protocol);
      expect(parsed.failureOrNull!.message, contains('0x7e'));
    });

    test('TELEMETRY is rejected with a pointer to the right codec', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.telemetry.code,
        Uint8List(24),
      );
      expect(parsed.isFailure, isTrue);
      expect(parsed.failureOrNull!.message, contains('TelemetryCodec'));
    });

    test('non-JSON bytes are a protocol failure, not an exception', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.status.code,
        Uint8List.fromList(<int>[0xFF, 0xFE, 0x00, 0x01]),
      );
      expect(parsed.isFailure, isTrue);
      expect(parsed.failureOrNull!.kind, FailureKind.protocol);
    });

    test('a JSON array where an object is required is rejected clearly', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.hello.code,
        Uint8List.fromList(utf8.encode('[1,2,3]')),
      );
      expect(parsed.isFailure, isTrue);
      expect(
        (parsed.failureOrNull!.cause! as MessageFormatException).problem,
        contains('expected a JSON object'),
      );
    });

    test('an integral double is accepted where an int is required', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.ack.code,
        Uint8List.fromList(utf8.encode('{"of":6.0,"seq":7.0}')),
      );
      expect(parsed.isOk, isTrue, reason: '${parsed.failureOrNull}');
      expect((parsed.valueOrNull! as AckMessage).seq, 7);
    });

    test('a fractional double where an int is required is rejected', () {
      final Result<DeviceMessage> parsed = MessageCodec.parsePayload(
        MessageType.ack.code,
        Uint8List.fromList(utf8.encode('{"of":6,"seq":7.5}')),
      );
      expect(parsed.isFailure, isTrue);
      expect(
        (parsed.failureOrNull!.cause! as MessageFormatException).field,
        'seq',
      );
    });
  });
}
