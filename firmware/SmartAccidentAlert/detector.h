// detector.h — multi-signal accident fusion (docs/02-ble-protocol.md §8/§9 and
// PROJECT_PLAN.md §8/§9).
//
// DESIGN CONTRACT, and the reason this file is free of Arduino headers:
//   Detector::process(const Sample&, uint32_t nowMs) -> Decision
// performs no I/O, touches no globals, allocates nothing, and uses no floating
// point. A host test can therefore drive the real production algorithm with a
// synthetic crash, a pothole, a kerb strike, or a dropped device, and assert on
// the Decision — see tests/sensors/ for the driver.
//
// The algorithm is a weighted fusion of six normalised evidence terms, not a
// threshold comparison:
//
//   1. free-fall      |a| < 0.3 g sustained        weight 0.30
//   2. z-score        accel surprise vs 1 s baseline   0.23
//   3. SW-420         independent mechanical switch    0.17
//   4. |a|            absolute severity                0.13
//   5. orientation    gravity-vector rotation          0.11
//   6. jerk           d|a|/dt                           0.06
//
// Every term is derived from the ADXL345's three-axis acceleration, from the
// SW-420 switch, or from their agreement in time. There is no gyroscope in this
// design, because the sensor has none: rotation is observed only as a change in
// the direction of gravity, which is what term 5 measures. A previous revision
// carried a seventh, gyro-only term worth 0.12; its weight was redistributed
// across the six above so the trip threshold did not move. See config.h.
//
// The self-calibrating z-score is what makes the same firmware work on a city
// speed bump and on a national highway: a fixed 3 g threshold is either useless
// or trigger-happy depending on the vehicle and the road, while a 4-sigma test
// against the vehicle's own recent history does not care.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "config.h"

namespace saas {

/// Per-sample input. POD, fixed point, 40 bytes, trivially memcpy'd through a ring.
struct Sample {
  uint32_t tMs;            ///< ms since boot
  // Acceleration is UNFILTERED on purpose: the impact evidence path bypasses
  // the 5 Hz section, which would otherwise report 69% of a real 40 ms impact
  // peak and smear the 60 ms free-fall signature. The noise it lets through is
  // handled by the z-score below, which is the correct way to reject an outlier
  // in a noisy signal. See the two-path note in sensors.h.
  int32_t axMg, ayMg, azMg;  ///< raw ADXL345 acceleration, milli-g
  uint16_t magMg;          ///< raw |a|, milli-g
  int32_t jerkMgPerS;      ///< |d|a|/dt| over the last interval, mg/s
  /// Dead-reckoned speed in milli-km/h. 32 bits, not 16: a uint16_t tops out at
  /// 65.535 km/h, which silently wraps a motorway speed into "stopped" and makes
  /// the speed gate reject exactly the crashes it exists to catch.
  uint32_t speedMilliKmh;
  uint8_t flags;           ///< SampleFlag bitfield
};

/// SampleFlag bitfield. Distinct from proto::Flag, which is the *wire* bitfield.
enum SampleFlag : uint8_t {
  kSfFreeFall = 0x01,   ///< |a| below kFreeFallMg for kFreeFallMs
  kSfSw420 = 0x02,      ///< debounced SW-420 output is asserted
  kSfMoving = 0x04,     ///< dead-reckoned integrator is live (speed above noise)
  kSfSensorOk = 0x80,   ///< MPU present and the burst read succeeded
};

/// Detector's verdict for one sample.
struct Decision {
  uint8_t score;        ///< fused 0..100
  uint8_t tripped;      ///< 1 exactly on the sample the detector arms
  uint8_t released;     ///< 1 exactly on the sample it re-arms after a trip
  uint8_t blockedSpeed;      ///< trip suppressed by minSpeedKmh
  uint8_t blockedVibration;  ///< trip suppressed by vibrationRequired
  uint8_t freeFall;      ///< free-fall evidence present in the window
  uint8_t sw420;         ///< SW-420 evidence present in the window
  uint8_t sw420Hits;     ///< SW-420 rising edges in the last kSw420HitWindowMs
  uint8_t primed;        ///< 1 once the pre-impact window is full
  uint16_t magMg;        ///< peak |a| seen in the post window
  uint16_t peakAccMg;    ///< session peak |a|
  uint16_t orientDeg10;  ///< gravity rotation across the event, 0.1 degrees
  uint32_t speedMilliKmh;  ///< speed frozen just before the event
  uint16_t jerkMgPerS;    ///< window peak jerk
  int16_t zMilli;        ///< window peak z-score, milli-units
};

/// Runtime-tunable subset. Mirrors the CONFIG keys that affect detection; the
/// rest of CONFIG (telemetryHz, buzzer, led, mute, autoArm) lives in comm.h.
struct DetectorCfg {
  uint16_t accelThresholdMg = kCfgAccelThresholdMgDefault;
  bool vibrationRequired = kCfgVibrationRequiredDefault;
  uint16_t debounceMs = kCfgDebounceMsDefault;
  uint32_t minSpeedMilliKmh = kCfgMinSpeedMilliKmhDefault;
  uint16_t gainMilli = kCfgGainMilliDefault;  ///< 1000 = 1.0x
  bool armed = true;
};

/// Single-pass Welford accumulator over a fixed-size window. Fixed point Q8
/// (1/256 milli-g) so the per-update division is meaningful; the truncation
/// error is <= 1/256 mg per update and removals largely cancel it, which is two
/// orders of magnitude below the kMinSigmaMg floor.
class Welford {
 public:
  void clear() { *this = Welford(); }
  void add(int32_t x);      ///< x in Q8
  void remove(int32_t x);   ///< exact reverse of add()
  uint16_t n() const { return n_; }
  int32_t meanQ8() const { return meanQ8_; }
  /// Sample standard deviation in Q8.
  uint32_t sigmaQ8() const;

