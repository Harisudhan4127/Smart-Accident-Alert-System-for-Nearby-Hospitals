// scale_test.cpp — host tests for the ADXL345 raw->milli-g conversion.
//
// This exists because the scale was wrong once and nothing caught it. The
// firmware was configured for +/-16 g and scaled the output with the +/-2 g
// factor, so every reading was 8x too small: a node lying still reported
// 0.12 g instead of 0.94 g. Nothing in the suite objected, because every detector
// threshold is far above 0.12 g — the node simply never scored, which looks
// exactly like a healthy idle node on a display.
//
// The tests below pin the two facts that must stay true:
//   1 g is 1 g, 16 g is 16 g, and the conversion is symmetric about zero.

#include <stdio.h>

#include "sensors.h"

using saas::SensorPipeline;

static int g_fail = 0;
static int g_checks = 0;

static int32_t mg(int16_t raw) { return SensorPipeline::accelMg(raw); }

#define CHECK(cond)                                                \
  do {                                                             \
    g_checks++;                                                    \
    if (!(cond)) {                                                 \
      g_fail++;                                                    \
      printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);     \
    }                                                              \
  } while (0)

/// Allow tolMg of slack, for the integer division at the end of the conversion.
#define CHECK_NEAR(what, got, want, tolMg)                                    \
  do {                                                                        \
    g_checks++;                                                               \
    const int32_t g_ = (got);                                                 \
    const int32_t w_ = (want);                                                \
    const int32_t d_ = g_ > w_ ? g_ - w_ : w_ - g_;                          \
    if (d_ > (tolMg)) {                                                       \
      g_fail++;                                                               \
      printf("  FAIL %s:%d  %s = %d, want %d +/- %d\n", __FILE__, __LINE__,  \
             what, (int)g_, (int)w_, (int)(tolMg));                           \
    }                                                                         \
  } while (0)

static void testOneGramIsOneGram() {
  printf("1 g reads as 1 g\n");
  // 1 g at +/-16 g is 1000/31.2 = 32.05 counts, left-justified in a 16-bit
  // register. This returned 124 mg before the scale fix.
  const int16_t kRaw1G = (int16_t)(32 << 3);
  CHECK_NEAR("1 g", mg(kRaw1G), 1000, 5);
  CHECK_NEAR("-1 g", mg((int16_t)-kRaw1G), -1000, 5);
}

static void testFullScale() {
  printf("full scale is +/-16 g\n");
  // The 13-bit data word is two's complement, so its range is -4096..4095: 512
  // negative codes and 511 positive ones. That is a property of the part's
  // register, not of the conversion, and it shows up as one LSB of asymmetry at
  // the very top of the range.
  //
  // 511 counts x 31.2 mg = 15943 mg. An earlier version of this test asserted
  // 15974 — the number you get by reading "1024 counts" off the datasheet
  // without noticing the register is 13 bits — and failed. That was the test
  // being wrong, not the firmware.
  CHECK_NEAR("max", mg(4095), 15943, 2);
  CHECK_NEAR("-max", mg((int16_t)-4096), -15974, 2);

  // One LSB at +/-16 g is 0.031 g. Bound the asymmetry by that, so a real
  // regression — mishandled sign, say — still trips this.
  const int32_t neg = mg((int16_t)-4096);
  const int32_t asym = (neg < 0 ? -neg : neg) - mg(4095);
  CHECK_NEAR("extremes asymmetry", asym, 31, 1);

  // The point of the whole exercise: the +/-2 g factor this firmware must NOT
  // use would have given 2039 mg at the top of the range instead of ~15943.
  CHECK(mg(4095) > 15000);
}

static void testSymmetry() {
  printf("symmetric about zero\n");
  // An asymmetric conversion means the sign bit is being mishandled, which
  // silently inverts whichever axis carries gravity on a face-down mount.
  bool ok = true;
  for (int c = 1; c <= 1000; c += 37) {
    const int32_t pos = mg((int16_t)(c << 3));
    const int32_t ngt = mg((int16_t)(-(c << 3)));
    if (pos != -ngt) {
      ok = false;
      printf("  FAIL asymmetry at %d counts: %d vs %d\n", c, pos, ngt);
      break;
    }
  }
  g_checks++;
  if (!ok) g_fail++;
}

static void testPaddingBitsAreIgnored() {
  printf("the 3 padding bits do not change the reading\n");
  // The register holds 13 significant bits left-justified, so the low 3 bits are
  // padding. 256 and 259 are the same 1 g; if the shift were missing they would
  // differ by three counts — 117 mg, plainly visible on the display.
  const int32_t base = mg(256);
  bool ok = true;
  for (int16_t lo = 0; lo < 8; lo++) {
    if (mg((int16_t)(256 | lo)) != base) {
      ok = false;
      printf("  FAIL padding bit %d changed the reading: %d vs %d\n", lo,
             mg((int16_t)(256 | lo)), base);
      break;
    }
  }
  g_checks++;
  if (!ok) g_fail++;
}

static void testMonotonic() {
  printf("monotonic across the positive range\n");
  int32_t prev = mg(0);
  bool ok = true;
  for (int16_t r = 8; r < 4096; r = (int16_t)(r + 8)) {
    const int32_t v = mg(r);
    if (v < prev) {
      ok = false;
      printf("  FAIL not monotonic at raw=%d: %d after %d\n", r, v, prev);
      break;
    }
    prev = v;
  }
  g_checks++;
  if (!ok) g_fail++;
}

static void testZero() {
  printf("zero maps to zero\n");
  CHECK(mg(0) == 0);
}

int main() {
  testOneGramIsOneGram();
  testFullScale();
  testSymmetry();
  testPaddingBitsAreIgnored();
  testMonotonic();
  testZero();
  printf("\n%d checks, %d failures\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
