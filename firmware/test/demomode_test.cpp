// demomode_test.cpp — host tests for the run modes and the DEMO shake trigger.
//
// The trigger is timing arithmetic with a few sharp edges (the cooldown, the
// sensor-fault guard, the "don't fire on a mode change" rule), which is exactly
// the kind of code that is unpleasant to exercise by shaking a node on a desk
// and impossible to test for a fault path at all. So it lives in its own header
// with no Arduino dependency and is tested here.
//
// Build/run: `make test-firmware-host` from the repository root.
//
// This file lives in firmware/test/, NOT next to the .ino, and that placement is
// load-bearing. The Arduino build compiles and links every .cpp in the sketch
// directory, so a main() sitting beside SmartAccidentAlert.ino gets pulled into
// the firmware image and fights the IDE's own entry point.

#include <stdio.h>
#include <string.h>

#include "demomode.h"

using namespace saas;

static int g_fail = 0;
static int g_checks = 0;

#define CHECK(cond)                                                        \
  do {                                                                     \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
      g_fail++;                                                            \
      printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);             \
    }                                                                      \
  } while (0)

#define CHECK_EQ(a, b)                                                     \
  do {                                                                     \
    g_checks++;                                                            \
    const long _a = (long)(a), _b = (long)(b);                             \
    if (_a != _b) {                                                        \
      g_fail++;                                                            \
      printf("  FAIL %s:%d  %s == %s  (%ld vs %ld)\n", __FILE__, __LINE__, \
             #a, #b, _a, _b);                                              \
    }                                                                      \
  } while (0)

/// 50 Hz, the real sample rate.
static constexpr uint32_t kStep = 20;

/// Feed [count] samples at [magMg] with the switch at [sw420], one step apart.
static int feedShake(DemoTrigger& d, uint32_t t0, uint32_t count, int32_t magMg,
                     bool sw420, bool sensorOk = true) {
  int fired = 0;
  for (uint32_t i = 0; i < count; i++) {
    if (d.feed(t0 + i * kStep, magMg, sw420, sensorOk)) fired++;
  }
  return fired;
}

// ---------------------------------------------------------------------------
// The default, and the guarantee that NORMAL is the default
// ---------------------------------------------------------------------------

static void testDefaultsToNormal() {
  printf("boots in NORMAL\n");
  DemoTrigger d;
  CHECK_EQ(d.mode(), kModeNormal);
  CHECK(!d.enabled());
  CHECK_EQ(d.triggerCount(), 0);
  // The whole safety argument: a violent shake in the default mode fires nothing.
  CHECK_EQ(feedShake(d, 1000, 25, 9000, true), 0);
  CHECK_EQ(d.triggerCount(), 0);
}

static void testNormalNeverFires() {
  printf("NORMAL ignores any shake\n");
  DemoTrigger d;
  uint32_t t = 0;
  int fired = 0;
  // Ten seconds of violent shaking at 50 Hz, both sensors agreeing throughout.
  for (int i = 0; i < 500; i++, t += kStep) {
    const int32_t mag = (i % 2) ? 9000 : 200;
    if (d.feed(t, mag, (i % 7) == 0, true)) fired++;
  }
  CHECK_EQ(fired, 0);
  // But the peak is still tracked, so the display shows what it saw even in
  // NORMAL — the trace is for looking at, not only for triggering.
  CHECK_EQ(d.peakMagMg(), 9000);
}

// ---------------------------------------------------------------------------
// DEMO: both sensors must agree
// ---------------------------------------------------------------------------

static void testDemoFiresOnTwoSensorShake() {
  printf("DEMO fires when both sensors agree for the hold window\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  CHECK(d.enabled());

  d.feed(1000, 3000, true, true);
  d.feed(1020, 3000, true, true);
  CHECK_EQ(d.shakeRun(), 2);
  CHECK_EQ(d.triggerCount(), 0);

  // The third consecutive sample completes the 60 ms window.
  const bool fired = d.feed(1040, 3000, true, true);
  CHECK(fired);
  CHECK_EQ(d.triggerCount(), 1);
  // Rearmed from zero, not from one: a partially-primed counter would fire again
  // the instant the cooldown expired, from motion already counted.
  CHECK_EQ(d.shakeRun(), 0);
}

static void testDemoNeedsTheSwitch() {
  printf("DEMO does NOT fire on acceleration alone\n");
  // This is the rule that changed. DEMO used to let the accelerometer fire by
  // itself at 2.2 g, with the SW-420 as a shortcut, which meant a demo could
  // pass on a node with the vibration switch disconnected — exercising half the
  // hardware and proving nothing about the other half.
  DemoTrigger d;
  d.setMode(kModeDemo);
  CHECK_EQ(feedShake(d, 1000, 300, 9000, /*sw420=*/false), 0);
  CHECK_EQ(d.triggerCount(), 0);
  CHECK_EQ(d.shakeRun(), 0);
  // The peak is still tracked for the display.
  CHECK_EQ(d.peakMagMg(), 9000);
}

static void testDemoNeedsTheAccelerometer() {
  printf("DEMO does NOT fire on the switch alone\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  // A switch that chatters on a bench, with the node perfectly still.
  CHECK_EQ(feedShake(d, 1000, 300, 50, /*sw420=*/true), 0);
  CHECK_EQ(d.triggerCount(), 0);
}

static void testDemoPartialAgreementDoesNotAccumulate() {
  printf("alternating agreement never completes the window\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  // 6 s where the two sensors alternate: accel only, switch only, both, none.
  // If the run counter did not require both on the *same* sample it would fill
  // up and fire on evidence that never actually agreed.
  for (int i = 0; i < 300; i++) {
    const bool sw = (i % 4) >= 2;
    const int32_t mag = (i % 2) ? 4000 : 100;
    d.feed(1000 + static_cast<uint32_t>(i) * kStep, mag, sw, true);
  }
  CHECK_EQ(d.triggerCount(), 0);
  // The run never reached the hold window. Not necessarily zero at the end: the
  // final sample of the loop happens to have both sensors agreeing, so the
  // counter is legitimately 1. What matters is that it never got to 3.
  CHECK(d.shakeRun() < kDemoShakeHoldSamples);
}

static void testBothSensorsTogetherFire() {
  printf("both sensors fire at the lowest qualifying magnitude\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  // The lowest magnitude that counts, with the switch agreeing. There is no
  // single-sample shortcut any more: the hold window applies to both conditions.
  d.feed(1000, kDemoShakeMagMg, true, true);
  d.feed(1020, kDemoShakeMagMg, true, true);
  CHECK_EQ(d.triggerCount(), 0);
  CHECK(d.feed(1040, kDemoShakeMagMg, true, true));
  CHECK_EQ(d.triggerCount(), 1);
}

static void testBelowThresholdDoesNotFire() {
  printf("sub-threshold motion does not fire\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  // Switch agrees throughout, so the magnitude is the only thing holding it back.
  CHECK_EQ(feedShake(d, 1000, 25, kDemoShakeMagMg - 1, true), 0);
  CHECK_EQ(d.triggerCount(), 0);
}

// ---------------------------------------------------------------------------
// DIAGNOSTIC
// ---------------------------------------------------------------------------

static void testDiagNeverRaisesEvents() {
  printf("DIAGNOSTIC never raises an event, however hard it is shaken\n");
  DemoTrigger d;
  d.setMode(kModeDiag);
  CHECK(!d.enabled());
  CHECK(!modeCanRaiseEvents(kModeDiag));
  // A full minute of maximum shaking with both sensors agreeing.
  CHECK_EQ(feedShake(d, 1000, 3000, 9000, true), 0);
  CHECK_EQ(d.triggerCount(), 0);
  // But the evidence is still collected, because the DIAGNOSTIC screen shows it.
  CHECK_EQ(d.peakMagMg(), 9000);
}

static void testModeNamesAndEventPermission() {
  printf("mode names and which modes may raise events\n");
  CHECK(strcmp(runModeName(kModeNormal), "NORMAL") == 0);
  CHECK(strcmp(runModeName(kModeDemo), "DEMO") == 0);
  CHECK(strcmp(runModeName(kModeDiag), "DIAG") == 0);
  // Anything unknown reads as NORMAL, the mode where the node actually works.
  CHECK(strcmp(runModeName(7), "NORMAL") == 0);
  CHECK(strcmp(runModeName(200), "NORMAL") == 0);
  CHECK(modeCanRaiseEvents(kModeNormal));
  CHECK(modeCanRaiseEvents(kModeDemo));
  CHECK(!modeCanRaiseEvents(kModeDiag));
  CHECK(!modeCanRaiseEvents(99));
}

// ---------------------------------------------------------------------------
// Cooldown
// ---------------------------------------------------------------------------

static void testCooldownSuppressesRepeat() {
  printf("cooldown suppresses a re-trigger\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  uint32_t t = 1000;
  d.feed(t, 5000, true, true);
  d.feed(t += kStep, 5000, true, true);
  CHECK(d.feed(t += kStep, 5000, true, true));
  CHECK_EQ(d.triggerCount(), 1);

  // Keep shaking hard for well past the cooldown. Should fire again — but once
  // per cooldown, not once per sample.
  //
  // 300 samples is 6000 ms, comfortably past kDemoCooldownMs. The first attempt
  // at this test used 250 samples, which spans 249 * 20 ms = 4980 ms — twenty
  // milliseconds short of the cooldown, so it never fired a second time and the
  // test "failed" for a reason that had nothing to do with the code.
  int fired = 0;
  for (int i = 0; i < 300; i++, t += kStep) {
    if (d.feed(t, 5000, true, true)) fired++;
  }
  CHECK_EQ(fired, 1);
  CHECK_EQ(d.triggerCount(), 2);
}

static void testCooldownRemaining() {
  printf("cooldownRemaining reports time left\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  CHECK_EQ(d.cooldownRemaining(1000), 0);  // nothing fired yet: ready now
  d.feed(1000, 5000, true, true);
  d.feed(1020, 5000, true, true);
  d.feed(1040, 5000, true, true);
  // Straight after firing, the full cooldown is outstanding. Not zero: the
  // trigger has just been spent, so asking "when may I fire again" right now
  // must not answer "immediately" or the cooldown does not exist.
  CHECK_EQ(d.cooldownRemaining(1040), kDemoCooldownMs);
  CHECK_EQ(d.cooldownRemaining(1040 + kDemoCooldownMs / 2), kDemoCooldownMs / 2);
  CHECK_EQ(d.cooldownRemaining(1040 + kDemoCooldownMs), 0);
  CHECK_EQ(d.cooldownRemaining(1040 + kDemoCooldownMs + 1000), 0);
}

// ---------------------------------------------------------------------------
// Fault handling
// ---------------------------------------------------------------------------

static void testFaultySensorNeverFires() {
  printf("a sensor that is not answering never fires\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  // A dead bus reads back a constant. On its own that is not a shake, and
  // firing on it would look exactly like a sensor working perfectly.
  CHECK_EQ(feedShake(d, 1000, 100, 5000, true, /*sensorOk=*/false), 0);
  CHECK_EQ(d.triggerCount(), 0);
  CHECK_EQ(d.shakeRun(), 0);
  // The peak is still recorded, which is what the trace needs to show.
  CHECK_EQ(d.peakMagMg(), 5000);

  // And it recovers: the next healthy run can fire.
  uint32_t t = 4000;
  for (int i = 0; i < 3; i++, t += kStep) d.feed(t, 5000, true, true);
  CHECK_EQ(d.triggerCount(), 1);
}

static void testFaultClearsPartialRun() {
  printf("a fault mid-shake clears the partial run\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  d.feed(1000, 5000, true, true);
  d.feed(1020, 5000, true, true);
  CHECK_EQ(d.shakeRun(), 2);
  // Sensor drops out for one sample.
  d.feed(1040, 5000, true, false);
  CHECK_EQ(d.shakeRun(), 0);
  // Two more healthy samples must NOT complete a 3-sample window, because the
  // third sample of the original window was a fault and does not count.
  d.feed(1060, 5000, true, true);
  CHECK_EQ(d.triggerCount(), 0);
  d.feed(1080, 5000, true, true);
  CHECK(d.feed(1100, 5000, true, true));
  CHECK_EQ(d.triggerCount(), 1);
}

// ---------------------------------------------------------------------------
// Mode transitions
// ---------------------------------------------------------------------------

static void testModeChangeDiscardsPartialRun() {
  printf("switching mode discards a partial shake\n");
  DemoTrigger d;
  // Shake in NORMAL: nothing is armed, because NORMAL does not arm anything.
  d.feed(1000, 5000, true, true);
  d.feed(1020, 5000, true, true);
  CHECK_EQ(d.shakeRun(), 0);

  // Switch to DEMO. If a partial run survived, the next sample would fire on
  // motion that happened before DEMO existed.
  d.setMode(kModeDemo);
  CHECK(d.enabled());
  CHECK(!d.feed(1040, 5000, true, true));
  CHECK_EQ(d.triggerCount(), 0);
}

static void testUnknownModeIsNormal() {
  printf("an unrecognised mode is NORMAL, not undefined\n");
  DemoTrigger d;
  d.setMode(99);
  CHECK_EQ(d.mode(), kModeNormal);
  CHECK(!d.enabled());
  // NORMAL raises nothing at all, even with both sensors agreeing.
  CHECK_EQ(feedShake(d, 1000, 25, 9000, true), 0);
}

static void testResetStatsKeepsMode() {
  printf("RESET_STATS clears counts but keeps the mode\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  d.feed(1000, 5000, true, true);
  d.feed(1020, 5000, true, true);
  d.feed(1040, 5000, true, true);
  CHECK_EQ(d.triggerCount(), 1);
  d.resetStats();
  CHECK_EQ(d.triggerCount(), 0);
  CHECK_EQ(d.peakMagMg(), 0);
  CHECK(d.enabled());
  // A cleared trigger count means the cooldown is cleared too, so a reset node
  // can be shaken immediately.
  d.feed(2000, 5000, true, true);
  d.feed(2020, 5000, true, true);
  CHECK(d.feed(2040, 5000, true, true));
}

static void testResetAllReturnsToNormal() {
  printf("resetAll returns to NORMAL\n");
  DemoTrigger d;
  d.setMode(kModeDiag);
  d.feed(1000, 5000, true, true);
  d.feed(1020, 5000, true, true);
  d.feed(1040, 5000, true, true);
  d.resetAll();
  CHECK(!d.enabled());
  CHECK_EQ(d.triggerCount(), 0);
  CHECK_EQ(d.peakMagMg(), 0);
}

// ---------------------------------------------------------------------------

static void testSpeedIsIrrelevantInDemo() {
  printf("a demo fires at a standstill\n");
  DemoTrigger d;
  d.setMode(kModeDemo);
  // The production detector's speed gate needs 5 km/h, which nobody can produce
  // on a desk. The demo trigger has no speed input at all, by design: it is
  // watching magnitude and the switch, nothing else. This test exists to make
  // that explicit, because "demo does not work when stationary" is the first
  // thing someone would otherwise report as a bug.
  d.feed(1000, 4000, true, true);
  d.feed(1020, 4000, true, true);
  CHECK(d.feed(1040, 4000, true, true));
  CHECK_EQ(d.triggerCount(), 1);
}

int main() {
  testDefaultsToNormal();
  testNormalNeverFires();
  testDemoFiresOnTwoSensorShake();
  testDemoNeedsTheSwitch();
  testDemoNeedsTheAccelerometer();
  testDemoPartialAgreementDoesNotAccumulate();
  testDiagNeverRaisesEvents();
  testModeNamesAndEventPermission();
  testBelowThresholdDoesNotFire();
  testBothSensorsTogetherFire();
  testCooldownSuppressesRepeat();
  testCooldownRemaining();
  testFaultySensorNeverFires();
  testFaultClearsPartialRun();
  testModeChangeDiscardsPartialRun();
  testUnknownModeIsNormal();
  testResetStatsKeepsMode();
  testResetAllReturnsToNormal();
  testSpeedIsIrrelevantInDemo();

  printf("\n%d checks, %d failures\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
