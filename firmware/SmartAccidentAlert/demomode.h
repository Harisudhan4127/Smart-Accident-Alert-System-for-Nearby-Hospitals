// demomode.h — the NORMAL / DEMO switch and the demo shake trigger.
//
// DEMO exists so the whole accident path can be demonstrated on a bench: shake
// the node, and it raises a real event through the real state machine, the real
// BLE stack and the real app. Nothing is faked below this file — the trigger
// only decides *when* to trip, and then the normal code runs.
//
// The design rule that matters: **DEMO is never entered implicitly.** A node
// that booted into DEMO would raise simulated alerts about a car that was fine,
// and a person watching a 64-pixel screen is not going to notice the difference
// between a demo and a real crash. See kRunModeDefault.
//
// No Arduino headers here on purpose. The trigger is timing arithmetic, so it is
// unit-tested on the host rather than only on hardware.
#pragma once

#include <stdint.h>

#include "config.h"

namespace saas {

/// Wire values for RunMode. Kept as plain integers so they can go on the wire
/// and into JSON without a cast, and so an unknown value from a future firmware
/// decodes to NORMAL rather than to something that skips the safety checks.
enum RunMode : uint8_t {
  kModeNormal = 0,  ///< the real detector. The only mode that is ever armed.
  kModeDemo = 1,    ///< shake the node and it raises a simulated ACCIDENT_DETECTED
  kModeDiag = 2,    ///< sensor health check. Never raises an event, never arms.
};

/// Recognised part name for [RunMode]. Anything unrecognised reads as NORMAL,
/// because that is the mode where the node actually works.
const char* runModeName(uint8_t mode);

/// True for a mode that must never raise an event, whatever the sensors say.
///
/// DIAGNOSTIC is for checking the hardware, and the fastest way to make a
/// diagnostic useless is to have it page someone. `DemoTrigger::feed` returns
/// false in every mode this rejects, so the guarantee is in the one place that
/// decides to fire rather than in each caller's judgement.
bool modeCanRaiseEvents(uint8_t mode);

/// Decides when a simulated impact should fire, and remembers the mode.
///
/// Not thread-safe by design: it is fed from one task only (the detector path)
/// and read from another (the UI). The counts it exposes are the same values the
/// UI draws, so a torn read would only ever show a stale number, never a wrong
/// trigger.
class DemoTrigger {
 public:
  /// Switch mode. Leaving DEMO clears any partial shake run, so a mode change
  /// mid-shake cannot leave the counter primed to fire the moment you switch
  /// back.
  void setMode(uint8_t mode);

  uint8_t mode() const { return mode_; }

  /// True in DEMO. The single predicate every caller should test, so the mode
  /// can never be half-applied.
  bool enabled() const { return mode_ == kModeDemo; }

  /// Feed one sample. Returns true on exactly one tick per simulated impact.
  ///
  /// **Both sensors must agree**: |a| at or above kDemoShakeMagMg *and* the
  /// SW-420 asserted, on the same sample, for kDemoShakeHoldSamples running. The
  /// accelerometer alone and the switch alone are each insufficient — see
  /// kDemoShakeMagMg.
  ///
  /// `magMg` is the *unfiltered* magnitude, because a demo has to respond to a
  /// flick of the wrist: the 5 Hz section is for the gravity estimate and would
  /// report a fraction of a 40 ms peak. `sw420` is the already-debounced switch
  /// level.
  ///
  /// Returns false in NORMAL and in DIAGNOSTIC, and returns false without
  /// touching any state when `sensorOk` is false — a dead bus reads as a
  /// constant, and a constant is not evidence of a shake.
  bool feed(uint32_t nowMs, int32_t magMg, bool sw420, bool sensorOk);

  /// How many demo impacts have fired this session.
  uint32_t triggerCount() const { return triggers_; }

  /// Largest magnitude seen this session, milli-g. Drives the OLED trace's
  /// auto-scale, and is the number to read when asking "was that really a
  /// shake?".
  int32_t peakMagMg() const { return peakMagMg_; }

  /// Samples currently at or above the threshold, for the UI's "why has it not
  /// fired yet" readout.
  uint8_t shakeRun() const { return shakeRun_; }

  /// Milliseconds until the next trigger is allowed, 0 when one is allowed now.
  uint32_t cooldownRemaining(uint32_t nowMs) const;

  /// Clears the counters, keeping the mode. Bound to RESET_STATS.
  void resetStats();

  /// Clears counters *and* returns to NORMAL. Used by the boot path, so a
  /// power cycle always comes up in NORMAL.
  void resetAll();

 private:
  uint8_t mode_ = kRunModeDefault;
  uint8_t shakeRun_ = 0;
  uint32_t lastTriggerMs_ = 0;
  bool everTriggered_ = false;
  uint32_t triggers_ = 0;
  int32_t peakMagMg_ = 0;
};

}  // namespace saas
