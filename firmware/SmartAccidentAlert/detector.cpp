// detector.cpp — see detector.h.
//
// Everything here is integer. The protocol's telemetry is fixed point, the
// ESP32 has no FPU worth using at 50 Hz, and `-ffast-math` on a safety path is
// not a risk worth taking. The only non-obvious tool is a 129-entry acos table
// (kAcosDeg10) that turns a Q15 cosine into 0.1-degree units.
#include "detector.h"

#ifdef SAAS_DETECTOR_TRACE
#include <stdio.h>
#define DET_TRACE(...) printf(__VA_ARGS__)
#else
#define DET_TRACE(...) ((void)0)
#endif

namespace saas {
namespace {

constexpr int32_t kQ8 = 256;  ///< fixed-point scale for magnitude statistics

/// acos() of cos = (i-64)/64, in 0.1 degrees, i = 0..128. Index i is the cosine
/// in Q6 (+-1 maps to 0/128) biased by +64. Resolution is 1/64 in cosine, which
/// is ~1.1 degrees of arc near the middle -- ample for a telemetry field.
constexpr uint16_t kAcosDeg10[129] = {
        1800,  1699,  1656,  1624,  1596,  1572,  1550,  1530,
        1510,  1492,  1475,  1459,  1443,  1428,  1414,  1400,
        1386,  1373,  1360,  1347,  1334,  1322,  1310,  1298,
        1287,  1275,  1264,  1253,  1242,  1232,  1221,  1210,
        1200,  1190,  1180,  1169,  1159,  1150,  1140,  1130,
        1120,  1111,  1101,  1092,  1082,  1073,  1063,  1054,
        1045,  1036,  1026,  1017,  1008,   999,   990,   981,
         972,   963,   954,   945,   936,   927,   918,   909,
         900,   891,   882,   873,   864,   855,   846,   837,
         828,   819,   810,   801,   792,   783,   774,   764,
         755,   746,   737,   727,   718,   708,   699,   689,
         680,   670,   660,   650,   641,   631,   620,   610,
         600,   590,   579,   568,   558,   547,   536,   525,
         513,   502,   490,   478,   466,   453,   440,   427,
         414,   400,   386,   372,   357,   341,   325,   308,
         290,   270,   250,   228,   204,   176,   144,   101,
           0,
};

/// Integer square root (Newton). Used for the Welford sigma and for vector
/// magnitudes such as |a| and the gravity-vector length.
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

int32_t clamp32(int32_t v, int32_t lo, int32_t hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

/// Magnitude of a 3-axis Q15-ish integer vector, in the vector's own units.
int32_t mag3(int32_t x, int32_t y, int32_t z) {
  return static_cast<int32_t>(isqrt64(static_cast<uint64_t>(x * x + y * y + z * z)));
}

}  // namespace

// ---------------------------------------------------------------------------
// Welford (add/remove form)
// ---------------------------------------------------------------------------
//
// The rolling baseline is a sliding window, so the textbook add-only Welford
// cannot be used: removing the oldest sample needs the paired inverse update.
// This form is O(1) per sample, keeps the numerically-stable update, and stays
// in Q8 so the per-update division still carries information (a raw Q0 update
// would round every change below 1 mg to nothing and pin sigma to zero).

void Welford::add(int32_t x) {
  if (n_ == 0) {
    meanQ8_ = x;
    n_ = 1;
    return;
  }
  n_++;
  const int32_t d = x - meanQ8_;
  meanQ8_ += d / static_cast<int32_t>(n_);
  m2_ += static_cast<int64_t>(d) * (x - meanQ8_);
  if (m2_ < 0) m2_ = 0;
}

void Welford::remove(int32_t x) {
  if (n_ <= 1) {
    clear();
    return;
  }
  n_--;
  const int32_t d = x - meanQ8_;
  meanQ8_ -= d / static_cast<int32_t>(n_);
  m2_ -= static_cast<int64_t>(d) * (x - meanQ8_);
  if (m2_ < 0) m2_ = 0;
}

uint32_t Welford::sigmaQ8() const {
  if (n_ < 2) return 0;
  return isqrt64(static_cast<uint64_t>(m2_ / (n_ - 1)));
}

// ---------------------------------------------------------------------------
// Construction / reset
// ---------------------------------------------------------------------------

Detector::Detector() { reset(); }

void Detector::reset() {
  for (uint8_t i = 0; i < kPreWindowN; i++) pre_[i] = PreEntry{0, 0, 0, 0, 0};
  for (uint8_t i = 0; i < kPostWindowN; i++) post_[i] = PostEntry{0, 0, 0};
  preHead_ = 0;
  preCount_ = 0;
  postHead_ = 0;
  postCount_ = 0;
  magStats_.clear();
  gravMean_.clear();
  meanMagQ8_ = 0;
  sigmaQ8_ = static_cast<uint32_t>(kMinSigmaMg) * kQ8;
  baselineFrozen_ = false;
  tripped_ = false;
  aboveSince_ = 0;
  candidateSince_ = 0;
  lastNowMs_ = 0;
  windowPeakMag_ = 0;
  windowPeakJerk_ = 0;
  windowPeakZ_ = 0;
  windowFreeFall_ = 0;
  windowSw420_ = 0;
  windowOrientDeg10_ = 0;
  windowSpeedMilli_ = 0;
  lastScore_ = 0;
  lastSpeedMilliKmh_ = 0;
}

void Detector::resetStats() {
  peakAccMg_ = 0;
  sw420Hits_ = 0;
  sw420Last_ = 0;
  lastSw420Edge_ = 0;
  lastSw420High_ = 0;
}

void Detector::seedBaseline(int32_t meanMagQ8, int32_t gx, int32_t gy, int32_t gz) {
  meanMagQ8_ = meanMagQ8;
  // Calibration gives a mean but not a variance, so sigma starts at the floor.
  // It only matters for the first second of operation; after kPreWindowN samples
  // the rolling Welford has a real variance anyway.
  sigmaQ8_ = static_cast<uint32_t>(kMinSigmaMg) * kQ8;
  gravMean_.clear();
  for (uint16_t i = 0; i < kPreWindowN; i++) gravMean_.add(gx, gy, gz);
}

// ---------------------------------------------------------------------------
// Term normalisation
// ---------------------------------------------------------------------------

int32_t Detector::ramp(int32_t value, int32_t onKnee, int32_t fullKnee) {
  if (value <= onKnee) return 0;
  if (value >= fullKnee) return 1000;
  return ((value - onKnee) * 1000) / (fullKnee - onKnee);
}

int16_t Detector::angleDeg10(int64_t px, int64_t py, int64_t pz, int64_t qx,
                             int64_t qy, int64_t qz) {
  const int64_t pn = isqrt64(static_cast<uint64_t>(px * px + py * py + pz * pz));
  const int64_t qn = isqrt64(static_cast<uint64_t>(qx * qx + qy * qy + qz * qz));
  if (pn == 0 || qn == 0) return 0;
  const int64_t dot = px * qx + py * qy + pz * qz;
  int64_t cosQ15 = (dot << 15) / (pn * qn);
  cosQ15 = clamp32(static_cast<int32_t>(cosQ15), -32768, 32767);
  // The table spans cos = (i-64)/64, i.e. the cosine in Q6 biased by +64, so a
  // Q15 cosine must be shifted down by 9 bits before the bias is added.
  int32_t idx = static_cast<int32_t>(cosQ15 >> 9) + 64;
  idx = clamp32(idx, 0, 128);
  return static_cast<int16_t>(kAcosDeg10[idx]);
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

void Detector::pushPre(const Sample& s) {
  // A free-fall sample or a sample above the accel threshold is by definition not
  // normal driving. Letting it into the baseline would inflate sigma by hundreds
  // of mg and disarm the z-score for the rest of the window -- i.e. a crash would
  // blind the detector to the rest of the crash. Such samples still take a ring
  // slot (the orientation term needs the newest acceleration vectors) but they
  // are excluded from the mean/sigma/sum arithmetic.
  const uint8_t learnable =
      ((s.flags & kSfFreeFall) == 0 && s.magMg < cfg_.accelThresholdMg &&
       (s.flags & kSfSensorOk) != 0)
          ? 1u
          : 0u;
  const PreEntry e{s.magMg * kQ8, s.axMg, s.ayMg, s.azMg, learnable};
  // Evict using the *outgoing* slot's own flag, so add() and remove() stay exact
  // inverses and the running statistics cannot drift.
  if (preCount_ == kPreWindowN) {
    const PreEntry& old = pre_[preHead_];
    if (old.learnable) {
      magStats_.remove(old.magQ8);
      gravMean_.remove(old.ax, old.ay, old.az);
    }
  } else {
    preCount_++;
  }
  pre_[preHead_] = e;
  preHead_ = static_cast<uint8_t>((preHead_ + 1) % kPreWindowN);
  if (learnable) {
    magStats_.add(e.magQ8);
    gravMean_.add(e.ax, e.ay, e.az);
  }
}

void Detector::pushPost(const Sample& s) {
  const PostEntry e{s.jerkMgPerS, s.magMg, s.flags};
  post_[postHead_] = e;
  postHead_ = static_cast<uint8_t>((postHead_ + 1) % kPostWindowN);
  if (postCount_ < kPostWindowN) postCount_++;
}

// ---------------------------------------------------------------------------
// The algorithm
// ---------------------------------------------------------------------------

Decision Detector::process(const Sample& s, uint32_t nowMs) {
  Decision d{};
  // Mirrored out of the Decision on every path below, so lastScore() and
  // lastSpeedMilliKmh() are accurate even for the early-return (not primed) case.
  lastSpeedMilliKmh_ = s.speedMilliKmh;

  // --- SW-420 edge accounting, independent of the fusion -----------------
  // The module's own pot-set dwell time is 1-3 s, so correlating against rising
  // edges alone under-counts; level assertions feed the score and edges feed the
  // `sw420Hits` diagnostic.
  const uint8_t sw = (s.flags & kSfSw420) ? 1u : 0u;
  if (sw) {
    if (!sw420Last_) {
      if (sw420Hits_ == 0 || nowMs - lastSw420Edge_ > kSw420HitWindowMs) sw420Hits_ = 0;
      lastSw420Edge_ = nowMs;
      if (sw420Hits_ < kSw420MaxHits) sw420Hits_++;
    }
    lastSw420High_ = nowMs;
  }
  sw420Last_ = sw;

  // --- rolling baseline + evidence window --------------------------------
  pushPre(s);
  pushPost(s);

  if (s.magMg > peakAccMg_) peakAccMg_ = s.magMg;

  const bool primed = (preCount_ >= kPreWindowN) && (s.flags & kSfSensorOk) != 0;
  d.primed = primed ? 1u : 0u;
  d.peakAccMg = peakAccMg_;
  d.sw420Hits = sw420Hits_;

  if (!primed || !cfg_.armed) {
    d.score = 0;
    d.speedMilliKmh = s.speedMilliKmh;
    lastScore_ = 0;
    windowSpeedMilli_ = s.speedMilliKmh;
    return d;
  }

  // --- baseline statistics ----------------------------------------------
  if (!baselineFrozen_) {
    meanMagQ8_ = magStats_.meanQ8();
    const uint32_t sig = magStats_.sigmaQ8();
    sigmaQ8_ = sig < static_cast<uint32_t>(kMinSigmaMg) * kQ8
                  ? static_cast<uint32_t>(kMinSigmaMg) * kQ8
                  : sig;
    // The speed reported with the event is the last speed seen while the
    // baseline was still tracking normal driving, i.e. before the impact
    // polluted the window.
    windowSpeedMilli_ = s.speedMilliKmh;
  }

  // --- aggregate the post-impact evidence window -------------------------
  uint16_t peakMag = 0;
  uint16_t peakJerk = 0;
  uint16_t ffSamples = 0;
  bool sawSw420 = (lastSw420High_ != 0) && (nowMs - lastSw420High_ <= kSw420HoldMs);

  // Gravity vector over the newest `look` samples: the "after" side of the
  // orientation comparison.
  const uint8_t look =
      static_cast<uint8_t>(kPreSpeedLookbackMs / kSensorPeriodMs ? kPreSpeedLookbackMs / kSensorPeriodMs : 1);
  int64_t qx = 0, qy = 0, qz = 0;
  uint8_t qn = 0;

  uint8_t idx = static_cast<uint8_t>((postHead_ + kPostWindowN - postCount_) % kPostWindowN);
  for (uint8_t i = 0; i < postCount_; i++, idx = static_cast<uint8_t>((idx + 1) % kPostWindowN)) {
    const PostEntry& e = post_[idx];
    if (e.magMg > peakMag) peakMag = e.magMg;
    if (e.jerk > static_cast<int32_t>(peakJerk)) peakJerk = static_cast<uint16_t>(clamp32(e.jerk, 0, 65535));
    if (e.flags & kSfFreeFall) ffSamples++;
    if (e.flags & kSfSw420) sawSw420 = true;
    if (qn < look) {
      // The post window stores only derived signals, so the orientation vector is
      // read back from the pre window, which holds the same physical samples.
      const uint8_t pIdx = static_cast<uint8_t>(
          (static_cast<int32_t>(preHead_) + kPreWindowN - 1 - qn + kPreWindowN) % kPreWindowN);
      qx += pre_[pIdx].ax;
      qy += pre_[pIdx].ay;
      qz += pre_[pIdx].az;
      qn++;
    }
  }

  // --- evidence 1: free fall ---------------------------------------------
  // |a| below 0.3 g sustained. This is the strongest crash signature in the
  // physical world -- the vehicle stops pressing on the occupant -- and a
  // pothole, a kerb, or a desk drop cannot produce it.
  const bool freeFall = (ffSamples * kSensorPeriodMs) >= kFreeFallMs;

  // --- evidence 2: z-score -----------------------------------------------
  int32_t zMilli = ((static_cast<int32_t>(peakMag) * kQ8 - meanMagQ8_) * 1000) /
                   static_cast<int32_t>(sigmaQ8_ ? sigmaQ8_ : 1);
  zMilli = clamp32(zMilli, -32000, 32000);

  // --- evidence 6: orientation change ------------------------------------
  int16_t orientDeg10 = 0;
  if (qn > 0 && gravMean_.n > qn) {
    // The "before" vector is the 1 s mean with the newest `qn` samples removed,
    // so an impact cannot rotate its own reference frame.
    orientDeg10 = angleDeg10(gravMean_.x - qx, gravMean_.y - qy, gravMean_.z - qz, qx, qy, qz);
  }

  // --- normalise every term to 0..1000 and fuse ---------------------------
  const int32_t tFreeFall = freeFall ? 1000 : 0;
  const int32_t tZ = ramp(zMilli, knee::kZOnMilli, knee::kZFullMilli);
  const int32_t tSw420 = sawSw420 ? 1000 : 0;
  const int32_t tAbsMag = ramp(peakMag, static_cast<int32_t>(cfg_.accelThresholdMg), knee::kAbsFullMg);
  const int32_t tOrient = ramp(orientDeg10, knee::kOrientOnDeg10, knee::kOrientFullDeg10);
  const int32_t tJerk = ramp(peakJerk, knee::kJerkOnMgPerS, knee::kJerkFullMgPerS);

  const int32_t acc = tFreeFall * static_cast<int32_t>(wt::kFreeFall) +
                      tZ * static_cast<int32_t>(wt::kZScore) +
                      tSw420 * static_cast<int32_t>(wt::kSw420) +
                      tAbsMag * static_cast<int32_t>(wt::kAbsMag) +
                      tOrient * static_cast<int32_t>(wt::kOrient) +
                      tJerk * static_cast<int32_t>(wt::kJerk);
  // Each term is 0..1000 and the weights sum to wt::kSum (1000), so acc tops out
  // at 1,000,000. Dividing by (kSum * 1000 / 100) maps that onto 0..100.
  static_assert(wt::kSum == 1000, "score normalisation assumes a unit weight sum");
  int32_t score = (acc * 100) / (static_cast<int32_t>(wt::kSum) * 1000);
  score = (score * static_cast<int32_t>(cfg_.gainMilli)) / 1000;
  score = clamp32(score, 0, 100);
  DET_TRACE("t=%u ff=%d z=%d sw=%d abs=%d ori=%d jrk=%d -> score=%d\n", nowMs,
            tFreeFall, tZ, tSw420, tAbsMag, tOrient, tJerk, score);

  // --- corroboration gates ------------------------------------------------
  // Applied *before* the trip decision so a suppressed event is never latched
  // and then retracted: an impact at a standstill is a dropped unit, and a
  // high-g event with the SW-420 quiet is a pothole or a slammed door.
  const bool speedOk = (cfg_.minSpeedMilliKmh == 0) ||
                       (windowSpeedMilli_ >= cfg_.minSpeedMilliKmh);
  const bool vibOk = !cfg_.vibrationRequired || sawSw420;
  if (score >= kReleaseScore && !speedOk) d.blockedSpeed = 1;
  if (score >= kReleaseScore && !vibOk) d.blockedVibration = 1;
  const bool eligible = speedOk && vibOk;

  // --- candidate -> freeze -> debounce -> trip ----------------------------
  if (score >= kReleaseScore) {
    if (!candidateSince_) candidateSince_ = nowMs;
  } else {
    candidateSince_ = 0;
  }

  // Refractory: a single impact spans many 20 ms samples, and re-arming the
  // candidate the instant the latch clears would report one crash several times.
  // setRefractory() holds the detector off for a window after a trip; the state
  // machine owns the re-arm decision, this only blocks the raw latch.
  const bool inRefractory = (refractoryUntil_ != 0) && (int32_t)(nowMs - refractoryUntil_) < 0;

  if (!tripped_ && !inRefractory) {
    if (!baselineFrozen_ && candidateSince_ == nowMs) {
      // First sample at/above the candidate floor: freeze the baseline so the
      // impact cannot inflate the z-score reference it is measured against.
      baselineFrozen_ = true;
      aboveSince_ = 0;
    }
    if (baselineFrozen_) {
      if (score >= kTripScore) {
        if (!eligible) {
          // Corroboration failed while the event was building: discard it.
          unfreeze(nowMs);
        } else {
          if (aboveSince_ == 0) aboveSince_ = nowMs;
          if (nowMs - aboveSince_ >= cfg_.debounceMs) {
            tripped_ = true;
            d.tripped = 1;
          }
        }
      } else if (score < kReleaseScore) {
        // Hysteresis: the latch needs a sustained score >= 70 to set, and only
        // falls back below the lower release knee to clear.
        unfreeze(nowMs);
      } else {
        // In the band between release and trip: hold the latch, keep collecting.
        aboveSince_ = 0;
      }
    }
  }

  if (inRefractory) d.released = 0;  // the latch is held, not decaying

  if (tripped_ && score < kReleaseScore) {
    // Tell the caller the score has decayed below the release knee. The state
    // machine decides whether re-arming is allowed -- it is not while a
    // countdown is running.
    d.released = 1;
    tripped_ = false;
    unfreeze(nowMs);
  }

  // --- publish window statistics -----------------------------------------
  windowPeakMag_ = peakMag;
  windowPeakJerk_ = peakJerk;
  windowPeakZ_ = static_cast<int16_t>(zMilli);
  windowFreeFall_ = freeFall ? 1u : 0u;
  windowSw420_ = sawSw420 ? 1u : 0u;
  windowOrientDeg10_ = static_cast<uint16_t>(orientDeg10);

  d.score = static_cast<uint8_t>(score);
  lastScore_ = d.score;
  d.magMg = peakMag;
  d.orientDeg10 = windowOrientDeg10_;
  d.speedMilliKmh = windowSpeedMilli_;
  d.jerkMgPerS = windowPeakJerk_;
  d.zMilli = windowPeakZ_;
  d.freeFall = windowFreeFall_;
  d.sw420 = windowSw420_;
  return d;
}

void Detector::unfreeze(uint32_t nowMs) {
  (void)nowMs;
  baselineFrozen_ = false;
  candidateSince_ = 0;
  aboveSince_ = 0;
  windowPeakMag_ = 0;
  windowPeakJerk_ = 0;
  windowPeakZ_ = 0;
  windowFreeFall_ = 0;
  windowSw420_ = 0;
  windowOrientDeg10_ = 0;
}

}  // namespace saas
