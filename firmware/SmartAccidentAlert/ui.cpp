// ui.cpp — SSD1306 + outputs.
#include "ui.h"

#include "sensordiag.h"  // Health, for the DIAGNOSTIC verdicts

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
constexpr uint16_t kRedrawMinMs = 200;  ///< 5 Hz in NORMAL; kDemoRedrawMs is the DEMO rate

// The display is 128x64 with a 6x8 font: 21 columns, 8 pixel line pitch.
constexpr int8_t kCols = 21;
constexpr int8_t kTextLeft = 0;
constexpr int8_t kTextRight = 126;   ///< last x a character can start at and fit

/// Width in pixels of [text] at the given text size.
///
/// Adafruit_GFX 1.12.6 has no textWidth(), and adding one is not the point — the
/// built-in SSD1306 font is a fixed 5x7 glyph in a 6x8 cell, scaled by
/// setTextSize, so width is exactly 6 * size per character and no measurement is
/// needed. (The CP437 font enabled by cp437(true) uses the same 6x8 cell.)
int16_t textWidthPx(const char* text, uint8_t size) {
  int16_t w = 0;
  for (const char* p = text; *p; ++p) w += 6 * size;
  return w;
}

// Panel layout. Five text rows on an 8 px pitch occupy y = 0..39, so the trace
// takes y = 40..61: 22 px.
//
// The trace once started at y=36, which drew the first four rows of bars straight
// through the bottom two text lines — the graph was unreadable and the flags were
// unreadable, and both looked like a rendering fault rather than an overlap.
//
// 120 px wide leaves a 4 px gutter at each end so the newest sample is visibly
// "the edge" rather than touching the bezel.
constexpr int8_t kTraceLeft = 4;
constexpr int8_t kTraceWidth = 120;
constexpr int8_t kTraceTop = 40;
constexpr int8_t kTraceHeight = 22;   ///< 40..61, leaving 2 px at the bottom
}  // namespace

void Ui::pushTrace(int32_t magMg) {
  // Clamp rather than wrap: a spike beyond int16 would otherwise land as a
  // negative and draw a floor instead of a ceiling, which is the one artefact
  // that would make a real impact look like a sensor fault.
  int32_t clamped = magMg;
  if (clamped < 0) clamped = 0;
  if (clamped > 32767) clamped = 32767;
  trace_[traceHead_ & kTraceMask] = static_cast<int16_t>(clamped);
  traceHead_ = static_cast<uint16_t>((traceHead_ + 1) & kTraceMask);
  if (magMg > traceCeilingMg_) traceCeilingMg_ = magMg;
}

void Ui::clearTrace() {
  traceHead_ = 0;
  traceTail_ = 0;
  traceCeilingMg_ = kTraceFloorMg;
}

void Ui::showBanner(Banner b) {
  // Restart rather than ignore a second request: someone shaking the node twice
  // should see the confirmation twice, not have the second one swallowed by the
  // tail of the first.
  banner_ = b;
  bannerStartMs_ = millis();
}

/// Writes [mg] as exactly 5 characters, right-aligned, and returns the x after.
///
/// Exists because the obvious `print(mg / 1000.0, 2)` has no width guarantee, and
/// this display has 21 columns and no scrollbar. At +/-16 g a value can be
/// "-15.99" — six characters — so the three-axis line came to 24 and ran off the
/// right edge of the panel, silently truncating Z. The whole row has a hard
/// budget, so every value on it is written through here.
///
/// Two decimals below 10 g, one above: the detector's free-fall floor is 300 mg
/// and its severity knee is 6 g, so the interesting resolution is all inside the
/// 2-decimal range.
uint8_t Ui::printG5(int32_t mg) {
  const int32_t tenths = mg / 100;  // 0.1 g units
  char buf[8];
  if (tenths > -100 && tenths < 100) {
    snprintf(buf, sizeof(buf), "%5.2f", mg / 1000.0);
  } else {
    snprintf(buf, sizeof(buf), "%5.1f", mg / 1000.0);
  }
  g_oled.print(buf);
  return static_cast<uint8_t>(g_oled.getCursorX());
}