 private:
  int32_t sumQ16_ = 0;   ///< n * mean, kept so remove() can undo exactly
  int32_t meanQ8_ = 0;
  int64_t m2_ = 0;
  uint16_t n_ = 0;
};

/// Mean gravity vector over the pre-impact window, in milli-g. Integer running
/// sum with exact eviction, which is all the orientation term needs.
struct GravityMean {
  int64_t x = 0, y = 0, z = 0;
  uint16_t n = 0;

  void add(int32_t ax, int32_t ay, int32_t az) { x += ax; y += ay; z += az; n++; }
  void remove(int32_t ax, int32_t ay, int32_t az) { x -= ax; y -= ay; z -= az; n--; }
  void clear() { *this = GravityMean(); }
};

class Detector {
 public:
  Detector();

  /// The whole algorithm. Pure: no I/O, no globals, no allocation, no float.
  Decision process(const Sample& s, uint32_t nowMs);

  /// Replaces the run-time configuration (CONFIG message).
  void configure(const DetectorCfg& c) { cfg_ = c; }
  const DetectorCfg& config() const { return cfg_; }

  /// Clears the baseline and both windows. Called on boot, after CALIBRATE, and
  /// whenever the mount orientation could have changed.
  void reset();

  /// After a trip is resolved, suppress re-arming for `ms` so the post-crash
  /// settling cannot immediately raise a second alert.
  void setRefractory(uint32_t nowMs, uint32_t ms) { refractoryUntil_ = nowMs + ms; }
  void clearRefractory() { refractoryUntil_ = 0; }
  bool tripped() const { return tripped_; }
  /// Live fused score of the most recent sample, for telemetry/STATUS/UI.
  uint8_t lastScore() const { return lastScore_; }
  /// Speed of the most recent sample. Not the frozen pre-impact value, which is
  /// what Decision::speedMilliKmh carries.
  uint32_t lastSpeedMilliKmh() const { return lastSpeedMilliKmh_; }

