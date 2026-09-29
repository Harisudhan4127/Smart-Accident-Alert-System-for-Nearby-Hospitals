// ui.h — OLED, LEDs, buzzer, SOS button.
//
// The UI is the only module allowed to be slow, and the only one that redraws
// unconditionally rather than on a change. Everything expensive is gated on a
// dirty flag, because the timing budget in docs §9 gives this task 5 ms per
// 100 ms and an SSD1306 full-frame push over I2C at 400 kHz costs ~25 ms. A
// naive redraw would blow the budget by 5x and starve the other core-0 tasks.
#pragma once

#include <stdint.h>
#include <string.h>

#include "config.h"
#include "protocol.h"
#include "sensordiag.h"  // Health, for the DIAGNOSTIC verdicts
#include "state_machine.h"

namespace saas {

/// A full-screen takeover announcement, animated.
///
/// The mode banner exists because a demo and a real crash are the same event on
/// the wire. A corner label that scrolls past is not enough: the moment that
/// matters is the half-second after someone shakes the node, and the answer to
/// "was that real?" has to be on the screen at that exact moment, not scrollable
/// back to.
///
/// So a banner owns the whole panel for its duration, is unreadable-by-mistake
/// (it inverts), and the caller does not have to remember to clear it — it
/// expires on its own.
enum class Banner : uint8_t {
  kNone,
  kModeDemo,    ///< "DEMO" — the node will now simulate on a two-sensor shake
  kModeDiag,    ///< "DIAG" — sensor health check, raises nothing
  kModeNormal,  ///< "NORMAL" — back to the real detector
  kSos,         ///< "SOS SENT" or "SOS IGNORED"
  kFault,       ///< "SENSOR FAULT"
  kCalibrated,  ///< "CALIBRATED"
};

/// Everything the UI needs to draw a frame. A plain struct so ui.cpp has no
/// dependency on the detector or the state machine's internals.
struct UiModel {
  uint8_t state;              ///< proto::State
  uint32_t uptimeMs;
  uint8_t batteryPct;         ///< 255 = unknown
  uint32_t batteryMv;
  bool charging;
  bool sw420;                 ///< debounced SW-420 level
  bool sosHeld;               ///< button currently down
  bool muted;                 ///< buzzer suppressed right now
  uint8_t score;              ///< live fused score
  uint8_t speedKmh;           ///< integer km/h, for the splash/calm screen
  int16_t tiltDeg;            ///< gravity vector off vertical
  bool sensorOk;
  bool accelPresent;
  bool calibrating;
  uint16_t calibProgressPct;
  bool eventUndelivered;      ///< red-LED flash per docs §8 step 5
  uint8_t queueDepth;
  int8_t bleClients;          ///< -1 = no client
  int8_t rssi;                ///< 0 = unknown
  bool flashTest;             ///< FLASH_TEST command: drive all outputs

  // --- live sensor readout -------------------------------------------------
  // The demo/inspection display. Raw, unfiltered axes on purpose — see
  // SensorPipeline::rawAxMg() for why the filtered values are the wrong thing to
  // look at when watching an impact go past.
  int16_t rawAxMg;             ///< unfiltered accelerometer X, milli-g
  int16_t rawAyMg;
  int16_t rawAzMg;
  int32_t rawMagMg;            ///< unfiltered |a|, milli-g
  uint32_t sampleCount;        ///< samples since boot; proves the task is alive

  // --- run mode ------------------------------------------------------------
  uint8_t runMode;             ///< saas::RunMode
  uint8_t demoShakeRun;        ///< samples currently above the shake threshold
  uint16_t demoTriggers;       ///< demo impacts fired this session
  uint32_t demoCooldownMs;     ///< ms until the next one is allowed
  int32_t demoPeakMagMg;       ///< largest magnitude seen this session
  uint16_t accelThresholdMg;   ///< drawn as a tick on the trace

  // --- DIAGNOSTIC mode verdicts -------------------------------------------
  // Only drawn in DIAGNOSTIC, but always computed: leaving them at their default
  // would mean the first frame after a mode switch shows "-- UNKNOWN" for every
  // sensor even though the evidence has been accumulating all along.
  Health diagAccel;
  Health diagSw420;
  Health diagBus;
  uint32_t diagReadFailures;   ///< consecutive failed reads
  uint32_t diagSwToggles;      ///< raw switch pin edges seen
};

class Ui {
 public:
  static Ui& instance();

  /// Probes the OLED. A missing display is not fatal: the firmware must still
  /// detect and alert over BLE with no screen attached.
  bool begin();

  bool oledOk() const { return oledOk_; }

  /// Call from uiTask. Redraws only when something visible changed.
  void loop(uint32_t nowMs, const UiModel& m);

  /// Takes over the display for [kBannerMs], then returns to the live screen.
  ///
  /// Re-entrant: calling it again restarts the animation, so a second shake
  /// restarts the confirmation rather than being swallowed by the tail of the
  /// first.
  void showBanner(Banner b);

