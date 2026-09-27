// sensors.h — MPU6050 acquisition, input conditioning, and the signals the
// detector consumes.
//
// Split of responsibilities, and why: the *signal chain* (filters, free-fall,
// jerk, dead-reckoned speed, Welford calibration) is pure fixed-point C++ with no
// Arduino header, so it can be driven and verified on a host exactly as the
// detector is. The *acquisition* layer (I2C, interrupts, millis) lives in
// sensors.cpp behind `#if defined(ARDUINO)`. That means the arithmetic that decides
// whether an ambulance is called can be unit-tested without a bus, an MPU, or a
// simulator.
//
// Signal chain, in order:
//
//   RAW --> |a| --------------------------------------------> detector (fast)
//    |                                                          |
//    +--> moving average (4) --> biquad LPF (5 Hz) --> gravity  |
//                                    |        tracker (1 s IIR) |
//   gyro --> moving average (2) ----------------------------> detector (fast)
//                                    |
//                            linear accel --> forward projection
//                                                    |
//                                            dead-reckoned speed (speed gate)
//
// TWO PATHS, AND WHY. The impact evidence is deliberately NOT filtered. A 5 Hz
// second-order section has roughly 30 ms of group delay, and measured against a
// realistic 40 ms / 5.9 g impact pulse it retains only 69% of the true peak
// (see the impulse test in the host suite). A crash that reads 4.2 g instead of
// 5.9 g still trips, but the reported `peakAccMg` would be wrong on the wire, and
// the 60 ms free-fall signature -- three samples at 50 Hz -- is smeared to the
// point where the 0.26-weighted free-fall term, the single strongest evidence in
// the whole design, becomes unreliable.
//
// So the impact path carries the raw reading and the *noise* is handled
// statistically instead: the detector's z-score compares the peak against a
// rolling mean and variance of the same unfiltered magnitude, which is the
// textbook way to detect an outlier in a noisy signal. Quantisation is not a
// concern at this scale anyway -- 1 LSB is 1000/16384 = 0.06 mg -- and the
// MPU's own 44 Hz DLPF is the anti-aliaser for its 1 kHz internal rate.
//
// The 5 Hz biquad earns its place on the *slow* path, where it does what a
// low-pass is actually good at: it isolates gravity. Orientation change, the
// dead-reckoned speed integrator, the OLED tilt readout, and the calibration
// baseline all need a clean DC vector, and there a 30 ms delay is irrelevant.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "config.h"
#include "detector.h"
#include "json.h"  // json::CalibSampleView, the CALIB_LOG wire record

namespace saas {

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

/// Second-order low-pass, RBJ cookbook, Q15 coefficients, transposed Direct
/// Form II. Per-axis state, so each instance is one channel.
class Biquad {
 public:
  /// 5 Hz cutoff at the 50 Hz detector rate, Q = 1/sqrt(2) (Butterworth).
  ///
  /// RBJ's cookbook coefficients are (1-cos w0)/2, 1-cos w0, (1-cos w0)/2 over
  /// -2cos w0, 1-alpha -- but with a0 = 1+alpha that leaves a DC gain of
  /// (b0+b1+b2)/(1+a1+a2) = -11.4 instead of 1, so every coefficient must be
  /// divided by a0. The numbers below are the a0-normalised values in Q15 and
  /// were verified against the closed-form response:
  ///
  ///     DC     0.99989  ( -0.0 dB)
  ///     2 Hz   0.98867  ( -0.1 dB)
  ///     5 Hz   0.70709  ( -3.0 dB)   <- the cutoff, by construction
  ///    10 Hz   0.19612  (-14.1 dB)   <- 12 dB/octave, as a 2nd-order section must
  ///    20 Hz   0.01116  (-39.0 dB)
  static void configure5Hz(Biquad& f) {
    f.b0_ = 2210;    // 0.06745527
    f.b1_ = 4421;    // 0.13491055
    f.b2_ = 2210;
    f.a1_ = -37453;  // -1.14298050
    f.a2_ = 13527;   // 0.41280160
  }
  void reset(int32_t seed = 0) { s1_ = 0; s2_ = 0; y_ = seed; }
  int32_t step(int32_t x) {
    // Transposed Direct Form II:
    //     y[n] = b0*x[n] + s1[n-1]
    //     s1[n] = b1*x[n] - a1*y[n] + s2[n-1]
    //     s2[n] = b2*x[n] - a2*y[n]
    //
    // Fixed-point convention: s1_/s2_ hold 2^15 * (the float state), so the
    // state updates carry NO shift -- shifting them would halve the feedback
    // every sample and the filter collapses to a bare b0 feedthrough. Only the
    // output needs the shift back down.
    //
    // The states are 64-bit because with a Q15 state convention a full-scale
    // 8 g input puts s1_ near 2^15 * 8000 = 2.6e8 and the intermediate
    // b1*x - a1*y near 3.3e8: comfortable in 32 bits, but only just, and a
    // filter that overflows is a filter that reports garbage acceleration.
    const int64_t y = (static_cast<int64_t>(b0_) * x + s1_) >> 15;
    s1_ = static_cast<int64_t>(b1_) * x - static_cast<int64_t>(a1_) * y + s2_;
    s2_ = static_cast<int64_t>(b2_) * x - static_cast<int64_t>(a2_) * y;
    y_ = static_cast<int32_t>(y);
    return y_;
  }
  int32_t value() const { return y_; }

