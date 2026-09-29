// power.h — sleep policy and the watchdog.
//
// Two separate concerns that both answer "may this CPU stop working right now?":
//   * Light sleep between sensor samples, which is *always* safe and gated only
//     on there being nothing to do.
//   * Deep sleep, which is never automatic. A node that parks itself at 3 V and
//     stops detecting is worse than one that runs flat, so deep sleep has to be
//     armed explicitly (config or a command) and the firmware refuses to arm it
//     while the detector is armed.
#pragma once

#include <stdint.h>

#include "config.h"
#include "protocol.h"

namespace saas {

/// Task ids for the watchdog slots.
///
/// **This lives here, not in the sketch, because both sides have to agree.**
/// It was declared in the .ino and the critical-set predicate in this header
/// spelled its own numbers — and immediately disagreed with it: the predicate
/// said "3 is sys" when 3 is ui, so the display task was allowed to restart the
/// chip and the housekeeping task was not. A host test caught it, which is the
/// only reason it was found before it shipped. One declaration, used by both.
enum WdTask : uint8_t {
  kWdSensor = 0,
  kWdDetect,
  kWdBle,
  kWdUi,
  kWdSys,
  kWdWatchdog,
  kWdCount,  ///< == kTaskSlots. static_assert'd below.
};

/// Why a sleep was refused, so the caller can log or surface it rather than
/// silently busy-waiting.
enum SleepVerdict : uint8_t {
  kSleepOk = 0,
  kSleepBusyBle,        ///< a phone is connected; the radio needs the core
  kSleepBusyAlarm,      ///< alarming, or an event is still unacknowledged
  kSleepBusyDisarmed,   ///< the detector is armed; never park
  kSleepBusyCharging,   ///< charging; keep the rail up
  kSleepNotForced,      ///< forced sleep declined by policy
};
const char* sleepVerdictName(uint8_t v);

class Power {
 public:
  static Power& instance();

  void begin();

  /// Feed the task watchdog. Each task has its own slot, so one wedged task is
  /// visible rather than masked by a healthy neighbour.
  void feed(WdTask taskId);
  /// Check the slots; returns true if the chip must be reset.
  ///
  /// Only the tasks whose liveness *is* the safety property are allowed to
  /// trigger a reset — see kWatchdogCritical().
  bool checkWatchdog(uint32_t nowMs);

  /// True when every task has fed within kWatchdogTimeoutS. Also true before
  /// begin(), so a caller that forgets to begin() does not sleep forever.
  bool allTasksHealthy(uint32_t nowMs) const;

  /// True when every *critical* task has fed within kWatchdogTimeoutS.
  ///
  /// A display task that missed its slot is a cosmetic problem. A sensor or
  /// detect task that missed its slot means a crash would not be noticed, and
  /// that is the one failure worth a reset.
  ///
  /// This distinction matters more than it looks. The watchdog used to restart
  /// the chip for *any* slot, so a slow SSD1306 push — or the BLE stack holding
  /// core 0 — could reboot a node that was otherwise detecting perfectly well,
  /// losing the crash that was happening at the time. A reboot in response to a
  /// late display is strictly worse than a late display: it destroys the trace,
  /// the run mode and the armed state, and it does so while the vehicle moves.
  bool criticalTasksHealthy(uint32_t nowMs) const;

  /// May we enter light sleep this instant? Pure decision, no I/O, so the policy
  /// is testable and cannot drift from what actually happens.
  SleepVerdict mayLightSleep(bool bleConnected, uint8_t state, bool armed, bool charging,
                             bool eventPending) const;

  /// Arm an explicit deep sleep after `delayMs`. Returns the refusal if the
  /// policy declines. The wake source is the SW-420 pin: a hard impact wakes
  /// the node even if nothing else is attached.
  SleepVerdict armDeepSleep(uint32_t delayMs, bool armed, bool charging, uint8_t state,
                            bool eventPending);

  /// True once a deep sleep has been armed and the caller should yield the core.
  bool deepSleepArmed() const { return deepArmed_; }

  /// Enter light sleep if permitted. Returns the verdict for diagnostics.
  SleepVerdict serviceLightSleep(uint32_t nowMs, bool bleConnected, uint8_t state, bool armed,
                                 bool charging, bool eventPending, uint32_t maxSleepMs = 8);

  uint32_t watchdogResets() const { return wdResets_; }
  void noteWatchdogReset() { wdResets_++; }

 private:
  Power() = default;
 public:
  /// Number of watchdog slots, and the array bound. Public so the host test can
  /// check the slot-id contract without reaching into the class.
  static constexpr uint8_t kTaskSlots = kWdCount;
  static_assert(kTaskSlots == 6, "every task needs a watchdog slot");
  static_assert(static_cast<uint8_t>(kWdCount - 1) < kTaskSlots,
                "WdTask values must index fedAtMs_ without overflowing it");

  /// Slots that may restart the chip.
  ///
  /// kWdWatchdog is included deliberately: it is the task doing the checking, and
  /// excluding it would hide the exact bug that was here — wdtTask never fed its
  /// own slot, so the watchdog found itself stale and restarted the node every
  /// kWatchdogTimeoutS. Keeping it in the set means that failure is still caught
  /// by the same code path rather than by luck.
  ///
  /// kWdUi and kWdBle are excluded on purpose. A slow SSD1306 push or a radio
  /// stack that holds core 0 must not reboot a node that is otherwise detecting
  /// perfectly well: the restart would destroy the trace, the run mode and the
  /// armed state, and would do it while the vehicle is moving. They are still
  /// tracked by allTasksHealthy() and surface in DIAG.
  static bool kWatchdogCritical(WdTask t) {
    return t == kWdSensor || t == kWdDetect || t == kWdSys || t == kWdWatchdog;
  }

  uint32_t fedAtMs_[kTaskSlots]{};
  bool fed_[kTaskSlots]{};
  bool deepArmed_ = false;
  uint32_t wdResets_ = 0;
};

}  // namespace saas
