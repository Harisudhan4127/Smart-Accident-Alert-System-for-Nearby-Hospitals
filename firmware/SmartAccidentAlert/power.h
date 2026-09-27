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

  /// Feed the task watchdog. Each task has its own slot, so one wedged task
  /// resets the chip instead of being masked by a healthy neighbour.
  void feed(uint8_t taskId);
  /// Check all slots; returns true if the chip must be reset.
  bool checkWatchdog(uint32_t nowMs);

  /// True when every task has fed within kWatchdogTimeoutS. Also true before
  /// begin(), so a caller that forgets to begin() does not sleep forever.
  bool allTasksHealthy(uint32_t nowMs) const;

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
  static constexpr uint8_t kTaskSlots = 6;

  uint32_t fedAtMs_[kTaskSlots]{};
  bool fed_[kTaskSlots]{};
  bool deepArmed_ = false;
  uint32_t wdResets_ = 0;
};

}  // namespace saas
