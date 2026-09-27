/// Typed codecs for the JSON messages in §6 of the protocol.
///
/// ## Why this file exists
///
/// §4 gives every message a code and a direction, but §6 gives the *shapes*,
/// and the shapes are what break: a firmware field renamed, an `int` arriving
/// as a `double`, a `null` where a `String` is documented. This file is the one
/// place that knows those shapes, so the BLE service, the repositories and the
/// tests all agree on what a `STATUS` is.
///
/// ## The no-`dynamic` rule
///
/// `jsonDecode` returns `dynamic`. `decodeJsonValue` ([ble_frame.dart]) already
/// re-freezes that into a `Map<String, Object?>`, so nothing here ever touches
/// `dynamic`. Field access goes through [JsonReader], which throws
/// [MessageFormatException] with the offending field name rather than letting a
/// `TypeError` escape. [MessageCodec.parse] converts that into a
/// [FailureResult], so nothing above this file has to catch anything.
///
/// ## A note on clamping
///
/// §6.4 says the *device* clamps out-of-range `CONFIG` values and reports the
/// effective value in `STATUS`. [DeviceConfig.clamp] mirrors those bounds so
/// the app can predict what the device will do, and so a slider can show the
/// clamped value before the round trip. The device stays authoritative: see
/// [StatusMessage.effectiveConfig].
library;

import 'dart:typed_data';

import '../../core/result.dart';
import '../../domain/entities/telemetry.dart';
import 'ble_frame.dart';

/// Thrown by [JsonReader] when a payload does not match the documented schema.
///
/// Carries [field] and [message] so a failing parse can say *which* key was
/// wrong — the difference between a five-minute and a five-hour debugging
/// session on a device that is not in front of you.
final class MessageFormatException implements Exception {
  /// Creates a format error for [field] explaining [problem].
  const MessageFormatException(this.field, this.problem);

  /// The JSON key at fault, or `null` when the whole payload is wrong.
  final String? field;

  /// What was expected, and what was found.
  final String problem;

  @override
  String toString() => field == null
      ? 'MessageFormatException: $problem'
      : 'MessageFormatException: field "$field": $problem';
}

/// Typed accessors over a decoded `Map<String, Object?>`.
///
/// Every method either returns the value in the right type or throws
/// [MessageFormatException]. There is no "return null and hope" path, because
/// the fields this reads are all required by §6.
final class JsonReader {
  /// Wraps [json] for typed access.
  JsonReader(this.json);

  /// The frozen payload.
  final Map<String, Object?> json;

  /// The keys actually present, for error messages and diagnostics.
  Iterable<String> get keys => json.keys;

  /// Whether [key] is present and not `null`.
  bool has(String key) => json[key] != null;

  Object? _raw(String key) {
    if (!json.containsKey(key)) {
      throw MessageFormatException(key, 'required key is missing');
    }
    return json[key];
  }

  /// A required `String`.
  String string(String key) {
    final Object? v = _raw(key);
    if (v is String) {
      return v;
    }
    throw MessageFormatException(key, 'expected String, got ${v.runtimeType}');
  }

  /// An optional `String`; `null` when absent or JSON `null`.
  String? stringOrNull(String key) {
    final Object? v = json[key];
    if (v == null) {
      return null;
    }
    if (v is String) {
      return v;
    }
    throw MessageFormatException(key, 'expected String, got ${v.runtimeType}');
  }

  /// A required integer. Accepts a JSON `double` that is exactly integral,
  /// because firmware that computes `4.0` and serialises it as `4.0` is
  /// producing a number, and rejecting it would be pedantry, not safety.
  int integer(String key) {
    final Object? v = _raw(key);
    if (v is int) {
      return v;
    }
    if (v is double && v.isFinite && v == v.roundToDouble()) {
      return v.toInt();
    }
    throw MessageFormatException(key, 'expected int, got ${v.runtimeType}');
  }

  /// An optional integer.
  int? integerOrNull(String key) => json[key] == null ? null : integer(key);

  /// A required finite double. `NaN`/infinity cannot appear in JSON, but a
  /// future non-standard serialiser could produce them, and a NaN in a
  /// distance calculation silently poisons everything downstream.
  double number(String key) {
    final Object? v = _raw(key);
    if (v is num) {
      final double d = v.toDouble();
      if (d.isFinite) {
        return d;
      }
      throw MessageFormatException(key, 'expected a finite number, got $d');
    }
    throw MessageFormatException(key, 'expected number, got ${v.runtimeType}');
  }

  /// An optional finite double.
  double? numberOrNull(String key) => json[key] == null ? null : number(key);

  /// A required `bool`.
  bool boolean(String key) {
    final Object? v = _raw(key);
    if (v is bool) {
      return v;
    }
    throw MessageFormatException(key, 'expected bool, got ${v.runtimeType}');
  }

  /// An optional `bool`.
  bool? booleanOrNull(String key) => json[key] == null ? null : boolean(key);

  /// A required nested object.
  JsonReader object(String key) => JsonReader(_asObject(key, _raw(key)));

  /// An optional nested object.
  JsonReader? objectOrNull(String key) {
    if (json[key] == null) {
      return null;
    }
    return JsonReader(_asObject(key, _raw(key)));
  }

  /// A required array of objects.
  List<JsonReader> objectList(String key) {
    final Object? v = _raw(key);
    if (v is! List<Object?>) {
      throw MessageFormatException(key, 'expected array, got ${v.runtimeType}');
    }
    return <JsonReader>[
      for (final Object? item in v)
        if (item is Map<String, Object?>)
          JsonReader(item)
        else
          throw MessageFormatException(key, 'array element is not an object'),
    ];
  }

  /// A required array of strings.
  List<String> stringList(String key) {
    final Object? v = _raw(key);
    if (v is! List<Object?>) {
      throw MessageFormatException(key, 'expected array, got ${v.runtimeType}');
    }
    return <String>[
      for (final Object? item in v)
        if (item is String)
          item
        else
          throw MessageFormatException(key, 'array element is not a string'),
    ];
  }

  static Map<String, Object?> _asObject(String key, Object? v) {
    if (v is Map<String, Object?>) {
      return v;
    }
    throw MessageFormatException(key, 'expected object, got ${v.runtimeType}');
  }
}

/// Base class for every §6 message.
///
/// Sealed so the BLE service can `switch` over what arrived and get a compile
/// error when a new type is added, rather than silently dropping it.
sealed class DeviceMessage {
  /// Const constructor for the subclasses.
  const DeviceMessage();

  /// The wire type code and direction.
  MessageType get type;

  /// The payload as §6 documents it. Key order is insertion order, which is
  /// what the reference encoder emits (see [encodeJson]).
  Map<String, Object?> toJson();

  /// This message as a complete, ready-to-write frame.
  Uint8List toFrameBytes({bool pad = false}) => encodeJsonFrame(
        typeCode: type.code,
        json: toJson(),
        pad: pad,
      );
}

/// `0x01` phone → device. Opens the session (§6.1).
final class HelloMessage extends DeviceMessage {
  /// Creates a `HELLO`.
  const HelloMessage({
    required this.app,
    required this.appVersion,
    required this.proto,
    required this.capabilities,
    required this.deviceName,
    required this.locale,
  });

  /// Decodes a `HELLO` payload.
  factory HelloMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return HelloMessage(
      app: r.string('app'),
      appVersion: r.string('appVersion'),
      proto: r.integer('proto'),
      capabilities: r.stringList('capabilities'),
      deviceName: r.string('deviceName'),
      locale: r.string('locale'),
    );
  }

  /// Sent as `app`; the device ignores it, but it makes logs greppable.
  final String app;

  /// The app build that produced this session, for firmware-side bug reports.
  final String appVersion;

  /// Protocol version the phone speaks (§3).
  final int proto;

  /// Features the phone can handle, e.g. `telemetry`, `config`, `calibrate`,
  /// `command`, `diag`. The device must not emit a feature that is absent here.
  final List<String> capabilities;

  /// User-supplied name for this vehicle, shown in the UI.
  final String deviceName;

  /// BCP-47-ish locale tag, e.g. `en-IN`.
  final String locale;

  @override
  MessageType get type => MessageType.hello;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'app': app,
        'appVersion': appVersion,
        'proto': proto,
        'capabilities': capabilities,
        'deviceName': deviceName,
        'locale': locale,
      };
}

