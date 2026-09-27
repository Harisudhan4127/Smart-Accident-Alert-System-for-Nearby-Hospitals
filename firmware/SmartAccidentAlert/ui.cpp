// ui.cpp — SSD1306 + outputs.
#include "ui.h"

#if defined(ARDUINO)
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Wire.h>

namespace saas {

// Half-periods, in ms. on/off/on/off...
const uint16_t kPatternChirp[] = {90, 120, 90};
const uint16_t kPatternConfirm[] = {60, 60, 60, 60, 200};
const uint16_t kPatternAlarm[] = {400, 200, 400, 1000};
const uint16_t kPatternCount[] = {40, 40, 40, 40};

namespace {
Adafruit_SSD1306 g_oled(128, 64, &Wire, -1);
constexpr uint8_t kRedrawMinMs = 200;  ///< 5 Hz: fast enough to feel live, slow enough to fit the budget
}  // namespace

Ui& Ui::instance() {
  static Ui u;
  return u;
}

bool Ui::begin() {
  pinMode(kPinLedGreen, OUTPUT);
  pinMode(kPinLedRed, OUTPUT);
  pinMode(kPinBuzzer, OUTPUT);
  pinMode(kPinSosButton, INPUT_PULLUP);
  digitalWrite(kPinLedGreen, kLedActiveHigh ? LOW : HIGH);
  digitalWrite(kPinLedRed, kLedActiveHigh ? LOW : HIGH);
  digitalWrite(kPinBuzzer, kBuzzerActiveLow ? HIGH : LOW);

  // A missing OLED is survivable: BLE still carries every alert, and the LEDs
  // and buzzer still work. Failing the whole boot over a detached ribbon cable
  // would turn a cosmetic problem into a safety one.
  if (!g_oled.begin(SSD1306_SWITCHCAPVCC, kOledAddr)) return false;
  g_oled.cp437(true);
  g_oled.clearDisplay();
  g_oled.display();
  oledOk_ = true;
  if (!oledOk_) {
    g_oled.dim(true);  // no such panel: leave it dark rather than driving a blank bus
    return false;
  }
  g_oled.setTextColor(SSD1306_WHITE);
  g_oled.setTextSize(1);
  g_oled.clearDisplay();
  g_oled.setCursor(0, 0);
  g_oled.print(F("SAAS node booting"));
  g_oled.display();
  return true;
}

void Ui::pollButton(uint32_t nowMs) {
  // Active low with an internal pull-up: pressed reads LOW.
  const bool down = digitalRead(kPinSosButton) == (kSosButtonActiveLow ? LOW : HIGH);
  if (down == buttonDown_) return;
  if (nowMs - buttonEdgeMs_ < kSosDebounceMs) return;
  buttonEdgeMs_ = nowMs;
  buttonDown_ = down;
  if (down) lastHeldMs_ = nowMs;
  if (down) {
    pressStartMs_ = nowMs;
    longFired_ = false;
  } else {
    longLatched_ = false;
  }
}

bool Ui::sosPressed() {
  // A press only counts once the button is released, so holding the button does
  // not fire MANUAL_SOS on every uiTask tick.
  if (buttonDown_ || pressLatched_) return false;
  pressLatched_ = true;
  return true;
}

bool Ui::sosLongPressed() {
  if (!buttonDown_ || longLatched_ || longFired_) return false;
  if (lastHeldMs() - pressStartMs_ < kSosLongPressMs) return false;
  longLatched_ = true;
  longFired_ = true;
  return true;
}

void Ui::setPattern(const uint16_t* pattern, uint8_t len) {
  pattern_ = pattern;
  patternLen_ = len;
  patternIdx_ = 0;
  patternOn_ = true;
  nextStepMs_ = 0;  // first half-period starts now
  servicePattern(0);
}

void Ui::stopPattern() {
  pattern_ = nullptr;
  patternLen_ = 0;
  setBuzzer(false);
}

void Ui::chirp() { setPattern(kPatternChirp, 3); }

void Ui::servicePattern(uint32_t nowMs) {
  if (!pattern_ || !patternLen_) return;
  if (nowMs < nextStepMs_) return;
  const uint16_t half = pattern_[patternIdx_];
  setBuzzer(patternOn_);
  patternOn_ = !patternOn_;
  patternIdx_ = static_cast<uint8_t>((patternIdx_ + 1) % patternLen_);
  nextStepMs_ = nowMs + half;
}

void Ui::setLedGreen(bool on) { green_ = on; }
void Ui::setLedRed(bool on) { red_ = on; }
void Ui::setBuzzer(bool on) { buzzer_ = on; }

void Ui::loop(uint32_t nowMs, const UiModel& m) {
  pollButton(nowMs);
  servicePattern(nowMs);

  // The undelivered-event flash has to keep running even when nothing else
  // changed, so it is exempt from the dirty check.
  const bool flashing = m.eventUndelivered;
  const bool changed = !haveLast_ ||
                       memcmp(&m, &last_, sizeof(m)) != 0 ||
                       (flashing && (nowMs / kQueuedEventBlinkMs) != (last_.uptimeMs / kQueuedEventBlinkMs));
  if (!changed) return;
  if (nowMs < nextRedrawMs_) return;
  nextRedrawMs_ = nowMs + kRedrawMinMs;
  last_ = m;
  haveLast_ = true;
  redraws_++;

  if (m.flashTest) {
    setLedGreen(true);
    setLedRed(true);
    setBuzzer(true);
  } else {
    // Green: armed and healthy. Red: alarming, faulted, or holding an event the
    // phone never acknowledged.
    setLedGreen(m.state == proto::kStateIdle && m.sensorOk && !m.eventUndelivered);
    setLedRed(m.state == proto::kStateAlarm || m.state == proto::kStateFault || m.eventUndelivered ||
              !m.sensorOk);
  }

  if (!oledOk_) return;

  g_oled.clearDisplay();
  g_oled.setCursor(0, 0);
  g_oled.print(proto::stateName(m.state));

  if (m.calibrating) {
    g_oled.setCursor(0, 16);
    g_oled.print(F("calibrating "));
    g_oled.print(m.calibProgressPct);
    g_oled.print('%');
  } else if (m.state == proto::kStateAlarm) {
    g_oled.setCursor(0, 16);
    g_oled.print(F("ALARM  score "));
    g_oled.print(m.score);
  } else {
    g_oled.setCursor(0, 16);
    g_oled.print(m.speedKmh);
    g_oled.print(F(" km/h  tilt "));
    g_oled.print(m.tiltDeg);
    g_oled.print('*');
  }

  g_oled.setCursor(0, 32);
  g_oled.print(F("bat "));
  if (m.batteryPct == 255) g_oled.print(F("--"));
  else g_oled.print(m.batteryPct);
  g_oled.print('%');
  if (m.charging) g_oled.print(F(" CHG"));
  if (m.muted) g_oled.print(F(" mute"));

  g_oled.setCursor(0, 48);
  g_oled.print(F("sw"));
  g_oled.print(m.sw420 ? F("1") : F("0"));
  g_oled.print(F(" q"));
  g_oled.print(m.queueDepth);
  g_oled.print(F(" c"));
  char num[6];
  if (m.bleClients < 0) {
    g_oled.print('-');
  } else {
    snprintf(num, sizeof(num), "%u", static_cast<unsigned>(m.bleClients));
    g_oled.print(num);
  }
  if (m.eventUndelivered) g_oled.print(F(" UNDEL"));
  if (!m.sensorOk) g_oled.print(F(" SENSOR"));
  if (!m.mpuPresent) g_oled.print(F(" NOMP"));

  g_oled.display();
}

}  // namespace saas

#else
namespace saas {
Ui& Ui::instance() {
  static Ui u;
  return u;
}
bool Ui::begin() { return false; }
void Ui::loop(uint32_t, const UiModel&) {}
void Ui::pollButton(uint32_t) {}
bool Ui::sosPressed() { return false; }
bool Ui::sosLongPressed() { return false; }
void Ui::setPattern(const uint16_t*, uint8_t) {}
void Ui::stopPattern() {}
void Ui::chirp() {}
void Ui::setLedGreen(bool) {}
void Ui::setLedRed(bool) {}
void Ui::setBuzzer(bool) {}
}  // namespace saas
#endif
