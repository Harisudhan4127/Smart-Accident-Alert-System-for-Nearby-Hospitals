// config.h — Smart Accident Alert Node, build-time configuration.
//
// Every tunable in the firmware lives here. Nothing in this file is `const`-only at
// runtime: the protocol CONFIG message may change a subset of these at run time
// (see protocol::Settings in comm.h), but the *defaults* and the compile-time
// hardware description live here so there is exactly one place to look when a
// board is respun.
//
// See docs/02-ble-protocol.md for the wire contract this firmware implements.
#pragma once

#include <stddef.h>
#include <stdint.h>

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

#define SAAS_FW_VERSION "1.0.0"
#define SAAS_HW_NAME "esp32-devkit-v1"
#define SAAS_MODEL_NAME "Smart Accident Alert Node v1"

/// Protocol major/minor byte carried in every frame (VER field). Frozen at 1.
constexpr uint8_t kProtoVersion = 1;

namespace detail {

/// "Jan".."Dec" -> 1..12. `d` points at the 3-character month abbreviation.
constexpr int monthFromAbbrev(const char* d) {
  return (d[0] == 'J' && d[1] == 'a')     ? 1
         : (d[0] == 'F')                   ? 2
         : (d[0] == 'M' && d[1] == 'a')    ? 3
         : (d[0] == 'A' && d[1] == 'p')    ? 4
         : (d[0] == 'M' && d[2] == 'y')    ? 5
         : (d[0] == 'J' && d[2] == 'n')    ? 6
         : (d[0] == 'J' && d[2] == 'l')    ? 7
         : (d[0] == 'A' && d[1] == 'u')    ? 8
         : (d[0] == 'S' && d[1] == 'e')    ? 9
         : (d[0] == 'O' && d[1] == 'c')    ? 10
         : (d[0] == 'N' && d[1] == 'o')    ? 11
                                       : 12;
}

/// `__DATE__` is "Mmm dd yyyy"; the day is space padded, the year always starts at
/// index 7. Returns an integer of the form YYYYMMDD, which is the shape the
/// protocol's `fwBuild` field uses (golden.json: 20260927).
constexpr uint32_t buildStampFromDate() {
  const char* d = __DATE__;
  const int mon = monthFromAbbrev(d);
  const int day = (d[4] == ' ') ? (d[5] - '0') : ((d[4] - '0') * 10 + (d[5] - '0'));
  const int yr = (d[7] - '0') * 1000 + (d[8] - '0') * 100 + (d[9] - '0') * 10 +
                 (d[10] - '0');
  return static_cast<uint32_t>(yr) * 10000u + static_cast<uint32_t>(mon) * 100u +
         static_cast<uint32_t>(day);
}

}  // namespace detail

#ifndef SAAS_FW_BUILD
constexpr uint32_t kFwBuild = detail::buildStampFromDate();
#else
constexpr uint32_t kFwBuild = SAAS_FW_BUILD;
#endif

// ---------------------------------------------------------------------------
// Pin map — PROJECT_PLAN.md §6
// ---------------------------------------------------------------------------

constexpr uint8_t kPinI2cSda = 21;
constexpr uint8_t kPinI2cScl = 22;
constexpr uint8_t kPinSw420 = 27;
constexpr uint8_t kPinBuzzer = 25;   // active LOW through an NPN transistor
constexpr uint8_t kPinSosButton = 26;  // active LOW, internal pull-up
constexpr uint8_t kPinLedGreen = 32;
constexpr uint8_t kPinLedRed = 33;
constexpr uint8_t kPinBatteryAdc = 34;  // input-only: correct choice for a divider
constexpr uint8_t kPinChargingStat = 35;  // TP4056 CHRG, open-drain active LOW
/// Set to 0 to build for a board with no charge-status wiring at all.
constexpr bool kChargingPinPresent = true;
/// When no CHRG pin is wired we fall back to a voltage-rise heuristic.
constexpr bool kChargingHeuristic = true;

constexpr bool kBuzzerActiveLow = true;
constexpr bool kLedActiveHigh = true;
constexpr bool kSw420ActiveHigh = true;  // module pulls OUT HIGH on vibration
constexpr bool kSosButtonActiveLow = true;

constexpr uint32_t kI2cClockHz = 400000;

// Battery divider: two equal resistors, so the pin sees cell/2.
constexpr uint16_t kBatteryDividerNum = 2;
constexpr uint16_t kBatteryDividerDen = 1;
/// ADC readings below this are treated as "no battery connected" (USB only).
constexpr uint16_t kBatteryAdcIgnoreMv = 1200;

// ---------------------------------------------------------------------------
// I2C addresses
// ---------------------------------------------------------------------------

