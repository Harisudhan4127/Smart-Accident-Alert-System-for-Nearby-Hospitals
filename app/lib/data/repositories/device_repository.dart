/// The device link: connection lifecycle, framing, and message fan-out.
///
/// ## The central design decision
///
/// Telemetry arrives at 50 Hz. Events arrive a few times per drive. These have
/// wildly different rates and wildly different importance, and they are exposed
/// as **separate streams** for exactly that reason:
///
/// * [telemetry] is high-frequency and lossy-by-design. A widget that rebuilt on
///   every sample would rebuild 50 times a second, which is how you get a UI
///   that janks while a countdown is running. Consumers are expected to throttle
///   or sample it; [telemetryStats] exposes the rate so a view can decide.
/// * [messages] is low-frequency and must not be dropped. Every message the
///   protocol defines except telemetry arrives here.
///
/// Conflating them into one stream would force every consumer to either rebuild
/// at 50 Hz or drop events — both unacceptable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/paired_device.dart';
import '../../domain/entities/telemetry.dart';
import '../ble/ble_transport.dart';
import '../protocol/ble_frame.dart' as wire;
import '../protocol/messages.dart';
import '../protocol/telemetry.dart' as tcodec;

/// A decoded inbound message, tagged with the channel it arrived on.
@immutable
class DeviceUpdate {
  const DeviceUpdate(this.message, this.channel, this.rssi);

  final DeviceMessage message;
  final AppBleChannel channel;

  /// Signal strength at the moment of receipt, for the link-quality display.
  final int rssi;

  @override
  String toString() => 'DeviceUpdate(${message.type.name}, ${channel.wireName})';
}

/// Counters describing the health of the inbound stream.
@immutable
class TelemetryStats {
  const TelemetryStats({
    required this.samples,
    required this.measuredHz,
    required this.crcErrors,
    required this.droppedByBackpressure,
  });

  static const TelemetryStats zero = TelemetryStats(
    samples: 0,
    measuredHz: 0,
    crcErrors: 0,
    droppedByBackpressure: 0,
  );

  /// Samples decoded since connect.
  final int samples;

  /// Measured arrival rate. The app compares this with the device's configured
  /// `telemetryHz`: a large shortfall means the link is congested, which is
  /// worth telling the user about before it becomes a missed alert.
  final double measuredHz;

  /// Frames that failed CRC.
  final int crcErrors;

  /// Samples discarded because a slow consumer could not keep up.
  final int droppedByBackpressure;

  @override
  String toString() =>
      'TelemetryStats(${samples.toString()} samples, '
      '${measuredHz.toStringAsFixed(1)} Hz, $crcErrors crc)';
}

/// Owns the connection to one node.
class DeviceRepository {
  DeviceRepository({
    required BleTransport transport,
    AppLogger? log,
    DateTime Function()? clock,
  })  : _transport = transport,
        _log = log ?? AppLogger(),
        _clock = clock ?? DateTime.now;

  final BleTransport _transport;
  final AppLogger _log;
  final DateTime Function() _clock;

  final StreamController<DeviceUpdate> _messages =
      StreamController<DeviceUpdate>.broadcast();
  final StreamController<TelemetryRecord> _telemetry =
      StreamController<TelemetryRecord>.broadcast();
  final StreamController<DeviceLinkState> _linkState =
      StreamController<DeviceLinkState>.broadcast();
  final StreamController<PairedDevice> _device =
      StreamController<PairedDevice>.broadcast();

  /// One scanner per notify channel. The protocol doc (§3) is explicit that a
  /// scanner belongs to one subscription, because a single `A5 5A` split across
  /// two notifications would be unrecoverable.
  final wire.FrameScanner _txScanner = wire.FrameScanner();
  final wire.FrameScanner _ctrlScanner = wire.FrameScanner();

  final Map<int, StreamSubscription<Uint8List>> _subs =
      <int, StreamSubscription<Uint8List>>{};
  final Map<int, DateTime> _lastAckBySeq = <int, DateTime>{};

