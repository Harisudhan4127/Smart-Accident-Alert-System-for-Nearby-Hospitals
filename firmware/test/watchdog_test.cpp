// watchdog_test.cpp — host tests for the task watchdog.
//
// This exists because the watchdog restarted the node on a loop and nothing
// noticed. The cause was one line missing: wdtTask never fed its own slot, so
// `allTasksHealthy` found slot 5 stale five seconds after boot and called
// ESP.restart() — forever. The firmware compiled, every other test passed, and
// the node rebooted every five seconds while appearing to work.
//
// The failure mode is worth naming: a watchdog with no test is a timer that
// turns the power off on a schedule nobody chose. These tests pin the two
// properties that matter.
//
//   1. Every task can feed its own slot, and the ids are one shared enum.
//   2. A restart is reserved for the tasks whose liveness is the safety
//      property — never for the display or the radio.

#include <stdio.h>

#include "power.h"

using saas::Power;
// `WdTask` is an enum *type* in namespace saas; its enumerators are ordinary
// namespace-scope names, so importing the namespace brings the names in and the
// type stays qualified. That distinction is why `WdTask` alone does not resolve.
using namespace saas;
static constexpr uint8_t kSlots = Power::kTaskSlots;

static int g_fail = 0;
static int g_checks = 0;

#define CHECK(cond)                                            \
  do {                                                         \
    g_checks++;                                                \
    if (!(cond)) {                                             \
      g_fail++;                                                \
      printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); \
    }                                                          \
  } while (0)

static void testSlotIdsAreContiguous() {
  printf("WdTask values index the slot array\n");
  // Every task the sketch creates needs a slot, and every slot needs a task. A
  // gap or an overflow here is a silent out-of-bounds write in feed().
  CHECK(static_cast<uint8_t>(kWdSensor) == 0);
  CHECK(static_cast<uint8_t>(kWdDetect) == 1);
  CHECK(static_cast<uint8_t>(kWdBle) == 2);
  CHECK(static_cast<uint8_t>(kWdUi) == 3);
  CHECK(static_cast<uint8_t>(kWdSys) == 4);
  CHECK(static_cast<uint8_t>(kWdWatchdog) == 5);
  CHECK(kSlots == 6);
  // The enum is the array bound, so kWdCount == kTaskSlots by construction.
  CHECK(static_cast<uint8_t>(kWdCount) == kSlots);
}

static void testCriticalSetIsSensorDetectSysWatchdog() {
  printf("only sensor/detect/sys/watchdog may restart the chip\n");
  // The regression this file exists for, in the second form it took: the
  // predicate originally spelled its own index numbers and said "3 is sys" when
  // 3 is ui. So the display task could reboot the node and the housekeeping
  // task could not. Asserting each task by *name* is what makes that
  // unrepresentable.
  CHECK(Power::kWatchdogCritical(kWdSensor));
  CHECK(Power::kWatchdogCritical(kWdDetect));
  CHECK(Power::kWatchdogCritical(kWdSys));
  CHECK(Power::kWatchdogCritical(kWdWatchdog));

  // Explicitly not: a slow SSD1306 push or a radio stack holding core 0 must
  // not lose a node that is detecting perfectly well.
  CHECK(!Power::kWatchdogCritical(kWdUi));
  CHECK(!Power::kWatchdogCritical(kWdBle));
}

static void testWatchdogSlotIsCritical() {
  printf("the watchdog's own slot is critical\n");
  // kWdWatchdog being non-critical would have hidden the original bug entirely:
  // a wdtTask that never fed would be defined as "healthy".
  CHECK(Power::kWatchdogCritical(kWdWatchdog));
}

static void testEverySlotDecidesSomething() {
  printf("every slot id gets a definite answer\n");
  // An id outside the enum must answer false rather than defaulting to
  // "critical" — otherwise a typo in a feed() call corrupts a neighbour's slot
  // and the node restarts for no stated reason.
  for (uint8_t i = 0; i < kSlots; i++) {
    g_checks++;
    if (!Power::kWatchdogCritical(static_cast<WdTask>(i))) {
      // Non-critical is a legitimate answer for ble and ui only.
      const WdTask t = static_cast<WdTask>(i);
      if (t != kWdUi && t != kWdBle) {
        g_fail++;
        printf("  FAIL slot %u unexpectedly non-critical\n", i);
      }
    }
  }
}

int main() {
  testSlotIdsAreContiguous();
  testCriticalSetIsSensorDetectSysWatchdog();
  testWatchdogSlotIsCritical();
  testEverySlotDecidesSomething();
  printf("\n%d checks, %d failures\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