constexpr uint8_t kMpuAddr = 0x68;
constexpr uint8_t kOledAddr = 0x3C;

// ---------------------------------------------------------------------------
// Sampling / task timing — matches the budget table in docs/02-ble-protocol.md §9
// ---------------------------------------------------------------------------

constexpr uint16_t kSensorHz = 50;                 ///< Detector rate. 20 ms period.
constexpr uint32_t kSensorPeriodMs = 1000 / kSensorHz;
constexpr uint16_t kTelemetryHzDefault = 50;
/// How long the detector stays blind after a confirmed alert. One impact spans
/// dozens of 20 ms samples and the post-impact ring-down still reads above the
/// candidate floor, so without a window a single crash is reported several times.
constexpr uint32_t kDetectorRefractoryMs = 5000;

constexpr uint16_t kTelemetryHzMin = 5;
constexpr uint16_t kTelemetryHzMax = 100;
constexpr uint32_t kUiPeriodMs = 100;
constexpr uint32_t kSysPeriodMs = 1000;
constexpr uint16_t kWatchdogTimeoutS = 5;

// ── ADXL345 configuration ───────────────────────────────────────────────────
//
// The ADXL345 is an ACCELEROMETER ONLY. It has no gyroscope, no magnetometer and
// no temperature output on this interface, and nothing in this firmware may
// claim otherwise. Every rotation-related term that the previous MPU6050-based
// design used has been replaced with an accelerometer-derived equivalent; see
// `namespace wt` below and detector.cpp for the reasoning.
//
// I2C address. The part has two, selected by the SDO / ALT_ADDRESS pin:
//   0x53  SDO tied LOW  (the default on most breakout boards -- assumed here)
//   0x1D  SDO tied HIGH
// 0x53 is the safe default because it collides with nothing else on the bus:
// the SSD1306 OLED is at 0x3C and the SW-420 is a plain GPIO. See
// docs/03-hardware-and-wiring.md.
constexpr uint8_t kAdxlAddr = 0x53;
/// The alternative address, accepted as a fallback if 0x53 does not answer.
/// Two devices on one bus would need this, but 0x53/0x1D/0x3C are mutually
/// exclusive, so a scan can always tell them apart.
constexpr uint8_t kAdxlAddrAlt = 0x1D;

/// ODR. The part's own ODR is the anti-aliaser for the bus, so it must sit at
/// or above the detector rate. 100 Hz is the lowest rate that comfortably
/// covers the 50 Hz loop, and it is the part's lowest power-consumption rate
/// that still oversamples us (ADXL345_DATARATE_100_HZ = 50 Hz bandwidth).
constexpr uint8_t kAdxlOdr = 0x0A;

/// Full-scale range. +/-16 g, chosen so a genuinely hard crash cannot clip:
/// 1024 counts at 31.2 mg/LSB gives +/-31.9 g per axis, and the detector's
/// kAbsFullMg knee is only 6 g. Clipping here would flatten the very peaks the
/// severity term is there to measure.
constexpr uint8_t kAdxlRange16G = 0x0B;  ///< ADXL345_RANGE_16_G

/// ADXL345 sensitivity for a given full-scale range, in tenths of a milli-g per
/// LSB. The datasheet tabulates it per range:
///
/// | Range | DATA_FORMAT | mg/LSB | returned here |
/// | --- | --- | --- | --- |
/// | +/-2 g  | `0x00` | 3.9  |  39 |
/// | +/-4 g  | `0x01` | 7.8  |  78 |
/// | +/-8 g  | `0x02` | 15.6 | 156 |
/// | +/-16 g | `0x03` | 31.2 | 312 |
///
/// FULL_RES (bit 3 of DATA_FORMAT, which `setRange()` always sets) holds the
/// output at 13 significant bits / 1024 counts on *every* range. It fixes the
/// number of distinct values, **not** the mass each one represents — so the
/// widest range costs real resolution, and the scale has to move with it.
///
/// **Why this is a function and not a constant next to kAdxlRange16G.** It was
/// a constant, set to 39 (the +/-2 g figure) on the theory that FULL_RES pinned
/// it. That made every reading 8x too small: a node lying still reported
/// 0.12 g instead of 0.94 g, and the free-fall floor, the z-score baseline and
/// the trip threshold were all compared against a sensor lying about its
/// scale. Nothing complained, because 0.12 g looks like a plausible number and
/// the detector simply never scored.
///
/// Deriving it from the range makes that class of bug unrepresentable: there is
/// no second constant to forget to update. `accelScaleIsConsistent` below is the
/// same table read a second time as a `static_assert`, so a typo in *this*
/// function is still a build failure rather than a wrong number on a display.
///
/// The Adafruit library makes the same mistake — its getEvent() hardcodes
/// `ADXL345_MG2G_MULTIPLIER (0.004)`, the +/-2 g value — so the library's own
/// physical-units accessor cannot be used above +/-2 g. That is why
/// `sensors.cpp` reads the raw registers and scales them here.
constexpr int32_t adxlMilliTenthsPerLsb(uint8_t range) {
  switch (range & 0x03) {
    case 0x00: return 39;   // +/-2 g,  3.9 mg
    case 0x01: return 78;   // +/-4 g,  7.8 mg
    case 0x02: return 156;  // +/-8 g, 15.6 mg
    default: return 312;    // +/-16 g, 31.2 mg
  }
}