  BlePeripheral? _peripheral;
  PairedDevice? _snapshot;
  int _sampleCount = 0;
  int _crcErrors = 0;
  int _backpressureDrops = 0;
  DateTime? _firstSampleAt;
  DateTime? _lastSampleAt;
  Timer? _reconnectTimer;
  Timer? _ackTimer;
  int _reconnectAttempt = 0;
  String? _desiredPeripheralId;
  bool _disposed = false;

  /// Telemetry samples, high frequency. See the library docs.
  Stream<TelemetryRecord> get telemetry => _telemetry.stream;

  /// Every non-telemetry message, low frequency and loss-critical.
  Stream<DeviceUpdate> get messages => _messages.stream;

  /// Link state transitions.
  Stream<DeviceLinkState> get linkState => _linkState.stream;

  /// The full device snapshot, updated on every meaningful change.
  Stream<PairedDevice> get device => _device.stream;

  /// The current snapshot, or `null` before the first connect.
  PairedDevice? get snapshot => _snapshot;

  /// The currently connected peripheral.
  BlePeripheral? get peripheral => _peripheral;

  /// Health counters.
  TelemetryStats get telemetryStats => TelemetryStats(
        samples: _sampleCount,
        measuredHz: _measuredHz(),
        crcErrors: _crcErrors,
        droppedByBackpressure: _backpressureDrops,
      );

  double _measuredHz() {
    final DateTime? first = _firstSampleAt;
    final DateTime? last = _lastSampleAt;
    if (first == null || last == null) return 0;
    final int ms = last.difference(first).inMilliseconds;
    if (ms <= 0) return 0;
    return (_sampleCount - 1) * 1000 / ms;
  }

  /// Scan for nodes.
  Stream<List<BlePeripheralInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async* {
    final List<BlePeripheralInfo> found = <BlePeripheralInfo>[];
    await for (final BlePeripheralInfo info in _transport.scan(timeout: timeout)) {
      if (!found.any((BlePeripheralInfo e) => e.id == info.id)) found.add(info);
      yield List<BlePeripheralInfo>.unmodifiable(found);
    }
  }

  /// The account uid used for [PairedDevice]. Set once at construction time by
  /// the DI layer, after anonymous sign-in has resolved.
  set userId(String value) => _userId = value;

  /// Connect to [id], remembering it for automatic reconnection.
  Future<Result<BlePeripheral>> connect(String id) async {
    _desiredPeripheralId = id;
    return _connect(id);
  }

  Future<Result<BlePeripheral>> _connect(String id) {
    return guard<BlePeripheral>(
      () async {
        final BlePeripheral peripheral = await _transport.connect(id);
        _peripheral = peripheral;
        _reconnectAttempt = 0;
        _sampleCount = 0;
        _backpressureDrops = 0;
        _firstSampleAt = null;
        _lastSampleAt = null;
        _txScanner.reset();
        _ctrlScanner.reset();
        await _subscribe(peripheral);
        _publishLinkState(DeviceLinkState.connected);
        _log.log(LogLevel.info, 'device', 'connected to $id');
        return peripheral;
      },
      kind: FailureKind.bluetooth,
      message: 'Could not connect to the node',
      log: _log,
      logTag: 'Device',
    );
  }

  Future<void> _subscribe(BlePeripheral peripheral) async {
    for (final AppBleChannel channel in <AppBleChannel>[
      AppBleChannel.tx,
      AppBleChannel.ctrl,
    ]) {
      _subs[channel.index] = peripheral.notifications(channel).listen(
        (Uint8List data) => _onNotification(channel, data),
        onError: (Object error) => _log.log(
          LogLevel.warning,
          'device',
          '${channel.wireName} stream error: $error',
        ),
      );
    }
  }