  /// Append one magnitude to the rolling trace, milli-g.
  ///
  /// Called from the **sensor** task at the full 50 Hz sample rate, not from
  /// uiTask. That is the whole point: an impact peak is ~40 ms wide, and a trace
  /// fed at the 10 Hz redraw rate samples it once in five and draws a small
  /// bump for what was a 5 g event. A user shaking the node to see the display
  /// react would conclude the detector is broken.
  ///
  /// Single-producer (sensorTask) / single-consumer (uiTask) by design. The
  /// buffer is a power of two and the indices are only ever advanced by their
  /// own task, so no lock is needed: a torn read costs at most one column.
  void pushTrace(int32_t magMg);

  /// Drops the trace history, keeping the auto-scale. Bound to RESET_STATS.
  void clearTrace();

  /// The SOS button's debounced state, for the state machine. A short press is a
  /// rising edge; a long press is handled by the caller via sosLongPressed().
  void pollButton(uint32_t nowMs);
  bool buttonDown() const { return buttonDown_; }
  /// True exactly once per long press.
  bool sosLongPressed();
  /// ms the button has been held, for sosLongPressed's own comparison.
  uint32_t lastHeldMs() const { return lastHeldMs_; }
  /// True exactly once per press, so a tap cannot be counted twice.
  bool sosPressed();

  /// Non-blocking buzzer. `pattern` is a list of on/off half-periods, so the
  /// alarm can chirp without a task ever blocking on delay().
  void setPattern(const uint16_t* pattern, uint8_t len);
  void stopPattern();
  /// One-shot chirp, used to acknowledge a command.
  void chirp();

  void setLedGreen(bool on);
  void setLedRed(bool on);
  void setBuzzer(bool on);

  uint32_t redraws() const { return redraws_; }

 private:
  Ui() = default;
  void servicePattern(uint32_t nowMs);
  void drawHeader(const UiModel& m);
  /// Rows 3 and 4 in NORMAL/DEMO: one status line, one scale+link line.
  void drawRunRows(const UiModel& m);
  /// Rows 3 and 4 in DIAGNOSTIC: one verdict per sensor, and what to do about it.
  void drawDiagRows(const UiModel& m);
  void drawReadout(const UiModel& m);
  void drawTrace(const UiModel& m);
  /// Draws the animated full-screen banner if one is running. Returns true when
  /// it drew, so the caller skips the live screen entirely.
  bool drawBanner(uint32_t nowMs);
  /// Writes [mg] as exactly 5 characters, right-aligned, no sign padding.
  /// Returns the x position just past the text.
  uint8_t printG5(int32_t mg);

  bool oledOk_ = false;
  bool buttonDown_ = false;
  bool pressLatched_ = false;
  bool longLatched_ = false;
  bool longFired_ = false;
  /// Whether the press that just ended had been held long enough to be a hold.
  /// Set on release, and the guard that stops one gesture doing two things.
  bool heldLong_ = false;
  uint32_t buttonEdgeMs_ = 0;
  uint32_t pressStartMs_ = 0;
  uint32_t lastHeldMs_ = 0;

  bool green_ = false;
  bool red_ = false;
  bool buzzer_ = false;

  const uint16_t* pattern_ = nullptr;
  uint8_t patternLen_ = 0;
  uint8_t patternIdx_ = 0;
  bool patternOn_ = false;
  uint32_t nextStepMs_ = 0;

  // The live trace: a ring of magnitudes, written by sensorTask and drawn by
  // uiTask. See pushTrace() for the concurrency note.
  int16_t trace_[kTraceLen] = {0};
  volatile uint16_t traceHead_ = 0;  ///< next write, by the sensor task
  volatile uint16_t traceTail_ = 0;  ///< next read, by the UI task
  /// Largest magnitude currently in the trace, milli-g. Drives the vertical
  /// scale; never shrinks, so the bars do not twitch while being watched. The
  /// ceiling is printed on the display so the axis is never a mystery.
  int32_t traceCeilingMg_ = kTraceFloorMg;

  Banner banner_ = Banner::kNone;
  uint32_t bannerStartMs_ = 0;
  /// What the loop last drew, so the dirty check can tell "a new banner started"
  /// and "the banner advanced a frame" apart from "nothing happened".
  Banner lastBanner_ = Banner::kNone;
  uint8_t lastBannerFrame_ = 0;

  UiModel last_{};
  bool haveLast_ = false;
  uint32_t redraws_ = 0;
  uint32_t nextRedrawMs_ = 0;
};

/// The chirp pattern for a detector trip, and the confirm chirp. Static consts
/// so they outlive any Ui::setPattern call.
extern const uint16_t kPatternChirp[];
extern const uint16_t kPatternConfirm[];
extern const uint16_t kPatternAlarm[];
extern const uint16_t kPatternCount[];

}  // namespace saas