bool Ui::drawBanner(uint32_t nowMs) {
  if (banner_ == Banner::kNone) return false;
  const uint32_t age = nowMs - bannerStartMs_;
  if (age >= kBannerMs) {
    banner_ = Banner::kNone;
    return false;
  }

  const char* title = "";
  const char* sub = "";
  switch (banner_) {
    case Banner::kModeDemo:   title = "DEMO";    sub = "shake = simulated"; break;
    case Banner::kModeDiag:   title = "DIAG";    sub = "sensor check";      break;
    case Banner::kModeNormal: title = "NORMAL";  sub = "real detection";     break;
    case Banner::kSos:        title = "SOS";     sub = "alert sent";         break;
    case Banner::kFault:      title = "FAULT";   sub = "sensor not ok";      break;
    case Banner::kCalibrated: title = "READY";   sub = "calibrated";         break;
    default: break;
  }

  // Frame counter, so the animation is a function of time and not of how often
  // the redraw happens to fire.
  const uint8_t frame = static_cast<uint8_t>((age * kBannerFrames) / kBannerMs);
  const uint8_t step = frame + 1;

  // 1. A border that closes in from the edges over the first frames. It is the
  //    motion; the text alone on a blank panel does not read as an event.
  //    Margin shrinks 10 px per frame, so frame 5 is a full-panel box.
  const int8_t margin = static_cast<int8_t>(10 - 2 * step);
  if (margin > 0) {
    g_oled.drawRect(margin, margin,
                    static_cast<int16_t>(128 - 2 * margin),
                    static_cast<int16_t>(64 - 2 * margin), SSD1306_WHITE);
  } else {
    g_oled.drawRect(0, 0, 128, 64, SSD1306_WHITE);
  }

  // 2. Title, centred, at 2x so it is unmistakable. `textWidth` is measured at
  //    the size actually used — measuring at size 1 and drawing at 2 centres
  //    something visibly left of middle.
  g_oled.setTextSize(2);
  const int16_t tw = textWidthPx(title, 2);
  g_oled.setCursor(static_cast<int16_t>((128 - tw) / 2), 16);
  g_oled.print(title);
  g_oled.setTextSize(1);

  // 3. Subtitle, centred. Skipped on the first frame so the two do not appear
  //    as one block of text.
  if (step >= 3) {
    const int16_t sw = textWidthPx(sub, 1);
    g_oled.setCursor(static_cast<int16_t>((128 - sw) / 2), 38);
    g_oled.print(sub);
  }

  // 4. A progress rule along the bottom that fills as the banner runs, so the
  //    time remaining is visible and the banner visibly ends rather than
  //    vanishing.
  const int16_t w = static_cast<int16_t>((128 * step) / kBannerFrames);
  g_oled.drawFastHLine(0, 62, w, SSD1306_WHITE);

  // 5. Invert the whole panel on the final frame. A full inversion is the one
  //    thing a 1-bit panel can do that no amount of text can imitate, and it is
  //    what makes this readable as an announcement across a room.
  if (step >= kBannerFrames) {
    g_oled.invertDisplay(true);
    g_oled.display();
    g_oled.invertDisplay(false);
  }
  return true;
}

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
  if (down != buttonDown_) {
    if (nowMs - buttonEdgeMs_ < kSosDebounceMs) return;  // still chattering
    buttonEdgeMs_ = nowMs;
    buttonDown_ = down;
    if (down) {
      // New press.
      pressStartMs_ = nowMs;
      lastHeldMs_ = nowMs;
      longFired_ = false;
      longLatched_ = false;
      pressLatched_ = false;
    } else {
      // Release. The hold-vs-click decision is made here, once, from how long
      // the button was actually down — and recorded, so a long press cannot
      // *also* be delivered as a click on the way out.
      heldLong_ = (lastHeldMs_ - pressStartMs_) >= kSosHoldMs;
    }
  } else if (down) {
    lastHeldMs_ = nowMs;
  }
}

bool Ui::sosPressed() {
  // A click: the button is up, it had been down, and it was released before the
  // hold threshold. Latched so one press is one event across the uiTask ticks
  // that the release edge happens to span.
  //
  // The `heldLong_` guard is the whole point. Without it a press held for 2 s
  // fires SOS on the way down *and* a mode click on the way up — one gesture,
  // two unrelated actions, and the second one happening after the buzzer has
  // already started, which is exactly when nobody is looking at the screen.
  if (buttonDown_ || pressLatched_ || heldLong_) return false;
  pressLatched_ = true;
  return true;
}