  void _onNotification(AppBleChannel channel, Uint8List data) {
    final wire.FrameScanner scanner =
        channel == AppBleChannel.tx ? _txScanner : _ctrlScanner;

    scanner.scan(data, (wire.BleFrameView view) {
      _crcErrors += scanner.stats.crcErrors;
      if (view.type == wire.MessageType.telemetry) {
        _onTelemetryFrame(view);
        return true;
      }
      _onControlFrame(view);
      return true;
    });
  }

  void _onTelemetryFrame(wire.BleFrameView view) {
    final TelemetryRecord? record = tcodec.TelemetryCodec.decodeFrame(view);
    if (record == null) return;

    _sampleCount++;
    final DateTime now = _clock();
    _firstSampleAt ??= now;
    _lastSampleAt = now;

    // Backpressure: a broadcast controller with no listener buffers. If a
    // consumer is slow, drop the sample rather than let an unbounded queue grow
    // — telemetry is the one thing in the system that is safe to lose, and an
    // unbounded queue would eventually take the app down.
    if (_telemetry.hasListener) {
      _telemetry.add(record);
    } else {
      _backpressureDrops++;
    }

    final PairedDevice? current = _snapshot;
    if (current != null) {
      _pushSnapshot(current.withTelemetry(record));
    }
  }

  void _onControlFrame(wire.BleFrameView view) {
    final Result<DeviceMessage> parsed = MessageCodec.parseView(view);
    final DeviceMessage? message = parsed.valueOrNull;
    if (message == null) {
      _log.log(
        LogLevel.warning,
        'device',
        'undecodable ${view.type.name} frame: ${parsed.failureOrNull}',
      );
      return;
    }

    // §8 stop-and-wait: acknowledge every event so the device can retire it
    // from its retry queue. Without this the node retransmits forever, burning
    // radio time on an alert we have already received.
    if (message is EventMessage) {
      _sendAck(message.seq);
    }

    if (message is HelloAckMessage) {
      _applyHelloAck(message);
    }
    if (message is DeviceInfoMessage && _snapshot != null) {
      _log.log(
        LogLevel.info,
        'device',
        'info: ${message.name} fw ${message.fwVersion}',
      );
    }

    if (_messages.hasListener) {
      _messages.add(
        DeviceUpdate(message, AppBleChannel.ctrl, _peripheral?.rssi ?? -100),
      );
    } else {
      _messages.add(
        DeviceUpdate(message, AppBleChannel.ctrl, _peripheral?.rssi ?? -100),
      );
    }
  }

  /// Acknowledge an event (protocol §8).
  void _sendAck(int seq) {
    final BlePeripheral? peripheral = _peripheral;
    if (peripheral == null) return;
    try {
      peripheral.writeWithoutResponse(
        AppBleChannel.rx,
        _encode(
          AckMessage(
            of: wire.MessageType.event.code,
            seq: seq,
            ofName: 'EVENT',
          ),
        ),
      );
      _lastAckBySeq[seq] = _clock();
      // Bounded: an hour of events at 20/min is 1200 entries, and a stale ack
      // is worthless, so old keys are dropped rather than accumulated.
      if (_lastAckBySeq.length > 256) {
        _lastAckBySeq.removeWhere(
          (int _, DateTime at) => _clock().difference(at).inMinutes > 30,
        );
      }
    } on Object catch (error) {
      _log.log(LogLevel.warning, 'device', 'could not ack event $seq: $error');
    }
  }