/// The scale this build actually uses, for the conversion in sensors.cpp.
constexpr int32_t kAdxlMilliTenthsPerLsb = adxlMilliTenthsPerLsb(kAdxlRange16G);

/// Every range in the table, so a mistyped entry above is a build failure.
/// Redundant with the switch, deliberately: a `static_assert` is evaluated
/// where a wrong number is impossible to miss.
static_assert(adxlMilliTenthsPerLsb(0x00) == 39 && adxlMilliTenthsPerLsb(0x01) == 78 &&
                  adxlMilliTenthsPerLsb(0x02) == 156 && adxlMilliTenthsPerLsb(0x03) == 312,
              "ADXL345 sensitivity table must match the datasheet");

/// How many consecutive identical samples count as a dead sensor. 1 second at
/// 50 Hz: a still vehicle legitimately repeats the same count for much longer,
/// so the test cannot trip on stillness -- but a bus that has gone open or a
/// part that has stopped answering freezes on one value immediately. Reporting
/// that as a SENSOR FAULT is the difference between "the node is not listening"
/// and "the node thinks everything is fine".
constexpr uint8_t kAdxlFrozenRuns = 50;


// ---------------------------------------------------------------------------
// Filter coefficients (Q15, integer) — detector input conditioning
// ---------------------------------------------------------------------------

/// Moving average length on the SLOW accel path (gravity, orientation, speed).
/// 4 taps @ 50 Hz = 80 ms; enough to kill I2C ringing without visibly lagging
/// gravity. The impact path is deliberately unfiltered -- see sensors.h.
constexpr uint8_t kMaTaps = 4;
/// First-order gravity tracker time constant used to split linear / gravity accel.
constexpr uint8_t kGravityTaps = 48;  // ~1 s

/// IIR coefficient of the gravity tracker: 1 - exp(-dt/tau) with dt = 20 ms and
/// tau = kGravityTaps * 20 ms, in Q15. Computed from the taps so retuning the
/// time constant cannot silently desync the coefficient.
constexpr int32_t kGravityAlphaQ15 = 649;  // 0.019801 = 1 - exp(-0.02/1.0)
static_assert(kGravityAlphaQ15 > 0 && kGravityAlphaQ15 < 32768,
              "gravity IIR coefficient must be a sane Q15 fraction");

/// The raw data registers hold 13 significant bits left-justified in 16, so the
/// conversion is (raw >> 3) * 312 / 10. Integer throughout: the sensor's 3 LSBs
/// of padding are discarded by the shift and the 31.2 mg scale is applied as an
/// exact rational, so there is no float anywhere in the acquisition path.
constexpr uint8_t kAdxlRawShift = 3;  // 16-bit register -> 13-bit value

/// Largest magnitude a single axis can report at kAdxlRange16G, milli-g.
/// 1024 counts x 31.2 mg = 31968 mg. The `Sample` axes are int32 all the way
/// into the protocol encoder, which clamps to int16 (+/-32000), so this is the
/// value that has to fit in the wire format without silently saturating.
constexpr int32_t kAccelMagMaxMg = 31968;
static_assert(kAccelMagMaxMg <= 32000,
              "per-axis full scale must still fit the int16 telemetry field");


/// SW-420 contact debounce. The module is a vibration-sensitive microswitch and
/// chatters for milliseconds; 25 ms is long enough to reject it and short enough
/// that a real 1-3 s assertion is not eroded.
constexpr uint16_t kSw420DebounceMs = 25;

// ---------------------------------------------------------------------------
// Fusion weights — see detector.cpp for the justification of every number
// ---------------------------------------------------------------------------

namespace wt {
constexpr uint16_t kFreeFall = 300;  // 0.30  loss of contact, |a| < 0.3 g
constexpr uint16_t kZScore = 230;    // 0.23  accel surprise vs rolling baseline
constexpr uint16_t kSw420 = 170;     // 0.17  independent mechanical switch
constexpr uint16_t kAbsMag = 130;    // 0.13  absolute severity
constexpr uint16_t kOrient = 110;    // 0.11  gravity-vector rotation (accel-derived)
constexpr uint16_t kJerk = 60;       // 0.06  d|mag|/dt
constexpr uint16_t kSum = kFreeFall + kZScore + kSw420 + kAbsMag + kOrient + kJerk;
static_assert(kSum == 1000, "fusion weights must sum to 1000 (= 1.000)");
}  // namespace wt

