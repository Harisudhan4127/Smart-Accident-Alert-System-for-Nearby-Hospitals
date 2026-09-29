// demomode.cpp — the NORMAL / DEMO switch and the demo shake trigger.
#include "demomode.h"

namespace saas {

const char* runModeName(uint8_t mode) {
  switch (mode) {
    case kModeDemo: return "DEMO";
    case kModeDiag: return "DIAG";
    default: return "NORMAL";
  }
}

bool modeCanRaiseEvents(uint8_t mode) {
  // Enumerated, not "everything except DIAGNOSTIC". A negative test fails OPEN:
  // the day a fourth mode is added, `mode != kModeDiag` would let it raise
  // accidents without anyone re-reading this function. Naming the two modes
  // that may fire means a new one is inert until somebody decides otherwise.
  return mode == kModeNormal || mode == kModeDemo;
}

void DemoTrigger::setMode(uint8_t mode) {
  // Anything that is not exactly kModeDemo is NORMAL. A node that has been
  // flashed with a mismatched app could otherwise be told "DEMO3" and end up in
  // no defined mode at all, which is the one outcome worse than either.
  const uint8_t next = (mode == kModeDemo) ? kModeDemo : kModeNormal;
  if (next == mode_) return;
  mode_ = next;
  // Drop a partial shake. Without this, shaking in NORMAL, switching to DEMO
  // and stopping would fire on the strength of motion that happened before the
  // mode existed — a demo that triggers without being shaken, which teaches the
  // opposite of what it is for.
  shakeRun_ = 0;
}

void DemoTrigger::resetStats() {
  triggers_ = 0;
  peakMagMg_ = 0;
  shakeRun_ = 0;
  everTriggered_ = false;
  lastTriggerMs_ = 0;
}

void DemoTrigger::resetAll() {
  resetStats();
  mode_ = kRunModeDefault;
}

uint32_t DemoTrigger::cooldownRemaining(uint32_t nowMs) const {
  if (!everTriggered_) return 0;
  const uint32_t since = nowMs - lastTriggerMs_;
  return since >= kDemoCooldownMs ? 0 : (kDemoCooldownMs - since);
}

bool DemoTrigger::feed(uint32_t nowMs, int32_t magMg, bool sw420, bool sensorOk) {
  if (magMg > peakMagMg_) peakMagMg_ = magMg;
  // Only DEMO. The peak above is still tracked in every mode, because the trace
  // is for looking at and the DIAGNOSTIC screen reports it.
  if (mode_ != kModeDemo || !modeCanRaiseEvents(mode_)) return false;

  // A sensor that is not answering reads back a constant. That constant is not
  // evidence of anything, and firing on it would look exactly like a sensor
  // that is working perfectly. Dropping it here also means the peak tracked
  // above still records what was seen, which is what the trace needs.
  if (!sensorOk) {
    shakeRun_ = 0;
    return false;
  }

  // **Both** sensors, on the same sample. Not "either", and not "the
  // accelerometer with the switch as a shortcut": the SW-420 is the only input
  // with a failure mode the accelerometer does not have, so a demo trigger that
  // can ignore it is not demonstrating the node.
  const bool strong = magMg >= kDemoShakeMagMg;
  if (strong && sw420) {
    if (shakeRun_ < 255) shakeRun_++;
  } else {
    shakeRun_ = 0;
  }

  if (shakeRun_ < kDemoShakeHoldSamples) return false;
  if (cooldownRemaining(nowMs) != 0) return false;

  // Fire once, then rearm from zero. Not `shakeRun_ = 1`: leaving the counter
  // part-primed would fire again the moment the cooldown expired, from motion
  // that had already been counted.
  triggers_++;
  lastTriggerMs_ = nowMs;
  everTriggered_ = true;
  shakeRun_ = 0;
  return true;
}

}  // namespace saas