/// `0x02` phone → device. Liveness probe.
final class PingMessage extends DeviceMessage {
  /// Creates a `PING`. [nonce] is echoed back in the `ACK` so the caller can
  /// measure round-trip time; the device does not interpret it.
  const PingMessage({this.nonce});

  /// Decodes a `PING` payload. Every field is optional, so an empty object is
  /// a valid `PING`.
  factory PingMessage.fromJson(Map<String, Object?> json) =>
      PingMessage(nonce: JsonReader(json).integerOrNull('nonce'));

  /// Opaque echo value.
  final int? nonce;

  @override
  MessageType get type => MessageType.ping;

  @override
  Map<String, Object?> toJson() =>
      <String, Object?>{if (nonce != null) 'nonce': nonce};
}

/// `0x04` phone → device. A partial update: absent keys keep their value
/// (§6.4), which is why this is a patch and not a whole [DeviceConfig].
final class ConfigMessage extends DeviceMessage {
  /// Creates a `CONFIG` patch.
  const ConfigMessage(this.patch);

  /// Decodes a `CONFIG` payload, ignoring keys this version does not know.
  ///
  /// Ignoring unknown keys is deliberate: a newer app that adds a setting must
  /// not brick `CONFIG` against older firmware.
  factory ConfigMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return ConfigMessage(
      ConfigPatch(
        accelThresholdMg: r.integerOrNull('accelThresholdMg'),
        gyroThresholdDps: r.numberOrNull('gyroThresholdDps'),
        vibrationRequired: r.booleanOrNull('vibrationRequired'),
        debounceMs: r.integerOrNull('debounceMs'),
        confirmWindowSec: r.integerOrNull('confirmWindowSec'),
        minSpeedKmh: r.numberOrNull('minSpeedKmh'),
        detectorGain: r.numberOrNull('detectorGain'),
        telemetryHz: r.integerOrNull('telemetryHz'),
        buzzerEnabled: r.booleanOrNull('buzzerEnabled'),
        ledEnabled: r.booleanOrNull('ledEnabled'),
        muteUntil: r.integerOrNull('muteUntil'),
        autoArm: r.booleanOrNull('autoArm'),
      ),
    );
  }

  /// The requested changes.
  final ConfigPatch patch;

  @override
  MessageType get type => MessageType.config;

  @override
  Map<String, Object?> toJson() => patch.toJson();
}

/// `0x05` phone → device. Starts a calibration capture (§6.8).
final class CalibrateMessage extends DeviceMessage {
  /// Creates a `CALIBRATE`.
  const CalibrateMessage({required this.durationMs, required this.kind});

  /// Decodes a `CALIBRATE` payload.
  factory CalibrateMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return CalibrateMessage(
      durationMs: r.integer('durationMs'),
      kind: CalibrationKind.require(r.string('kind')),
    );
  }

  /// How long to sample for. Long enough to average out vibration.
  final int durationMs;

  /// Which calibration to run.
  final CalibrationKind kind;

  @override
  MessageType get type => MessageType.calibrate;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'durationMs': durationMs,
        'kind': kind.wireName,
      };
}

/// The calibration procedures §6.8 supports.
enum CalibrationKind {
  /// Capture a still-vehicle baseline for the accelerometer.
  staticBaseline('STATIC_BASELINE'),

  /// Capture gyro bias offsets.
  gyroBias('GYRO_BIAS');

  const CalibrationKind(this.wireName);

  /// The exact string on the wire.
  final String wireName;

  /// Parses [name], or returns `null` for anything unknown.
  static CalibrationKind? fromName(String name) {
    for (final CalibrationKind kind in CalibrationKind.values) {
      if (kind.wireName == name) {
        return kind;
      }
    }
    return null;
  }

  /// Like [fromName] but throws, for a required field.
  static CalibrationKind require(String name) {
    final CalibrationKind? kind = fromName(name);
    if (kind == null) {
      throw MessageFormatException('kind', 'unknown calibration "$name"');
    }
    return kind;
  }
}

/// `0x06` phone → device. The command surface (§6.7).
final class CommandMessage extends DeviceMessage {
  /// Creates a `COMMAND`.
  const CommandMessage({
    required this.op,
    this.eventId,
    this.untilUnixS,
  });

  /// Decodes a `COMMAND` payload.
  factory CommandMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return CommandMessage(
      op: CommandOp.require(r.string('op')),
      eventId: r.stringOrNull('eventId'),
      untilUnixS: r.integerOrNull('untilUnixS'),
    );
  }

  /// Which action to take.
  final CommandOp op;

  /// The event being acted on. Required by `CONFIRM`/`CANCEL`, ignored
  /// otherwise. A mismatched `eventId` is the device's cue to ignore a stale
  /// command that arrived after the user already dismissed the alert.
  final String? eventId;

  /// For `MUTE`: when the buzzer comes back. Unix seconds; `0` means never.
  final int? untilUnixS;

  @override
  MessageType get type => MessageType.command;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'op': op.wireName,
        if (eventId != null) 'eventId': eventId,
        if (untilUnixS != null) 'untilUnixS': untilUnixS,
      };
}

/// The operations §6.7 defines.
enum CommandOp {
  /// Cancel the countdown and escalate to `ALARM`.
  confirm('CONFIRM'),

  /// Cancel the countdown, clear any alarm, return to `IDLE`.
  cancel('CANCEL'),

  /// Run the detector against synthetic data (the *Test Alert* button).
  test('TEST'),

  /// Enable the detection loop.
  arm('ARM'),

  /// Disable the detection loop.
  disarm('DISARM'),

  /// Silence the buzzer until [CommandMessage.untilUnixS].
  mute('MUTE'),

  /// Blink the LEDs so the user can verify the wiring.
  flashTest('FLASH_TEST'),

  /// Full hardware self-test; the device replies with `DIAG`.
  selftest('SELFTEST'),

  /// Clear the peak-hold and counter statistics.
  resetStats('RESET_STATS');

  const CommandOp(this.wireName);

  /// The exact string on the wire.
  final String wireName;

  /// Parses [name], or `null` when unknown.
  static CommandOp? fromName(String name) {
    for (final CommandOp op in CommandOp.values) {
      if (op.wireName == name) {
        return op;
      }
    }
    return null;
  }

  /// Like [fromName] but throws, for a required field.
  static CommandOp require(String name) {
    final CommandOp? op = fromName(name);
    if (op == null) {
      throw MessageFormatException('op', 'unknown command "$name"');
    }
    return op;
  }

  /// Whether this command must name the event it applies to.
  bool get requiresEventId => this == confirm || this == cancel;
}

/// `0x07` device → phone. Acknowledges a phone message (§6.10, §8).
final class AckMessage extends DeviceMessage {
  /// Creates an `ACK`.
  const AckMessage({
    required this.of,
    required this.ofName,
    this.seq,
    this.op,
  });

  /// Decodes an `ACK` payload.
  factory AckMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return AckMessage(
      of: r.integer('of'),
      ofName: r.stringOrNull('ofName') ??
          MessageType.fromCode(r.integer('of'))?.name,
      seq: r.integerOrNull('seq'),
      op: r.stringOrNull('op'),
    );
  }

  /// The type code being acknowledged.
  final int of;

  /// Its name, for logs. Derived from [of] when the device omits it.
  final String? ofName;

  /// The event sequence number this ACK confirms. `null` for a `PING`, `0` for
  /// the retried `HELLO_ACK` (§8).
  final int? seq;

  /// The command being acknowledged, echoed for readability.
  final String? op;

  @override
  MessageType get type => MessageType.ack;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'of': of,
        if (ofName != null) 'ofName': ofName,
        if (seq != null) 'seq': seq,
        if (op != null) 'op': op,
      };
}

