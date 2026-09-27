/// Telemetry codec (§5): the 24-byte binary record, in and out.
///
/// ## The rounding trap
///
/// `tools/protocol/codec.js` clamps with `Math.round`, which is
/// `floor(x + 0.5)` — it rounds **half up**, toward positive infinity, so
/// `Math.round(-0.5)` is `-0` and `Math.round(-1.5)` is `-1`. Dart's
/// `double.round()` rounds **half away from zero**, so `(-0.5).round()` is
/// `-1` and `(-1.5).round()` is `-2`.
///
/// The two disagree on every negative half-integer, which is exactly where the
/// golden vectors are sharpest (`fracNeg` encodes `ax = -0.5` to `-1` in JS and
/// `-1` in Dart only by coincidence; `ax = -1.5` would differ). Since the
/// reference vector generator is JavaScript, **this file must use JS rounding**,
/// and [jsRound] exists for exactly that reason. The two functions are
/// neighbours in this file on purpose: the next person to "simplify" one into
/// the other should have to look at this comment.
///
/// Clamping is not decoration either. `clampI16`/`clampU16`/`clampByte` mirror
/// the reference, so a simulator sample of `40000` milli-g encodes to `32767`
/// (saturated) on both sides instead of silently wrapping to a negative
/// acceleration.
library;

import 'dart:typed_data';

import '../../core/result.dart';
import '../../domain/entities/telemetry.dart';
// Prefixed: `TelemetryCodec.encodeFrame` would otherwise resolve to *itself*
// instead of `ble_frame.dart`'s top-level frame builder.
import 'ble_frame.dart' as wire;

/// Encode/decode the 24-byte telemetry record (§5).
abstract final class TelemetryCodec {
  /// Decode [payload] into a [TelemetryRecord], or `null` if it is not exactly
  /// [telemetryRecordBytes] long.
  ///
  /// `null` rather than a thrown [RangeError] because the caller is a
  /// notification handler: a short read is a link problem to be counted, not an
  /// exception to propagate into the BLE plugin's callback.
  static TelemetryRecord? tryDecode(Uint8List payload) {
    if (payload.length != telemetryRecordBytes) {
      return null;
    }
    final ByteData view = ByteData.sublistView(payload);
    return TelemetryRecord(
      tMs: view.getUint32(0, Endian.little),
      accX: view.getInt16(4, Endian.little),
      accY: view.getInt16(6, Endian.little),
      accZ: view.getInt16(8, Endian.little),
      gyrX: view.getInt16(10, Endian.little),
      gyrY: view.getInt16(12, Endian.little),
      gyrZ: view.getInt16(14, Endian.little),
      magMg: view.getUint16(16, Endian.little),
      peakMg: view.getUint16(18, Endian.little),
      flags: TelemetryFlags.fromByte(payload[20]),
      impactScore: payload[21],
      batteryPct: payload[22],
      state: DeviceState.fromByte(payload[23]),
    );
  }

  /// Decode [payload], reporting a length mismatch as a [Failure].
  ///
  /// This is the form a datasource uses; [tryDecode] is the form the scanner
  /// hot path uses.
  static Result<TelemetryRecord> decode(Uint8List payload) {
    if (payload.length != telemetryRecordBytes) {
      return fail<TelemetryRecord>(
        failureOf(
          FailureKind.validation,
          'Telemetry payload must be $telemetryRecordBytes bytes, '
          'got ${payload.length}',
        ),
      );
    }
    final TelemetryRecord? record = tryDecode(payload);
    if (record == null) {
      // Unreachable given the length check above, but the type system does not
      // know that, and a `!` here would be a lie.
      return fail<TelemetryRecord>(
        failureOf(
          FailureKind.validation,
          'Telemetry payload could not be decoded',
        ),
      );
    }
    return Ok<TelemetryRecord>(record);
  }

  /// Encode [record] to its 24 wire bytes (§5).
  static Uint8List encode(TelemetryRecord record) => record.toBytes();

  /// Encode a whole `TELEMETRY` frame (§3 + §5).
  static Uint8List encodeFrame(TelemetryRecord record, {bool pad = false}) =>
      wire.encodeFrame(
        typeCode: wire.MessageType.telemetry.code,
        payload: record.toBytes(),
        pad: pad,
      );

  /// Decode a frame's payload as telemetry, the composition the BLE service
  /// actually performs. Returns `null` for any frame that is not telemetry or
  /// whose length is wrong.
  static TelemetryRecord? decodeFrame(wire.BleFrameView frame) {
    if (frame.type != wire.MessageType.telemetry) {
      return null;
    }
    return tryDecode(frame.payload);
  }
}

/// JS `Math.round`: half up, toward positive infinity.
///
/// `(-0.5) -> -0`, `(-1.5) -> -1`, `2.5 -> 3`. See the file header for why this
/// exists and why `double.round()` is the wrong function here.
int jsRoundToInt(double value) {
  if (value.isNaN) {
    throw ArgumentError.value(value, 'value', 'NaN has no integer rounding');
  }
  if (value.isInfinite) {
    return value.isNegative ? -0x7FFFFFFFFFFFFFFF : 0x7FFFFFFFFFFFFFFF;
  }
  return (value + 0.5).floor();
}

/// JS `Math.round(value * 10^decimals) / 10^decimals`.
///
/// Used for the derived values the reference prints with 1 or 2 decimal places
/// (`impact.magG = 4.82`, `gyrMagDps = 402.1`). Powers of ten are tabulated
/// rather than computed with `pow` so the result is exact for the small
/// exponents in use, instead of being 0.30000000000000004-ish.
double jsRound(double value, int decimals) {
  if (decimals < 0 || decimals > 15) {
    throw RangeError.range(decimals, 0, 15, 'decimals');
  }
  if (!value.isFinite) {
    return value;
  }
  final double factor = _pow10Lookup(decimals);
  return jsRoundToInt(value * factor) / factor;
}