bool Ui::sosLongPressed() {
  if (!buttonDown_ || longLatched_ || longFired_) return false;
  if (lastHeldMs_ - pressStartMs_ < kSosHoldMs) return false;
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

  // Two things have to keep running even when nothing in UiModel changed: the
  // undelivered-event flash, and a running banner. The banner is exempt for a
  // different reason — it is an animation, so "nothing changed" is precisely the
  // condition under which it still has to advance.
  const bool flashing = m.eventUndelivered;
  const bool bannerRunning = (banner_ != Banner::kNone);
  const uint8_t bannerFrame =
      bannerRunning ? static_cast<uint8_t>(((nowMs - bannerStartMs_) * kBannerFrames) / kBannerMs) : 0;
  const uint8_t lastBannerFrame =
      (lastBanner_ != Banner::kNone) ? lastBannerFrame_ : 0xFF;
  const bool changed = !haveLast_ ||
                       memcmp(&m, &last_, sizeof(m)) != 0 ||
                       (flashing && (nowMs / kQueuedEventBlinkMs) != (last_.uptimeMs / kQueuedEventBlinkMs)) ||
                       (bannerRunning && (banner_ != lastBanner_ || bannerFrame != lastBannerFrame));
  if (!changed) return;
  // DEMO redraws twice as often. The screen exists to be watched in DEMO, and
  // 10 Hz is where numbers stop looking like a stopwatch. It is not free — a
  // full-frame SSD1306 push over I2C at 400 kHz is the most expensive thing this
  // task does — which is why NORMAL keeps the slower rate.
  const uint16_t redrawMs = (m.runMode == 1) ? kDemoRedrawMs : kRedrawMinMs;
  if (nowMs < nextRedrawMs_) return;
  nextRedrawMs_ = nowMs + redrawMs;
  last_ = m;
  haveLast_ = true;
  lastBanner_ = banner_;
  lastBannerFrame_ = bannerFrame;
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
  // A banner owns the panel. Drawing the live screen underneath it and then
  // covering it would work on the last frame and flicker badly on the first.
  if (!drawBanner(nowMs)) {
    drawHeader(m);
    drawReadout(m);
    drawTrace(m);
  }

  g_oled.display();
}

void Ui::drawHeader(const UiModel& m) {
  g_oled.setTextSize(1);

  // Five rows on an 8 px pitch occupy y = 0..39; the trace takes 40..61.
  //
  // Every numeric field goes through printG5, which is exactly 5 characters wide
  // by construction. Adafruit's print() does not clip — it runs off the panel —
  // and at +/-16 g a value is "-15.99", six characters, which silently ate the
  // next field. Each row below is annotated with its worst-case width; the panel
  // is 21 columns and there is no scrollbar.
  const bool diag = (m.runMode == 2);

  // --- row 0 (20 cols) — which sensors, and which mode --------------------
  // Naming the parts rather than showing the mode alone: a diagnostic screen that
  // says "DEMO" and a number tells you nothing about whether a cable is in.
  g_oled.setCursor(kTextLeft, 0);
  g_oled.print(F("ADXL345  "));
  g_oled.setCursor(14, 0);
  g_oled.print(diag ? F("DIAG") : (m.runMode == 1 ? F("DEMO") : F("NORM")));

  // --- row 1 (20 cols) — the three raw axes ------------------------------
  g_oled.setCursor(kTextLeft, 8);
  g_oled.print(F("X"));
  printG5(m.rawAxMg);
  g_oled.print(F(" Y"));
  printG5(m.rawAyMg);
  g_oled.print(F(" Z"));
  printG5(m.rawAzMg);

  // --- row 2 (20 cols) — magnitude, the switch, and the score ------------
  g_oled.setCursor(kTextLeft, 16);
  g_oled.print(F("|a|"));
  printG5(m.rawMagMg);
  g_oled.print(F("g SW"));
  g_oled.print(m.sw420 ? F("1") : F("0"));
  g_oled.print(F(" S"));
  g_oled.print(m.score);

  if (diag) {
    drawDiagRows(m);
  } else {
    drawRunRows(m);
  }

  if (!oledOk_) return;
}

void Ui::drawRunRows(const UiModel& m) {
  g_oled.setTextSize(1);

  // --- row 3 (20 cols) — the one line that says whether to trust it ------
  // Order matters: the fault cases come first, so the most urgent word is
  // always the leftmost thing on the line.
  g_oled.setCursor(kTextLeft, 24);
  if (!m.accelPresent) {
    g_oled.print(F("!! NO ACCELEROMETER"));
  } else if (!m.sensorOk) {
    g_oled.print(F("!! SENSOR FAULT"));
  } else if (m.calibrating) {
    g_oled.print(F("CALIBRATING"));
  } else {
    g_oled.print(F("OK "));
    g_oled.print(m.speedKmh);
    g_oled.print(F("km/h b"));
    g_oled.print(m.batteryPct == 255 ? 255 : m.batteryPct);
    g_oled.print(F("%"));
    if (m.charging) g_oled.print(F("+"));
    if (m.muted) g_oled.print(F(" mute"));
  }

  // --- row 4 (20 cols) — the trace's scale, and the link ------------------
  g_oled.setCursor(kTextLeft, 32);
  // The trace is auto-scaled, so its ceiling has to be on screen: an axis whose
  // units you cannot see is a decoration, not a measurement. It sits next to the
  // |a| figure's row, one below, which is where a reader looks for it.
  g_oled.print(F("C"));
  g_oled.print(traceCeilingMg_ / 1000, 1);
  g_oled.print(F("g up"));
  g_oled.print(m.uptimeMs / 1000);
  g_oled.print(F("s q"));
  g_oled.print(m.queueDepth);
  g_oled.print(F(" c"));
  g_oled.print(m.bleClients < 0 ? '-' : static_cast<int>(m.bleClients));
  if (m.eventUndelivered) g_oled.print(F(" UND"));
}