/// `0x08` device → phone (§6.10).
final class ErrorMessage extends DeviceMessage {
  /// Creates an `ERROR`.
  const ErrorMessage({
    required this.code,
    required this.message,
    this.codeName,
  });

  /// Decodes an `ERROR` payload.
  factory ErrorMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return ErrorMessage(
      code: r.integer('code'),
      codeName: r.stringOrNull('codeName'),
      message: r.string('message'),
    );
  }

  /// The numeric code from §6.10.
  final int code;

  /// Its name, for logs. Derived from [code] when the device omits it.
  final String? codeName;

  /// Human-readable detail, safe to show in a diagnostics screen.
  final String message;

  /// The typed code, or `null` if the device sent a code this app predates.
  ProtocolErrorCode? get typedCode => ProtocolErrorCode.fromCode(code);

  @override
  MessageType get type => MessageType.error;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        if (codeName != null) 'codeName': codeName,
        'message': message,
      };
}

/// The error codes §6.10 defines.
enum ProtocolErrorCode {
  /// CRC or SOF failure.
  badFrame(0, 'BAD_FRAME'),

  /// Unknown type or version.
  unsupported(1, 'UNSUPPORTED'),

  /// Malformed JSON.
  badArgs(2, 'BAD_ARGS'),

  /// The command is not legal from the current state (§7).
  badState(3, 'BAD_STATE'),

  /// Detection is disabled.
  notArmed(4, 'NOT_ARMED'),

  /// The device is already busy with the previous command.
  busy(5, 'BUSY'),

  /// A bug on the device.
  internal(6, 'INTERNAL');

  const ProtocolErrorCode(this.code, this.wireName);

  /// The numeric code on the wire.
  final int code;

  /// The name exactly as §6.10 spells it.
  ///
  /// Stored per value rather than derived from [name]: the spec uses
  /// underscores (`BAD_STATE`, `NOT_ARMED`), and a mechanical
  /// `name.toUpperCase()` would emit `BADSTATE` — a string the firmware never
  /// sends. Deriving a wire format from a Dart identifier is exactly the kind
  /// of shortcut that survives review and fails on a device.
  final String wireName;

  /// Parses [code], or `null` when unknown.
  static ProtocolErrorCode? fromCode(int code) {
    for (final ProtocolErrorCode value in ProtocolErrorCode.values) {
      if (value.code == code) {
        return value;
      }
    }
    return null;
  }
}

/// `0x09` device → phone. The single event envelope (§6.6).
///
/// Every user-relevant event shares this type with a `type` discriminator, so
/// there is one parser to keep in sync with the firmware instead of a dozen.
final class EventMessage extends DeviceMessage {
  /// Creates an `EVENT`.
  const EventMessage({
    required this.eventType,
    required this.eventId,
    required this.seq,
    required this.tMs,
    required this.uptimeMs,
    this.score,
    this.impact,
    this.confirmWindowSec,
    this.canCancel,
  });

  /// Decodes an `EVENT` payload.
  ///
  /// The impact block is only present for the impact-bearing types, and
  /// [canCancel] is only meaningful while a countdown is running, so both are
  /// optional. [EventType] is required: an event with an unrecognised
  /// discriminator is a protocol change, and swallowing it would lose an
  /// accident.
  factory EventMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    final EventType eventType = EventType.require(r.string('type'));
    final JsonReader? impact = r.objectOrNull('impact');
    return EventMessage(
      eventType: eventType,
      eventId: r.string('eventId'),
      seq: r.integer('seq'),
      tMs: r.integer('t_ms'),
      uptimeMs: r.integer('uptimeMs'),
      score: r.integerOrNull('score'),
      impact: impact == null ? null : ImpactSummary.fromReader(impact),
      confirmWindowSec: r.integerOrNull('confirmWindowSec'),
      canCancel: r.booleanOrNull('canCancel'),
    );
  }

  /// Which event this is.
  final EventType eventType;

  /// Unique id derived from the chip's hardware MAC (§6.6). This is what makes
  /// re-delivery safe: the app de-duplicates on it, so the stop-and-wait
  /// retransmit in §8 cannot create two alerts.
  final String eventId;

  /// Monotonic event counter; `ACK{of: 9, seq: n}` confirms it.
  final int seq;

  /// Device milliseconds since boot. Note the wire key is `t_ms`, matching
  /// the telemetry record, even though the JSON convention here is camelCase.
  final int tMs;

  /// Same clock as [tMs]; the device emits both during the §7 transition.
  final int uptimeMs;

  /// Detector confidence, 0…100. Higher means a more certain impact.
  final int? score;

  /// The measured impact, for the types that have one.
  final ImpactSummary? impact;

  /// How long the user has to cancel, in seconds.
  final int? confirmWindowSec;

  /// Whether a `CANCEL` will be honoured right now.
  final bool? canCancel;

  @override
  MessageType get type => MessageType.event;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType.wireName,
        'eventId': eventId,
        'seq': seq,
        't_ms': tMs,
        'uptimeMs': uptimeMs,
        if (score != null) 'score': score,
        if (impact != null) 'impact': impact!.toJson(),
        if (confirmWindowSec != null) 'confirmWindowSec': confirmWindowSec,
        if (canCancel != null) 'canCancel': canCancel,
      };
}

/// The event discriminator values in §6.6.
enum EventType {
  /// The fused detector crossed threshold.
  accidentDetected('ACCIDENT_DETECTED'),

  /// The physical SOS button was pressed.
  manualSos('MANUAL_SOS'),

  /// The user (or the button) cancelled.
  alertCancelled('ALERT_CANCELLED'),

  /// The countdown elapsed, or the user confirmed.
  alertConfirmed('ALERT_CONFIRMED'),

  /// The device acknowledged that dispatch started.
  alertSent('ALERT_SENT'),

  /// The user marked the incident resolved.
  resolved('RESOLVED'),

  /// A sensor fault or a watchdog reset.
  deviceFault('DEVICE_FAULT');

  const EventType(this.wireName);

  /// The exact string on the wire.
  final String wireName;

  /// Parses [name], or `null` when unknown.
  static EventType? fromName(String name) {
    for (final EventType type in EventType.values) {
      if (type.wireName == name) {
        return type;
      }
    }
    return null;
  }

  /// Like [fromName] but throws, for a required field.
  static EventType require(String name) {
    final EventType? type = fromName(name);
    if (type == null) {
      throw MessageFormatException('type', 'unknown event "$name"');
    }
    return type;
  }

  /// Whether this event means an impact was measured, and so carries an
  /// [ImpactSummary].
  bool get hasImpact => this == accidentDetected || this == manualSos;

  /// Whether the user can still cancel at the moment this is emitted.
  bool get isCancellable => this == accidentDetected || this == manualSos;
}

/// The `impact` block of an [EventMessage] (§6.6).
///
/// Deliberately the *summary* rather than the raw record: this is what the
/// alert screen shows, and the 50 Hz detail lives in [TelemetryRecord].
final class ImpactSummary {
  /// Creates an impact summary.
  const ImpactSummary({
    required this.magG,
    required this.peakAccMg,
    required this.peakGyrDps,
    required this.gyrMagDps,
    required this.sw420,
    this.orientationChangeDeg,
    this.preImpactSpeedKmh,
  });

  /// Decodes an `impact` object.
  factory ImpactSummary.fromJson(Map<String, Object?> json) =>
      ImpactSummary.fromReader(JsonReader(json));

  /// Decodes an `impact` object from an existing [JsonReader].
  factory ImpactSummary.fromReader(JsonReader r) => ImpactSummary(
        magG: r.number('magG'),
        peakAccMg: r.integer('peakAccMg'),
        peakGyrDps: r.integer('peakGyrDps'),
        gyrMagDps: r.number('gyrMagDps'),
        sw420: r.boolean('sw420'),
        orientationChangeDeg: r.numberOrNull('orientationChangeDeg'),
        preImpactSpeedKmh: r.numberOrNull('preImpactSpeedKmh'),
      );

  /// Combined accelerometer magnitude in g at the moment of peak.
  final double magG;

