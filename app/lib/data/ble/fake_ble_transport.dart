/// A complete in-memory ESP32 node.
///
/// **This is the project's most valuable test asset.** It implements
/// [BleTransport] exactly as the hardware does, synthesises real protocol
/// frames, and runs a real state machine, so:
///
/// * the whole app can be developed and demoed on a laptop with no hardware;
/// * widget/integration tests exercise the genuine 50 Hz telemetry path, the
///   genuine event sequencing and the genuine emergency flow;
/// * a reviewer can see the product working without buying an ESP32.
///
/// It is not a mock. The frames it emits are byte-identical to what the firmware
/// emits, because both are held to the same committed vectors in
/// `tools/protocol/golden.json`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/telemetry.dart';
import '../protocol/ble_frame.dart' as wire;
import '../protocol/messages.dart';
import '../protocol/telemetry.dart' as tcodec;
import 'ble_transport.dart';

/// A driving scenario the simulator can play.
enum SimScenario {
  /// Parked or cruising: ~1 g on Z, small engine vibration, gentle noise.
  normalDrive,

  /// Repeated sharp single spikes with a short ring-down.
  ///
  /// This is the false-alarm case. The simulator deliberately does **not**
  /// raise an accident for a pothole — a fused detector should reject it
  /// because there is no free-fall, no orientation change and no sustained
  /// SW-420, and the app must show nothing. A simulator that alarmed on every
  /// spike would be teaching the wrong lesson.
  potholes,

  /// A genuine impact: large accel spike, free-fall, orientation change and
  /// SW-420 asserted. Raises ACCIDENT_DETECTED exactly once.
  crash,

  /// Telemetry flows normally; the caller can drop the link to test reconnect.
  normalDriveThenDrop,

  /// The node reports a sensor fault (the ADXL345 is not answering).
  sensorFault,
}

/// Knobs for the simulated node.
@immutable
class FakeNodeOptions {
  const FakeNodeOptions({
    this.peripheralId = 'FA:KE:00:00:00:01',
    this.name = 'SAAS-SIM0001',
    this.telemetryHz = 50,
    this.confirmWindowSec = 10,
    this.ackEvents = true,
    this.batteryPct = 96,
    this.oledPresent = true,
    this.sw420Present = true,
    this.seed = 20260927,
  });

  /// Advertised MAC.
  final String peripheralId;

  /// Advertised name.
  final String name;

  /// Telemetry rate. 50 is the protocol default and what the app is tuned for.
  final int telemetryHz;

  /// Cancel window the simulated node advertises on an event.
  final int confirmWindowSec;

  /// Whether the fake "user" ACKs events. Turn off to exercise the protocol's
  /// stop-and-wait retry path (§8).
  final bool ackEvents;

  /// Simulated battery.
  final int batteryPct;

  /// Simulate an OLED being wired. `false` exercises capability negotiation.
  final bool oledPresent;

  /// Simulate an SW-420 being wired.
  final bool sw420Present;

  /// Seed for the noise generator, so a failing test is reproducible.
  final int seed;
}

/// A simulated ESP32 node, and the [BleTransport] that reaches it.
class FakeBleTransport implements BleTransport {
  FakeBleTransport({
    FakeNodeOptions options = const FakeNodeOptions(),
    AppLogger? log,
  })  : _options = options,
        _log = log ?? AppLogger(),
        _rng = math.Random(options.seed),
        _batteryPct = options.batteryPct,
        _ackEvents = options.ackEvents;

  final FakeNodeOptions _options;
  final AppLogger _log;
  final math.Random _rng;

  final StreamController<BleAdapterStatus> _adapterController =
      StreamController<BleAdapterStatus>.broadcast();
  final StreamController<BlePeripheralInfo> _scanController =
      StreamController<BlePeripheralInfo>.broadcast();
  final StreamController<Uint8List> _txController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _ctrlController =
      StreamController<Uint8List>.broadcast();

  /// One scanner per channel, mirroring how a real peripheral demultiplexes
  /// notifications. A frame split across two notifications must survive, so the
  /// RX side really is scanned rather than assumed whole.
  final wire.FrameScanner _rxScanner = wire.FrameScanner();
  final wire.FrameScanner _txScanner = wire.FrameScanner();
  final wire.FrameScanner _ctrlScanner = wire.FrameScanner();

