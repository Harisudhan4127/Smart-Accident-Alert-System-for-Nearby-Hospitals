// sensors.cpp — see sensors.h.
//
// The signal chain (top half) is pure fixed-point C++ and is compiled on the
// host. The acquisition layer (bottom) is compiled only for Arduino/ESP32, which
// keeps Wire, millis() and attachInterrupt out of the arithmetic that decides
// whether an ambulance is dispatched.
#include "sensors.h"

#if defined(ARDUINO)
// File scope, not inside namespace saas: these bring in millis(), pinMode(),
// Wire and IRAM_ATTR, all of which the acquisition layer below needs.
#include <Arduino.h>
#include <Wire.h>
#endif

namespace saas {
namespace {

uint32_t isqrt64(uint64_t v) {
  if (v == 0) return 0;
  uint64_t x = v;
  uint64_t y = (x + 1) >> 1;
  while (y < x) {
    x = y;
    y = (x + v / x) >> 1;
  }
  return static_cast<uint32_t>(x);
}

int32_t mag3i(int32_t x, int32_t y, int32_t z) {
  return static_cast<int32_t>(isqrt64(static_cast<uint64_t>(x * x + y * y + z * z)));
}

int32_t clampi(int32_t v, int32_t lo, int32_t hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

}  // namespace

// ---------------------------------------------------------------------------
// Calibrator
// ---------------------------------------------------------------------------

void Calibrator::add(int32_t axMg, int32_t ayMg, int32_t azMg, int32_t gxDps10, int32_t gyDps10,
                     int32_t gzDps10, bool sw420) {
  const int32_t mag = mag3i(axMg, ayMg, azMg);
  const int32_t x = mag << 8;  // Q8, matching the detector's scale
  if (n_ == 0) {
    meanQ8_ = x;
    n_ = 1;
  } else {
    n_++;
    const int32_t d = x - meanQ8_;
    meanQ8_ += d / static_cast<int32_t>(n_);
    m2_ += static_cast<int64_t>(d) * (x - meanQ8_);
    if (m2_ < 0) m2_ = 0;
  }
  gxSum_ += axMg;
  gySum_ += ayMg;
  gzSum_ += azMg;

  // Store a decimated history for CALIB_LOG. kCalibMaxSamples is 48 and a 5 s
  // calibration at 50 Hz is 250 samples, so keep every 5th.
  if (histN_ < kCalibMaxSamples) {
    if ((n_ % histEvery_) == 0 || histN_ == 0) {
      hist_[histN_] = mag;
      histX_[histN_] = axMg;
      histY_[histN_] = ayMg;
      histZ_[histN_] = azMg;
      histN_++;
    }
  }
}

int32_t Calibrator::meanMagMg() const {
  return n_ ? (meanQ8_ >> 8) : 0;
}

uint32_t Calibrator::sigmaMg() const {
  if (n_ < 2) return 0;
  return isqrt64(static_cast<uint64_t>(m2_ / (n_ - 1))) >> 8;
}

uint8_t Calibrator::drainFrom(uint16_t start, uint8_t maxOut, json::CalibSampleView* out) const {
  if (start >= histN_ || !out) return 0;
  const uint8_t avail = static_cast<uint8_t>(histN_ - start);
  const uint8_t n = (avail < maxOut) ? avail : maxOut;
  for (uint8_t i = 0; i < n; i++) {
    const uint8_t k = static_cast<uint8_t>(start + i);
    out[i].tMs = static_cast<uint32_t>(k) * kSensorPeriodMs * histEvery_;
    out[i].accX = static_cast<int16_t>(clampi(histX_[k], -32768, 32767));
    out[i].accY = static_cast<int16_t>(clampi(histY_[k], -32768, 32767));
    out[i].accZ = static_cast<int16_t>(clampi(histZ_[k], -32768, 32767));
    out[i].gyrX = static_cast<int16_t>(clampi(histGx_[k], -32768, 32767));
    out[i].gyrY = static_cast<int16_t>(clampi(histGy_[k], -32768, 32767));
    out[i].gyrZ = static_cast<int16_t>(clampi(histGz_[k], -32768, 32767));
    out[i].sw420 = histSw_[k] != 0;
  }
  return n;
}

// ---------------------------------------------------------------------------
// SpeedEstimator
// ---------------------------------------------------------------------------

void SpeedEstimator::configureForwardFromGravity(int32_t gxMg, int32_t gyMg, int32_t gzMg) {
  const int64_t n2 = static_cast<int64_t>(gxMg) * gxMg + static_cast<int64_t>(gyMg) * gyMg +
                     static_cast<int64_t>(gzMg) * gzMg;
  const int64_t n = isqrt64(static_cast<uint64_t>(n2));
  if (n == 0) {
    valid_ = false;
    return;
  }
  // Unit gravity, Q15. The accelerometer reads the *reaction* to gravity, so this
  // points along +g (towards the ceiling in a level mount), but only the
  // direction matters here.
  const int64_t ux = (static_cast<int64_t>(gxMg) << 15) / n;
  const int64_t uy = (static_cast<int64_t>(gyMg) << 15) / n;
  const int64_t uz = (static_cast<int64_t>(gzMg) << 15) / n;

  // p = e_x - (e_x . u) u  with e_x = (1,0,0), i.e. e_x . u == ux.
  int64_t p0 = 32768 - ((ux * ux) >> 15);
  int64_t p1 = -((ux * uy) >> 15);
  int64_t p2 = -((ux * uz) >> 15);
  int64_t pn2 = p0 * p0 + p1 * p1 + p2 * p2;
  int64_t pn = isqrt64(static_cast<uint64_t>(pn2));
  if (pn < 2048) {
    // X is (almost) parallel to gravity: the unit is lying flat. Fall back to Y,
    // which is then guaranteed to be in the horizontal plane.
    p0 = -((uy * ux) >> 15);
    p1 = 32768 - ((uy * uy) >> 15);
    p2 = -((uy * uz) >> 15);
    pn2 = p0 * p0 + p1 * p1 + p2 * p2;
    pn = isqrt64(static_cast<uint64_t>(pn2));
  }
  if (pn < 512) {
    // Degenerate: |g| itself is ~0, the sensor is not reporting.
    valid_ = false;
    return;
  }
  fx_ = static_cast<int32_t>((p0 << 15) / pn);
  fy_ = static_cast<int32_t>((p1 << 15) / pn);
  fz_ = static_cast<int32_t>((p2 << 15) / pn);
  valid_ = true;
}

void SpeedEstimator::step(int32_t linAxMg, int32_t linAyMg, int32_t linAzMg, uint32_t dtMs) {
  if (!valid_) return;
  // Forward component of linear acceleration, milli-g, Q15 arithmetic.
  const int64_t aF = (static_cast<int64_t>(linAxMg) * fx_ + static_cast<int64_t>(linAyMg) * fy_ +
                      static_cast<int64_t>(linAzMg) * fz_) >>
                     15;
  // 1 mg of forward acceleration over one 20 ms tick is 0.706 milli-km/h, i.e.
  // 11.297 Q4 units (Q4 = milli-km/h x 16, so the truncation cannot bias a slow
  // integration to zero). kSpeedQ4PerMgPerTick is x1000 to keep the tick-rate
  // term exact for any dtMs.
  const int64_t dvQ4 = aF * static_cast<int64_t>(kSpeedQ4PerMgPerTick) * dtMs /
                       (static_cast<int64_t>(kSensorPeriodMs) * 1000);
  speedQ4_ = static_cast<int32_t>(clampi(static_cast<int32_t>(speedQ4_ + dvQ4), -3200000, 3200000));

  // Rest detection. A real crash ends with the vehicle at a standstill, so this
  // is also what stops a dead-reckoned speed from staying high after impact.
  const int32_t linMag = mag3i(linAxMg, linAyMg, linAzMg);
  if (linMag < kRestAccelMg) {
    restMs_ += dtMs;
    if (restMs_ >= kRestResetMs) speedQ4_ = 0;
  } else {
    restMs_ = 0;
  }
  if (restMs_ < kRestResetMs) {
    // Leak so drift cannot accumulate forever while coasting downhill.
    speedQ4_ = static_cast<int32_t>((static_cast<int64_t>(speedQ4_) * kLeakQ15) >> 15);
  }
  if (speedQ4_ < 0) speedQ4_ = 0;
  if (static_cast<uint32_t>(speedQ4_) / 16 > kSpeedMaxMilliKmh) speedQ4_ = static_cast<int32_t>(kSpeedMaxMilliKmh) << 4;
}

// ---------------------------------------------------------------------------
// Sw420
// ---------------------------------------------------------------------------

void Sw420::configure(bool activeHigh, uint32_t debounceMs) {
  activeHigh_ = activeHigh;
  debounceMs_ = debounceMs;
  level_ = rawLevel_ = lastLevel_ = false;
  pending_ = false;
  changedAt_ = 0;
}

bool Sw420::update(bool rawLevel, uint32_t nowMs) {
  const bool asserted = activeHigh_ ? rawLevel : !rawLevel;
  rawLevel_ = rawLevel;
  if (pending_) {
    pending_ = false;
    // The ISR saw a transition; the level must agree for the whole debounce
    // window before it is believed.
    changedAt_ = nowMs;
    return level_;
  }
  if (asserted != level_) {
    if (nowMs - changedAt_ >= debounceMs_) {
      level_ = asserted;
      changedAt_ = nowMs;
      if (level_ && edges_ < 255) edges_++;
    }
  }
  return level_;
}

// ---------------------------------------------------------------------------
// SensorPipeline
// ---------------------------------------------------------------------------

void SensorPipeline::reset() {
  maAx_.reset(); maAy_.reset(); maAz_.reset();
  maGx_.reset(); maGy_.reset(); maGz_.reset();
  lpAx_.reset(); lpAy_.reset(); lpAz_.reset();
  grav_.reset();
  speed_.reset();
  sw_.configure(kSw420ActiveHigh, kSw420DebounceMs);
  calib_.reset();
  lastMagMg_ = 0;
  lastFastMag_ = 0;
  ffRun_ = 0;
  ffOffRun_ = 0;
  ffLatched_ = false;
  swLevel_ = 0;
  sensorOk_ = true;
  speedValid_ = false;
  calibrating_ = false;
  primed_ = false;
}

void SensorPipeline::prime(int32_t axMg, int32_t ayMg, int32_t azMg, int32_t gxDps10,
                           int32_t gyDps10, int32_t gzDps10) {
  maAx_.reset(axMg); maAy_.reset(ayMg); maAz_.reset(azMg);
  maGx_.reset(gxDps10); maGy_.reset(gyDps10); maGz_.reset(gzDps10);
  Biquad::configure5Hz(lpAx_); lpAx_.reset(axMg);
  Biquad::configure5Hz(lpAy_); lpAy_.reset(ayMg);
  Biquad::configure5Hz(lpAz_); lpAz_.reset(azMg);
  grav_.seed(axMg, ayMg, azMg);
  lastMagMg_ = mag3i(axMg, ayMg, azMg);
  lastFastMag_ = lastMagMg_;
  primed_ = true;
}

int32_t SensorPipeline::accelMg(int16_t raw) {
  return (static_cast<int32_t>(raw) * 1000) / kAccelLsbPerG;
}

int32_t SensorPipeline::gyroDps10(int16_t raw) {
  return (static_cast<int32_t>(raw) * 10000) / kGyroLsbPerDps;
}

void SensorPipeline::beginCalibration(uint32_t nowMs, uint16_t durationMs) {
  calib_.reset();
  // Decimate the stored history so a 5 s / 250-sample calibration still fits the
  // 48-record CALIB_LOG budget.
  const uint32_t total = static_cast<uint32_t>(durationMs) / kSensorPeriodMs + 1;
  calib_.setDecimation(
      static_cast<uint8_t>(total / kCalibMaxSamples + 1));
  calibrating_ = true;
  calibDurationMs_ = durationMs;
  calibStartMs_ = nowMs;
}

bool SensorPipeline::calibrationDone(uint32_t nowMs) const {
  return calibrating_ && (nowMs - calibStartMs_) >= calibDurationMs_;
}

void SensorPipeline::applyCalibration() {
  calibrating_ = false;
  const int32_t gx = calib_.meanGx(), gy = calib_.meanGy(), gz = calib_.meanGz();
  grav_.seed(gx, gy, gz);
  speed_.configureForwardFromGravity(gx, gy, gz);
  speedValid_ = speed_.valid();
}

bool SensorPipeline::step(uint32_t nowMs, const RawSample& in, Sample& out) {
  // --- SW-420, debounced on the sample tick -----------------------------
  const bool sw = sw_.update(in.sw420Raw, nowMs);
  swLevel_ = sw ? 1u : 0u;
  sensorOk_ = in.sensorOk;

  out = Sample{};
  out.tMs = nowMs;
  if (sw) out.flags |= kSfSw420;

  if (!in.sensorOk) {
    // A fault is not a quiet vehicle. Report the fault with kSfSensorOk clear so
    // the detector refuses to score (primed == 0) and STATUS can raise the red
    // LED, instead of a dead MPU looking like a smooth drive.
    ffRun_ = 0;
    ffOffRun_ = 0;
    ffLatched_ = false;
    return false;
  }
  out.flags |= kSfSensorOk;

  if (!primed_) prime(in.axMg, in.ayMg, in.azMg, in.gxDps10, in.gyDps10, in.gzDps10);

  // --- fast path: the impact evidence, unfiltered ------------------------
  // raw mag for |a|, free fall, jerk, the z-score, and the orientation vector.
  const int32_t fax = in.axMg, fay = in.ayMg, faz = in.azMg;
  const int32_t gx = maGx_.push(in.gxDps10);
  const int32_t gy = maGy_.push(in.gyDps10);
  const int32_t gz = maGz_.push(in.gzDps10);
  const int32_t mag = mag3i(fax, fay, faz);

  // Free fall: sustained |a| below 0.3 g. Counted, not instantaneous, because a
  // single 20 ms dip also occurs when the vehicle drops off a bump. This must
  // run on the unfiltered magnitude -- a 5 Hz section smears the 60 ms window
  // into something that never quite reaches three consecutive samples.
  //
  // LATCHED, not an edge. The condition "|a| has been below 0.3 g for at least
  // 60 ms" is a state, and the flag stays asserted for the whole low-g episode
  // (until |a| has been high again for 60 ms). Firing it on the single sample
  // where the threshold is first crossed would make the duration bookkeeping
  // disagree with the detector, which independently re-counts flagged samples in
  // its post window: an un-latched flag satisfies the 60 ms rule once, and the
  // detector's "3 flagged samples" test would then never be met.
  if (mag < kFreeFallMg) {
    if (ffRun_ < 0xFFFF) ffRun_++;
    ffOffRun_ = 0;
  } else {
    ffRun_ = 0;
    if (ffOffRun_ < 0xFFFF) ffOffRun_++;
  }
  if (ffRun_ * kSensorPeriodMs >= kFreeFallMs) ffLatched_ = true;
  if (ffLatched_ && ffOffRun_ * kSensorPeriodMs >= kFreeFallMs) ffLatched_ = false;
  if (ffLatched_) out.flags |= kSfFreeFall;

  const int32_t jerk = ((mag - lastFastMag_) * 1000) / kSensorPeriodMs;
  lastFastMag_ = mag;

  // --- slow path: gravity, speed, display, calibration baseline ----------
  const int32_t sax = lpAx_.step(maAx_.push(in.axMg));
  const int32_t say = lpAy_.step(maAy_.push(in.ayMg));
  const int32_t saz = lpAz_.step(maAz_.push(in.azMg));
  grav_.step(sax, say, saz);
  const int32_t lax = sax - grav_.gx();
  const int32_t lay = say - grav_.gy();
  const int32_t laz = saz - grav_.gz();
  speed_.step(lax, lay, laz, kSensorPeriodMs);
  lastMagMg_ = mag3i(sax, say, saz);

  if (speed_.moving()) out.flags |= kSfMoving;

  out.axMg = fax;
  out.ayMg = fay;
  out.azMg = faz;
  out.gxDps10 = gx;
  out.gyDps10 = gy;
  out.gzDps10 = gz;
  out.magMg = static_cast<uint16_t>(clampi(mag, 0, 65535));
  out.jerkMgPerS = jerk;
  out.speedMilliKmh = speed_.milliKmh();

  // --- calibration tap ---------------------------------------------------
  if (calibrating_ && calib_.count() < kCalibMaxSamples * 4) {
    // The SLOW-path accel: the calibration baseline must be the same filtered
    // signal the gravity tracker and speed integrator see, or the baseline the
    // app plots is not the one the firmware uses.
    calib_.add(sax, say, saz, gx, gy, gz, swLevel_ != 0);
  }

  return true;
}

// ---------------------------------------------------------------------------
// Battery (pure, host-testable)
// ---------------------------------------------------------------------------

uint16_t batteryMilliVolts(uint16_t adcRaw) {
  // ESP32 default 11 dB attenuation: 0..3100 mV over 4095 counts, ~0.757 mV/count.
  // The divider halves the cell voltage, so multiply by kBatteryDividerNum/Den.
  const uint32_t pinMv = (static_cast<uint32_t>(adcRaw) * 3100u) / 4095u;
  const uint32_t cellMv = (pinMv * kBatteryDividerNum) / kBatteryDividerDen;
  return static_cast<uint16_t>(cellMv > 65535u ? 65535u : cellMv);
}

uint8_t batteryPercent(uint16_t milliVolts) {
  // Piecewise-linear Li-ion discharge curve. The knees below are the usual
  // points from a 18650 load test; between them the curve is close enough to
  // linear that a table lookup with interpolation is indistinguishable from a
  // curve fit, and it costs 9 comparisons.
  static const uint16_t kMv[] = {3300, 3600, 3700, 3800, 3950, 4050, 4200, 4300, 4400};
  static const uint8_t kPct[] = {0, 10, 20, 40, 60, 75, 88, 95, 100};
  if (milliVolts <= kMv[0]) return 0;
  const uint8_t n = static_cast<uint8_t>(sizeof(kMv) / sizeof(kMv[0]));
  if (milliVolts >= kMv[n - 1]) return 100;
  for (uint8_t i = 1; i < n; i++) {
    if (milliVolts < kMv[i]) {
      const uint32_t span = kMv[i] - kMv[i - 1];
      const uint32_t into = milliVolts - kMv[i - 1];
      const uint32_t pct = kPct[i - 1] + (into * (kPct[i] - kPct[i - 1])) / span;
      return static_cast<uint8_t>(pct > 100 ? 100 : pct);
    }
  }
  return 100;
}

// ---------------------------------------------------------------------------
// Acquisition layer -- Arduino/ESP32 only
// ---------------------------------------------------------------------------
#if defined(ARDUINO)

namespace {
Sw420* volatile gSw = nullptr;
volatile bool gSwLevel = false;

/// Both edges, so the level is always current no matter which way the module is
/// wired. The handler does one store and nothing else.
IRAM_ATTR void sw420Isr() {
  if (gSw != nullptr) gSw->onEdge(gSwLevel);
}
}  // namespace

void attachSw420Interrupt(Sw420& sw) {
  pinMode(kPinSw420, kSw420ActiveHigh ? INPUT_PULLDOWN : INPUT_PULLUP);
  gSw = &sw;
  gSwLevel = (digitalRead(kPinSw420) == HIGH);
  attachInterrupt(digitalPinToInterrupt(kPinSw420), sw420Isr, CHANGE);
}

void SensorPipeline::attachInterrupts() { attachSw420Interrupt(sw_); }

bool Mpu6050::writeReg(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(addr_);
  Wire.write(reg);
  Wire.write(val);
  if (Wire.endTransmission() != 0) {
    errors_++;
    return false;
  }
  return true;
}

bool Mpu6050::readRegs(uint8_t reg, uint8_t* buf, size_t n) {
  Wire.beginTransmission(addr_);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {  // repeated start
    errors_++;
    return false;
  }
  const size_t got = Wire.requestFrom(addr_, static_cast<uint8_t>(n), static_cast<uint8_t>(n));
  if (got != n) {
    errors_++;
    return false;
  }
  for (size_t i = 0; i < n; i++) buf[i] = static_cast<uint8_t>(Wire.read());
  return true;
}

bool Mpu6050::begin(uint8_t addr) {
  addr_ = addr;
  present_ = false;
  uint8_t id = 0;
  if (!readRegs(0x75, &id, 1)) return false;
  // 0x68/0x69/0x70/0x71/0x73 are all MPU-6050 (the 0x69 and 0x73 parts are the
  // same die with a different AD0 strap). Rejecting the wrong id here means a
  // floating bus cannot masquerade as a working sensor.
  const bool ok = (id == 0x68 || id == 0x69 || id == 0x70 || id == 0x71 || id == 0x73);
  if (!ok) return false;
  who_ = id;
  present_ = true;
  setRanges(kMpuAccelRangeG, kMpuGyroRangeDps);
  writeReg(0x6A, 0x00);  // USER_CTRL: disable FIFO and I2C master
  writeReg(0x6B, 0x01);  // PWR_MGMT_1: wake, PLL with X gyro as the clock reference
  vTaskDelay(2);        // the datasheet asks for 100 ms after a reset; the part
                        // is already running, this is just settling time.
  return true;
}

void Mpu6050::setRanges(int8_t accelG, int16_t gyroDps) {
  uint8_t a = 0x00;
  if (accelG == 2) a = 0x08;
  else if (accelG == 4) a = 0x10;
  else if (accelG == 8) a = 0x18;
  writeReg(0x1B, a);
  uint8_t g = 0x00;
  if (gyroDps == 250) g = 0x08;
  else if (gyroDps == 500) g = 0x10;
  else if (gyroDps == 1000) g = 0x18;
  else if (gyroDps == 2000) g = 0x20;
  writeReg(0x1C, g);
  writeReg(0x1A, kMpuDlpf);
}

bool Mpu6050::read(int16_t& ax, int16_t& ay, int16_t& az, int16_t& gx, int16_t& gy, int16_t& gz) {
  uint8_t b[14];
  // One burst from ACCEL_XOUT_H so all six axes are the same instant. Two
  // transactions 400 us apart can fabricate angular rate that never happened.
  if (!readRegs(0x3B, b, sizeof(b))) return false;
  auto be16 = [&](int i) -> int16_t {
    return static_cast<int16_t>((static_cast<uint16_t>(b[i]) << 8) | b[i + 1]);
  };
  ax = be16(0);
  ay = be16(2);
  az = be16(4);
  gx = be16(8);
  gy = be16(10);
  gz = be16(12);
  return true;
}

#endif  // ARDUINO

}  // namespace saas

#if !defined(ARDUINO)
// Host build: no pin, so no interrupt to attach. Declared here rather than in the
// header because it only exists to keep the Arduino call site compiling.
namespace saas {
void SensorPipeline::attachInterrupts() {}
}  // namespace saas
#endif
