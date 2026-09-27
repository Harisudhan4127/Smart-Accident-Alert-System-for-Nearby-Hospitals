/// Extra telemetry vectors, beyond `tools/protocol/golden.json`.
///
/// The shipped golden file covers the *happy* paths (a nominal sample, an impact,
/// a saturation, a muted sample) and nothing else. Every clamp and rounding
/// boundary lives only in the firmware's `clampI16`/`clampU16`/`clampByte` and
/// in JavaScript's `Math.round`, so a mismatch there is invisible until the one
/// moment it matters: the device reports 32768 milli-g and the app shows a
/// negative acceleration.
///
/// Each case below was produced by running the *inputs* through
/// `tools/protocol/codec.js#encodeTelemetry` and recording the bytes, so the
/// expectation is the reference implementation's output, not a value derived
/// from the Dart under test. To regenerate:
///
/// ```sh
/// node -e '
///   const { encodeTelemetry, encodeFrame } = require("./tools/protocol/codec.js");
///   ...'
/// ```
///
/// which is exactly what `tools/protocol/generate-golden.mjs` does — these cases
/// are the ones that generator does not emit, added because the generator's
/// sampling missed them.
library;

/// A telemetry encode case: loose inputs, expected bytes, and the reason it
/// exists.
class TelemetryVector {
  const TelemetryVector({
    required this.name,
    required this.reason,
    required this.tMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.magMg,
    required this.peakMg,
    required this.flags,
    required this.score,
    required this.batteryPct,
    required this.state,
    required this.payloadHex,
    required this.frameHex,
    required this.expectTMs,
    required this.expectAx,
    required this.expectAy,
    required this.expectAz,
    required this.expectGx,
    required this.expectGy,
    required this.expectGz,
    required this.expectMagMg,
    required this.expectPeakMg,
    required this.expectFlags,
    required this.expectScore,
    required this.expectBatteryPct,
    required this.expectState,
  });

  /// Case name, used as the test description.
  final String name;

  /// What this case is for. Written into the failure message, because
  /// `expected FF7F actual 8000` does not say *why* that matters.
  final String reason;

  // --- inputs, passed straight through to the reference encoder -------------
  final double tMs;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double magMg;
  final double peakMg;
  final int flags;
  final double score;
  final double batteryPct;
  final int state;

  /// Expected 24-byte payload, uppercase hex.
  final String payloadHex;

  /// Expected full `TELEMETRY` frame (§3 + §5), uppercase hex.
  final String frameHex;

  // --- expected decoded integers ---------------------------------------------
  final int expectTMs;
  final int expectAx;
  final int expectAy;
  final int expectAz;
  final int expectGx;
  final int expectGy;
  final int expectGz;
  final int expectMagMg;
  final int expectPeakMg;
  final int expectFlags;
  final int expectScore;
  final int expectBatteryPct;
  final int expectState;
}

