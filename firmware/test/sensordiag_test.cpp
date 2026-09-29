// sensordiag_test.cpp — host tests for the DIAGNOSTIC verdicts.
//
// The cases here are the ones that cost the most bench time when they are wrong,
// and that cannot be produced on purpose without a soldering iron:
//
//   * an ADXL345 with VS unconnected, which answers I2C and reads ~0.1 g
//   * a bus that has gone open, so every read "succeeds" and the value never
//     changes
//   * an SW-420 that has simply never been tapped
//
// The first two are the whole reason this module exists, and neither is visible
// to a firmware that only counts I2C errors.
//
// Build/run: `make test-firmware-host` from the repository root.

#include <stdio.h>
#include <string.h>

#include "sensordiag.h"

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

/// Equality on longs, so `Health` (a scoped enum) and `size_t` both compare
/// without a cast at every call site.
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

/// Feeds a still node reading `magMg` for `count` samples, with the switch at
/// `sw420` and every read succeeding.
static void feedStill(SensorHealth& h, uint32_t t0, uint32_t count, int32_t magMg,
                      bool sw420 = false) {
  for (uint32_t i = 0; i < count; i++) {
    h.feed(t0 + i * kStep, magMg, sw420, sw420, true, true);
  }
}

/// Feeds a node that is jiggling around `baseMg` by +/- 200 mg, which is what a
/// real one on a desk does. This is what satisfies the "has it moved" test.
static void feedJiggle(SensorHealth& h, uint32_t t0, uint32_t count, int32_t baseMg) {
  for (uint32_t i = 0; i < count; i++) {
    const int32_t mag = baseMg + ((i % 2) ? 200 : -200);
    h.feed(t0 + i * kStep, mag, false, false, true, true);
  }
}

static void testHealthyNodeIsAllOk() {
  printf("a healthy, tapped, jiggling node is all OK\n");
  SensorHealth h;
  feedJiggle(h, 1000, 200, 1000);
  h.feed(1000 + 200 * kStep, 1200, true, true, true, true);  // tap the switch
  CHECK(h.accel() == Health::kOk);
  CHECK(h.sw420() == Health::kOk);
  CHECK(h.bus() == Health::kOk);
  CHECK(h.allOk());
  CHECK(h.sawGravity());
  CHECK(h.sawMotion());
  CHECK_EQ(h.sw420Toggles(), 1);
}

static void testUnpoweredAccelerometerFails() {
  printf("a part that answers I2C but is not powered FAILS\n");
  // The case this module exists for. The node is "present", every read succeeds,
  // DEVID is valid — and |a| sits at 0.1 g forever, because VS is unconnected and
  // the data registers read nothing. A firmware that only counts bus errors sees
  // a perfect sensor here.
  SensorHealth h;
  feedStill(h, 1000, 300, 117);  // 6 s of 0.117 g
  CHECK_EQ(h.accel(), (long)Health::kFail);
  CHECK_EQ(h.bus(), (long)Health::kOk);  // the bus really is fine
  // The evidence is retained so the display can say *why*.
  CHECK(!h.sawGravity());
  CHECK(h.noGravityMs() >= kDiagNoGravityMs);
  CHECK_EQ(h.minMagMg(), 117);
  CHECK_EQ(h.maxMagMg(), 117);
}

static void testAbsentAccelerometerFails() {
  printf("an absent part FAILS immediately\n");
  SensorHealth h;
  for (int i = 0; i < 5; i++) h.feed(1000 + i * kStep, 1000, false, false, true, /*present=*/false);
  CHECK_EQ(h.accel(), (long)Health::kFail);
  CHECK_EQ(h.bus(), (long)Health::kFail);
  CHECK(!h.allOk());
}

static void testFailingReadsFail() {
  printf("consecutive read failures FAIL the sensor and the bus\n");
  SensorHealth h;
  feedJiggle(h, 1000, 50, 1000);
  CHECK(h.accel() == Health::kOk);
  // Now the bus goes away entirely.
  for (int i = 0; i < 40; i++) {
    h.feed(2000 + i * kStep, 0, false, false, /*sensorOk=*/false, true);
  }
  CHECK_EQ(h.accel(), (long)Health::kFail);
  CHECK_EQ(h.bus(), (long)Health::kFail);
  CHECK(h.readFailures() >= kDiagFailReads);
  CHECK_EQ(h.worstReadFailures(), (long)h.readFailures());
}