 private:
  int32_t b0_ = 2210, b1_ = 4421, b2_ = 2210, a1_ = -37453, a2_ = 13527;
  int64_t s1_ = 0, s2_ = 0;
  int32_t y_ = 0;
};

/// Fixed-length boxcar average, templated on the tap count so each path can pick
/// its own: 4 taps on the slow accel path (80 ms), 2 on the gyro fast path.
/// `N` must be a power of two so the divide is a shift.
template <uint8_t N>
class MovingAverageN {
  static_assert(N >= 1 && (N & (N - 1)) == 0, "tap count must be a power of two");

 public:
  /// Seeded, not zeroed: a filter that starts at 0 reports a spurious 1 g step
  /// for its first N samples, and that step is itself an impact-shaped event.
  void reset(int32_t seed = 0) {
    for (uint8_t i = 0; i < N; i++) buf_[i] = seed;
    sum_ = seed * N;
    head_ = 0;
  }
  int32_t push(int32_t x) {
    sum_ -= buf_[head_];
    buf_[head_] = x;
    sum_ += x;
    head_ = static_cast<uint8_t>((head_ + 1) & (N - 1));
    return sum_ >> kMaShift;
  }
  int32_t value() const { return sum_ >> kMaShift; }

 private:
  static constexpr uint8_t kMaShift = (N == 1) ? 0 : static_cast<uint8_t>([] {
    uint8_t s = 0, n = N;
    while (n > 1) { n >>= 1; s++; }
    return s;
  }());
  int32_t buf_[N] = {0};
  int32_t sum_ = 0;
  uint8_t head_ = 0;
};

using MovingAverage = MovingAverageN<kMaTaps>;
/// The gyro fast path: 2 taps. The gyro DLPF is already 42 Hz, so this is only
/// there to reject single-sample outliers, and more taps would smear a 40 ms
/// rotation pulse that the orientation term depends on.
using GyroAverage = MovingAverageN<kGyroMaTaps>;

/// First-order IIR with a 1 s time constant, used to split the measured vector
/// into gravity and linear acceleration. Seeded with the first sample so a unit
/// bolted to a windscreen does not report 1 g of "linear" acceleration for the
/// first second after boot.
class GravityTracker {
 public:
  void reset(int32_t seed = 0) { gx_ = gy_ = gz_ = seed; seeded_ = (seed != 0); }
  void seed(int32_t ax, int32_t ay, int32_t az) {
    gx_ = ax; gy_ = ay; gz_ = az; seeded_ = true;
  }
  void step(int32_t ax, int32_t ay, int32_t az) {
    if (!seeded_) {
      seed(ax, ay, az);
      return;
    }
    gx_ += ((ax - gx_) * kGravityAlphaQ15) >> 15;
    gy_ += ((ay - gy_) * kGravityAlphaQ15) >> 15;
    gz_ += ((az - gz_) * kGravityAlphaQ15) >> 15;
  }
  int32_t gx() const { return gx_; }
  int32_t gy() const { return gy_; }
  int32_t gz() const { return gz_; }
  bool seeded() const { return seeded_; }