  /// Peak accelerometer magnitude in milli-g.
  ///
  /// An `int`, not a `double`, and that is not laziness: the golden vector
  /// carries `4820`, not `4820.0`, so a `double` here re-encodes to different
  /// bytes and fails golden conformance. The split is coherent rather than
  /// arbitrary — `magG` and `gyrMagDps` are computed magnitudes and genuinely
  /// fractional, while `peakAccMg` and `peakGyrDps` are whole units that happen
  /// to be small. The wire types are honoured instead of smoothed over.
  final int peakAccMg;

  /// Peak gyroscope rate in degrees per second, whole degrees. See [peakAccMg]
  /// for why this is an `int`.
  final int peakGyrDps;

  /// Combined gyroscope magnitude in degrees per second.
  final double gyrMagDps;

  /// Whether the SW-420 vibration sensor also fired.
  final bool sw420;

  /// How far the vehicle had rotated before the impact, in degrees. `null`
  /// when the device has no orientation estimate.
  final double? orientationChangeDeg;

  /// Speed before the impact, in km/h. `null` when there is no GPS link.
  final double? preImpactSpeedKmh;

  /// The §6.6 object form.
  Map<String, Object?> toJson() => <String, Object?>{
        'magG': magG,
        'peakAccMg': peakAccMg,
        'peakGyrDps': peakGyrDps,
        'gyrMagDps': gyrMagDps,
        'sw420': sw420,
        if (orientationChangeDeg != null)
          'orientationChangeDeg': orientationChangeDeg,
        if (preImpactSpeedKmh != null) 'preImpactSpeedKmh': preImpactSpeedKmh,
      };
}

/// `0x11` device → phone (§6.5). Also the reply to `CONFIG`.
final class StatusMessage extends DeviceMessage {
  /// Creates a `STATUS`.
  const StatusMessage({
    required this.state,
    required this.sinceMs,
    required this.uptimeMs,
    this.stateName,
    this.effectiveConfig,
    this.peakMagMg,
    this.peakGyrDps,
    this.sw420,
    this.sw420Hits,
    this.score,
    this.queueDepth,
    this.heapFree,
    this.watchdogResets,
    this.loopOverageCount,
  });

  /// Decodes a `STATUS` payload.
  ///
  /// `state` is decoded through [DeviceState.fromByte] so an undocumented
  /// state becomes [DeviceState.unknown] instead of throwing — a firmware
  /// that grows a new state must not stop the app from showing the old ones.
  factory StatusMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    final JsonReader? config = r.objectOrNull('effectiveConfig');
    return StatusMessage(
      state: DeviceState.fromByte(r.integer('state')),
      stateName: r.stringOrNull('stateName'),
      sinceMs: r.integer('sinceMs'),
      uptimeMs: r.integer('uptimeMs'),
      effectiveConfig: config == null ? null : ConfigPatch.fromReader(config),
      peakMagMg: r.numberOrNull('peakMagMg'),
      peakGyrDps: r.numberOrNull('peakGyrDps'),
      sw420: r.booleanOrNull('sw420'),
      sw420Hits: r.integerOrNull('sw420Hits'),
      score: r.integerOrNull('score'),
      queueDepth: r.integerOrNull('queueDepth'),
      heapFree: r.integerOrNull('heapFree'),
      watchdogResets: r.integerOrNull('watchdogResets'),
      loopOverageCount: r.integerOrNull('loopOverageCount'),
    );
  }

  /// The device state machine's current state (§7).
  final DeviceState state;

  /// Its name, for logs. Derived from [state] when the device omits it.
  final String? stateName;

  /// Milliseconds spent in [state].
  final int sinceMs;

  /// Milliseconds since boot.
  final int uptimeMs;

  /// The values the device actually applied after clamping (§6.4).
  ///
  /// This — not the requested [ConfigPatch] — is what the settings screen must
  /// display, which is the whole reason §6.4 specifies clamping instead of
  /// rejecting.
  final ConfigPatch? effectiveConfig;

  /// Peak accelerometer magnitude held since reset, milli-g.
  final double? peakMagMg;

  /// Peak gyroscope rate held since reset, °/s.
  final double? peakGyrDps;

  /// Whether the SW-420 output is currently high.
  final bool? sw420;

  /// How many times the SW-420 has fired.
  final int? sw420Hits;

  /// Current detector score, 0…100.
  final int? score;

  /// Events waiting to be delivered (§8).
  final int? queueDepth;

  /// Free heap, bytes. A number trending down across sessions is the early
  /// warning for the "works for 20 minutes" class of firmware bug.
  final int? heapFree;

  /// Watchdog resets since boot. Non-zero means the firmware crashed.
  final int? watchdogResets;

  /// Times the 50 Hz loop overran its deadline.
  final int? loopOverageCount;

  @override
  MessageType get type => MessageType.status;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'state': state.byte,
        if (stateName != null) 'stateName': stateName,
        'sinceMs': sinceMs,
        'uptimeMs': uptimeMs,
        if (effectiveConfig != null)
          'effectiveConfig': effectiveConfig!.toJson(),
        if (peakMagMg != null) 'peakMagMg': peakMagMg,
        if (peakGyrDps != null) 'peakGyrDps': peakGyrDps,
        if (sw420 != null) 'sw420': sw420,
        if (sw420Hits != null) 'sw420Hits': sw420Hits,
        if (score != null) 'score': score,
        if (queueDepth != null) 'queueDepth': queueDepth,
        if (heapFree != null) 'heapFree': heapFree,
        if (watchdogResets != null) 'watchdogResets': watchdogResets,
        if (loopOverageCount != null) 'loopOverageCount': loopOverageCount,
      };
}

/// The `mpu` object of a [HelloAckMessage] (§6.2).
final class MpuInfo {
  /// Creates MPU6050 presence info.
  const MpuInfo({
    required this.present,
    this.addr,
    this.whoAmI,
  });

  /// Decodes an `mpu` object.
  factory MpuInfo.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return MpuInfo(
      present: r.boolean('present'),
      addr: r.stringOrNull('addr'),
      whoAmI: r.integerOrNull('whoAmI'),
    );
  }

  /// Whether an MPU6050 answered on I²C. `false` is a supported state, not an
  /// error: the app shows a "sensor not connected" panel and keeps working.
  final bool present;

  /// I²C address, e.g. `0x68`.
  final String? addr;

  /// The `WHO_AM_I` register, or `null` when the read failed.
  ///
  /// This is an identity byte, not a boolean, and pinning it to one part is how
  /// you end up rejecting a perfectly good node: `0x68` is an MPU-6050/6500, but
  /// `0x70` is an MPU-6500, `0x71` an MPU-9250/9255, `0x12` an ICM-20670/20602,
  /// and every one of those drives the node fine. §6.2's own example pairs
  /// `addr: "0x68"` with `whoAmI: 113` (`0x71`), so the spec itself is not
  /// internally consistent about which part it means. Use [isKnownImu] and
  /// [whoAmIName] instead of comparing against a single constant.
  final int? whoAmI;

  /// The recognised part for [whoAmI], or `null` when it is not in the table.
  String? get whoAmIName => whoAmI == null ? null : imuNames[whoAmI];

  /// Whether [whoAmI] matches a part this app knows how to talk to.
  ///
  /// A `false` here is diagnostic, not fatal: the protocol is identical for all
  /// of these parts, and calibration is generic, so an unrecognised part still
  /// works. It just means the bus may be miswired and the value is worth
  /// showing in DIAG. Note this is deliberately *not* folded into
  /// [HelloAckMessage.fullyEquipped], which is about missing hardware.
  bool get isKnownImu => whoAmI != null && imuNames.containsKey(whoAmI);

  /// Known `WHO_AM_I` values, by part.
  ///
  /// The usual identity bytes of the 6-axis IMUs an ESP32 crash-logic node is
  /// built with. A `null` name means "responded, but not a part we recognise".
  static const Map<int, String> imuNames = <int, String>{
    0x12: 'ICM-20670/ICM-20602',
    0x19: 'ICM-20649',
    0x24: 'BMI270',
    0x67: 'ICM-42670',
    0x68: 'MPU-6050/MPU-6500',
    0x6B: 'LSM6DSO/LSM6DS3',
    0x70: 'MPU-6500/ICM-20948',
    0x71: 'MPU-9250/MPU-9255',
    0xA0: 'ICM-42688/ICM-42688-P',
  };

  /// The §6.2 object form.
  Map<String, Object?> toJson() => <String, Object?>{
        'present': present,
        if (addr != null) 'addr': addr,
        if (whoAmI != null) 'whoAmI': whoAmI,
      };
}