/// Two-decimal JS rounding, for g-valued derived fields.
double jsRound2(double value) => jsRound(value, 2);

/// One-decimal JS rounding, for °/s-valued derived fields.
double jsRound1(double value) => jsRound(value, 1);

/// `Math.max(-32768, Math.min(32767, Math.round(v)))` — the reference's
/// `clampI16`.
int clampI16(double value) {
  final int rounded = jsRoundToInt(value);
  if (rounded < -0x8000) {
    return -0x8000;
  }
  if (rounded > 0x7FFF) {
    return 0x7FFF;
  }
  return rounded;
}

/// `Math.max(0, Math.min(65535, Math.round(v)))` — the reference's `clampU16`.
int clampU16(double value) {
  final int rounded = jsRoundToInt(value);
  if (rounded < 0) {
    return 0;
  }
  if (rounded > 0xFFFF) {
    return 0xFFFF;
  }
  return rounded;
}

/// `Math.max(0, Math.min(255, Math.round(v)))` — the reference's `clampByte`.
int clampByte(double value) {
  final int rounded = jsRoundToInt(value);
  if (rounded < 0) {
    return 0;
  }
  if (rounded > 0xFF) {
    return 0xFF;
  }
  return rounded;
}

/// `t_ms` is a `u32`; the reference does `s.tMs >>> 0`, which is a modulo-2^32
/// on a *32-bit* value. In Dart, a `t_ms` of `2^32 + 5` is truncated the same
/// way, so `encodeTelemetryFields(tMs: 4294967301)` produces the same bytes the
/// JavaScript reference does.
int clampU32(double value) {
  final int rounded = jsRoundToInt(value);
  // Dart ints are 64-bit, so emulate `>>> 0` explicitly rather than relying on
  // the platform word size.
  return rounded & 0xFFFFFFFF;
}

/// Encode loose (possibly fractional, possibly out-of-range) telemetry fields the
/// way `tools/protocol/codec.js#encodeTelemetry` does.
///
/// This is the *reference-compatible* encoder: it clamps and JS-rounds, and it
/// accepts fractional milli-g. [TelemetryCodec.encode] is the typed encoder for
/// a [TelemetryRecord] that has already been through the wire once. The simulator
/// feed and the golden-vector round-trip test use this one; the BLE service uses
/// the other. Both must produce identical bytes for in-range input, and the
/// conformance test asserts exactly that.
Uint8List encodeTelemetryFields({
  required double tMs,
  required double ax,
  required double ay,
  required double az,
  required double gx,
  required double gy,
  required double gz,
  required double magMg,
  required double peakMg,
  required int flags,
  required double score,
  required double batteryPct,
  required int state,
}) {
  final Uint8List out = Uint8List(telemetryRecordBytes);
  final ByteData view = ByteData.sublistView(out);
  view.setUint32(0, clampU32(tMs), Endian.little);
  view.setInt16(4, clampI16(ax), Endian.little);
  view.setInt16(6, clampI16(ay), Endian.little);
  view.setInt16(8, clampI16(az), Endian.little);
  view.setInt16(10, clampI16(gx), Endian.little);
  view.setInt16(12, clampI16(gy), Endian.little);
  view.setInt16(14, clampI16(gz), Endian.little);
  view.setUint16(16, clampU16(magMg), Endian.little);
  view.setUint16(18, clampU16(peakMg), Endian.little);
  out[20] = flags & 0xFF;
  out[21] = clampByte(score);
  out[22] = clampByte(batteryPct);
  out[23] = state & 0xFF;
  return out;
}

/// The JSON shape `tools/protocol/codec.js#decodeTelemetry` produces.
///
/// Only used to diff a decoded record against `golden.json`'s `telemetry`
/// object, which is why the field names are the reference's short ones
/// (`ax`, `gx`, `score`) rather than the domain's.
Map<String, Object?> telemetryToReferenceJson(TelemetryRecord record) =>
    <String, Object?>{
      'tMs': record.tMs,
      'ax': record.accX,
      'ay': record.accY,
      'az': record.accZ,
      'gx': record.gyrX,
      'gy': record.gyrY,
      'gz': record.gyrZ,
      'magMg': record.magMg,
      'peakMg': record.peakMg,
      'flags': record.flags.toByte(),
      'score': record.impactScore,
      'batteryPct': record.batteryPct,
      'state': record.state.byte,
      'stateName': record.state.name.toUpperCase(),
      'sw420': record.flags.sw420,
      'buzzer': record.flags.buzzer,
      'ledRed': record.flags.ledRed,
      'ledGreen': record.flags.ledGreen,
      'oledOk': record.flags.oledOk,
      'sosButton': record.flags.sosButton,
      'armed': record.flags.armed,
      'charging': record.flags.charging,
    };

/// 10^0 … 10^15, exact. `pow` would give 0.1 as 0.1000000000000000055511151231257827
/// and then every 1-decimal JS rounding in this file would be subtly off.
const List<double> _pow10 = <double>[
  1,
  10,
  100,
  1000,
  10000,
  100000,
  1000000,
  10000000,
  100000000,
  1000000000,
  10000000000,
  100000000000,
  1000000000000,
  10000000000000,
  100000000000000,
  1000000000000000,
];

double _pow10Lookup(int decimals) => _pow10[decimals];