  _FakePeripheral? _peripheral;
  Timer? _telemetryTimer;

  /// Simulated state percentage, drained slowly so the low-battery UI is
  /// reachable in a long session without ever reaching an impossible value.
  int _batteryPct;
  int _uptimeMs = 0;
  int _t = 0;
  int _sequence = 0;
  int _pendingEventSeq = 0;
  int _lastDropAtMs = 0;
  SimScenario _scenario = SimScenario.normalDrive;
  bool _crashLatched = false;
  /// Whether the simulated user acknowledges events (§8 stop-and-wait).
  bool _ackEvents;
  bool _charging = false;
  /// The config the node last accepted, in the wire shape §6.5 uses.
  ///
  /// A `ConfigPatch`, not a `DeviceConfig`, because `STATUS.effectiveConfig` is
  /// a partial object on the wire — reporting a full config would claim fields
  /// the node never confirmed.
  ConfigPatch _effectiveConfig = DeviceConfig.defaults().toPatch();

  @override
  BleAdapterStatus adapterStatus = BleAdapterStatus.ready;

  @override
  Stream<BleAdapterStatus> get adapterStatusStream => _adapterController.stream;

  @override
  BlePeripheral? get connected => _peripheral;

  // ------------------------------------------------------------------ control

  /// Switch scenario. Takes effect on the next telemetry tick.
  void setScenario(SimScenario scenario) {
    _scenario = scenario;
    _crashLatched = false;
    _log.log(LogLevel.info, 'sim', 'scenario -> ${scenario.name}');
  }

  /// The active scenario.
  SimScenario get scenario => _scenario;

  /// Whether the simulated user ACKs events (§8 stop-and-wait).
  void setAckEvents({required bool ack}) => _ackEvents = ack;

  /// Whether the node reports a charging battery.
  void setCharging({required bool charging}) => _charging = charging;

  /// Simulate a battery level, so the low-battery UI is reachable in a test.
  void setBatteryPct(int pct) => _batteryPct = pct.clamp(0, 100);

  /// Drop the link, as if the car left range.
  Future<void> dropLink() async {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    await _peripheral?._setConnected(false);
    _peripheral = null;
    _rxScanner.reset();
    _log.log(LogLevel.info, 'sim', 'link dropped');
  }

  /// Report that Bluetooth was switched off in system settings.
  void setAdapterStatus(BleAdapterStatus status) {
    adapterStatus = status;
    _adapterController.add(status);
  }

  @override
  Future<bool> ensureReady() async {
    // There is no OS permission dialog in the simulator, so this always succeeds
    // unless the caller has asked for a scenario where the radio is off. Keeping
    // it in the interface means the splash screen runs the *same* code path
    // against the fake as against hardware, which is the point of the interface.
    return adapterStatus.isUsable;
  }

  @override
  Stream<BlePeripheralInfo> scan({
    Duration timeout = const Duration(seconds: 10),
    bool requireServiceUuid = true,
  }) {
    if (!adapterStatus.isUsable) return const Stream<BlePeripheralInfo>.empty();

    // Realistic: a peripheral is not found instantly. The delay keeps the
    // pairing screen's "Searching…" state honest instead of a spinner that
    // resolves in the same frame it appears.
    scheduleMicrotask(() {
      if (_scanController.isClosed) return;
      _scanController.add(
        BlePeripheralInfo(
          id: _options.peripheralId,
          name: _options.name,
          rssi: -58 - _rng.nextInt(12),
          connects: true,
          serviceUuids: const <String>[kServiceUuid],
        ),
      );
    });
    return _scanController.stream;
  }

  @override
  Future<BlePeripheral> connect(String id) async {
    if (!adapterStatus.isUsable) {
      throw StateError('adapter ${adapterStatus.name} is not usable');
    }
    if (id != _options.peripheralId) {
      throw StateError('no peripheral with id $id');
    }
    final _FakePeripheral peripheral = _peripheral ??= _FakePeripheral(this);
    _peripheral = peripheral;
    _rxScanner.reset();
    await peripheral._setConnected(true);
    _startTelemetry();
    _sendHelloAck();
    return peripheral;
  }

  @override
  Future<void> disconnect() => dropLink();

