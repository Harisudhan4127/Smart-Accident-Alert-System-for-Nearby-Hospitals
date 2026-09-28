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
#include "state_machine.h"

namespace saas {

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

  bool oledOk_ = false;
  bool buttonDown_ = false;
  bool pressLatched_ = false;
  bool longLatched_ = false;
  bool longFired_ = false;
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