 private:
  int32_t gx_ = 0, gy_ = 0, gz_ = 0;
  bool seeded_ = false;
};

/// Plain (add/remove) Welford for the still-vehicle baseline. Accumulates the
/// mean magnitude and the mean gravity vector, which is all the detector needs to
/// seed itself; the variance is kept for the DIAG report.
class Calibrator {
 public:
  void reset() { *this = Calibrator(); }
  /// Gyro and SW-420 are part of the CALIB_LOG record (docs §6.8), so they are
  /// captured alongside the accel. Storing accel only would emit
  /// "gyr_x":0 for every sample, which looks like a working gyro that reads
  /// exactly zero -- the worst possible failure for a calibration log.
  void add(int32_t axMg, int32_t ayMg, int32_t azMg, int32_t gxDps10 = 0, int32_t gyDps10 = 0,
           int32_t gzDps10 = 0, bool sw420 = false);
  uint16_t count() const { return n_; }
  bool valid() const { return n_ >= kCalibMinSamples; }
  /// Mean |a| in milli-g, and the mean gravity vector.
  int32_t meanMagMg() const;
  int32_t meanGx() const { return gxSum_ / static_cast<int32_t>(n_ ? n_ : 1); }
  int32_t meanGy() const { return gySum_ / static_cast<int32_t>(n_ ? n_ : 1); }
  int32_t meanGz() const { return gzSum_ / static_cast<int32_t>(n_ ? n_ : 1); }
  /// Sample standard deviation of |a|, milli-g. Reported by DIAG.
  uint32_t sigmaMg() const;

  /// Sets how many raw samples are skipped between stored history taps, so a
  /// long calibration still fits the 48-record CALIB_LOG budget.
  void setDecimation(uint8_t every) { histEvery_ = (every < 1) ? 1 : every; }
  uint8_t decimation() const { return histEvery_; }
  /// Downsamples the collected taps into the CALIB_LOG wire records. Writes at
  /// most `maxOut` and returns how many were written. The records are already in
  /// the units the JSON carries (milli-g, 0.1 deg/s), so nothing is converted
  /// between here and the encoder.
  uint8_t drain(uint8_t maxOut, json::CalibSampleView* out) const {
    return drainFrom(0, maxOut, out);
  }
  /// As `drain`, but from an explicit index. CALIB_LOG has to be sent as
  /// several 512-byte frames and the wire has no cursor, so the sender walks the
  /// history with this.
  uint8_t drainFrom(uint16_t start, uint8_t maxOut, json::CalibSampleView* out) const;
  /// How many history taps exist.
  uint8_t historyCount() const { return histN_; }

 private:
  int32_t meanQ8_ = 0;
  int64_t m2_ = 0;
  int32_t gxSum_ = 0, gySum_ = 0, gzSum_ = 0;
  uint16_t n_ = 0;
  int32_t hist_[kCalibMaxSamples] = {0};  // raw |a| taps for the log
  int32_t histX_[kCalibMaxSamples] = {0};
  int32_t histY_[kCalibMaxSamples] = {0};
  int32_t histZ_[kCalibMaxSamples] = {0};
  int32_t histGx_[kCalibMaxSamples] = {0};
  int32_t histGy_[kCalibMaxSamples] = {0};
  int32_t histGz_[kCalibMaxSamples] = {0};
  uint8_t histSw_[kCalibMaxSamples] = {0};
  uint8_t histN_ = 0;
  uint8_t histEvery_ = 1;  ///< set by SensorPipeline::beginCalibration
};

/// Dead-reckoned speed, in milli-km/h. There is no GPS in this node, so the
/// speed gate integrates the forward component of linear acceleration and leaks
/// the result away when the vehicle is at rest. It is a *corroborating* signal
/// (>= 5 km/h says "this was a moving vehicle"), not an odometer: drift is
/// expected and is bounded by the leak and the rest detector.
class SpeedEstimator {
 public:
  void reset() { *this = SpeedEstimator(); }
  /// Fraction of the speed retained per 20 ms tick, as a Q15 *fraction*
  /// (32768 == 1.0). Deriving it from kSpeedLeakPpm keeps the ppm figure in
  /// config.h the single source of truth.
  static constexpr int32_t kLeakQ15 =
      32768 - static_cast<int32_t>((static_cast<int64_t>(kSpeedLeakPpm) * 32768) / 1000000);
  /// Derives the vehicle's forward axis from the measured gravity.
  ///
  /// Gravity alone gives "down" but not "forward" -- that would need a compass,
  /// and this node has none. The mount is therefore specified as "the MPU's X
  /// axis points forward" (see firmware/README.md), and all this does is remove
  /// the tilt component so the integrator does not mistake gravity for
  /// acceleration. The result is the X axis projected onto the horizontal plane
  /// and renormalised, which is correct for any mount within about 45 degrees of
  /// the specified orientation. If X is parallel to gravity (the unit is lying
  /// flat) it falls back to Y, so a flat mount degrades to "no speed estimate"
  /// rather than to nonsense.
  void configureForwardFromGravity(int32_t gxMg, int32_t gyMg, int32_t gzMg);
  void step(int32_t linAxMg, int32_t linAyMg, int32_t linAzMg, uint32_t dtMs);
  uint32_t milliKmh() const { return valid_ ? static_cast<uint32_t>((speedQ4_ + 8) >> 4) : 0u; }
  bool moving() const { return valid_ && restMs_ < kRestResetMs; }
  bool valid() const { return valid_; }
  void setInitialSpeed(uint32_t milliKmh) { speedQ4_ = static_cast<int32_t>(milliKmh) << 4; }

