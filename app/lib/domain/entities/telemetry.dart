/// The 50 Hz telemetry record (§5) and the flag bitfield it carries.
///
/// **Why this is a domain object and not a byte view.** The wire record is 18
/// bytes of little-endian integers in *milli-g*. Nothing above the protocol
/// layer should ever see those units: a
/// sparkline wants g, a threshold slider wants g, the detector comparison wants
/// g. So the entity keeps the raw integers (for the diagnostics view and for
/// lossless round-tripping) *and* exposes the derived physical values, and the
/// only place the conversion happens is here.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'accident.dart';

/// §5.2 device state.
enum DeviceState {
  /// Booting; sensors not yet validated.
  boot,

  /// Armed, no event in progress.
  idle,

  /// Impact candidate, inside the cancel window. This is the state the UI's
  /// countdown screen is showing.
  pending,

  /// Confirmed; emergency dispatch in progress.
  alarm,

  /// Manual SOS active.
  sos,

  /// Buzzer suppressed (night mode). Detection still runs.
  muted,

  /// Sensor fault or calibration required.
  fault,

  /// A state value the app does not know.
  ///
  /// Kept as a real case rather than an exception: a firmware upgrade that adds
  /// state 7 must not crash an app that is in the middle of monitoring a car.
  unknown;

  /// Parse a `state` byte (§5.2). Out-of-range maps to [unknown].
  static DeviceState fromByte(int value) => switch (value) {
        0 => DeviceState.boot,
        1 => DeviceState.idle,
        2 => DeviceState.pending,
        3 => DeviceState.alarm,
        4 => DeviceState.sos,
        5 => DeviceState.muted,
        6 => DeviceState.fault,
        _ => DeviceState.unknown,
      };

  /// The byte that goes on the wire.
  int get byte => switch (this) {
        DeviceState.boot => 0,
        DeviceState.idle => 1,
        DeviceState.pending => 2,
        DeviceState.alarm => 3,
        DeviceState.sos => 4,
        DeviceState.muted => 5,
        DeviceState.fault => 6,
        DeviceState.unknown => 255,
      };

  /// Whether the detector is running in this state.
  ///
  /// [fault] and [boot] are excluded: showing a live accelerometer trace from a
  /// device whose ADXL345 is not answering is worse than showing nothing.
  bool get isArmed => switch (this) {
        DeviceState.idle ||
        DeviceState.pending ||
        DeviceState.alarm ||
        DeviceState.sos ||
        DeviceState.muted =>
          true,
        DeviceState.boot || DeviceState.fault || DeviceState.unknown => false,
      };

  /// Whether an emergency dispatch is in progress and must not be dismissed
  /// without an explicit user action.
  bool get isEmergency => this == DeviceState.alarm || this == DeviceState.sos;

  /// Whether the app should be showing a cancel countdown.
  bool get isCancellable => this == DeviceState.pending;
}

/// Euclidean magnitude of a 3-axis vector.
///
/// Shared by [TelemetryRecord] and [CalibrationSample]. Deliberately naive:
/// these are two or three 16-bit values, not matrices.
double _magnitude3(double x, double y, double z) {
  final double sum = x * x + y * y + z * z;
  return sum <= 0 ? 0 : math.sqrt(sum);
}

/// §5.1 flag bitfield.
///
/// Immutable, with named getters, because `if (flags & 0x02) != 0` in a widget
/// is unreviewable and the bit order is the kind of thing that gets
/// "simplified" into a bug.
///
/// **Losslessness.** The named constructor builds the raw byte; [fromByte] keeps
/// whatever it was given and derives the named flags from it. All eight bits are
/// named in §5.1, so `fromByte(x).toByte() == x` for every `x` in `0…255` — a
/// property the conformance test asserts, so a future §5.1 that adds bit 8
/// cannot silently start dropping it.
@immutable
class TelemetryFlags {
  /// Builds the raw byte from eight named booleans, per §5.1.
  const TelemetryFlags({
    required bool sw420,
    required bool buzzer,
    required bool ledRed,
    required bool ledGreen,
    required bool oledOk,
    required bool sosButton,
    required bool armed,
    required bool charging,
  }) : _raw = (sw420 ? maskSw420 : 0) |
            (buzzer ? maskBuzzer : 0) |
            (ledRed ? maskLedRed : 0) |
            (ledGreen ? maskLedGreen : 0) |
            (oledOk ? maskOledOk : 0) |
            (sosButton ? maskSosButton : 0) |
            (armed ? maskArmed : 0) |
            (charging ? maskCharging : 0);

