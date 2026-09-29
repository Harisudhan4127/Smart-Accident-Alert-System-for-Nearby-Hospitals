// sensordiag.cpp — per-sensor health verdicts for the DIAGNOSTIC mode.
#include "sensordiag.h"

namespace saas {

const char* healthTag(Health h) {
  // Two characters each, without exception. They share a display row with fixed
  // fields around them, and a one-character tag would pull everything after it
  // left by a column the moment a verdict changed. That is the kind of flicker
  // that makes people stop reading a diagnostic display.
  switch (h) {
    case Health::kOk:     return "OK";
    case Health::kWarn:   return "??";
    case Health::kFail:   return "XX";
    default:              return "--";
  }
}

const char* healthText(Health h) {
  switch (h) {
    case Health::kOk:     return "OK";
    case Health::kWarn:   return "UNPROVEN";
    case Health::kFail:   return "FAIL";
    default:              return "UNKNOWN";
  }
}

void SensorHealth::reset() {
  *this = SensorHealth();
}

void SensorHealth::feed(uint32_t nowMs, int32_t magMg, bool sw420, bool sw420Level, bool sensorOk,
                        bool present) {
  present_ = present;
  haveEvidence_ = true;

  // Time base, for the "no gravity for this long" verdict. The first sample
  // establishes the epoch rather than counting as a huge interval from zero.
  const uint32_t dt = haveTime_ ? (nowMs - lastMs_) : 0;
  lastMs_ = nowMs;
  haveTime_ = true;

  if (!sensorOk) {
    readFailures_++;
    if (readFailures_ > worstReadFailures_) worstReadFailures_ = readFailures_;
    // Deliberately do NOT return early. The min/max/span tracking below is how a
    // frozen value gets caught, and freezing is precisely the case where reads
    // succeed. Returning here would make the frozen-bus check unreachable.
  } else {
    readFailures_ = 0;
  }

  if (!haveMag_) {
    lastMagMg_ = magMg;
    minMagMg_ = magMg;
    maxMagMg_ = magMg;
    haveMag_ = true;
  } else {
    // Motion, not just variation: a real node jitters by tens of mg on a desk,
    // and 150 mg is well above that noise floor but well below anything a person
    // does to it. This is what separates "responding" from "stuck".
    const int32_t delta = magMg > lastMagMg_ ? magMg - lastMagMg_ : lastMagMg_ - magMg;
    if (delta > kDiagMotionMg) sawMotion_ = true;
    if (magMg < minMagMg_) minMagMg_ = magMg;
    if (magMg > maxMagMg_) maxMagMg_ = magMg;
    lastMagMg_ = magMg;
  }

  // Gravity. The window is generous because a node is often held at an angle and
  // a knock can briefly read low, but it is far below the "this sensor is not
  // powered" case, which reads ~0.1 g forever.
  if (magMg >= kDiagGravityMinMg && magMg <= kDiagGravityMaxMg) {
    sawGravity_ = true;
    noGravityMs_ = 0;
  } else if (sensorOk) {
    noGravityMs_ += dt;
  }

  if (haveSwLevel_ && sw420Level != lastSwLevel_) swToggles_++;
  lastSwLevel_ = sw420Level;
  haveSwLevel_ = true;
  if (sw420) sawSw420_ = true;
}

Health SensorHealth::accel() const {
  // No evidence at all is UNKNOWN, not WARN. After reset() — which is what
  // entering DIAGNOSTIC does — the sensor has been neither passed nor condemned,
  // and reporting a verdict there would be inventing a diagnosis. The first
  // sample resolves it.
  if (!haveEvidence_) return Health::kUnknown;
  if (!present_) return Health::kFail;
  if (readFailures_ >= kDiagFailReads) return Health::kFail;
  // The case that DEVID cannot catch: present, answering, and reading nothing.
  if (noGravityMs_ >= kDiagNoGravityMs) return Health::kFail;
  // Present and answering, but gravity has not been seen — most likely the node
  // is in free fall, held, or the part is only partly powered.
  if (!sawGravity_) return Health::kWarn;
  // Gravity seen but the number has never moved. On a bench this is almost
  // always a frozen bus or a wedged part; in a moving car it can be a very still
  // one, so it is a warning and not a failure.
  if (!sawMotion_) return Health::kWarn;
  return Health::kOk;
}

Health SensorHealth::sw420() const {
  if (!haveEvidence_) return Health::kUnknown;
  // A switch nobody has tapped is unproven, not broken. Marking it FAIL would
  // make a correctly wired node look faulty until someone happened to knock it,
  // which is the opposite of what a diagnostic is for.
  return sawSw420_ ? Health::kOk : Health::kWarn;
}

Health SensorHealth::bus() const {
  if (!haveEvidence_) return Health::kUnknown;
  if (!present_) return Health::kFail;
  if (readFailures_ >= kDiagFailReads) return Health::kFail;
  if (readFailures_ > 0) return Health::kWarn;
  return Health::kOk;
}

}  // namespace saas