/// The `oled` object of a [HelloAckMessage] (§6.2).
final class OledInfo {
  /// Creates OLED presence info.
  const OledInfo({required this.present, this.addr});

  /// Decodes an `oled` object.
  factory OledInfo.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return OledInfo(
      present: r.boolean('present'),
      addr: r.stringOrNull('addr'),
    );
  }

  /// Whether an SSD1306 answered. Optional hardware, per §6.2.
  final bool present;

  /// I²C address, e.g. `0x3C`.
  final String? addr;

  /// The §6.2 object form.
  Map<String, Object?> toJson() => <String, Object?>{
        'present': present,
        if (addr != null) 'addr': addr,
      };
}

/// `0x12` device → phone. The session handshake reply (§6.2).
final class HelloAckMessage extends DeviceMessage {
  /// Creates a `HELLO_ACK`.
  const HelloAckMessage({
    required this.fwVersion,
    required this.hw,
    required this.proto,
    required this.chipId,
    required this.mac,
    required this.name,
    required this.batteryMv,
    required this.batteryPct,
    required this.charging,
    required this.uptimeMs,
    required this.sensorRateHz,
    required this.state,
    this.mpu,
    this.oled,
    this.sw420,
    this.calibrated,
    this.stateName,
  });

  /// Decodes a `HELLO_ACK` payload.
  factory HelloAckMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    final JsonReader? mpu = r.objectOrNull('mpu');
    final JsonReader? oled = r.objectOrNull('oled');
    return HelloAckMessage(
      fwVersion: r.string('fwVersion'),
      hw: r.string('hw'),
      proto: r.integer('proto'),
      chipId: r.string('chipId'),
      mac: r.string('mac'),
      name: r.string('name'),
      batteryMv: r.integer('batteryMv'),
      batteryPct: r.integer('batteryPct'),
      charging: r.boolean('charging'),
      uptimeMs: r.integer('uptimeMs'),
      sensorRateHz: r.integer('sensorRateHz'),
      state: DeviceState.fromByte(r.integer('state')),
      mpu: mpu == null ? null : MpuInfo.fromJson(mpu.json),
      oled: oled == null ? null : OledInfo.fromJson(oled.json),
      sw420: r.booleanOrNull('sw420'),
      calibrated: r.booleanOrNull('calibrated'),
      stateName: r.stringOrNull('stateName'),
    );
  }

  /// Firmware version string.
  final String fwVersion;

  /// Hardware revision, e.g. `esp32-devkit-v1`.
  final String hw;

  /// Protocol version the device speaks.
  final int proto;

  /// Last 8 hex digits of the MAC — the short id shown in the UI.
  final String chipId;

  /// Full MAC address. Also the seed for `eventId`, which is why two devices
  /// cannot collide.
  final String mac;

  /// Firmware's own name for the node, e.g. `SAAS-A1B2C3D4`.
  final String name;

  /// Battery voltage, millivolts.
  final int batteryMv;

  /// Battery charge, 0…100. `255` is the "unknown" sentinel (§5).
  final int batteryPct;

  /// Whether the node is charging.
  final bool charging;

  /// Milliseconds since boot.
  final int uptimeMs;

  /// The node's sample rate. The app throttles its *display* to 10 Hz
  /// regardless; this is what tells it the real rate.
  final int sensorRateHz;

  /// The state machine's state at handshake time.
  final DeviceState state;

  /// Its name, for logs.
  final String? stateName;

  /// MPU6050 presence and identity.
  final MpuInfo? mpu;

  /// SSD1306 presence.
  final OledInfo? oled;

  /// Whether a SW-420 is wired up. Part of the capability negotiation (§6.2).
  final bool? sw420;

  /// Whether the accelerometer baseline has been captured. `false` means the
  /// detector is running on factory defaults, and the app should say so.
  final bool? calibrated;

  /// Whether every optional sensor the firmware knows about is present.
  ///
  /// The app renders the degraded state rather than erroring (§6.2): a user who
  /// never wired the OLED still gets a working app.
  bool get fullyEquipped =>
      (mpu?.present ?? false) && (oled?.present ?? true) && (sw420 ?? false);

  @override
  MessageType get type => MessageType.helloAck;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'fwVersion': fwVersion,
        'hw': hw,
        'proto': proto,
        'chipId': chipId,
        'mac': mac,
        'name': name,
        'batteryMv': batteryMv,
        'batteryPct': batteryPct,
        'charging': charging,
        'uptimeMs': uptimeMs,
        if (mpu != null) 'mpu': mpu!.toJson(),
        if (oled != null) 'oled': oled!.toJson(),
        if (sw420 != null) 'sw420': sw420,
        if (calibrated != null) 'calibrated': calibrated,
        'sensorRateHz': sensorRateHz,
        'state': state.byte,
        if (stateName != null) 'stateName': stateName,
      };
}

/// `0x13` device → phone. Downsampled calibration samples (§6.8).
final class CalibLogMessage extends DeviceMessage {
  /// Creates a `CALIB_LOG` from [samples].
  const CalibLogMessage(this.samples);

  /// Decodes a `CALIB_LOG` payload.
  ///
  /// ## A real spec ambiguity
  ///
  /// §4 calls this payload a "JSON array" and §6.8 calls it "an array of
  /// downsampled samples", but the example in §6.8 is a single sample
  /// *object*, not an array. Firmware built from either reading is plausible,
  /// so this accepts all three shapes and normalises them:
  ///
  /// * `{"samples": [ … ]}` — an envelope, which is what we emit;
  /// * `[ … ]` — a bare array, per the literal wording;
  /// * `{ … }` — one bare sample, per the literal example.
  ///
  /// Decoding permissively here is safe: these are *diagnostics*, so accepting
  /// a shape costs nothing, and rejecting one would leave the calibration
  /// chart permanently empty on some firmware.
  factory CalibLogMessage.fromJson(Map<String, Object?> json) {
    if (json.containsKey('samples')) {
      return CalibLogMessage(
        JsonReader(json).objectList('samples').map(_sample).toList(),
      );
    }
    return CalibLogMessage(<CalibrationSample>[_sample(JsonReader(json))]);
  }

  /// Decodes a `CALIB_LOG` from an already-decoded payload that may be a bare
  /// array rather than an object.
  factory CalibLogMessage.fromDecoded(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      return CalibLogMessage.fromJson(decoded);
    }
    if (decoded is List<Object?>) {
      return CalibLogMessage(<CalibrationSample>[
        for (final Object? item in decoded)
          if (item is Map<String, Object?>)
            _sample(JsonReader(item))
          else
            throw const MessageFormatException(
              'samples',
              'array element is not an object',
            ),
      ]);
    }
    throw const MessageFormatException(
      null,
      'CALIB_LOG payload is neither an object nor an array',
    );
  }

  static CalibrationSample _sample(JsonReader r) => CalibrationSample(
        tMs: r.integer('t_ms'),
        accX: r.integer('acc_x'),
        accY: r.integer('acc_y'),
        accZ: r.integer('acc_z'),
        gyrX: r.integer('gyr_x'),
        gyrY: r.integer('gyr_y'),
        gyrZ: r.integer('gyr_z'),
        sw420: r.booleanOrNull('sw420') ?? false,
      );

  /// The samples, oldest first.
  final List<CalibrationSample> samples;

  @override
  MessageType get type => MessageType.calibLog;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'samples': <Object?>[
          for (final CalibrationSample s in samples)
            <String, Object?>{
              't_ms': s.tMs,
              'acc_x': s.accX,
              'acc_y': s.accY,
              'acc_z': s.accZ,
              'gyr_x': s.gyrX,
              'gyr_y': s.gyrY,
              'gyr_z': s.gyrZ,
              'sw420': s.sw420,
            },
        ],
      };
}

