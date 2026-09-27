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

/// DLPF setting written to MPU CONFIG register. 3 => 44 Hz accel / 42 Hz gyro
/// bandwidth at a 1 kHz internal output rate. We read the newest sample pair at
/// 50 Hz, so the effective anti-aliasing matches the detector rate.
constexpr uint8_t kMpuDlpf = 3;
constexpr int8_t kMpuAccelRangeG = 4;    // +/-4 g
constexpr int16_t kMpuGyroRangeDps = 500;  // +/-500 deg/s (int16: 500 does not fit int8)

// ---------------------------------------------------------------------------
// Filter coefficients (Q15, integer) — detector input conditioning
// ---------------------------------------------------------------------------

/// Moving average length on the SLOW accel path (gravity, orientation, speed).
/// 4 taps @ 50 Hz = 80 ms; enough to kill I2C ringing without visibly lagging
/// gravity. The impact path is deliberately unfiltered -- see sensors.h.
constexpr uint8_t kMaTaps = 4;
/// Moving average on the FAST gyro path. 2 taps @ 50 Hz = 40 ms, the most
/// smoothing that leaves a 40 ms rotation pulse intact.
constexpr uint8_t kGyroMaTaps = 2;
/// First-order gravity tracker time constant used to split linear / gravity accel.
constexpr uint8_t kGravityTaps = 48;  // ~1 s

/// IIR coefficient of the gravity tracker: 1 - exp(-dt/tau) with dt = 20 ms and
/// tau = kGravityTaps * 20 ms, in Q15. Computed from the taps so retuning the
/// time constant cannot silently desync the coefficient.
constexpr int32_t kGravityAlphaQ15 = 649;  // 0.019801 = 1 - exp(-0.02/1.0)
static_assert(kGravityAlphaQ15 > 0 && kGravityAlphaQ15 < 32768,
              "gravity IIR coefficient must be a sane Q15 fraction");

/// MPU6050 sensitivity at the ranges configured above. These are the numbers in
/// the MPU-6000 register map, not tuning knobs.
constexpr int32_t kAccelLsbPerG = 16384;   // AFS_SEL = +-4 g
constexpr int32_t kGyroLsbPerDps = 131;     // FS_SEL = +-500 deg/s

/// SW-420 contact debounce. The module is a vibration-sensitive microswitch and
/// chatters for milliseconds; 25 ms is long enough to reject it and short enough
/// that a real 1-3 s assertion is not eroded.
constexpr uint16_t kSw420DebounceMs = 25;

// ---------------------------------------------------------------------------
// Fusion weights — see detector.cpp for the justification of every number
// ---------------------------------------------------------------------------

namespace wt {
constexpr uint16_t kFreeFall = 260;  // 0.26  loss of contact, |a| < 0.3 g
constexpr uint16_t kZScore = 200;    // 0.20  accel surprise vs rolling baseline
constexpr uint16_t kSw420 = 150;     // 0.15  independent mechanical switch
constexpr uint16_t kGyro = 120;      // 0.12  rotation during the event
constexpr uint16_t kAbsMag = 110;    // 0.11  absolute severity
constexpr uint16_t kOrient = 100;    // 0.10  gravity-vector rotation
constexpr uint16_t kJerk = 60;       // 0.06  d|mag|/dt
constexpr uint16_t kSum = kFreeFall + kZScore + kSw420 + kGyro + kAbsMag + kOrient + kJerk;
static_assert(kSum == 1000, "fusion weights must sum to 1000 (= 1.000)");
}  // namespace wt

/// Trip / release hysteresis on the 0..100 fused score.
constexpr uint8_t kTripScore = 70;
constexpr uint8_t kReleaseScore = 45;

/// Normalisation knees. Each term is a clamped ramp from 0 at its "on" knee to 1
/// at its "full" knee, so the weights above are honest (each term can reach 1).
namespace knee {
constexpr int16_t kZOnMilli = 4000;    ///< 4.0 sigma
constexpr int16_t kZFullMilli = 12000;  ///< 12.0 sigma
/// The MPU is ranged +/-4 g on all three axes, so |a| tops out at
/// 4*sqrt(3) = 6.93 g. A "full" knee of 8 g would be unreachable and the term
/// could never score, which would silently redistribute its weight; 6 g is.
constexpr uint16_t kAbsFullMg = 6000;
/// Likewise the gyro is ranged +/-500 deg/s per axis (866 for a 3-axis vector).
constexpr int32_t kGyroFullDps10 = 6000;  ///< 600.0 deg/s
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
// CONFIRM / countdown defaults — docs/02-ble-protocol.md §6.4
// ---------------------------------------------------------------------------

constexpr uint16_t kCfgAccelThresholdMgDefault = 3000;
constexpr uint16_t kCfgAccelThresholdMgMin = 1500;
constexpr uint16_t kCfgAccelThresholdMgMax = 8000;
constexpr uint16_t kCfgGyroThresholdDpsDefault = 220;  // stored as 22.0 dps*10
constexpr uint16_t kCfgGyroThresholdDps10Min = 800;     // 80.0 dps
constexpr uint16_t kCfgGyroThresholdDps10Max = 8000;    // 800.0 dps
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
constexpr uint16_t kSosLongPressMs = 700;
/// Duration of the "detector tripped" beep pattern, and the CALIBRATE confirm
/// chirp, in milliseconds.
constexpr uint16_t kChirpMs = 90;
/// Red-LED flash cadence used to signal an undelivered event (docs §8 step 5).
constexpr uint16_t kQueuedEventBlinkMs = 120;