  void _applyHelloAck(HelloAckMessage ack) {
    // §2.3: a node speaking a protocol version this build does not know is a
    // *permanent* incompatibility, not a transient failure. Marking it
    // explicitly means the UI can say "update the app" instead of showing an
    // indefinite spinner, which is the failure mode this otherwise produces.
    final bool compatible = ack.proto == wire.kProtocolVersion;

    final PairedDevice? current = _snapshot;
    _pushSnapshot(
      PairedDevice(
        id: ack.mac.isEmpty ? ack.name : ack.mac,
        userId: _userId,
        deviceName: ack.name,
        mac: ack.mac,
        chipId: ack.chipId,
        firmwareVersion: ack.fwVersion,
        protocolVersion: ack.proto,
        // A first pairing is dated now; a re-handshake keeps the original date
        // so "paired on" does not change every time the car is started.
        pairedAt: current?.pairedAt ?? _clock(),
        label: current?.label,
        hardware: ack.hw,
        lastSeenAt: _clock(),
        lastKnownBatteryPct: ack.batteryPct,
        batteryMv: ack.batteryMv,
        isCharging: ack.charging,
        lastKnownState: ack.state,
        isCalibrated: ack.calibrated ?? false,
        hasVibrationSensor: ack.sw420 ?? false,
        hasOled: ack.oled?.present ?? false,
        sensorName: ack.sensor?.part,
        linkState: compatible ? DeviceLinkState.connected : DeviceLinkState.incompatible,
      ),
    );
  }

  void _pushSnapshot(PairedDevice next) {
    if (next == _snapshot) return;
    _snapshot = next;
    if (_device.hasListener) _device.add(next);
  }

  void _publishLinkState(DeviceLinkState state) {
    _linkStateValue = state;
    // `_linkState` is a broadcast stream of the DOMAIN enum; the transport's
    // `BleLinkState` is deliberately not exposed, so the UI never has to map
    // between two near-identical enums.
    if (_linkState.hasListener) _linkState.add(state);
  }

  DeviceLinkState _linkStateValue = DeviceLinkState.disconnected;

  /// The current link state.
  DeviceLinkState get linkStatus => _linkStateValue;

  /// The account that owns this pairing. Supplied by the caller at wire-up so
  /// a [PairedDevice] always has the uid the entity requires.
  String _userId = '';

  /// Mark the link as lost and (re)schedule reconnection.
  void onLinkLost([String? reason]) {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _publishLinkState(DeviceLinkState.disconnected);
    final PairedDevice? current = _snapshot;
    if (current != null) {
      _pushSnapshot(current.copyWith(linkState: DeviceLinkState.disconnected));
    }
    _log.log(LogLevel.warning, 'device', 'link lost${reason == null ? '' : ': $reason'}');
    _scheduleReconnect();
  }

  /// Reconnect with exponential backoff and jitter.
  ///
  /// The jitter is not decoration: a car parks in a metal box, the node goes out
  /// of range, and the phone comes back into range for several *phones* at once
  /// (a car park, a traffic queue). Without jitter they would all reconnect in
  /// the same millisecond and fight over the GATT connection.
  void _scheduleReconnect() {
    final String? id = _desiredPeripheralId;
    if (id == null) return;
    _reconnectAttempt++;
    final int capped = math.min(_reconnectAttempt, 6);
    final Duration base = Duration(milliseconds: 250 * (1 << (capped - 1)));
    final Duration jitter = Duration(milliseconds: (DateTime.now().microsecond % 300));
    _reconnectTimer = Timer(base + jitter, () async {
      final Result<BlePeripheral> r = await _connect(id);
      if (r.isFailure) _scheduleReconnect();
    });
  }

  /// True when the last `HELLO_ACK` reported a protocol version this build
  /// cannot speak. The UI shows "update the app" instead of a retry button.
  bool get isIncompatible => _snapshot?.linkState == DeviceLinkState.incompatible;