  /// Session peak trackers, cleared by COMMAND RESET_STATS.
  void resetStats();
  uint16_t peakAccMg() const { return peakAccMg_; }
  uint8_t sw420Hits() const { return sw420Hits_; }

  /// Injects a calibration baseline (mean magnitude / mean gravity) captured by
  /// sensors::Calibration. Applied on the next process() call.
  void seedBaseline(int32_t meanMagQ8, int32_t gx, int32_t gy, int32_t gz);  // gravity vector, milli-g

 private:
  /// One entry of the rolling pre-impact window. `learnable` is stored per slot
  /// because it describes the sample that *occupies* the slot, not the one being
  /// pushed: evicting slot N must undo exactly what adding slot N did.
  struct PreEntry {
    int32_t magQ8;
    int32_t ax, ay, az;
    uint8_t learnable;
  };
  /// One entry of the post-impact evidence window.
  struct PostEntry {
    int32_t jerk;
    uint16_t magMg;
    uint8_t flags;
  };

  /// 0..1000 ramp between two knees, used to normalise each evidence term.
  static int32_t ramp(int32_t value, int32_t onKnee, int32_t fullKnee);
  /// Angle between two gravity vectors, in 0.1 degrees, via a 129-entry acos
  /// table indexed by the Q7 cosine. Integer, so no libm on the safety path.
  static int16_t angleDeg10(int64_t px, int64_t py, int64_t pz, int64_t qx,
                            int64_t qy, int64_t qz);
  void pushPre(const Sample& s);
  void pushPost(const Sample& s);
  /// Drops the frozen baseline and every window statistic, returning the detector
  /// to candidate-hunting.
  void unfreeze(uint32_t nowMs);

  DetectorCfg cfg_{};

  // --- rolling 1 s baseline ---------------------------------------------
  PreEntry pre_[kPreWindowN];
  uint8_t preHead_ = 0;   ///< next write slot
  uint8_t preCount_ = 0;  ///< valid entries, saturates at kPreWindowN
  Welford magStats_{};
  GravityMean gravMean_{};
  int32_t meanMagQ8_ = 0;
  uint32_t sigmaQ8_ = kMinSigmaMg * 256u;

  // --- post-impact evidence window -------------------------------------
  PostEntry post_[kPostWindowN];
  uint8_t postHead_ = 0;
  uint8_t postCount_ = 0;

  // --- event latch ------------------------------------------------------
  bool baselineFrozen_ = false;
  bool tripped_ = false;
  uint32_t aboveSince_ = 0;      ///< when the score last sustained kTripScore
  uint32_t candidateSince_ = 0;  ///< when the score first showed interest
  uint32_t refractoryUntil_ = 0;
  uint32_t lastNowMs_ = 0;

  // --- session statistics ----------------------------------------------
  uint16_t peakAccMg_ = 0;
  uint8_t sw420Hits_ = 0;
  uint8_t sw420Last_ = 0;      ///< debounced level from the previous sample
  uint32_t lastSw420Edge_ = 0;  ///< when a rising edge was counted
  uint32_t lastSw420High_ = 0;  ///< when the level was last asserted (hold window)

  // --- window statistics for the current verdict -------------------------
  uint16_t windowPeakMag_ = 0;
  uint16_t windowPeakJerk_ = 0;
  int16_t windowPeakZ_ = 0;
  uint8_t windowFreeFall_ = 0;
  uint8_t windowSw420_ = 0;
  uint32_t windowSpeedMilli_ = 0;
  /// Live mirrors of the most recent Decision, for telemetry/STATUS/UI, which
  /// must not have to keep the last Decision around themselves.
  uint8_t lastScore_ = 0;
  uint32_t lastSpeedMilliKmh_ = 0;
  uint16_t windowOrientDeg10_ = 0;
};

}  // namespace saas