/// `0x14` device → phone. Hardware diagnostics (§6.9).
final class DiagMessage extends DeviceMessage {
  /// Creates a `DIAG`.
  const DiagMessage({
    required this.uptimeMs,
    required this.cpuLoadPct,
    required this.loopHz,
    required this.heapFree,
    this.heapMin,
    this.stackHighWater,
    this.queueDepth,
    this.droppedFrames,
    this.crcErrors,
    this.bleClients,
    this.mpuI2cErrors,
    this.oledOk,
    this.brownoutCount,
    this.watchdogResets,
    this.batteryMv,
    this.rssi,
  });

  /// Decodes a `DIAG` payload.
  factory DiagMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return DiagMessage(
      uptimeMs: r.integer('uptimeMs'),
      cpuLoadPct: r.number('cpuLoadPct'),
      loopHz: r.number('loopHz'),
      heapFree: r.integer('heapFree'),
      heapMin: r.integerOrNull('heapMin'),
      stackHighWater: r.integerOrNull('stackHighWater'),
      queueDepth: r.integerOrNull('queueDepth'),
      droppedFrames: r.integerOrNull('droppedFrames'),
      crcErrors: r.integerOrNull('crcErrors'),
      bleClients: r.integerOrNull('bleClients'),
      mpuI2cErrors: r.integerOrNull('mpuI2cErrors'),
      oledOk: r.booleanOrNull('oledOk'),
      brownoutCount: r.integerOrNull('brownoutCount'),
      watchdogResets: r.integerOrNull('watchdogResets'),
      batteryMv: r.integerOrNull('batteryMv'),
      rssi: r.integerOrNull('rssi'),
    );
  }

  /// Milliseconds since boot.
  final int uptimeMs;

  /// Average CPU load, percent.
  final double cpuLoadPct;

  /// Achieved rate of the sensor loop, Hz. Should match the 50 Hz the protocol
  /// assumes; a lower number here explains a suspiciously quiet dashboard.
  final double loopHz;

  /// Free heap, bytes.
  final int heapFree;

  /// Lowest free heap ever observed — the number that reveals a leak.
  final int? heapMin;

  /// High-water mark of stack usage, bytes.
  final int? stackHighWater;

  /// Events queued for delivery.
  final int? queueDepth;

  /// Telemetry frames the device could not hand to the BLE stack.
  final int? droppedFrames;

  /// Bad CRCs seen by the *device* (a reverse-direction health signal).
  final int? crcErrors;

  /// Connected central count.
  final int? bleClients;

  /// I²C errors talking to the MPU6050.
  final int? mpuI2cErrors;

  /// Whether the OLED responded to the last probe.
  final bool? oledOk;

  /// Brownout events, i.e. the battery sagged below the brownout threshold.
  final int? brownoutCount;

  /// Watchdog resets.
  final int? watchdogResets;

  /// Battery voltage, millivolts.
  final int? batteryMv;

  /// RSSI of the current connection, dBm.
  final int? rssi;

  /// Whether anything here is worth showing the user.
  ///
  /// A device can be reporting non-fatal numbers forever; these are the ones
  /// that mean "fix the wiring" or "the firmware is broken".
  List<String> get faults => <String>[
        if ((watchdogResets ?? 0) > 0) 'watchdog reset x$watchdogResets',
        if ((brownoutCount ?? 0) > 0) 'brownout x$brownoutCount',
        if ((mpuI2cErrors ?? 0) > 0) 'MPU I2C errors x$mpuI2cErrors',
        if (oledOk == false) 'OLED not responding',
        if ((crcErrors ?? 0) > 0) 'device saw $crcErrors CRC errors',
        if ((droppedFrames ?? 0) > 0) '$droppedFrames telemetry frames dropped',
        if (heapFree < 40000) 'low heap: $heapFree bytes free',
      ];

  @override
  MessageType get type => MessageType.diag;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'uptimeMs': uptimeMs,
        'cpuLoadPct': cpuLoadPct,
        'loopHz': loopHz,
        'heapFree': heapFree,
        if (heapMin != null) 'heapMin': heapMin,
        if (stackHighWater != null) 'stackHighWater': stackHighWater,
        if (queueDepth != null) 'queueDepth': queueDepth,
        if (droppedFrames != null) 'droppedFrames': droppedFrames,
        if (crcErrors != null) 'crcErrors': crcErrors,
        if (bleClients != null) 'bleClients': bleClients,
        if (mpuI2cErrors != null) 'mpuI2cErrors': mpuI2cErrors,
        if (oledOk != null) 'oledOk': oledOk,
        if (brownoutCount != null) 'brownoutCount': brownoutCount,
        if (watchdogResets != null) 'watchdogResets': watchdogResets,
        if (batteryMv != null) 'batteryMv': batteryMv,
        if (rssi != null) 'rssi': rssi,
      };
}

/// `0x20` device → phone, on the INFO characteristic (§6.3).
///
/// Separate from [HelloAckMessage] because it is *static* identity: it can be
/// read whenever the device is connected, including before a session exists,
/// which is what makes "which node is this?" answerable on a screen that
/// cannot open a link.
final class DeviceInfoMessage extends DeviceMessage {
  /// Creates a `DEVICE_INFO`.
  const DeviceInfoMessage({
    required this.name,
    required this.model,
    required this.hw,
    required this.fwVersion,
    required this.serial,
    this.fwBuild,
  });

  /// Decodes a `DEVICE_INFO` payload.
  factory DeviceInfoMessage.fromJson(Map<String, Object?> json) {
    final JsonReader r = JsonReader(json);
    return DeviceInfoMessage(
      name: r.string('name'),
      model: r.string('model'),
      hw: r.string('hw'),
      fwVersion: r.string('fwVersion'),
      fwBuild: r.integerOrNull('fwBuild'),
      serial: r.string('serial'),
    );
  }

  /// Firmware's name for the node, e.g. `SAAS-A1B2C3D4`.
  final String name;

  /// Product model string.
  final String model;

  /// Hardware revision.
  final String hw;

  /// Firmware version.
  final String fwVersion;

  /// Firmware build date as `YYYYMMDD`. Distinguishes two builds that report
  /// the same semantic version — which is exactly the situation when a user
  /// reports "I updated and it is still broken".
  final int? fwBuild;

  /// Factory serial.
  final String serial;

  @override
  MessageType get type => MessageType.deviceInfo;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'model': model,
        'hw': hw,
        'fwVersion': fwVersion,
        if (fwBuild != null) 'fwBuild': fwBuild,
        'serial': serial,
      };
}

/// A partial `CONFIG`: every key is optional (§6.4).
///
/// Used for both directions — what the app *wants* in a [ConfigMessage], and
/// what the device *applied* in [StatusMessage.effectiveConfig].
final class ConfigPatch {
  /// Creates a patch. Every field defaults to "not mentioned".
  const ConfigPatch({
    this.accelThresholdMg,
    this.gyroThresholdDps,
    this.vibrationRequired,
    this.debounceMs,
    this.confirmWindowSec,
    this.minSpeedKmh,
    this.detectorGain,
    this.telemetryHz,
    this.buzzerEnabled,
    this.ledEnabled,
    this.muteUntil,
    this.autoArm,
  });

  /// Decodes a `CONFIG`/`effectiveConfig` object, ignoring unknown keys.
  factory ConfigPatch.fromJson(Map<String, Object?> json) =>
      ConfigPatch.fromReader(JsonReader(json));

  /// Decodes a `CONFIG`/`effectiveConfig` object from an existing [JsonReader].
  factory ConfigPatch.fromReader(JsonReader r) => ConfigPatch(
        accelThresholdMg: r.integerOrNull('accelThresholdMg'),
        gyroThresholdDps: r.numberOrNull('gyroThresholdDps'),
        vibrationRequired: r.booleanOrNull('vibrationRequired'),
        debounceMs: r.integerOrNull('debounceMs'),
        confirmWindowSec: r.integerOrNull('confirmWindowSec'),
        minSpeedKmh: r.numberOrNull('minSpeedKmh'),
        detectorGain: r.numberOrNull('detectorGain'),
        telemetryHz: r.integerOrNull('telemetryHz'),
        buzzerEnabled: r.booleanOrNull('buzzerEnabled'),
        ledEnabled: r.booleanOrNull('ledEnabled'),
        muteUntil: r.integerOrNull('muteUntil'),
        autoArm: r.booleanOrNull('autoArm'),
      );