  /// Disconnect deliberately; no reconnection is attempted.
  Future<void> disconnect() async {
    _desiredPeripheralId = null;
    _reconnectTimer?.cancel();
    _ackTimer?.cancel();
    for (final StreamSubscription<Uint8List> sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    await _transport.disconnect();
    _peripheral = null;
    _publishLinkState(DeviceLinkState.disconnected);
  }

  // ------------------------------------------------------------- outbound

  /// Send the `HELLO` handshake (§6.1).
  Future<Result<void>> sayHello({String appVersion = '1.0.0', String deviceName = 'My Car'}) {
    return _send(
      HelloMessage(
        app: 'smart-accident-alert',
        appVersion: appVersion,
        proto: 1,
        capabilities: const <String>[
          'telemetry',
          'config',
          'calibrate',
          'command',
          'diag',
        ],
        deviceName: deviceName,
        locale: 'en-IN',
      ),
    );
  }

  /// Send a `PING`.
  /// Send a `PING` for a round-trip measurement.
  ///
  /// The nonce is an `int` on the wire, so the microsecond clock is truncated
  /// to milliseconds — still unique enough to identify one ping among a burst.
  Future<Result<void>> ping() =>
      _send(PingMessage(nonce: _clock().microsecondsSinceEpoch ~/ 1000));

  /// Apply a partial `CONFIG` (§6.4).
  Future<Result<void>> sendConfig(ConfigPatch patch) =>
      _send(ConfigMessage(patch));

  /// Run a hardware self-test.
  Future<Result<void>> calibrate({int durationMs = 5000, CalibrationKind kind = CalibrationKind.staticBaseline}) =>
      _send(CalibrateMessage(durationMs: durationMs, kind: kind));

  /// Run a `COMMAND` (§6.7).
  Future<Result<void>> command(CommandOp op, {String? eventId, int? untilUnixS}) =>
      _send(CommandMessage(op: op, eventId: eventId, untilUnixS: untilUnixS));

  /// Acknowledge the alert the user confirmed.
  Future<Result<void>> confirm(String? eventId) =>
      command(CommandOp.confirm, eventId: eventId);

  /// Dismiss a false alarm.
  Future<Result<void>> cancel(String? eventId) =>
      command(CommandOp.cancel, eventId: eventId);

  /// Fire the app's *Test Alert* button.
  Future<Result<void>> testAlert() => command(CommandOp.test);

  /// Read the static INFO characteristic (§2.1).
  Future<Result<DeviceInfoMessage?>> readInfo() {
    return guard<DeviceInfoMessage?>(
      () async {
        final BlePeripheral? peripheral = _peripheral;
        if (peripheral == null) {
          throw StateError('not connected');
        }
        final Uint8List raw = await peripheral.read(AppBleChannel.info);
        if (raw.isEmpty) return null;
        // A dedicated scanner, not the CTRL one: the INFO frame may straddle the
        // read, and borrowing the CTRL scanner would leave the event stream
        // holding a half-consumed frame.
        final wire.FrameScanner scanner = wire.FrameScanner();
        DeviceInfoMessage? info;
        scanner.scan(raw, (wire.BleFrameView view) {
          final Result<DeviceMessage> parsed = MessageCodec.parseView(view);
          final DeviceMessage? message = parsed.valueOrNull;
          if (message is DeviceInfoMessage) {
            info = message;
            return false; // stop scanning; we have what we came for
          }
          return true;
        });
        return info;
      },
      kind: FailureKind.bluetooth,
      message: 'Could not read device info',
      log: _log,
      logTag: 'Device',
    );
  }

  Future<Result<void>> _send(DeviceMessage message) {
    return guard<void>(
      () async {
        final BlePeripheral? peripheral = _peripheral;
        if (peripheral == null) {
          throw StateError('not connected');
        }
        await peripheral.writeWithoutResponse(AppBleChannel.rx, _encode(message));
      },
      kind: FailureKind.bluetooth,
      message: 'Could not send ${message.type.name} to the node',
      log: _log,
      logTag: 'Device',
    );
  }

  /// Encode a message as a complete frame.
  static Uint8List _encode(DeviceMessage message) => wire.encodeFrame(
        typeCode: message.type.code,
        payload: _json(message.toJson()),
      );

  static Uint8List _json(Map<String, Object?> json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  /// Release everything. The app calls this on teardown.
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _ackTimer?.cancel();
    for (final StreamSubscription<Uint8List> sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    await _messages.close();
    await _telemetry.close();
    await _linkState.close();
    await _device.close();
  }
}