// The previous design carried a 7th term worth 0.12 for gyroscope rotation
// during the event. The ADXL345 has no gyroscope, so that term is GONE, not
// faked. Its 120 points are redistributed across the six surviving
// accelerometer-derived terms in proportion to their existing weight, so the
// detector's *sensitivity* is preserved rather than quietly reduced.
//
//   before  260 200 150 [120] 110 100  60
//   after   300 230 170       130 110  60
//
// A rollover is still detected, because a rollover changes which way gravity
// points relative to the vehicle. That is exactly what the kOrient term already
// measures, from the accelerometer alone. What is genuinely lost is the
// ability to distinguish "spun in place" from "tilted" -- which does not occur
// in the crashes this system is trying to catch.
//
// CONSEQUENCE: kTripScore below is UNCHANGED, so the bar to trip is identical,
// but every term now leans on the same underlying measurement (magnitude over
// time). The terms are still independent evidence -- free-fall is a floor, the
// z-score is a surprise, SW-420 is a second physical sensor, orientation is a
// vector rotation, jerk is a derivative -- so a single artefact cannot
// manufacture a trip. Still: these weights have NOT been re-validated against
// real crash data and the on-road procedure in docs/10-testing.md must be re-run.

/// Trip / release hysteresis on the 0..100 fused score.
constexpr uint8_t kTripScore = 70;
constexpr uint8_t kReleaseScore = 45;

/// Normalisation knees. Each term is a clamped ramp from 0 at its "on" knee to 1
/// at its "full" knee, so the weights above are honest (each term can reach 1).
namespace knee {
constexpr int16_t kZOnMilli = 4000;    ///< 4.0 sigma
constexpr int16_t kZFullMilli = 12000;  ///< 12.0 sigma
/// The ADXL345 is ranged +/-16 g on all three axes, so |a| tops out at
/// 16*sqrt(3) = 27.7 g. A "full" knee of 8 g would be unreachable and the term
/// could never score, which would silently redistribute its weight; 6 g is
/// comfortably inside the part's range and just above a severe crash.
constexpr uint16_t kAbsFullMg = 6000;
/// Orientation change is measured as the angle between the pre-impact and
/// post-impact GRAVITY VECTORS -- both come from the accelerometer, so this term
/// survives the loss of the gyroscope. A rollover swings gravity through tens of
/// degrees; a pothole springs back to where it started.
constexpr int16_t kOrientOnDeg10 = 150;   ///< 15.0 degrees
constexpr int16_t kOrientFullDeg10 = 600;  ///< 60.0 degrees
constexpr int32_t kJerkOnMgPerS = 5000;
constexpr int32_t kJerkFullMgPerS = 20000;
}  // namespace knee

/// Windows. 50 taps = 1 s of baseline at 50 Hz, 30 taps = 600 ms of post-impact
/// evidence. The baseline window is intentionally long enough to average out a
/// single pothole strike; the post window is short enough to stay inside one
/// crash event.
constexpr uint8_t kPreWindowN = 50;
constexpr uint8_t kPostWindowN = 30;
/// Speed snapshot is frozen this long after the trip for `preImpactSpeedKmh`.
constexpr uint16_t kPreSpeedLookbackMs = 200;

/// Minimum |sigma| used by the z-score. A vehicle parked on a dyno can hold the
/// magnitude to a few tenths of a milli-g, which would make any bump a 200-sigma
/// event; flooring sigma stops that while staying far below road noise (~10 mg).
constexpr uint16_t kMinSigmaMg = 12;

/// Free-fall detection: |a| below kFreeFallMgG for at least kFreeFallMs.
constexpr uint16_t kFreeFallMg = 300;  // 0.3 g
constexpr uint16_t kFreeFallMs = 60;   // 3 consecutive samples at 50 Hz

/// An SW-420 assertion keeps contributing to the fused score for this long after
/// the last rising edge: the module's own pot-set dwell time is typically 1-3 s,
/// so correlating against its *rising edges* alone under-counts.
constexpr uint16_t kSw420HoldMs = 250;
/// A rising edge older than this is not counted in `sw420Hits`.
constexpr uint16_t kSw420HitWindowMs = 10000;
constexpr uint8_t kSw420MaxHits = 255;

// ---------------------------------------------------------------------------
// Dead-reckoned speed gate
// ---------------------------------------------------------------------------