static void testFrozenBusIsCaughtByMotionTest() {
  printf("a frozen value is caught even though every read succeeds\n");
  // The other case the module exists for. The bus has gone open but the I2C
  // transactions still complete, so readFailures_ stays at 0 and a bus-error
  // count sees nothing. What gives it away is that |a| never changes: a real
  // accelerometer on a desk jitters by tens of milli-g, this one is bit-identical
  // for six seconds.
  //
  // A *constant* 1000 mg is also a valid gravity reading, so gravity alone cannot
  // catch this — which is why sawMotion() is checked separately.
  SensorHealth h;
  feedStill(h, 1000, 300, 1000);
  CHECK_EQ(h.readFailures(), 0);          // the bus reports no errors at all
  CHECK(h.sawGravity());                   // and the magnitude looks perfect
  CHECK(!h.sawMotion());                   // but it has never once moved
  CHECK_EQ(h.accel(), (long)Health::kWarn);
  CHECK(h.minMagMg() == h.maxMagMg());
  // And a jiggling one at the same magnitude is fine, which is what proves the
  // test is measuring motion rather than just magnitude.
  SensorHealth g;
  feedJiggle(g, 1000, 300, 1000);
  CHECK(g.sawMotion());
  CHECK_EQ(g.accel(), (long)Health::kOk);
}

static void testUntappedSwitchIsWarnNotFail() {
  printf("an untapped SW-420 is UNPROVEN, not broken\n");
  // A switch nobody has tapped is not a faulty switch. Calling it FAIL would
  // make a correctly wired node look broken until someone happened to knock it,
  // which is the opposite of what a diagnostic is for — and would train people to
  // ignore the display.
  SensorHealth h;
  feedJiggle(h, 1000, 200, 1000);
  CHECK_EQ(h.sw420(), (long)Health::kWarn);
  CHECK(!h.allOk());
  CHECK_EQ(h.accel(), (long)Health::kOk);
  // One tap and it is proven.
  h.feed(6000, 1100, true, true, true, true);
  CHECK_EQ(h.sw420(), (long)Health::kOk);
  CHECK(h.allOk());
}

static void testSwitchChatterIsCounted() {
  printf("raw switch edges are counted before the debounce\n");
  // The debounce hides chatter from the detector, which is right for detection
  // and wrong for diagnosis: a switch chattering 50 times a second is a wiring
  // fault, and it must be visible here. So the *raw* pin level is fed in
  // alongside the debounced one.
  SensorHealth h;
  feedJiggle(h, 1000, 200, 1000);
  CHECK_EQ(h.sw420Toggles(), 0);
  for (int i = 0; i < 50; i++) h.feed(6000 + i * kStep, 1000, false, (i % 2) == 0, true, true);
  CHECK_EQ(h.sw420Toggles(), 50);
  CHECK_EQ(h.sw420(), (long)Health::kWarn);  // chatter is not an assertion
}

static void testResetClearsEvidence() {
  printf("reset returns every verdict to UNKNOWN\n");
  // Entering DIAGNOSTIC resets, so a check can never answer with the previous
  // check's results — which would be the most confusing possible diagnostic
  // output: a node fixed five minutes ago still reporting the old failure.
  SensorHealth h;
  feedStill(h, 1000, 300, 117);
  CHECK_EQ(h.accel(), (long)Health::kFail);
  h.reset();
  CHECK_EQ(h.accel(), (long)Health::kUnknown);
  CHECK_EQ(h.sw420(), (long)Health::kUnknown);
  CHECK_EQ(h.bus(), (long)Health::kUnknown);
  CHECK_EQ(h.noGravityMs(), 0);
  CHECK(!h.sawGravity());
  CHECK(!h.allOk());
}

static void testFreeFallIsWarnNotFail() {
  printf("a node genuinely in free fall is UNPROVEN, not failed\n");
  // A free-fall window reads near zero on every axis — the same signature as an
  // unpowered part. The difference is duration, which is why the failure
  // threshold is a time and not a magnitude. 1 s of zero is not yet FAIL.
  SensorHealth h;
  feedStill(h, 1000, 50, 0);  // 1 s
  CHECK_EQ(h.accel(), (long)Health::kWarn);
  CHECK(h.noGravityMs() < kDiagNoGravityMs);
}

static void testTagsAreTwoCharacters() {
  printf("verdict tags are fixed width\n");
  // They share a display row with other fields, so a tag that changed width
  // would reflow the row as verdicts change.
  CHECK(strlen(healthTag(Health::kOk)) == 2);
  CHECK(strlen(healthTag(Health::kWarn)) == 2);
  CHECK(strlen(healthTag(Health::kFail)) == 2);
  CHECK(strlen(healthTag(Health::kUnknown)) == 2);
  CHECK(strcmp(healthTag(Health::kOk), "OK") == 0);
  CHECK(strcmp(healthTag(Health::kFail), "XX") == 0);
  // The long forms exist for the serial monitor and are not width-constrained.
  CHECK(strcmp(healthText(Health::kWarn), "UNPROVEN") == 0);
}

int main() {
  testHealthyNodeIsAllOk();
  testUnpoweredAccelerometerFails();
  testAbsentAccelerometerFails();
  testFailingReadsFail();
  testFrozenBusIsCaughtByMotionTest();
  testUntappedSwitchIsWarnNotFail();
  testSwitchChatterIsCounted();
  testResetClearsEvidence();
  testFreeFallIsWarnNotFail();
  testTagsAreTwoCharacters();
  printf("\n%d checks, %d failures\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
