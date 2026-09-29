// sensordiag.h — per-sensor health verdicts for the DIAGNOSTIC mode.
//
// The question this answers is "is the sensor actually working?", and that is
// emphatically not the same question as "is the sensor answering I²C?". Those
// two come apart more often than anyone expects, and the gap is where bench
// time goes:
//
//   * An ADXL345 breakout with `VS` unconnected still acknowledges I2C — the bus
//     is held up by the regulator's standby rail — so `DEVID` reads 0xE5 and the
//     part looks present. The data registers read nothing. `|a|` sits at 0.1 g
//     instead of 1 g, which is the only honest evidence, and the only place to
//     check for it is a gravity test.
//   * A bus that has gone open freezes the last good sample, so every read
//     "succeeds" and the value never changes. A firmware that only counts I2C
//     errors sees a perfectly healthy sensor.
//   * An SW-420 that is wired backwards, or with the pot at an extreme, sits
//     quiet forever. The only way to know it works is for it to have toggled at
//     some point, which means someone has to tap it.
//
// So each sensor gets a verdict derived from what it has actually done, not from
// whether it was found. No Arduino dependency, so all of it is host-testable —
// which matters, because the cases above are the ones you cannot produce on
// purpose on a bench without a soldering iron.
#pragma once

#include <stdint.h>

#include "config.h"

namespace saas {

/// A sensor's verdict. Deliberately four-valued: a two-valued OK/not-OK makes
/// "present but unproven" indistinguishable from "broken", and those two need
/// different actions on a bench — one needs a tap, the other needs a new board.
enum class Health : uint8_t {
  kUnknown = 0,  ///< nothing observed yet
  kOk,           ///< observed behaving correctly
  kWarn,         ///< present and answering, but not yet proven
  kFail,         ///< present and provably wrong
};

/// Two characters for a Health, for the 128x64 display. Fixed width so a row of
/// three verdicts does not reflow as they change.
const char* healthTag(Health h);

/// Long form, for the serial monitor, where there is room to be specific.
const char* healthText(Health h);

/// Accumulates evidence about the two input sensors and produces verdicts.
///
/// Fed once per sample from the same place `DemoTrigger::feed` is. Stateless
/// with respect to time-of-day: every verdict is derived from what has been seen
/// since the last reset(), so "FAIL" always means "failed just now, or since you
/// last looked" and never a stale memory.
class SensorHealth {
 public:
  /// Clears all evidence. Returns every verdict to kUnknown. Bound to
  /// RESET_STATS and to entering DIAGNOSTIC, so a check is never answering with
  /// the previous check's results.
  void reset();

  /// One sample of evidence.
  ///
  /// `magMg`       unfiltered |a|, milli-g
  /// `sw420`       debounced switch level
  /// `sw420Level`  the *raw* pin level, pre-debounce, so a chattering switch is
  ///               visible as chatter rather than hidden by the debounce
  /// `sensorOk`    the acquisition read succeeded this sample
  /// `present`     the part was found at begin()
  void feed(uint32_t nowMs, int32_t magMg, bool sw420, bool sw420Level, bool sensorOk,
            bool present);

  // --- verdicts ----------------------------------------------------------

  /// The accelerometer.
  ///
  /// FAIL when absent, when reads are failing, or when gravity is missing for
  /// long enough that it cannot be a measurement. OK once it has shown gravity
  /// *and* moved at least once, because a sensor that only ever reports a
  /// constant cannot be distinguished from a stuck one.
  Health accel() const;

  /// The SW-420.
  ///
  /// OK once it has asserted at least once — that is the only proof the wiring and
  /// the pot are right. WARN before that, which is the honest state for a switch
  /// nobody has tapped yet. It is never FAIL: a switch that has not been tapped
  /// is not a broken switch.
  Health sw420() const;

  /// The I²C bus.
  Health bus() const;

  // --- the evidence behind the verdicts, for the display ------------------

  /// True once a gravity reading in a plausible range has been seen.
  bool sawGravity() const { return sawGravity_; }
  /// True once |a| has changed by more than the noise floor — i.e. the part is
  /// responding to being moved, not just returning a constant.
  bool sawMotion() const { return sawMotion_; }
  /// Milliseconds the magnitude has sat implausibly low.
  uint32_t noGravityMs() const { return noGravityMs_; }
  /// How many times the raw switch pin changed level.
  uint32_t sw420Toggles() const { return swToggles_; }
  /// Consecutive failed acquisition reads.
  uint32_t readFailures() const { return readFailures_; }
  /// Longest run of consecutive failed reads seen.
  uint32_t worstReadFailures() const { return worstReadFailures_; }
  /// The lowest |a| seen, milli-g. Zero on a node whose sensor is not powered.
  int32_t minMagMg() const { return minMagMg_; }
  /// The highest |a| seen, milli-g.
  int32_t maxMagMg() const { return maxMagMg_; }

  /// True when every sensor and the bus are OK — the one-line "this node is
  /// working" answer for the OLED.
  bool allOk() const { return accel() == Health::kOk && sw420() == Health::kOk && bus() == Health::kOk; }

 private:
  int32_t lastMagMg_ = 0;
  int32_t minMagMg_ = 0x7FFFFFFF;
  int32_t maxMagMg_ = -0x7FFFFFFF;
  bool haveMag_ = false;

  bool sawGravity_ = false;
  bool sawMotion_ = false;
  bool sawSw420_ = false;
  bool lastSwLevel_ = false;
  bool haveSwLevel_ = false;
  bool present_ = true;

  /// True once feed() has been called at least since the last reset. Without it
  /// the verdicts would have to guess about a sensor they have never observed,
  /// and "no evidence" would read as "probably fine" — which is the one answer a
  /// diagnostic must never give.
  bool haveEvidence_ = false;

  uint32_t swToggles_ = 0;
  uint32_t readFailures_ = 0;
  uint32_t worstReadFailures_ = 0;
  uint32_t noGravityMs_ = 0;
  uint32_t lastMs_ = 0;
  bool haveTime_ = false;
};

}  // namespace saas