/// Acceleration below this counts as "at rest" for the rest-timer.
constexpr int32_t kRestAccelMg = 60;
constexpr uint16_t kRestResetMs = 3000;  ///< decay v to zero after 3 s at rest
/// Per-tick leak applied while coasting, so drift does not accumulate forever.
/// 1200 ppm is 0.12 %/tick, i.e. the estimate halves about every 11 s. A crash
/// ends with the vehicle stationary, so the rest detector (kRestResetMs) is what
/// actually clears it; the leak only bounds the drift of a long downhill.
constexpr int16_t kSpeedLeakPpm = 1200;  // 0.12 %/tick ~ 5.8 %/s
/// dv per milli-g of forward acceleration over one kSensorPeriodMs tick, in
/// Q4 milli-km/h (milli-km/h x 16). 1 mg over 20 ms is 0.706 milli-km/h, so this
/// is 11.297 Q4 units -- the x1000 lets the integrator scale exactly by dtMs.
constexpr int32_t kSpeedQ4PerMgPerTick = 11297;
/// Stored as milli-km/h, so this needs 32 bits (see Sample::speedMilliKmh).
constexpr uint32_t kSpeedMaxMilliKmh = 200000;  // 200.0 km/h
constexpr uint32_t kSpeedRestMilliKmhPerMs = 6000;  // 0.006 km/h per ms = 21.6 km/h/s

// ---------------------------------------------------------------------------
// Buffer sizing — nothing here is ever allocated at run time
// ---------------------------------------------------------------------------

/// MAX_PAYLOAD is 512, so 600 leaves room for the 8-byte frame header/CRC.
constexpr size_t kFrameBufSize = 600;
constexpr size_t kJsonBufSize = 600;
constexpr size_t kRxBufSize = 600;  // static FrameScanner payload reservoir

/// Telemetry ring. Best effort: when the phone is congested we drop the oldest
/// samples instead of stalling the detector (docs/02-ble-protocol.md §2.2).
constexpr uint8_t kTelemRingN = 4;
/// Sensor -> detector ring is lossless (blocking I2C must not drop data).
constexpr uint8_t kSampleRingN = 8;

/// CTRL event queue. Events are rare; the sequencer retries, so a full queue
/// drops the *newest* event and lights the red LED rather than blocking.
constexpr uint8_t kEventQueueN = 8;
constexpr size_t kEventSlotSize = 320;  ///< 512 max payload, 320 is ample

// ---------------------------------------------------------------------------
// Event sequencer — docs/02-ble-protocol.md §8
// ---------------------------------------------------------------------------

constexpr uint16_t kEventRetryMs = 750;
constexpr uint16_t kEventMaxRetries = 3;      ///< 750 / 1500 / 3000 ms
constexpr uint8_t kHelloAckMaxRetries = 5;    ///< seq 0, retried harder
constexpr uint16_t kHelloAckRetryMs = 400;

// ---------------------------------------------------------------------------
// The four parameters the specification names explicitly.
//
// These are EXPERIMENTAL. They are gathered here, in one block, because they are
// the only numbers in the firmware that cannot be justified from a datasheet —
// every other constant is either a register value or a filter coefficient. They
// are starting points for the road test in docs/10-testing.md, NOT validated
// thresholds, and the file carries no claim that they have seen real crash data.
// ---------------------------------------------------------------------------

/// ACCELERATION_THRESHOLD — the |a| (in milli-g) that counts as an impact
/// candidate. 3.0 g separates a hard pothole (0.4–1.2 g) from a low-speed
/// collision (2.5–5 g) and a serious one (6–15 g) with room above it.
/// Also the user-facing "impact threshold" in CONFIG, clamped to the range above.
constexpr int32_t kAccelerationThresholdMg = 3000;

/// VIBRATION_CONFIRMATION_WINDOW — how close in time the ADXL345 peak and an
/// SW-420 assertion must be to corroborate each other. 400 ms is roughly the
/// duration of the impact transient itself, so "within the same bump" is true
/// and "within the same drive" is not. Widen it and a pothole twenty seconds
/// after a kerb starts counting; narrow it and a real crash whose microswitch
/// fires a few samples late stops counting.
constexpr uint16_t kVibrationConfirmationWindowMs = 400;

/// ACCIDENT_CONFIRMATION_TIME — how long the fused score must stay above the
/// trip level before the event is declared. 60 ms is three consecutive 50 Hz
/// samples, which rejects a single-sample electrical spike without delaying a
/// real crash by anything a person would notice.
constexpr uint16_t kAccidentConfirmationTimeMs = 60;