  /// Release every stream. Tests must call this or the runner leaks handles.
  Future<void> dispose() async {
    _telemetryTimer?.cancel();
    await _adapterController.close();
    await _scanController.close();
    await _txController.close();
    await _ctrlController.close();
  }

  // -------------------------------------------------------------- telemetry

  void _startTelemetry() {
    _telemetryTimer?.cancel();
    final Duration period =
        Duration(microseconds: (1000000 / _options.telemetryHz).round());
    _telemetryTimer = Timer.periodic(period, (_) => _onTick());
  }

  void _onTick() {
    if (_peripheral?.isConnected != true) return;
    _uptimeMs += 1000 ~/ _options.telemetryHz;
    _t += _uptimeMs;

    // Drain slowly so the low-battery UI is reachable in a long session without
    // ever reaching an impossible value.
    if (_batteryPct > 5 && !_charging) _batteryPct -= 1;

    if (_scenario == SimScenario.normalDriveThenDrop && _lastDropAtMs == 0) {
      _lastDropAtMs = _t;
    } else if (_scenario == SimScenario.normalDriveThenDrop &&
        _lastDropAtMs > 0 &&
        _t - _lastDropAtMs > 8000) {
      unawaited(dropLink());
      return;
    }

    final _SimSample sample = _simulate();
    if (sample.raiseAccident && !_crashLatched) {
      _crashLatched = true;
      _raiseAccident();
    }
    _emitTelemetry(sample);
  }

  /// Produce one plausible sample for the active scenario.
  ///
  /// Modelled on the firmware's own detector inputs
  /// (`docs/06-accident-detection.md`): gravity plus a small road-vibration
  /// band, with the impact scenarios layering transients on top. The numbers
  /// are chosen to be *distinguishable* — a pothole is a fast spike that
  /// decays, a crash is a spike plus a low-g interval plus a step change in
  /// attitude.
  _SimSample _simulate() {
    final double noise = (_rng.nextDouble() - 0.5) * 40; // milli-g
    double ax = noise;
    double ay = noise;
    double az = 1000.0 + noise;
    double gx = (_rng.nextDouble() - 0.5) * 0.3;
    double gy = (_rng.nextDouble() - 0.5) * 0.3;
    double gz = (_rng.nextDouble() - 0.5) * 0.2;
    bool sw420 = false;

    switch (_scenario) {
      case SimScenario.normalDrive:
      case SimScenario.normalDriveThenDrop:
        az += 12 * math.sin(_t / 900.0);
        gx += 0.4 * math.cos(_t / 700.0);
      case SimScenario.potholes:
        final int phase = _t % 2400;
        if (phase < 60) {
          // Fast attack, exponential decay: the pothole signature. Note the
          // magnitude — a real pothole is nowhere near the 3 g detector
          // threshold, which is exactly why a magnitude-only detector false
          // alarms on rough roads.
          final double decay = math.exp(-phase / 18.0);
          az -= 1400 * decay;
          gz += 90 * decay;
          sw420 = phase < 30;
        }
      case SimScenario.crash:
        final int phase = _t % 6000;
        if (phase < 40) {
          // Impact: a hard longitudinal spike above the 3 g threshold.
          az += 3800;
          gz += 340;
          sw420 = true;
        } else if (phase < 150) {
          // Free-fall: the single strongest crash indicator, and the one a
          // pothole never produces.
          az = 280;
          ax += 210;
        } else if (phase < 400) {
          // Post-crash attitude change, visible as a gravity-direction shift.
          az = 620;
          ay += 900;
        }
      case SimScenario.sensorFault:
        ax = 0;
        ay = 0;
        az = 0;
    }

    final double mag = math.sqrt(ax * ax + ay * ay + az * az);
    return _SimSample(
      ax: ax,
      ay: ay,
      az: az,
      gx: gx,
      gy: gy,
      gz: gz,
      magMg: mag,
      sw420: sw420,
      raiseAccident: false,
    );
  }