  const TelemetryFlags._(this._raw);

  /// All flags clear.
  static const TelemetryFlags none = TelemetryFlags(
    sw420: false,
    buzzer: false,
    ledRed: false,
    ledGreen: false,
    oledOk: false,
    sosButton: false,
    armed: false,
    charging: false,
  );

  /// Decompose a `flags` byte (§5.1) without losing any bit.
  factory TelemetryFlags.fromByte(int value) {
    if (value < 0 || value > 0xFF) {
      throw ArgumentError.value(value, 'value', 'must be a byte');
    }
    return TelemetryFlags._(value);
  }

  /// The `flags` byte exactly as received.
  final int _raw;

  /// Bit 0 — SW-420 vibration output currently HIGH.
  static const int maskSw420 = 0x01;

  /// Bit 1 — buzzer active.
  static const int maskBuzzer = 0x02;

  /// Bit 2 — red LED.
  static const int maskLedRed = 0x04;

  /// Bit 3 — green LED.
  static const int maskLedGreen = 0x08;

  /// Bit 4 — OLED responding.
  static const int maskOledOk = 0x10;

  /// Bit 5 — SOS button currently pressed.
  static const int maskSosButton = 0x20;

  /// Bit 6 — detection loop enabled.
  static const int maskArmed = 0x40;

  /// Bit 7 — charging.
  static const int maskCharging = 0x80;

  /// SW-420 vibration output HIGH. One of the three sensor inputs the fused
  /// detector combines.
  bool get sw420 => _raw & maskSw420 != 0;

  /// Buzzer active. The user can mute it; the app never turns it on.
  bool get buzzer => _raw & maskBuzzer != 0;

  /// Red LED — the firmware uses it as "an event is in progress".
  bool get ledRed => _raw & maskLedRed != 0;

  /// Green LED — "armed and nominal".
  bool get ledGreen => _raw & maskLedGreen != 0;

  /// OLED responding. `false` means the display is not wired; §6.2 makes this
  /// a capability-negotiation flag, so the app must keep working.
  bool get oledOk => _raw & maskOledOk != 0;

  /// SOS button held down right now.
  bool get sosButton => _raw & maskSosButton != 0;

  /// Detection loop enabled. `false` means the device will not raise an event on
  /// its own — which the UI must state plainly, because a disarmed car looks
  /// identical to a safe one otherwise.
  bool get armed => _raw & maskArmed != 0;

  /// Charging.
  bool get charging => _raw & maskCharging != 0;

  /// The `flags` byte to put on the wire (§5.1).
  int toByte() => _raw;

  /// Whether [mask] is set.
  bool has(int mask) => (_raw & mask) != 0;

  @override
  String toString() => 'TelemetryFlags('
      '0x${_raw.toRadixString(16).padLeft(2, '0')}'
      '${sw420 ? ' SW420' : ''}'
      '${buzzer ? ' BUZZER' : ''}'
      '${ledRed ? ' LED_RED' : ''}'
      '${ledGreen ? ' LED_GREEN' : ''}'
      '${oledOk ? ' OLED_OK' : ''}'
      '${sosButton ? ' SOS_BUTTON' : ''}'
      '${armed ? ' ARMED' : ''}'
      '${charging ? ' CHARGING' : ''})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TelemetryFlags && other._raw == _raw;

  @override
  int get hashCode => _raw.hashCode;
}

/// Milli-gravity in an int16, as the firmware sends it.
const int kMilliGMin = -32000;

/// Max accelerometer magnitude, milli-g (§5 range).
const int kMilliGMax = 32000;