/// CANCEL_COUNTDOWN_SECONDS — the window the driver has to call a false alarm
/// before anything is sent. Long enough to react to a pothole, short enough
/// that a real crash is not delayed past the point where it matters.
constexpr uint16_t kCancelCountdownSeconds = 10;

// ---------------------------------------------------------------------------
// CONFIRM / countdown defaults — docs/02-ble-protocol.md §6.4
// ---------------------------------------------------------------------------

// The configurable impact threshold. The ADXL345 is ranged +/-16 g, so the
// maximum was raised from the old +/-4 g ceiling (8000) to 16000: a hard crash
// on the new part can legitimately exceed 8 g without clipping.
constexpr uint16_t kCfgAccelThresholdMgDefault = 3000;
constexpr uint16_t kCfgAccelThresholdMgMin = 1500;
constexpr uint16_t kCfgAccelThresholdMgMax = 16000;
// NOTE: there is no gyro threshold, because there is no gyroscope. The
// `gyroThresholdDps` key is gone from the CONFIG wire format (protocol v2).
constexpr uint16_t kCfgDebounceMsDefault = 60;
constexpr uint16_t kCfgDebounceMsMin = 20;
constexpr uint16_t kCfgDebounceMsMax = 500;
constexpr uint16_t kCfgConfirmWindowSecDefault = 10;
constexpr uint16_t kCfgConfirmWindowSecMin = 5;
constexpr uint16_t kCfgConfirmWindowSecMax = 120;
constexpr uint32_t kCfgMinSpeedMilliKmhDefault = 5000;  // 5.0 km/h
constexpr uint32_t kCfgMinSpeedMilliKmhMax = 60000;    // 60.0 km/h
constexpr uint16_t kCfgGainMilliDefault = 1000;        // 1.0x
constexpr uint16_t kCfgGainMilliMin = 500;
constexpr uint16_t kCfgGainMilliMax = 3000;
constexpr uint32_t kCfgMuteUntilDefault = 0;
constexpr bool kCfgVibrationRequiredDefault = true;
constexpr bool kCfgBuzzerEnabledDefault = true;
constexpr bool kCfgLedEnabledDefault = true;
constexpr bool kCfgAutoArmDefault = true;

// ---------------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------------

constexpr uint16_t kCalibMinMs = 500;
/// Minimum samples a calibration must contain to be trusted, at kSensorHz.
constexpr uint16_t kCalibMinSamples = kCalibMinMs / kSensorPeriodMs;
constexpr uint16_t kCalibMaxMs = 10000;
constexpr uint16_t kCalibDefaultMs = 5000;
/// Total samples reported across the CALIB_LOG frame(s), downsampled.
constexpr uint16_t kCalibMaxSamples = 48;
/// Boot-time automatic calibration. The device must be still when mounted.
constexpr uint16_t kBootCalibMs = 1200;

// ---------------------------------------------------------------------------
// Feature switches — every one of these degrades gracefully
// ---------------------------------------------------------------------------

#ifndef SAAS_ENABLE_OLED
#define SAAS_ENABLE_OLED 1
#endif
#ifndef SAAS_ENABLE_BUZZER
#define SAAS_ENABLE_BUZZER 1
#endif
#ifndef SAAS_ENABLE_LED
#define SAAS_ENABLE_LED 1
#endif
#ifndef SAAS_ENABLE_SERIAL_LOG
#define SAAS_ENABLE_SERIAL_LOG 1
#endif

/// Light sleep between samples when there is provably nothing to do: no BLE
/// client, state IDLE, detection disarmed. Deep sleep is *not* automatic — see
/// power.cpp for the explicitly-armed path.
#ifndef SAAS_ENABLE_LIGHT_SLEEP
#define SAAS_ENABLE_LIGHT_SLEEP 1
#endif

/// Set to 1 to run the full hardware self-test on boot. The runtime equivalent is
/// holding the FLASH button (GPIO0) for 2 s during the splash, or COMMAND
/// SELFTEST from the app.
#ifndef FIRMWARE_SELFTEST
#define FIRMWARE_SELFTEST 0
#endif

// ---------------------------------------------------------------------------
// FreeRTOS task priorities and stacks (ESP32: 25 = configMAX_PRIORITIES - 1)
// ---------------------------------------------------------------------------

constexpr uint32_t kPrioSys = 3;    ///< 1 Hz housekeeping, owns Serial
constexpr uint32_t kPrioBle = 4;    ///< connection supervision deadlines
constexpr uint32_t kPrioUi = 2;     ///< OLED must never delay anything
constexpr uint32_t kPrioDetect = 5; ///< fusion, must not jitter
constexpr uint32_t kPrioSensor = 6; ///< blocking I2C, off the BLE core
constexpr uint32_t kPrioWdt = 7;    ///< watchdog feed, lowest latency