  /// Accelerometer trip threshold, milli-g. §6.4 accepts 1500…8000.
  final int? accelThresholdMg;

  /// Gyroscope trip threshold, °/s. Accepts 80…800.
  final double? gyroThresholdDps;

  /// Whether the SW-420 must also trip. Defaults to `true`.
  final bool? vibrationRequired;

  /// How long the fused signal must stay above threshold, ms. Accepts 20…500.
  final int? debounceMs;

  /// Countdown before the alert escalates, s. Accepts 5…120.
  final int? confirmWindowSec;

  /// Below this speed an impact is ignored (a kerb, not a collision), km/h.
  /// Accepts 0…60.
  final double? minSpeedKmh;

  /// Detector sensitivity multiplier. Accepts 0.5…3.0.
  final double? detectorGain;

  /// Telemetry rate, Hz. Accepts 5…100. The protocol assumes 50.
  final int? telemetryHz;

  /// Whether the buzzer may sound. Defaults to `true`.
  final bool? buzzerEnabled;

  /// Whether the LEDs may light. Defaults to `true`.
  final bool? ledEnabled;

  /// Unix seconds until which the buzzer stays silent; `0` = never (§6.4).
  final int? muteUntil;

  /// Whether the device arms itself on boot. Defaults to `true`.
  final bool? autoArm;

  /// Whether this patch would change anything.
  bool get isEmpty =>
      accelThresholdMg == null &&
      gyroThresholdDps == null &&
      vibrationRequired == null &&
      debounceMs == null &&
      confirmWindowSec == null &&
      minSpeedKmh == null &&
      detectorGain == null &&
      telemetryHz == null &&
      buzzerEnabled == null &&
      ledEnabled == null &&
      muteUntil == null &&
      autoArm == null;

  /// Which keys this patch actually sets, in a stable order.
  ///
  /// Used by the settings screen to show "3 of 12 settings changed" and by the
  /// tests to assert that absent keys really are absent.
  List<String> get changedKeys => <String>[
        if (accelThresholdMg != null) 'accelThresholdMg',
        if (gyroThresholdDps != null) 'gyroThresholdDps',
        if (vibrationRequired != null) 'vibrationRequired',
        if (debounceMs != null) 'debounceMs',
        if (confirmWindowSec != null) 'confirmWindowSec',
        if (minSpeedKmh != null) 'minSpeedKmh',
        if (detectorGain != null) 'detectorGain',
        if (telemetryHz != null) 'telemetryHz',
        if (buzzerEnabled != null) 'buzzerEnabled',
        if (ledEnabled != null) 'ledEnabled',
        if (muteUntil != null) 'muteUntil',
        if (autoArm != null) 'autoArm',
      ];

  /// The §6.4 object form, omitting keys that were not set.
  Map<String, Object?> toJson() => <String, Object?>{
        if (accelThresholdMg != null) 'accelThresholdMg': accelThresholdMg,
        if (gyroThresholdDps != null) 'gyroThresholdDps': gyroThresholdDps,
        if (vibrationRequired != null) 'vibrationRequired': vibrationRequired,
        if (debounceMs != null) 'debounceMs': debounceMs,
        if (confirmWindowSec != null) 'confirmWindowSec': confirmWindowSec,
        if (minSpeedKmh != null) 'minSpeedKmh': minSpeedKmh,
        if (detectorGain != null) 'detectorGain': detectorGain,
        if (telemetryHz != null) 'telemetryHz': telemetryHz,
        if (buzzerEnabled != null) 'buzzerEnabled': buzzerEnabled,
        if (ledEnabled != null) 'ledEnabled': ledEnabled,
        if (muteUntil != null) 'muteUntil': muteUntil,
        if (autoArm != null) 'autoArm': autoArm,
      };

  /// Overlays this patch onto [base], leaving unset keys alone (§6.4).
  ConfigPatch mergedOnto(ConfigPatch base) => ConfigPatch(
        accelThresholdMg: accelThresholdMg ?? base.accelThresholdMg,
        gyroThresholdDps: gyroThresholdDps ?? base.gyroThresholdDps,
        vibrationRequired: vibrationRequired ?? base.vibrationRequired,
        debounceMs: debounceMs ?? base.debounceMs,
        confirmWindowSec: confirmWindowSec ?? base.confirmWindowSec,
        minSpeedKmh: minSpeedKmh ?? base.minSpeedKmh,
        detectorGain: detectorGain ?? base.detectorGain,
        telemetryHz: telemetryHz ?? base.telemetryHz,
        buzzerEnabled: buzzerEnabled ?? base.buzzerEnabled,
        ledEnabled: ledEnabled ?? base.ledEnabled,
        muteUntil: muteUntil ?? base.muteUntil,
        autoArm: autoArm ?? base.autoArm,
      );

  @override
  String toString() => 'ConfigPatch(${changedKeys.join(', ')})';
}

/// A fully-populated `CONFIG`, with the §6.4 defaults and bounds.
///
/// The device clamps rather than rejects (§6.4), so the app keeps a clamped
/// local copy to render *before* the round trip completes, then replaces it
/// with [StatusMessage.effectiveConfig] as soon as that arrives.
final class DeviceConfig {
  /// Creates a full config, clamping every field to its documented bounds.
  ///
  /// Not `const`: clamping is a computation, and a `const` here would let a
  /// caller believe an out-of-range value had been accepted.
  DeviceConfig({
    required int accelThresholdMg,
    required double gyroThresholdDps,
    required this.vibrationRequired,
    required int debounceMs,
    required int confirmWindowSec,
    required double minSpeedKmh,
    required double detectorGain,
    required int telemetryHz,
    required this.buzzerEnabled,
    required this.ledEnabled,
    required int muteUntil,
    required this.autoArm,
  })  : accelThresholdMg = _clampInt(accelThresholdMg, 1500, 8000),
        gyroThresholdDps = _clampDouble(gyroThresholdDps, 80, 800),
        debounceMs = _clampInt(debounceMs, 20, 500),
        confirmWindowSec = _clampInt(confirmWindowSec, 5, 120),
        minSpeedKmh = _clampDouble(minSpeedKmh, 0, 60),
        detectorGain = _clampDouble(detectorGain, 0.5, 3.0),
        telemetryHz = _clampInt(telemetryHz, 5, 100),
        muteUntil = muteUntil < 0 ? 0 : muteUntil;

  /// The §6.4 defaults.
  factory DeviceConfig.defaults() => DeviceConfig(
        accelThresholdMg: 3000,
        gyroThresholdDps: 220,
        vibrationRequired: true,
        debounceMs: 60,
        confirmWindowSec: 10,
        minSpeedKmh: 5.0,
        detectorGain: 1.0,
        telemetryHz: 50,
        buzzerEnabled: true,
        ledEnabled: true,
        muteUntil: 0,
        autoArm: true,
      );

  /// Builds a full config from a [DeviceConfig] by overlaying [patch].
  factory DeviceConfig.fromPatch(ConfigPatch patch) {
    final DeviceConfig base = DeviceConfig.defaults();
    final ConfigPatch merged = patch.mergedOnto(base.toPatch());
    return DeviceConfig(
      accelThresholdMg: merged.accelThresholdMg ?? 3000,
      gyroThresholdDps: merged.gyroThresholdDps ?? 220,
      vibrationRequired: merged.vibrationRequired ?? true,
      debounceMs: merged.debounceMs ?? 60,
      confirmWindowSec: merged.confirmWindowSec ?? 10,
      minSpeedKmh: merged.minSpeedKmh ?? 5.0,
      detectorGain: merged.detectorGain ?? 1.0,
      telemetryHz: merged.telemetryHz ?? 50,
      buzzerEnabled: merged.buzzerEnabled ?? true,
      ledEnabled: merged.ledEnabled ?? true,
      muteUntil: merged.muteUntil ?? 0,
      autoArm: merged.autoArm ?? true,
    );
  }