/// Sentinel for "battery percentage unknown" (§5, byte 22).
const int kBatteryUnknown = 255;

/// One decoded 18-byte telemetry record (§5).
///
/// Immutable and value-equal, which is what lets the throttled UI stream
/// deduplicate: two identical consecutive records can be dropped without
/// rebuilding anything.
@immutable
class TelemetryRecord {
  /// One 18-byte sample, as sent on the wire (§5).
  ///
  /// Every field is stored in its *wire* unit — milli-g — so equality,
  /// [toBytes] and the conformance vectors all agree. The
  /// `accXG`/`magG`/… getters convert.
  const TelemetryRecord({
    required this.tMs,
    required this.accX,
    required this.accY,
    required this.accZ,
    required this.magMg,
    required this.peakMg,
    required this.flags,
    required this.impactScore,
    required this.batteryPct,
    required this.state,
  });

  /// Milliseconds since device boot. Wraps at ~49.7 days (§5), so **never** use
  /// this as a wall-clock timestamp — [AccidentRecord] records the phone's
  /// clock for that instead.
  final int tMs;

  /// Accelerometer X, milli-g (§5).
  final int accX;

  /// Accelerometer Y, milli-g.
  final int accY;

  /// Accelerometer Z, milli-g.
  final int accZ;

  /// Magnitude of the acceleration vector, milli-g (§5).
  final int magMg;

  /// Session peak magnitude so far, milli-g.
  final int peakMg;

  /// Decoded flag bitfield.
  final TelemetryFlags flags;

  /// Detector confidence, 0…100 (§5).
  final int impactScore;

  /// Device battery percentage, 0…100, or [kBatteryUnknown].
  ///
  /// Modelled as `int` rather than `int?` because the wire has no null: it has a
  /// magic 255. Keeping the sentinel visible at the type level via
  /// [batteryPctOrNull] avoids both a null-check and a comparison against a
  /// magic number at every call site.
  final int batteryPct;

  /// Decoded device state (§5.2).
  final DeviceState state;

  /// [batteryPct], or `null` when the device reported [kBatteryUnknown].
  int? get batteryPctOrNull =>
      batteryPct == kBatteryUnknown ? null : batteryPct;

  /// Whether the device reported a usable battery percentage.
  bool get hasBattery => batteryPctOrNull != null;

  /// Accelerometer X in g.
  double get accXG => accX / 1000.0;

  /// Accelerometer Y in g.
  double get accYG => accY / 1000.0;

  /// Accelerometer Z in g.
  double get accZG => accZ / 1000.0;

  /// Magnitude in g.
  double get magG => magMg / 1000.0;

  /// Session peak in g.
  double get peakG => peakMg / 1000.0;

  /// Vector magnitude of the three accelerometer axes in g.
  ///
  /// Computed rather than trusting [magMg] because the device's `mag_mg` is
  /// derived from *filtered* axes, and a sparkline drawn from the raw axes will
  /// not line up with the threshold the firmware is comparing against. Both are
  /// available; the UI picks.
  double get accVectorG => _magnitude3(accXG, accYG, accZG);

  /// Whether this sample's magnitude has reached the threshold the *app* is
  /// configured to consider notable.
  ///
  /// This is a client-side convenience for colouring; the authoritative
  /// decision is the firmware's, and arrives as [impactScore] and via the
  /// [DeviceState.pending] transition.
  bool exceedsThresholdMg(int thresholdMg) => magMg >= thresholdMg;

  /// How far into the boot period this sample is, as a fraction of [tMs] — used
  /// only by tests to assert monotonic timestamps.
  bool get isFirstSample => tMs == 0;