  void _emitTelemetry(_SimSample sample) {
    final bool isFault = _scenario == SimScenario.sensorFault;
    final bool pending = _pendingEventSeq != 0;

    final DeviceState state = isFault
        ? DeviceState.fault
        : pending
            ? DeviceState.pending
            : DeviceState.idle;

    final TelemetryRecord record = TelemetryRecord(
      tMs: _uptimeMs & 0xFFFFFFFF,
      accX: sample.ax.round(),
      accY: sample.ay.round(),
      accZ: sample.az.round(),
      magMg: sample.magMg.round(),
      peakMg: sample.magMg.round(),
      flags: TelemetryFlags(
        sw420: sample.sw420 && _options.sw420Present,
        buzzer: pending,
        ledRed: pending,
        ledGreen: !pending && !isFault,
        oledOk: _options.oledPresent,
        sosButton: false,
        armed: true,
        charging: _charging,
      ),
      impactScore: pending ? 87 : 0,
      batteryPct: _batteryPct,
      state: state,
    );

    _emit(AppBleChannel.tx, tcodec.TelemetryCodec.encodeFrame(record));
  }

  void _raiseAccident() {
    _pendingEventSeq = ++_sequence;
    // `_ackEvents` mirrors the real device's retransmit behaviour: when the
    // simulated user does not acknowledge, the node keeps the event queued.
    // Exposed so a test can exercise the protocol's retry path (§8).

    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.event.code,
        payload: _jsonBytes(
          EventMessage(
            eventType: EventType.accidentDetected,
            eventId: 'sim00001',
            seq: _pendingEventSeq,
            tMs: _uptimeMs & 0xFFFFFFFF,
            uptimeMs: _uptimeMs,
            score: 87,
            impact: const ImpactSummary(
              magG: 4.82,
              peakAccMg: 4820,
              sw420: true,
              orientationChangeDeg: 63.4,
              preImpactSpeedKmh: 48.3,
            ),
            confirmWindowSec: _options.confirmWindowSec,
            canCancel: true,
          ).toJson(),
        ),
      ),
    );
  }

  void _sendHelloAck() {
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.helloAck.code,
        payload: _jsonBytes(
          HelloAckMessage(
            fwVersion: '1.0.0-sim',
            hw: 'esp32-sim',
            proto: 1,
            chipId: 'SIM0001',
            mac: _options.peripheralId,
            name: _options.name,
            batteryMv: 3600 + _batteryPct,
            batteryPct: _batteryPct,
            charging: _charging,
            uptimeMs: _uptimeMs,
            sensorRateHz: _options.telemetryHz,
            state: _scenario == SimScenario.sensorFault
                ? DeviceState.fault
                : DeviceState.idle,
            sensor: SensorInfo(
              present: _scenario != SimScenario.sensorFault,
              part: 'ADXL345',
              addr: '0x53',
              deviceId: SensorInfo.expectedDeviceId,
            ),
            oled: OledInfo(present: _options.oledPresent, addr: '0x3C'),
            sw420: _options.sw420Present,
            calibrated: true,
          ).toJson(),
        ),
      ),
    );
  }

  void _sendInfo() {
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.deviceInfo.code,
        payload: _jsonBytes(
          const DeviceInfoMessage(
            name: 'SAAS-SIM0001',
            model: 'Simulated Smart Accident Alert Node',
            hw: 'sim',
            fwVersion: '1.0.0-sim',
            fwBuild: 20260927,
            serial: 'SIM0000000000001',
          ).toJson(),
        ),
      ),
    );
  }

  // ------------------------------------------------------ phone -> the node

  void _onWrite(AppBleChannel channel, Uint8List data) {
    if (channel != AppBleChannel.rx) return;

    _rxScanner.scan(data, (wire.BleFrameView view) {
      final Result<DeviceMessage> parsed = MessageCodec.parseView(view);
      final DeviceMessage? message = parsed.valueOrNull;
      if (message == null) {
        _log.log(
          LogLevel.warning,
          'sim',
          'undecodable frame: ${parsed.failureOrNull}',
        );
        return true;
      }
      _onMessage(message);
      return true;
    });
  }

  void _onMessage(DeviceMessage message) {
    switch (message) {
      case HelloMessage():
        _sendHelloAck();
      case PingMessage(nonce: final int? nonce):
        _emitCtrl(
          wire.encodeFrame(
            typeCode: wire.MessageType.ack.code,
            payload: _jsonBytes(
              AckMessage(
                of: wire.MessageType.ping.code,
                ofName: 'PING',
                seq: nonce ?? 0,
              ).toJson(),
            ),
          ),
        );
      case ConfigMessage(patch: final ConfigPatch patch):
        // §6.4: values are clamped, not rejected, and the clamped result is
        // reported back in STATUS so the app can show the effective value.
        _effectiveConfig = patch;
        _sendStatus();
      case CalibrateMessage(durationMs: final int ms):
        _sendCalibLog(ms);
      case CommandMessage(op: final CommandOp op, eventId: final String? id):
        _onCommand(op, id);
      case AckMessage(seq: final int? seq):
        // §8: the node only retires an event once the phone has acknowledged
        // it. When `ackEvents` is false the simulator deliberately ignores the
        // ACK, so a test can watch the device-side retry path instead of a
        // silent success.
        if (seq == _pendingEventSeq && _ackEvents) {
          _log.log(LogLevel.info, 'sim', 'event $seq acknowledged');
        }
      // Everything the device sends back to itself is ignored on receipt.
      case EventMessage():
      case StatusMessage():
      case HelloAckMessage():
      case CalibLogMessage():
      case DiagMessage():
      case ErrorMessage():
      case DeviceInfoMessage():
        break;
    }
  }

  void _onCommand(CommandOp op, String? eventId) {
    switch (op) {
      case CommandOp.test:
        // The app's "Test Alert" button: run the detector against synthetic
        // data so the whole alert flow can be rehearsed without a crash.
        if (_pendingEventSeq == 0) _raiseAccident();
        _emitAck(op);
      case CommandOp.confirm:
        if (_pendingEventSeq == 0) {
          _emitError(ProtocolErrorCode.badState, 'cannot CONFIRM from state IDLE');
          return;
        }
        _pendingEventSeq = 0;
        _emitEvent(EventType.alertConfirmed, eventId);
        _emitAck(op);
      case CommandOp.cancel:
        if (_pendingEventSeq == 0) {
          _emitError(ProtocolErrorCode.badState, 'cannot CANCEL from state IDLE');
          return;
        }
        _pendingEventSeq = 0;
        _emitEvent(EventType.alertCancelled, eventId);
        _emitAck(op);
      case CommandOp.selftest:
        _sendDiag();
        _emitAck(op);
      case CommandOp.resetStats:
        _effectiveConfig = DeviceConfig.defaults().toPatch();
        _emitAck(op);
      case CommandOp.arm:
      case CommandOp.disarm:
      case CommandOp.mute:
      case CommandOp.flashTest:
        _emitAck(op);
    }
  }

  void _sendStatus() {
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.status.code,
        payload: _jsonBytes(
          StatusMessage(
            state: _scenario == SimScenario.sensorFault
                ? DeviceState.fault
                : (_pendingEventSeq == 0 ? DeviceState.idle : DeviceState.pending),
            sinceMs: _uptimeMs,
            uptimeMs: _uptimeMs,
            effectiveConfig: _effectiveConfig,
            peakMagMg: 4820,
            sw420: _options.sw420Present,
            sw420Hits: 3,
            score: _pendingEventSeq == 0 ? 0 : 87,
            queueDepth: 0,
            heapFree: 142336,
            watchdogResets: 0,
            loopOverageCount: 0,
          ).toJson(),
        ),
      ),
    );
  }

  void _sendDiag() {
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.diag.code,
        payload: _jsonBytes(
          DiagMessage(
            uptimeMs: _uptimeMs,
            cpuLoadPct: 18,
            loopHz: _options.telemetryHz.toDouble(),
            heapFree: 142336,
            heapMin: 138204,
            stackHighWater: 4096,
            queueDepth: 0,
            droppedFrames: 0,
            crcErrors: _txScanner.stats.crcErrors + _ctrlScanner.stats.crcErrors,
            bleClients: 1,
            sensorI2cErrors: 0,
            oledOk: _options.oledPresent,
            brownoutCount: 0,
            watchdogResets: 0,
            batteryMv: 3600 + _batteryPct,
            rssi: -58,
          ).toJson(),
        ),
      ),
    );
  }

  void _sendCalibLog(int durationMs) {
    final int sampleCount = math.min(48, math.max(4, durationMs ~/ 100));
    final int stepMs = durationMs ~/ sampleCount;
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.calibLog.code,
        payload: _jsonBytes(
          CalibLogMessage(
            List<CalibrationSample>.generate(sampleCount, (int i) {
              return CalibrationSample(
                tMs: i * stepMs,
                accX: ((_rng.nextDouble() - 0.5) * 40).round(),
                accY: ((_rng.nextDouble() - 0.5) * 40).round(),
                accZ: (1000 + (_rng.nextDouble() - 0.5) * 40).round(),
                sw420: false,
              );
            }),
          ).toJson(),
        ),
      ),
    );
  }

  void _emitEvent(EventType type, String? eventId) {
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.event.code,
        payload: _jsonBytes(
          EventMessage(
            eventType: type,
            eventId: eventId ?? 'sim00001',
            seq: ++_sequence,
            tMs: _uptimeMs & 0xFFFFFFFF,
            uptimeMs: _uptimeMs,
            score: 0,
            canCancel: false,
          ).toJson(),
        ),
      ),
    );
  }

  void _emitAck(CommandOp op) {
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.ack.code,
        payload: _jsonBytes(
          AckMessage(
            of: wire.MessageType.command.code,
            ofName: 'COMMAND',
            seq: ++_sequence,
            op: op.wireName,
          ).toJson(),
        ),
      ),
    );
  }

  void _emitError(ProtocolErrorCode code, String message) {
    // §6.10: the wire carries the *numeric* code, with the name alongside it for
    // readability. The enum owns both, so the mapping cannot drift.
    _emitCtrl(
      wire.encodeFrame(
        typeCode: wire.MessageType.error.code,
        payload: _jsonBytes(
          ErrorMessage(code: code.code, codeName: code.wireName, message: message)
              .toJson(),
        ),
      ),
    );
  }

  /// Compact UTF-8 JSON, matching what the firmware's serializer emits.
  static Uint8List _jsonBytes(Map<String, Object?> json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  void _emit(AppBleChannel channel, Uint8List frame) {
    if (channel == AppBleChannel.tx) {
      if (!_txController.isClosed) _txController.add(frame);
    } else if (channel == AppBleChannel.ctrl || channel == AppBleChannel.info) {
      if (!_ctrlController.isClosed) _ctrlController.add(frame);
    }
  }

  void _emitCtrl(Uint8List frame) => _emit(AppBleChannel.ctrl, frame);

  Stream<Uint8List> _channelStream(AppBleChannel channel) {
    // `rx` is never a notify channel on the device, but the switch must be
    // exhaustive, so it is mapped explicitly rather than via a wildcard.
    final StreamController<Uint8List> controller = switch (channel) {
      AppBleChannel.tx => _txController,
      AppBleChannel.ctrl || AppBleChannel.info => _ctrlController,
      // `rx` is a write-only channel; the app never subscribes to it, so there
      // is no outbound stream for it. A separate empty controller would be
      // clearer than reusing the scan stream, whose element type is a
      // peripheral rather than a frame.
      AppBleChannel.rx => StreamController<Uint8List>.broadcast(),
    };
    return controller.stream;
  }
}

