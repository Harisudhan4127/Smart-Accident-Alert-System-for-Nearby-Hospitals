// power.cpp — sleep policy + task watchdog.
#include "power.h"

#if defined(ARDUINO)
#include <Arduino.h>
#include <esp_sleep.h>
#else
#include <chrono>
/// Host stand-in for millis(), so the watchdog and sleep policy can be stepped
/// from a test. Sourced from the steady clock, never the wall clock: a test that
/// jumps the system time must not be able to expire a watchdog.
inline uint32_t millis() {
  using namespace std::chrono;
  return static_cast<uint32_t>(
      duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}
#endif

namespace saas {

const char* sleepVerdictName(uint8_t v) {
  switch (v) {
    case kSleepOk: return "OK";
    case kSleepBusyBle: return "BLE_ACTIVE";
    case kSleepBusyAlarm: return "ALARM_ACTIVE";
    case kSleepBusyDisarmed: return "DETECTOR_ARMED";
    case kSleepBusyCharging: return "CHARGING";
    case kSleepNotForced: return "NOT_ALLOWED";
    default: return "?";
  }
}

Power& Power::instance() {
  static Power p;
  return p;
}

void Power::begin() {
  const uint32_t now = millis();
  for (uint8_t i = 0; i < kTaskSlots; i++) {
    fedAtMs_[i] = now;
    fed_[i] = true;
  }
  deepArmed_ = false;
}

void Power::feed(uint8_t taskId) {
  if (taskId >= kTaskSlots) return;
  fedAtMs_[taskId] = millis();
  fed_[taskId] = true;
}

bool Power::allTasksHealthy(uint32_t nowMs) const {
  for (uint8_t i = 0; i < kTaskSlots; i++) {
    if (!fed_[i]) continue;  // a task that has never run cannot be late
    if (nowMs - fedAtMs_[i] > static_cast<uint32_t>(kWatchdogTimeoutS) * 1000u) return false;
  }
  return true;
}

bool Power::checkWatchdog(uint32_t nowMs) {
  if (allTasksHealthy(nowMs)) return false;
  // A single starved task is a real fault. Records survive a soft reset through
  // RTC_NOINIT_ATTR, so DIAG can tell the user their node has been resetting.
#if defined(ARDUINO)
  noteWatchdogReset();
  ESP.restart();
#endif
  return true;
}

SleepVerdict Power::mayLightSleep(bool bleConnected, uint8_t state, bool armed, bool charging,
                                  bool eventPending) const {
  // Any state where a miss would cost someone their rescue is "busy". PENDING is
  // in this set deliberately: the vehicle may be sitting there with a false
  // positive waiting to be cancelled, and a sleeping node cannot show that.
  switch (state) {
    case proto::kStatePending:
    case proto::kStateAlarm:
    case proto::kStateSos:
    case proto::kStateFault:
      return kSleepBusyAlarm;
    default:
      break;
  }
  if (bleConnected) return kSleepBusyBle;
  if (eventPending) return kSleepBusyAlarm;
  if (armed) return kSleepBusyDisarmed;
  if (charging) return kSleepBusyCharging;
  return kSleepOk;
}

SleepVerdict Power::armDeepSleep(uint32_t delayMs, bool armed, bool charging, uint8_t state,
                                 bool eventPending) {
  // Deep sleep is *never* allowed while the node can still detect. A parked node
  // that misses the crash it was installed to catch is the worst possible
  // failure, so the guard is unconditional: no config, no command, no
  // combination of them, gets past this line.
  if (armed) return kSleepBusyDisarmed;
  const SleepVerdict v = mayLightSleep(false, state, armed, charging, eventPending);
  if (v != kSleepOk) return v;
#if defined(ARDUINO)
  // Wake on the SW-420 pin, which is the one physical input that can indicate
  // something happened while we were parked. Level-triggered on HIGH, matching
  // the module's active-high output: ext1 is level- not edge-triggered, and
  // ESP-IDF 5 has no "any edge" mode for it, so a bounce that re-asserts the
  // line still wakes us.
  esp_sleep_enable_ext1_wakeup(1ULL << kPinSw420, ESP_EXT1_WAKEUP_ANY_HIGH);
  esp_sleep_enable_timer_wakeup(delayMs * 1000ULL);
  deepArmed_ = true;
  (void)0;
#endif
  return kSleepOk;
}

SleepVerdict Power::serviceLightSleep(uint32_t nowMs, bool bleConnected, uint8_t state, bool armed,
                                      bool charging, bool eventPending, uint32_t maxSleepMs) {
  (void)nowMs;
  const SleepVerdict v = mayLightSleep(bleConnected, state, armed, charging, eventPending);
  if (v != kSleepOk) return v;
#if defined(ARDUINO) && SAAS_ENABLE_LIGHT_SLEEP
  // esp_sleep_enable_timer_wakeup takes microseconds. Capped, because the sensor
  // period is the only thing that bounds how long we may be off, and a caller
  // that asked for a longer nap would miss a sample.
  if (maxSleepMs > kSensorPeriodMs) maxSleepMs = kSensorPeriodMs;
  esp_sleep_enable_timer_wakeup(static_cast<uint64_t>(maxSleepMs) * 1000ULL);
  esp_light_sleep_start();
#endif
  return kSleepOk;
}

}  // namespace saas