/// The vectors. See the file header for provenance.
const List<TelemetryVector> kExtraTelemetryVectors = <TelemetryVector>[
  TelemetryVector(
    name: 'halfRounding',
    reason: 'JS Math.round is half-up, Dart double.round() is half-away-from-'
        'zero. They agree on positive halves and disagree on every negative '
        'half: 0.5/1.5/2.5 encode the same, -0.5/-1.5/-2.5 do not.',
    tMs: 0,
    ax: 0.5,
    ay: 1.5,
    az: 2.5,
    gx: -0.5,
    gy: -1.5,
    gz: -2.5,
    magMg: 0,
    peakMg: 0,
    flags: 0x00,
    score: 0,
    batteryPct: 0,
    state: 0,
    // ax=1, ay=2, az=3, gx=-0, gy=-1, gz=-2
    payloadHex: '000000000100020003000000FFFFFEFF0000000000000000',
    frameHex:
        'A55A01101800000000000100020003000000FFFFFEFF000000000000000085BD',
    expectTMs: 0,
    expectAx: 1,
    expectAy: 2,
    expectAz: 3,
    expectGx: 0,
    expectGy: -1,
    expectGz: -2,
    expectMagMg: 0,
    expectPeakMg: 0,
    expectFlags: 0x00,
    expectScore: 0,
    expectBatteryPct: 0,
    expectState: 0,
  ),
  TelemetryVector(
    name: 'tMsMax',
    reason: 't_ms is a u32 (§5); 0xFFFFFFFF must survive as 4294967295 and not '
        'be read as -1.',
    tMs: 0xFFFFFFFF,
    ax: 0,
    ay: 0,
    az: 0,
    gx: 1000,
    gy: -1000,
    gz: 0,
    magMg: 1000,
    peakMg: 0,
    flags: 0x00,
    score: 0,
    batteryPct: 100,
    state: 1,
    payloadHex: 'FFFFFFFF000000000000E80318FC0000E803000000006401',
    frameHex:
        'A55A01101800FFFFFFFF000000000000E80318FC0000E803000000006401E4A3',
    expectTMs: 0xFFFFFFFF,
    expectAx: 0,
    expectAy: 0,
    expectAz: 0,
    expectGx: 1000,
    expectGy: -1000,
    expectGz: 0,
    expectMagMg: 1000,
    expectPeakMg: 0,
    expectFlags: 0x00,
    expectScore: 0,
    expectBatteryPct: 100,
    expectState: 1,
  ),
  TelemetryVector(
    name: 'tMsOverflow',
    reason: 'The reference does `s.tMs >>> 0`, i.e. modulo 2^32. A simulator '
        'or a device with a wrapped clock must truncate identically.',
    tMs: 0x100000000,
    ax: 0,
    ay: 0,
    az: 0,
    gx: 1000,
    gy: 0,
    gz: 0,
    magMg: 0,
    peakMg: 0,
    flags: 0x00,
    score: 0,
    batteryPct: 0,
    state: 0,
    payloadHex: '00000000000000000000E803000000000000000000000000',
    frameHex:
        'A55A0110180000000000000000000000E8030000000000000000000000007D5F',
    expectTMs: 0,
    expectAx: 0,
    expectAy: 0,
    expectAz: 0,
    expectGx: 1000,
    expectGy: 0,
    expectGz: 0,
    expectMagMg: 0,
    expectPeakMg: 0,
    expectFlags: 0x00,
    expectScore: 0,
    expectBatteryPct: 0,
    expectState: 0,
  ),
  TelemetryVector(
    name: 'clampSat',
    reason: 'Saturation, not wraparound. A corrupt or overloaded sensor must '
        'clamp to +/-32767 / -32768 and 65535, never wrap to a negative '
        'acceleration or a negative battery.',
    tMs: 1,
    ax: 40000,
    ay: -40000,
    az: 32000.5,
    gx: 40000,
    gy: -40000,
    gz: 32767.5,
    magMg: 70000,
    peakMg: -5,
    flags: 0xFF,
    score: 300,
    batteryPct: -1,
    state: 6,
    payloadHex: '01000000FF7F0080017DFF7F0080FF7FFFFF0000FFFF0006',
    frameHex:
        'A55A0110180001000000FF7F0080017DFF7F0080FF7FFFFF0000FFFF0006AC64',
    expectTMs: 1,
    expectAx: 32767,
    expectAy: -32768,
    expectAz: 32001,
    expectGx: 32767,
    expectGy: -32768,
    expectGz: 32767,
    expectMagMg: 65535,
    expectPeakMg: 0,
    expectFlags: 0xFF,
    expectScore: 255,
    expectBatteryPct: 0,
    expectState: 6,
  ),
  TelemetryVector(
    name: 'intBounds',
    reason: 'The exact representable boundaries of every field: i16 min/max, '
        'u16 max, and 0xFF for flags/score/battery/state (§5: battery 255 = '
        'unknown).',
    tMs: 0x80000000,
    ax: -32768,
    ay: 32767,
    az: -32768,
    gx: 32767,
    gy: 0,
    gz: 0,
    magMg: 65535,
    peakMg: 65535,
    flags: 0xFF,
    score: 255,
    batteryPct: 255,
    state: 255,
    payloadHex: '000000800080FF7F0080FF7F00000000FFFFFFFFFFFFFFFF',
    frameHex:
        'A55A01101800000000800080FF7F0080FF7F00000000FFFFFFFFFFFFFFFF0265',
    expectTMs: 0x80000000,
    expectAx: -32768,
    expectAy: 32767,
    expectAz: -32768,
    expectGx: 32767,
    expectGy: 0,
    expectGz: 0,
    expectMagMg: 65535,
    expectPeakMg: 65535,
    expectFlags: 0xFF,
    expectScore: 255,
    expectBatteryPct: 255,
    // 255 is not a §5.2 state, so it must decode to DeviceState.unknown
    // (byte 255) rather than throwing.
    expectState: 255,
  ),
];

/// A payload whose length is deliberately wrong, for the length-rejection tests.
const String kShortTelemetryPayloadHex = 'A55A01101000';

/// A frame with a deliberately bad CRC (last byte flipped), for the
/// CRC-rejection tests.
const String kCorruptCrcFrameHex = 'A55A01020000149D';