 private:
  int32_t fx_ = 0, fy_ = 0, fz_ = 0;  // Q15 unit vector, horizontal
  bool valid_ = false;
  int32_t speedQ4_ = 0;               // milli-km/h * 16
  uint32_t restMs_ = kRestResetMs + 1;
};

// ---------------------------------------------------------------------------
// SW-420
// ---------------------------------------------------------------------------

/// Debounced SW-420 reader. The module is a spring-loaded microswitch with a
/// vibration-sensitive contact, so it chatters. The pin drives an ISR that only
/// records an edge; the level is re-read and debounced here on the sample tick,
/// which keeps the ISR to a single store and avoids `delay()` in interrupt
/// context.
class Sw420 {
 public:
  void configure(bool activeHigh, uint32_t debounceMs);
  /// Called from the GPIO ISR. Must only touch a volatile.
  void onEdge(bool level) { lastLevel_ = level; pending_ = true; }
  /// Called on the 50 Hz tick. `rawLevel` is the level just read from the pin.
  bool update(bool rawLevel, uint32_t nowMs);
  bool level() const { return level_; }
  /// Rising edges that survived debouncing, for the STATUS diagnostic.
  uint8_t edges() const { return edges_; }
  void clearEdges() { edges_ = 0; }

 private:
  bool activeHigh_ = true;
  bool level_ = false;
  bool rawLevel_ = false;
  bool lastLevel_ = false;
  bool pending_ = false;
  uint32_t changedAt_ = 0;
  uint32_t debounceMs_ = 25;
  uint8_t edges_ = 0;
};

// ---------------------------------------------------------------------------
// The pipeline
// ---------------------------------------------------------------------------

/// Post-acquisition, pre-filter readings, in physical units. The acquisition task
/// fills one of these per tick; the pipeline owns everything downstream. Keeping
/// the boundary here means the SW-420 pin and the MPU burst read are the only
/// hardware-aware code, and the whole signal chain below is host-testable.
struct RawSample {
  int32_t axMg, ayMg, azMg;      ///< raw MPU6050 accel, milli-g
  int32_t gxDps10, gyDps10, gzDps10;  ///< raw MPU6050 gyro, 0.1 deg/s
  bool sensorOk;                 ///< MPU present and the burst read succeeded
  bool sw420Raw;                 ///< level at the SW-420 pin, unpolarised
};


/// Turns a RawSample into a detector::Sample. Owns every filter in the chain, so
/// there is exactly one place where a raw reading becomes a decision input.
class SensorPipeline {
 public:
  void reset();
  /// Attach the SW-420 pin interrupt. The Sw420 lives inside the pipeline (the
  /// ISR needs a stable address), so the pipeline attaches it rather than
  /// exposing the member.
  void attachInterrupts();
  /// Seeds the filters from a first reading, so the first second of telemetry is
  /// not a ramp from zero. Call immediately after `begin()`.
  void prime(int32_t axMg, int32_t ayMg, int32_t azMg, int32_t gxDps10, int32_t gyDps10,
             int32_t gzDps10);

  /// One tick. Returns false when the sample must be dropped (sensor fault), in
  /// which case `out` still gets a timestamp and the SW-420 level but carries
  /// kSfSensorOk clear, so the detector knows the difference between "quiet" and
  /// "not listening" instead of scoring a fault as calm.
  bool step(uint32_t nowMs, const RawSample& in, Sample& out);

  /// Raw counts -> physical units, using kMpuAccelRangeG / kMpuGyroRangeDps.
  static int32_t accelMg(int16_t raw);
  static int32_t gyroDps10(int16_t raw);