void Ui::drawDiagRows(const UiModel& m) {
  g_oled.setTextSize(1);

  // --- row 3 (20 cols) — one verdict per sensor --------------------------
  // Two characters each, fixed width, so the row does not reflow as verdicts
  // change. This is the whole point of the mode: three questions, three answers,
  // answerable while holding the node in one hand and shaking it with the other.
  g_oled.setCursor(kTextLeft, 24);
  g_oled.print(F("ADXL"));
  g_oled.print(healthTag(m.diagAccel));
  g_oled.print(F(" SW"));
  g_oled.print(healthTag(m.diagSw420));
  g_oled.print(F(" BUS"));
  g_oled.print(healthTag(m.diagBus));

  // --- row 4 (20 cols) — the evidence behind those verdicts --------------
  // So that a WARN can be acted on. "SW ?" with no explanation is a dead end;
  // "SW ? tap me" tells the user exactly what to do next.
  g_oled.setCursor(kTextLeft, 32);
  if (m.diagAccel == Health::kFail) {
    g_oled.print(F("fix accel wiring"));
  } else if (m.diagSw420 == Health::kWarn) {
    g_oled.print(F("tap the SW-420"));
  } else if (m.diagAccel == Health::kWarn) {
    g_oled.print(F("shake the node"));
  } else {
    g_oled.print(F("all sensors OK"));
  }
  // Second half of the same row: the counters, so a marginal bus is visible
  // before it becomes a fault.
  g_oled.setCursor(kTextLeft + 84, 32);
  g_oled.print(m.diagReadFailures);
}

void Ui::drawReadout(const UiModel& m) {
  // Kept as a separate function so the header above stays readable; nothing is
  // drawn here at the moment because the trace owns the lower panel. It exists
  // so the panel layout has a named seam rather than a magic offset baked into
  // two places.
  (void)m;
}

void Ui::drawTrace(const UiModel& m) {
  // The ceiling only ever grows, so the bars do not rescale while being watched
  // and an impact that happened 2 s ago keeps the height it had when it
  // happened. Clamped to a sane band: a single absurd sample would otherwise
  // squash the rest of the trace into one pixel row for the rest of the session.
  int32_t ceiling = traceCeilingMg_;
  if (ceiling < kTraceFloorMg) ceiling = kTraceFloorMg;
  if (ceiling > kTraceCeilingMaxMg) ceiling = kTraceCeilingMaxMg;
  g_oled.drawFastVLine(kTraceLeft + kTraceWidth, kTraceTop, kTraceHeight, SSD1306_WHITE);

  // The acceleration threshold, as a tick on the left edge. Only drawn when it
  // is inside the current scale, otherwise it would be drawn at a height that
  // does not correspond to any bar on the screen.
  if (m.accelThresholdMg > 0 && m.accelThresholdMg <= ceiling) {
    const int8_t y = kTraceTop + kTraceHeight -
                     static_cast<int8_t>((static_cast<int32_t>(m.accelThresholdMg) *
                                          (kTraceHeight - 1)) / ceiling);
    for (int8_t x = kTraceLeft; x < kTraceLeft + kTraceWidth; x += 2) {
      g_oled.drawPixel(x, y, SSD1306_WHITE);
    }
  }

  // Oldest first, so the trace scrolls left and the newest sample is the right
  // edge — the same direction as a chart recorder.
  uint16_t head = traceHead_;
  if (head - traceTail_ > kTraceLen) {
    // The UI was starved or the sensor task reset. Skipping to the newest kTraceLen
    // samples is better than drawing a partial buffer: it keeps the time axis honest.
    traceTail_ = static_cast<uint16_t>(head - kTraceLen);
  }
  for (int8_t col = 0; col < kTraceWidth; col++) {
    const uint16_t idx = static_cast<uint16_t>(traceTail_ + col);
    const int32_t mg = trace_[idx & kTraceMask];
    if (mg <= 0) continue;
    int32_t h = (mg * (kTraceHeight - 1)) / ceiling;
    if (h < 1) h = 1;  // a real non-zero sample is at least one pixel tall
    if (h > kTraceHeight) h = kTraceHeight;
    g_oled.drawFastVLine(static_cast<int16_t>(kTraceLeft + col),
                         static_cast<int16_t>(kTraceTop + kTraceHeight - h),
                         static_cast<int8_t>(h), SSD1306_WHITE);
  }
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
void Ui::pushTrace(int32_t) {}
void Ui::clearTrace() {}
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