  /// Copy with individual fields replaced.
  TelemetryRecord copyWith({
    int? tMs,
    int? accX,
    int? accY,
    int? accZ,
    int? magMg,
    int? peakMg,
    TelemetryFlags? flags,
    int? impactScore,
    int? batteryPct,
    DeviceState? state,
  }) =>
      TelemetryRecord(
        tMs: tMs ?? this.tMs,
        accX: accX ?? this.accX,
        accY: accY ?? this.accY,
        accZ: accZ ?? this.accZ,
        magMg: magMg ?? this.magMg,
        peakMg: peakMg ?? this.peakMg,
        flags: flags ?? this.flags,
        impactScore: impactScore ?? this.impactScore,
        batteryPct: batteryPct ?? this.batteryPct,
        state: state ?? this.state,
      );

  /// Encode back to the 18 wire bytes (§5), little-endian.
  ///
  /// Present so a test can assert `decode(encode(x)) == x` and so the simulator
  /// feed can produce records with the exact layout the firmware uses.
  Uint8List toBytes() {
    final Uint8List out = Uint8List(telemetryRecordBytes);
    final ByteData view = ByteData.sublistView(out);
    view.setUint32(0, tMs, Endian.little);
    view.setInt16(4, accX, Endian.little);
    view.setInt16(6, accY, Endian.little);
    view.setInt16(8, accZ, Endian.little);
    view.setUint16(10, magMg, Endian.little);
    view.setUint16(12, peakMg, Endian.little);
    out[14] = flags.toByte();
    out[15] = impactScore & 0xFF;
    out[16] = batteryPct & 0xFF;
    out[17] = state.byte & 0xFF;
    return out;
  }

  @override
  String toString() => 'TelemetryRecord(t=${tMs}ms, '
      'acc=$accX/$accY/$accZ mg, '
      'mag=$magMg mg, peak=$peakMg mg, score=$impactScore, '
      'batt=$batteryPct, state=${state.name}, $flags)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TelemetryRecord &&
          other.tMs == tMs &&
          other.accX == accX &&
          other.accY == accY &&
          other.accZ == accZ &&
          other.magMg == magMg &&
          other.peakMg == peakMg &&
          other.flags == flags &&
          other.impactScore == impactScore &&
          other.batteryPct == batteryPct &&
          other.state == state;

  @override
  int get hashCode => Object.hash(
        tMs,
        accX,
        accY,
        accZ,
        magMg,
        peakMg,
        flags,
        impactScore,
        batteryPct,
        state,
      );
}

/// Size of a telemetry record in bytes (§5). Fixed, not negotiated.
///
/// 18 in protocol v2. v1 was 24 and included three gyroscope axes; the node
/// moved to an ADXL345, which has no gyroscope, so those six bytes were
/// removed rather than zero-filled.
const int telemetryRecordBytes = 18;

/// One row of a `CALIB_LOG` array (§6.8).
///
/// Same units as [TelemetryRecord] but no magnitude, no peak, no state: the
/// device only streams it while calibrating, when the app is drawing a "is the
/// vehicle still?" chart and needs the raw axes.
@immutable
class CalibrationSample {
  /// One row of a `CALIB_LOG`, in the same units as [TelemetryRecord].
  const CalibrationSample({
    required this.tMs,
    required this.accX,
    required this.accY,
    required this.accZ,
    required this.sw420,
  });

  /// Milliseconds since boot.
  final int tMs;

  /// Accelerometer X in milli-g.
  final int accX;

  /// Accelerometer Y in milli-g.
  final int accY;

  /// Accelerometer Z in milli-g.
  final int accZ;

  /// SW-420 output during this sample.
  final bool sw420;

  /// Accelerometer Z in g. The axis gravity points along when the vehicle is
  /// upright, so during a correct static calibration this hovers near 1.0.
  double get accZG => accZ / 1000.0;

  /// Vector magnitude in g.
  double get accVectorG {
    return _magnitude3(accX / 1000.0, accY / 1000.0, accZG);
  }

  @override
  String toString() => 'CalibrationSample(t=${tMs}ms, '
      'acc=$accX/$accY/$accZ, sw420=$sw420)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CalibrationSample &&
          other.tMs == tMs &&
          other.accX == accX &&
          other.accY == accY &&
          other.accZ == accZ &&
          other.sw420 == sw420;

  @override
  int get hashCode => Object.hash(tMs, accX, accY, accZ, sw420);
}