  /// Accelerometer trip threshold, milli-g. §6.4: 1500…8000, default 3000.
  final int accelThresholdMg;

  /// Gyroscope trip threshold, °/s. §6.4: 80…800, default 220.
  final double gyroThresholdDps;

  /// Whether the SW-420 must also trip.
  final bool vibrationRequired;

  /// Debounce window, ms. §6.4: 20…500, default 60.
  final int debounceMs;

  /// Cancel countdown, s. §6.4: 5…120, default 10.
  final int confirmWindowSec;

  /// Minimum speed to consider it an accident, km/h. §6.4: 0…60, default 5.
  final double minSpeedKmh;

  /// Detector gain. §6.4: 0.5…3.0, default 1.0.
  final double detectorGain;

  /// Telemetry rate, Hz. §6.4: 5…100, default 50.
  final int telemetryHz;

  /// Whether the buzzer may sound.
  final bool buzzerEnabled;

  /// Whether the LEDs may light.
  final bool ledEnabled;

  /// Unix seconds until which the buzzer stays silent; 0 = never.
  final int muteUntil;

  /// Whether the device arms on boot.
  final bool autoArm;

  /// This config as a full [ConfigPatch], for sending or for comparing against
  /// [StatusMessage.effectiveConfig].
  ConfigPatch toPatch() => ConfigPatch(
        accelThresholdMg: accelThresholdMg,
        gyroThresholdDps: gyroThresholdDps,
        vibrationRequired: vibrationRequired,
        debounceMs: debounceMs,
        confirmWindowSec: confirmWindowSec,
        minSpeedKmh: minSpeedKmh,
        detectorGain: detectorGain,
        telemetryHz: telemetryHz,
        buzzerEnabled: buzzerEnabled,
        ledEnabled: ledEnabled,
        muteUntil: muteUntil,
        autoArm: autoArm,
      );

  /// The `CONFIG` message that would set every key to these values.
  ConfigMessage toMessage() => ConfigMessage(toPatch());

  /// Whether the device would be sending faster than the UI displays.
  ///
  /// The app throttles its own display to 10 Hz regardless (§6.2), so this is
  /// informational: a `telemetryHz` far above 50 costs battery for no visible
  /// gain, and the settings screen can say so.
  bool get isTelemetryRateWasteful => telemetryHz > 20;

  /// Which fields this config had to clamp away from [requested].
  ///
  /// Lets the settings screen explain "we asked for 12 000, the device uses
  /// 8 000" instead of silently moving the slider.
  static List<String> clampedFields(
    ConfigPatch requested, {
    required int accelThresholdMg,
    required double gyroThresholdDps,
    required int debounceMs,
    required int confirmWindowSec,
    required double minSpeedKmh,
    required double detectorGain,
    required int telemetryHz,
  }) =>
      <String>[
        if (requested.accelThresholdMg != null &&
            requested.accelThresholdMg != accelThresholdMg)
          'accelThresholdMg',
        if (requested.gyroThresholdDps != null &&
            requested.gyroThresholdDps != gyroThresholdDps)
          'gyroThresholdDps',
        if (requested.debounceMs != null && requested.debounceMs != debounceMs)
          'debounceMs',
        if (requested.confirmWindowSec != null &&
            requested.confirmWindowSec != confirmWindowSec)
          'confirmWindowSec',
        if (requested.minSpeedKmh != null &&
            requested.minSpeedKmh != minSpeedKmh)
          'minSpeedKmh',
        if (requested.detectorGain != null &&
            requested.detectorGain != detectorGain)
          'detectorGain',
        if (requested.telemetryHz != null &&
            requested.telemetryHz != telemetryHz)
          'telemetryHz',
      ];

  @override
  String toString() =>
      'DeviceConfig(accel=${accelThresholdMg}mg, gyro=${gyroThresholdDps}dps, '
      'debounce=${debounceMs}ms, window=${confirmWindowSec}s, '
      'minSpeed=$minSpeedKmh km/h, gain=$detectorGain, hz=$telemetryHz)';
}

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

double _clampDouble(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// The entry point for turning frames into typed messages.
///
/// One [switch] on the type code, so adding a message to §4 is a compile
/// error here until someone handles it — which is exactly the pressure you
/// want when the alternative is a silently dropped accident event.
abstract final class MessageCodec {
  /// Parses a JSON message payload of type [typeCode].
  ///
  /// Returns a [FailureResult] with [FailureKind.protocol] for a malformed
  /// payload, so a device sending garbage produces a logged, counted link
  /// error rather than an exception in a BLE callback.
  static Result<DeviceMessage> parsePayload(int typeCode, Uint8List payload) {
    final MessageType? type = MessageType.fromCode(typeCode);
    if (type == null) {
      return fail<DeviceMessage>(
        failureOf(
          FailureKind.protocol,
          'Unknown message type 0x${typeCode.toRadixString(16)}',
        ),
      );
    }
    if (type == MessageType.telemetry) {
      return fail<DeviceMessage>(
        failureOf(
          FailureKind.protocol,
          'TELEMETRY is binary; use TelemetryCodec.tryDecode, not this',
        ),
      );
    }
    return guardSync<DeviceMessage>(
      () => parseJson(type, decodeJsonValue(payload)),
      kind: FailureKind.protocol,
      message: 'Malformed ${type.name.toUpperCase()} payload',
    );
  }

  /// Parses an already-decoded JSON object of type [type].
  ///
  /// [CalibLogMessage.fromDecoded] is reached through here, so a `CALIB_LOG`
  /// that arrived as a bare array still decodes.
  static DeviceMessage parseJson(MessageType type, Object? json) {
    if (type == MessageType.calibLog) {
      return CalibLogMessage.fromDecoded(json);
    }
    final Map<String, Object?> object = switch (json) {
      final Map<String, Object?> m => m,
      null => throw const MessageFormatException(
          null,
          'payload decoded to null',
        ),
      final Object other => throw MessageFormatException(
          null,
          'expected a JSON object, got ${other.runtimeType}',
        ),
    };
    return switch (type) {
      MessageType.hello => HelloMessage.fromJson(object),
      MessageType.ping => PingMessage.fromJson(object),
      MessageType.config => ConfigMessage.fromJson(object),
      MessageType.calibrate => CalibrateMessage.fromJson(object),
      MessageType.command => CommandMessage.fromJson(object),
      MessageType.ack => AckMessage.fromJson(object),
      MessageType.error => ErrorMessage.fromJson(object),
      MessageType.event => EventMessage.fromJson(object),
      MessageType.status => StatusMessage.fromJson(object),
      MessageType.helloAck => HelloAckMessage.fromJson(object),
      MessageType.calibLog => CalibLogMessage.fromJson(object),
      MessageType.diag => DiagMessage.fromJson(object),
      MessageType.deviceInfo => DeviceInfoMessage.fromJson(object),
      MessageType.telemetry => throw const MessageFormatException(
          null,
          'TELEMETRY has no JSON form',
        ),
      // `unknown` is the synthetic member for a code outside §4; it cannot
      // reach here because `parsePayload` resolves the code first.
      MessageType.unknown => throw const MessageFormatException(
          null,
          'unknown message type',
        ),
    };
  }

  /// Parses a borrowed frame, as handed to a [FrameVisitor] by a [FrameScanner].
  ///
  /// Zero-copy: [BleFrameView.payload] is a `sublistView`, so this allocates
  /// only the typed message. Nothing retains it past the callback.
  static Result<DeviceMessage> parseView(BleFrameView frame) =>
      parsePayload(frame.typeCode, frame.payload);

  /// Parses an owned frame, e.g. from [FrameScanner.scanToList] or a replay.
  static Result<DeviceMessage> parseFrame(BleFrame frame) =>
      parsePayload(frame.typeCode, frame.payload);
}