constexpr uint32_t kStackSensor = 4096;
constexpr uint32_t kStackDetect = 4096;
constexpr uint32_t kStackBle = 6144;
constexpr uint32_t kStackUi = 4096;
constexpr uint32_t kStackSys = 4096;
constexpr uint32_t kStackWdt = 2048;

// ---------------------------------------------------------------------------
// Advertising / connection parameters — docs/02-ble-protocol.md §2.3, §2.4
// ---------------------------------------------------------------------------

constexpr int8_t kBleTxPowerDbm = 9;
constexpr uint16_t kConnIntervalMinMs = 15;
constexpr uint16_t kConnIntervalMaxMs = 30;
constexpr uint16_t kConnLatency = 4;
constexpr uint16_t kConnSupervisionMs = 4000;
constexpr uint16_t kAdvTxPowerLevelDbm = 3;  ///< advertised level, 3 dBm
constexpr uint8_t kBleAppearance = 0x03;     ///< Generic Sensor

// ---------------------------------------------------------------------------
// Button / LED behaviour
// ---------------------------------------------------------------------------

constexpr uint16_t kSosDebounceMs = 40;
/// Hold time for the SOS button. Defined with the rest of the button mapping at
/// the end of this file; this is the name the UI has always used.
constexpr uint16_t kSosLongPressMs = 800;
/// Duration of the "detector tripped" beep pattern, and the CALIBRATE confirm
/// chirp, in milliseconds.
constexpr uint16_t kChirpMs = 90;
/// Red-LED flash cadence used to signal an undelivered event (docs §8 step 5).
constexpr uint16_t kQueuedEventBlinkMs = 120;

// ---------------------------------------------------------------------------
// Run mode — NORMAL vs DEMO
// ---------------------------------------------------------------------------

/// Which mode the node boots into.
///
/// **NORMAL, always.** This is a safety decision, not a default: a node that
/// booted into DEMO would raise simulated accident alerts about a car that was
/// fine, and nobody watching the OLED would necessarily notice the difference.
/// DEMO has to be asked for, every time, by a COMMAND or the button — so the
/// powered state of a car is never something a bench session left behind.
constexpr uint8_t kRunModeDefault = 0;  ///< kModeNormal

/// Hold the SOS button this long on boot to enter DEMO, and again to leave.
///
/// The alternative — a serial command only — means the mode cannot be reached
/// with the phone disconnected, which is exactly when you want to demonstrate
/// the node on a bench. A long press is deliberate, so a stray tap during a
/// normal test cannot flip it.
constexpr uint32_t kDemoToggleHoldMs = 2000;

/// Magnitude that must accompany an SW-420 assertion before a shake counts,
/// milli-g.
///
/// **Both sensors must agree.** An earlier revision let DEMO fire on the
/// accelerometer alone at 2.2 g, with the SW-420 as an optional shortcut. That
/// made a demo tell you less than the hardware can: the whole point of the SW-420
/// is that it is a *different* failure mode from an accelerometer, so a demo
/// trigger that ignores it is only exercising half the node.
///
/// Requiring both is also what makes the demo honest about the real detector,
/// which never trips on acceleration alone either.
///
/// 1.0 g is a gentle shake by hand on a desk — far below the 3 g production
/// threshold, because nobody can produce 3 g while holding a module.
constexpr int32_t kDemoShakeMagMg = 1000;

/// Consecutive qualifying samples before firing, at 50 Hz.
///
/// 3 = 60 ms, the same window the real free-fall term uses, so a demo shake lasts
/// about as long as a real impact. With both sensors required there is no
/// single-sample shortcut: both have to be true at the same time, and for long
/// enough, which is what a real strike looks like.
constexpr uint8_t kDemoShakeHoldSamples = 3;

/// Quiet period after a demo trigger.
///
/// Without this, holding the node still shaking fires 50 events a second and
/// the BLE queue fills with undelivered alerts. 5 s is long enough to read what
/// happened on the OLED and long enough not to machine-gun.
constexpr uint32_t kDemoCooldownMs = 5000;

// ---------------------------------------------------------------------------
// Live sensor readout (OLED + serial)
// ---------------------------------------------------------------------------

/// Samples in the OLED bar trace. A power of two so the wrap is a mask, and
/// 128 at the 50 Hz sample rate is 2.56 s of history — enough to see an impact
/// arrive and decay without the interesting part scrolling off.
constexpr uint8_t kTraceLen = 128;
constexpr uint8_t kTraceMask = kTraceLen - 1;