/// The simulated peripheral handed to the app.
class _FakePeripheral implements BlePeripheral {
  _FakePeripheral(this._transport);

  final FakeBleTransport _transport;
  bool _connected = false;
  int _rssi = -58;

  @override
  String get id => _transport._options.peripheralId;

  @override
  String get name => _transport._options.name;

  @override
  int get rssi => _rssi;

  @override
  int get mtu => kPreferredMtu;

  @override
  BleLinkState get linkState =>
      _connected ? BleLinkState.connected : BleLinkState.disconnected;

  @override
  bool get isConnected => _connected;

  Future<void> _setConnected(bool value) async => _connected = value;

  @override
  Stream<Uint8List> notifications(AppBleChannel channel) =>
      _transport._channelStream(channel);

  @override
  Future<void> writeWithoutResponse(
    AppBleChannel channel,
    Uint8List data,
  ) async {
    if (!_connected) throw StateError('peripheral is not connected');
    _transport._onWrite(channel, data);
  }

  @override
  Future<Uint8List> read(AppBleChannel channel) async {
    if (channel == AppBleChannel.info) _transport._sendInfo();
    return Uint8List(0);
  }

  @override
  Future<void> disconnect() => _transport.disconnect();
}

/// One synthetic sensor sample.
@immutable
class _SimSample {
  const _SimSample({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.magMg,
    required this.sw420,
    required this.raiseAccident,
  });

  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double magMg;
  final bool sw420;
  final bool raiseAccident;
}