  // --- calibration ------------------------------------------------------
  void beginCalibration(uint32_t nowMs, uint16_t durationMs);
  /// True once the requested duration has elapsed.
  bool calibrationDone(uint32_t nowMs) const;
  bool calibrating() const { return calibrating_; }
  Calibrator& calibration() { return calib_; }
  /// Applies the completed baseline to the filters and the speed estimator, and
  /// leaves the pipeline in a known state. Must be called after a calibration
  /// ends or the detector is re-seeded.
  void applyCalibration();

  // --- accessors --------------------------------------------------------
  /// True once the pipeline has produced at least one valid sample.
  bool primed() const { return primed_; }
  bool sensorOk() const { return sensorOk_; }
  /// Number of consecutive samples currently below kFreeFallMg.
  uint16_t freeFallRun() const { return ffRun_; }
  /// True while the latched free-fall condition holds.
  bool freeFallLatched() const { return ffLatched_ != 0; }
  bool sw420Level() const { return swLevel_ != 0; }
  uint8_t sw420Edges() const { return sw_.edges(); }
  void clearSw420Edges() { sw_.clearEdges(); }

  // --- telemetry / STATUS / OLED ---------------------------------------
  int32_t gravityX() const { return grav_.gx(); }
  int32_t gravityY() const { return grav_.gy(); }
  int32_t gravityZ() const { return grav_.gz(); }
  uint32_t speedMilliKmh() const { return speed_.milliKmh(); }
  bool speedValid() const { return speedValid_; }

 private:
  // Slow path: feeds the gravity tracker, the speed integrator, the display, and
  // the calibration baseline.
  MovingAverage maAx_, maAy_, maAz_;
  Biquad lpAx_, lpAy_, lpAz_;
  GyroAverage maGx_, maGy_, maGz_;
  GravityTracker grav_;
  SpeedEstimator speed_;
  Sw420 sw_;
  Calibrator calib_;
  int32_t lastMagMg_ = 0;
  int32_t lastFastMag_ = 0;
  uint16_t ffRun_ = 0;      ///< consecutive samples below kFreeFallMg
  uint16_t ffOffRun_ = 0;   ///< consecutive samples above it (hysteresis)
  bool ffLatched_ = false;  ///< see the note in step()
  uint8_t swLevel_ = 0;
  bool sensorOk_ = true;
  bool speedValid_ = false;
  uint32_t calibStartMs_ = 0;
  uint16_t calibDurationMs_ = 0;
  bool calibrating_ = false;
  bool primed_ = false;
};

// ---------------------------------------------------------------------------
// MPU6050 over I2C (ESP32 / Arduino only)
// ---------------------------------------------------------------------------

/// Minimal MPU6050 driver: no interrupts, no DMP, no FIFO. One 14-byte burst read
/// per tick keeps the accel/gyro pairs in the same instant, which matters more
/// than it sounds -- reading them in two transactions can mix samples 400 us
/// apart and fabricate angular rate that does not exist.
class Mpu6050 {
 public:
  bool begin(uint8_t addr = kMpuAddr);
  bool present() const { return present_; }
  uint8_t address() const { return addr_; }
  uint8_t whoAmI() const { return who_; }
  /// Raw accel/gyro burst. Returns false on an I2C error.
  bool read(int16_t& ax, int16_t& ay, int16_t& az, int16_t& gx, int16_t& gy, int16_t& gz);
  void setRanges(int8_t accelG, int16_t gyroDps);
  uint32_t errorCount() const { return errors_; }

 private:
  bool writeReg(uint8_t reg, uint8_t val);
  bool readRegs(uint8_t reg, uint8_t* buf, size_t n);
  uint8_t addr_ = kMpuAddr;
  uint8_t who_ = 0;
  bool present_ = false;
  uint32_t errors_ = 0;
};

/// Registers the ISR that latches SW-420 edges. The handler only stores a level
/// and a flag -- all debouncing happens on the sample tick, because
/// millis()/delay() are not safe in an ISR on ESP32 and a 250 ms block in an
/// ISR handler would stall the BLE stack.
void attachSw420Interrupt(Sw420& sw);

/// Battery divider -> millivolts, with the ESP32's 11 dB/12-bit ADC attenuation
/// and a 2:1 divider correction. Pure, so it is host-testable.
uint16_t batteryMilliVolts(uint16_t adcRaw);
/// Li-ion curve, 0..100 %. Pure, so it is host-testable.
uint8_t batteryPercent(uint16_t milliVolts);

}  // namespace saas