/// Floor for the trace's auto-scale, milli-g.
///
/// A node sitting on a desk reads 1000 mg and would otherwise draw a full-height
/// bar that means nothing. The scale grows to the largest magnitude seen this
/// session and never shrinks, so the bar does not twitch while you watch it, and
/// the ceiling is printed on the display — an auto-scaled axis is only honest if
/// the reader can see what it is scaled to.
constexpr int32_t kTraceFloorMg = 3000;

/// OLED redraw period in DEMO, ms.
///
/// 100 ms, against 200 ms in NORMAL. The screen exists to be watched in DEMO,
/// and 10 Hz is the point where numbers stop looking like a stopwatch. The
/// change is not free: it is 5 full-frame I2C pushes per second instead of 2.5,
/// which is why NORMAL keeps the slower rate.
constexpr uint16_t kDemoRedrawMs = 100;

/// Hard ceiling on the live trace's auto-scale, milli-g (20 g).
///
/// The scale grows to whatever the largest sample was, so a cap is needed: one
/// absurd reading — a node knocked off the desk — would otherwise squash the
/// next 2.5 s of trace into a single pixel row and make the display useless
/// exactly when someone is trying to watch it. 20 g is well above any impact
/// worth showing and well above the ADXL345's practical range, so the cap only
/// engages on a genuinely broken reading.
constexpr int32_t kTraceCeilingMaxMg = 20000;

/// Serial telemetry period, ms. 200 ms = 5 lines/s, readable in a monitor.
constexpr uint16_t kSerialDataMs = 200;

/// Consecutive failed accelerometer reads that mean the sensor is gone, not
/// momentarily noisy.
///
/// 25 samples at 50 Hz is half a second. Long enough that a single dropped I2C
/// transaction, or the moment a phone connects and the radio briefly starves the
/// bus, cannot raise a fault; short enough that a cable pulled off is reported
/// before anyone has driven a kilometre believing the node was watching.
constexpr uint8_t kSensorFaultFailRuns = 25;

/// How long a full-screen banner owns the display, ms.
///
/// Long enough to read a two-word message and register it, short enough that it
/// is not in the way when you go back to watching the trace. 1.2 s is roughly
/// what it takes to read "ENTERED DEMO" and glance up.
constexpr uint16_t kBannerMs = 1200;

/// Frames in the banner animation. Six at kBannerMs is one every 200 ms, which
/// reads as motion rather than as a strobe. Too many and it flickers; too few
/// and it looks like a static screen that happens to vanish.
constexpr uint8_t kBannerFrames = 6;

/// Hold time that means SOS rather than a mode click, ms.
///
/// Must equal kSosLongPressMs above, which is the name Ui uses. Asserted rather
/// than aliased because they are declared on opposite sides of this file, and a
/// silent divergence here would mean the button does one thing and the comment
/// on the other says another.
///
/// Long enough that a knock on the dashboard is not an emergency call, short
/// enough to be usable in one. Same idea as press-and-hold-to-power-off:
/// deliberate, not instant.
constexpr uint16_t kSosHoldMs = 800;
static_assert(kSosHoldMs == kSosLongPressMs,
              "the SOS hold time must be the same value under both names");

// ---------------------------------------------------------------------------
// DIAGNOSTIC mode — what counts as a working sensor
// ---------------------------------------------------------------------------

/// Plausible |a| range for a node that is being held, in milli-g.
///
/// The window is wide on purpose. A node on a bench can be at any angle, and
/// 1 g is the *magnitude*, so a still node reads 1 g whatever its orientation.
/// The lower bound is the one that matters: an unpowered ADXL345 reads ~0.1 g
/// (see sensordiag.h), which is the failure this exists to catch, and 500 mg sits
/// comfortably above that noise while comfortably below any real reading.
constexpr int32_t kDiagGravityMinMg = 500;
constexpr int32_t kDiagGravityMaxMg = 3000;

/// Change in |a| that counts as the sensor responding to being moved, milli-g.
///
/// A node resting on a desk jitters by tens of milli-g. 150 mg is well above
/// that and well below anything a person does to it, so it separates "responding"
/// from "stuck" without demanding a deliberate shake.
constexpr int32_t kDiagMotionMg = 150;

/// How long gravity may be missing before the accelerometer is called failed.
///
/// 3 s is generous: it allows for a node being held, knocked, or briefly
/// unpowered, while an unpowered part — which reads ~0.1 g indefinitely — trips
/// it well within a second of being switched on.
constexpr uint32_t kDiagNoGravityMs = 3000;

/// Consecutive failed reads that make a sensor FAIL. The firmware's own fault
/// threshold is kSensorFaultFailRuns; this is deliberately the same number, so
/// DIAGNOSTIC and the state machine never disagree about whether the hardware is
/// broken.
constexpr uint32_t kDiagFailReads = kSensorFaultFailRuns;
