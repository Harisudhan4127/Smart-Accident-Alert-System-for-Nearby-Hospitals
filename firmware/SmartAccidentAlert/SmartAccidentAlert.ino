// SmartAccidentAlert.ino — Smart Accident Alert Node.
//
// Six tasks across two cores, per docs/02-ble-protocol.md §9 and
// PROJECT_PLAN.md §8. The shape of the firmware is deliberately boring:
//
//   core 1   sensorTask  blocking I2C read of the ADXL345
//            detectTask  filter, fuse, score
//   core 0   bleTask    pack telemetry, drive the event sequencer
//            uiTask     OLED on change, LEDs, buzzer, button
//            sysTask    1 Hz housekeeping: battery, watchdog, fault detection
//            wdtTask    nothing but feeding the watchdog
//
// The two cores never share a variable without a lock. Everything crossing a
// core boundary goes through one of the rings in comm.h / sensors.h, and
// nothing allocates after setup().

#include <Arduino.h>

#include <math.h>
#include <Wire.h>
#include <esp_mac.h>

#include "comm.h"
#include "config.h"
#include "demomode.h"
#include "detector.h"
#include "json.h"
#include "power.h"
#include "protocol.h"
#include "sensors.h"
#include "sensordiag.h"
#include "state_machine.h"
#include "ui.h"

using namespace saas;

// ---------------------------------------------------------------------------
// Shared state. Every cross-task value here is either atomic or guarded by the
// mutex below, and the comment on each says which.
// ---------------------------------------------------------------------------

namespace {

// Task ids for the watchdog slots are `saas::WdTask` in power.h, not declared
// here. They used to live in this file, and the critical-set predicate in
// power.h carried its own copy of the numbers — and disagreed with this one
// about which index was which task. One declaration now, shared by the feeder,
// the checker and the test.
//
// One slot per task, plus the watchdog. The watchdog is deliberately its own
// entry rather than reusing `kWdCount - 1`, which is `kWdSys` — a previous build
// stored the watchdog's handle there and silently clobbered the sysTask handle,
// so the diagnostics display showed a task that had been replaced.

saas::Adxl345 g_accel;
saas::SensorPipeline g_pipeline;
saas::Detector g_detector;
saas::StateMachine g_sm;
/// NORMAL/DEMO switch and the demo shake trigger. Fed from detectTask, read by
/// uiTask; see demomode.h for why that needs no lock.
saas::DemoTrigger g_demo;
/// Per-sensor health evidence for DIAGNOSTIC mode. Fed alongside g_demo from
/// detectTask, read by uiTask; see sensordiag.h.
saas::SensorHealth g_health;

/// SPSC: sensorTask writes, detectTask reads. Losing a sample here would mean
/// losing a crash, so this ring is sized to absorb a full detectTask stall and
/// is never allowed to drop.
saas::Sample g_sampleRing[kSampleRingN];
volatile uint8_t g_sampleHead = 0, g_sampleTail = 0;

/// SPSC: detectTask writes, bleTask reads. Telemetry is best-effort, so the
/// oldest record is overwritten when the phone falls behind (docs §2.2).
saas::proto::Telemetry g_telemRing[kTelemRingN];
volatile uint8_t g_telemHead = 0, g_telemTail = 0;

/// Multi-writer: the detect task and the UI task both report a sensor fault.
/// Guarded by g_stateLock.
portMUX_TYPE g_stateLock = portMUX_INITIALIZER_UNLOCKED;
bool g_sensorFault = false;
uint32_t g_accelI2cErrors = 0;
uint32_t g_crcErrors = 0;
uint32_t g_loopOverage = 0;
uint32_t g_stateSinceMs = 0;

/// Guards the JSON document buffers: the BLE task builds them for reads while
/// the detect task builds events, and both can be in flight at once.
SemaphoreHandle_t g_jsonLock = nullptr;

saas::BleHooks g_hooks;
TaskHandle_t g_handle[kWdCount] = {};

/// Set when a CALIBRATE has been accepted and its samples still need sending.
/// Owned by the command handler and drained by sysTask, so the frame is built on
/// the core that already owns the BLE queue.
volatile bool g_calibLogPending = false;

// The identity strings HELLO_ACK and DEVICE_INFO need. Built once into static
// storage: nothing here may allocate.
char g_chipId[9];
char g_mac[18];
char g_name[16];
char g_serial[17];
uint32_t g_eventSeq = 0;
uint32_t g_flashTestUntil = 0;
uint32_t g_eventIdBase = 0;

portMUX_TYPE g_idLock = portMUX_INITIALIZER_UNLOCKED;

}  // namespace

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

static void buildIdentity() {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  json::fmtMac(g_mac, mac);
  json::fmtHex(g_chipId, (static_cast<uint32_t>(mac[3]) << 16) | (static_cast<uint32_t>(mac[4]) << 8) | mac[5], 8);
  snprintf(g_name, sizeof(g_name), "SAAS-%.4s", g_chipId);
  static const char kHex[] = "0123456789ABCDEF";
  for (int i = 0; i < 6; i++) {
    g_serial[i * 2] = kHex[mac[i] >> 4];
    g_serial[i * 2 + 1] = kHex[mac[i] & 0xF];
  }
  g_serial[12] = '\0';
  // Two devices must never produce the same eventId, so seed it from the MAC
  // rather than from a counter that restarts on every power cycle.
  g_eventIdBase = (static_cast<uint32_t>(mac[2]) << 24) | (static_cast<uint32_t>(mac[3]) << 16) |
                  (static_cast<uint32_t>(mac[4]) << 8) | mac[5];
}

// ---------------------------------------------------------------------------
// Battery
// ---------------------------------------------------------------------------

// The battery ADC has exactly one owner.
//
// `analogReadMilliVolts` on core 3.3 drives the ADC oneshot driver, and that
// driver is not reentrant: two cores inside it at once gives
//   E (7532) adc_oneshot: adc_oneshot_get_calibrated_result(330): read fail
// which is what the log showed, several times a second, forever.
//
// It happened because the reading was taken at every call site. detectTask alone
// was doing 50 Hz x 16 oversampling = 800 reads/second on core 1, uiTask was
// doing another 160 on core 0, and both the detector and the display wanted the
// answer more often than a LiPo divider can possibly change.
//
// So: one owner, one cadence, everyone else reads the cache. The value moves by
// a few millivolts per minute; sampling it 800 times a second was never buying
// anything, and it was costing a driver-level fault.
portMUX_TYPE g_batteryLock = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t g_batteryMvCache = 0;  ///< 0 = not sampled yet

/// Samples the battery. **sysTask only.** Every other reader must use
/// batteryMvCached().
static void refreshBattery() {
  // 16x oversampling: a single sample of a LiPo divider swings the percentage
  // by several points, which would make the OLED number flicker and wake the UI
  // task for nothing.
  uint32_t acc = 0;
  for (uint8_t i = 0; i < 16; i++) acc += analogReadMilliVolts(kPinBatteryAdc);
  const uint32_t mv = acc / 16;
  portENTER_CRITICAL(&g_batteryLock);
  g_batteryMvCache = mv;
  portEXIT_CRITICAL(&g_batteryLock);
}

/// The last battery reading, in millivolts. 0 until sysTask has sampled once.
static uint32_t batteryMvCached() {
  portENTER_CRITICAL(&g_batteryLock);
  const uint32_t mv = g_batteryMvCache;
  portEXIT_CRITICAL(&g_batteryLock);
  return mv;
}

/// Cached millivolts as a battery percentage, or 255 when not yet known.
static uint8_t batteryPctCached() {
  const uint32_t mv = batteryMvCached();
  return mv ? batteryPercent(static_cast<uint16_t>(mv)) : 255;
}

/// TP4056 CHRG is open-drain and pulls LOW while charging; on a board with no
/// CHRG wire we fall back to a voltage that is still rising, which is what
/// kChargingHeuristic in config.h is for.
///
/// Reads the cache, never the ADC — see refreshBattery().
static bool g_charging() {
  if (kChargingPinPresent) return digitalRead(kPinChargingStat) == LOW;
  static uint32_t lastMv = 0;
  const uint32_t mv = batteryMvCached();
  const bool rising = mv != 0 && mv > lastMv;
  if (mv) lastMv = mv;
  return kChargingHeuristic ? rising : false;
}

// ---------------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------------

/// Clamp to a range. Duplicated here rather than reached for from sensors.h
/// because that one is a private static of SensorPipeline, and a second
/// `clamp` in a namespace would be the kind of near-duplicate that ends up with
/// two subtly different versions.
static int32_t clamp32(int32_t v, int32_t lo, int32_t hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

/// Angle of the measured gravity vector away from vertical, whole degrees.
///
/// Uses the *filtered* gravity vector, not the raw axes: the raw vector swings
/// with every bump, and a tilt readout that jitters with the road is useless for
/// spotting that a node is mounted crooked.
///
/// This is the one place the firmware calls into libm at display rate. The
/// argument here is not that a float is forbidden — it is that `acos` is the
/// honest way to get this number. An earlier version of this function used the
/// small-angle approximation `cos^-1(x) ~ 1 - x`, which is accurate near upright
/// and badly wrong at 90 deg: a node lying on its side would have reported about
/// 28 deg of tilt. On a safety display a cheap approximation that is wrong
/// exactly when the node is most obviously wrong is not a saving.
static int32_t tiltDegrees(int32_t gx, int32_t gy, int32_t gz) {
  const double mx = static_cast<double>(gx);
  const double my = static_cast<double>(gy);
  const double mz = static_cast<double>(gz);
  const double mag = sqrt(mx * mx + my * my + mz * mz);
  // A gravity vector of zero is what a free-fall window looks like, and |g| is
  // the denominator below. Reporting 0 deg there is the least-wrong answer and
  // avoids a NaN reaching the display.
  if (mag < 1.0) return 0;
  double c = mz / mag;
  if (c > 1.0) c = 1.0;
  if (c < -1.0) c = -1.0;  // guards the domain against rounding
  const double deg = acos(c) * (180.0 / 3.14159265358979323846);
  return clamp32(static_cast<int32_t>(deg + 0.5), 0, 180);
}

/// Samples the sensor task has produced since boot. Incremented, not derived,
/// so the display can show that the acquisition task is alive even when every
/// reading it produces is identical — which is exactly the case where the
/// sensor has stopped answering.
volatile uint32_t g_sampleCount = 0;

// ---------------------------------------------------------------------------
// Ring helpers
// ---------------------------------------------------------------------------

static void pushSample(const saas::Sample& s) {
  const uint8_t next = static_cast<uint8_t>((g_sampleHead + 1) % kSampleRingN);
  if (next == g_sampleTail) {
    // Full. kSampleRingN is 8 against a 20 ms period, so reaching this means
    // detectTask has been starved for 160 ms -- a bug worth surfacing rather
    // than silently shedding data.
    portENTER_CRITICAL(&g_stateLock);
    g_loopOverage++;
    portEXIT_CRITICAL(&g_stateLock);
    return;
  }
  g_sampleRing[g_sampleHead] = s;
  portENTER_CRITICAL(&g_stateLock);
  g_sampleHead = next;
  portEXIT_CRITICAL(&g_stateLock);
}

static bool popSample(saas::Sample& out) {
  if (g_sampleTail == g_sampleHead) return false;
  out = g_sampleRing[g_sampleTail];
  g_sampleTail = static_cast<uint8_t>((g_sampleTail + 1) % kSampleRingN);
  return true;
}

static void pushTelemetry(const saas::proto::Telemetry& t) {
  const uint8_t next = static_cast<uint8_t>((g_telemHead + 1) % kTelemRingN);
  g_telemRing[g_telemHead] = t;
  portENTER_CRITICAL(&g_stateLock);
  g_telemHead = next;
  portEXIT_CRITICAL(&g_stateLock);
  // Deliberately NOT checking `next == tail`: the newest sample always wins, so
  // the detector's view of "now" stays current even if a frame is lost.
}

static bool popTelemetry(saas::proto::Telemetry& out) {
  if (g_telemTail == g_telemHead) return false;
  out = g_telemRing[g_telemTail];
  g_telemTail = static_cast<uint8_t>((g_telemTail + 1) % kTelemRingN);
  return true;
}

// ---------------------------------------------------------------------------
// Document builders (BLE hooks)
// ---------------------------------------------------------------------------

static size_t buildStatusDoc(char* out, size_t cap, void*) {
  json::StatusView v{};
  v.state = g_sm.state();
  v.stateName = g_sm.stateName();
  v.sinceMs = millis() - g_stateSinceMs;
  const saas::Settings& s = g_sm.settings();
  v.cfg.accelThresholdMg = s.accelThresholdMg;
  v.cfg.vibrationRequired = s.vibrationRequired;
  v.cfg.debounceMs = s.debounceMs;
  v.cfg.confirmWindowSec = s.confirmWindowSec;
  v.cfg.minSpeedMilliKmh = static_cast<uint16_t>(s.minSpeedMilliKmh > 0xFFFF ? 0xFFFF : s.minSpeedMilliKmh);
  v.cfg.gainMilli = s.gainMilli;
  v.cfg.telemetryHz = Comm::instance().telemetryHz();
  v.cfg.buzzerEnabled = s.buzzerEnabled;
  v.cfg.ledEnabled = s.ledEnabled;
  v.cfg.muteUntil = s.muteUntilUnixS;
  v.cfg.autoArm = s.autoArm;
  v.peakMagMg = g_detector.peakAccMg();
  v.sw420 = g_pipeline.sw420Level();
  v.sw420Hits = g_pipeline.sw420Edges();
  v.score = g_detector.lastScore();
  v.queueDepth = Comm::instance().queueDepth();
  v.heapFree = ESP.getFreeHeap();
  v.uptimeMs = millis();
  v.watchdogResets = Power::instance().watchdogResets();
  v.loopOverageCount = g_loopOverage;
  return json::buildStatus(out, cap, v);
}

static size_t buildDeviceInfoDoc(char* out, size_t cap, void*) {
  json::DeviceInfoView v{};
  v.name = g_name;
  v.model = SAAS_MODEL_NAME;
  v.hw = SAAS_HW_NAME;
  v.fwVersion = SAAS_FW_VERSION;
  v.fwBuild = kFwBuild;
  v.serial = g_serial;
  return json::buildDeviceInfo(out, cap, v);
}

static size_t buildDiagDoc(char* out, size_t cap, void*) {
  json::DiagView v{};
  v.uptimeMs = millis();
  v.heapFree = ESP.getFreeHeap();
  v.heapMin = ESP.getMinFreeHeap();
  v.queueDepth = Comm::instance().queueDepth();
  v.droppedFrames = Comm::instance().droppedFrames();
  v.crcErrors = Comm::instance().crcErrors();
  v.bleClients = Comm::instance().clientCount();
  v.oledOk = Ui::instance().oledOk();
  v.watchdogResets = Power::instance().watchdogResets();
  v.batteryMv = batteryMvCached();
  v.rssi = Comm::instance().rssi();
  portENTER_CRITICAL(&g_stateLock);
  v.accelI2cErrors = g_accel.errorCount();
  v.stackHighWater = uxTaskGetStackHighWaterMark(nullptr);
  v.loopHz = kSensorHz;
  v.cpuLoadPct = 0;
  v.brownoutCount = 0;
  portEXIT_CRITICAL(&g_stateLock);
  return json::buildDiag(out, cap, v);
}

static bool nextTelemetryDoc(saas::proto::Telemetry* out, void*) { return popTelemetry(*out); }

static void onEventAck(uint8_t type, uint16_t seq, void*) {
  // The stop-and-wait sequencer retires the head on ACK; the type/seq echo is
  // for the log only, because a mismatched seq means the phone is confused and
  // the retry is more useful than an early retire.
  (void)type;
  (void)seq;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

static void queueEvent(uint8_t type, const saas::Decision& d, uint8_t score) {
  static char doc[kJsonBufSize];
  static saas::EventQueue::Slot slot;

  if (!xSemaphoreTake(g_jsonLock, pdMS_TO_TICKS(20))) return;

  uint16_t seq;
  uint32_t id;
  portENTER_CRITICAL(&g_idLock);
  seq = static_cast<uint16_t>(g_eventSeq);
  g_eventSeq++;
  // The id is stable per (device, event), which is what makes a retry idempotent
  // in the app's de-duplication set.
  id = g_eventIdBase ^ (static_cast<uint32_t>(type) << 24) ^ g_eventSeq;
  portEXIT_CRITICAL(&g_idLock);

  json::EventView v{};
  v.type = proto::eventTypeName(type);
  static char idHex[9];
  json::fmtHex(idHex, id, 8);
  v.eventId = idHex;
  v.seq = seq;
  v.tMs = millis();
  v.score = score;
  v.impact.magMg = d.magMg;
  v.impact.peakAccMg = d.peakAccMg;
  v.impact.sw420 = d.sw420 != 0;
  v.impact.orientDeg10 = d.orientDeg10;
  v.impact.speedMilliKmh = static_cast<uint16_t>(d.speedMilliKmh > 0xFFFF ? 0xFFFF : d.speedMilliKmh);
  v.impact.freeFall = d.freeFall != 0;
  v.impact.jerkMgPerS = static_cast<uint16_t>(d.jerkMgPerS > 0xFFFF ? 0xFFFF : d.jerkMgPerS);
  v.confirmWindowSec = g_sm.settings().confirmWindowSec;
  v.canCancel = (type == proto::kEvAccidentDetected || type == proto::kEvManualSos) ? 1 : 0;

  const size_t n = json::buildEvent(doc, sizeof(doc), v);
  if (n) {
    slot.len = static_cast<uint16_t>(proto::encodeJson(slot.data, sizeof(slot.data), proto::kTypeEvent, doc, n));
    slot.inUse = 1;
    Comm::instance().queueEvent(slot, millis());
  }
  xSemaphoreGive(g_jsonLock);
}

// ---------------------------------------------------------------------------
// Request handling (the RX side of the protocol)
// ---------------------------------------------------------------------------

static void sendAck(uint8_t of, uint16_t seq, const char* ofName, const char* op) {
  static char doc[kJsonBufSize];
  static uint8_t frame[kFrameBufSize];
  const size_t n = json::buildAck(doc, sizeof(doc), of, seq, ofName, op);
  const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeAck, doc, n);
  if (fn) Comm::instance().notifyCtrlFrameNow(frame, fn);
}

static void sendError(uint8_t code, const char* message) {
  static char doc[kJsonBufSize];
  static uint8_t frame[kFrameBufSize];
  const size_t n = json::buildError(doc, sizeof(doc), code, message);
  const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeError, doc, n);
  if (fn) Comm::instance().notifyCtrlFrameNow(frame, fn);
}


static void handleParsedRequest(uint8_t type, json::Parser& p, const char* doc, size_t len);

static void onFrame(const proto::Frame& f, void*) {
  // Everything below runs on the BLE stack's callback context, so it must not
  // block. The JSON parse is bounded by the frame length, which is bounded by
  // MAX_PAYLOAD, so the worst case is a few hundred bytes of scanning.
  static json::Parser parser;
  if (f.len == 0) return;
  // The scanner already validated the CRC and split the header off, so f.payload
  // is the bare JSON document and f.type is the real frame type.
  const uint8_t* const payload = f.payload;
  const size_t len = f.len;
  const uint8_t type = f.type;

  if (type == proto::kTypeTelemetry) return;  // telemetry is one-way; ignore reflections

  // ACK (0x07) is the phone retiring a CTRL event (docs §8 step 3). It carries
  // no work beyond the sequence number, so it never reaches handleParsedRequest
  // and never allocates.
  if (type == proto::kTypeAck) {
    static char doc[kJsonBufSize];
    const size_t n = len < sizeof(doc) ? len : sizeof(doc) - 1;
    memcpy(doc, payload, n);
    doc[n] = '\0';
    json::Parser p2;
    json::Val v2;
    if (!p2.parse(doc, n)) return;
    if (p2.member(p2.root(), "seq", v2) && v2.kind == json::Val::kInt && v2.i >= 0) {
      Comm::instance().onEventAck(static_cast<uint16_t>(v2.i));
    }
    return;
  }

  if (type == proto::kTypeHello || type == proto::kTypePing || type == proto::kTypeConfig ||
      type == proto::kTypeCommand || type == proto::kTypeCalibrate) {
    // Parsed on the sysTask tick, not here, to keep the radio callback short.
    static char doc[kJsonBufSize];
    const size_t n = len < sizeof(doc) ? len : sizeof(doc) - 1;
    memcpy(doc, payload, n);
    doc[n] = '\0';
    if (!parser.parse(doc, n)) {
      sendError(2 /* BAD_ARGS */, "malformed JSON");
      return;
    }
    handleParsedRequest(type, parser, doc, n);
    return;
  }
  sendError(1 /* UNSUPPORTED */, "unknown request type");
}


// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

/// CALIB_LOG is chunked because a 512-byte payload only holds ~5 of the 48
/// samples a calibration can produce, and the frame ends with a STATUS so the app
/// knows the log is complete rather than truncated (docs §6.8).
/// CALIB_LOG is chunked: a 512-byte payload holds only ~5 of the 48 samples a
/// calibration can produce, and the sequence ends with a STATUS so the app knows
/// the log is complete rather than truncated (docs §6.8). Four samples per frame
/// leaves headroom for the key names, which cost ~40 bytes each.
static void streamCalibLog() {
  static char doc[kJsonBufSize];
  static uint8_t frame[kFrameBufSize];
  const Calibrator& c = g_pipeline.calibration();
  json::CalibSampleView chunk[4];
  uint16_t i = 0;
  while (i + 4 <= c.historyCount()) {
    const uint8_t got = c.drainFrom(i, 4, chunk);
    if (got == 0) break;
    json::Writer w(doc, sizeof(doc));
    json::calibBegin(w);
    for (uint8_t k = 0; k < got; k++) json::calibElement(w, chunk[k]);
    json::calibEnd(w);
    if (!w.ok()) break;
    const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeCalibLog, doc, w.size());
    if (fn) Comm::instance().notifyCtrlFrameNow(frame, fn);
    i = static_cast<uint16_t>(i + got);
  }
  Comm::instance().sendStatus(millis());
}

/// Applies a CONFIG document (docs §6.3). Every field is range-checked against
/// config.h and a rejected value leaves the previous one in place: a phone
/// sending a nonsense threshold must not be able to disarm the node, and "unset"
/// is routinely sent as 0, which is why the minimums are the guard.
static void applyConfig(json::Parser& p) {
  Settings& s = g_sm.settings();
  json::Val v;

  // Reads an integer member and stores it only if it is in range.
  auto ranged = [&](const char* key, uint32_t lo, uint32_t hi, uint32_t& dst) {
    if (!p.member(p.root(), key, v) || v.kind != json::Val::kInt || v.i < 0) return;
    const uint32_t raw = static_cast<uint32_t>(v.i);
    if (raw < lo || raw > hi) return;
    dst = raw;
  };
  auto flag = [&](const char* key, bool& dst) {
    if (p.member(p.root(), key, v) && v.kind == json::Val::kBool) dst = v.boolean;
  };

  uint32_t tmp = 0;
  ranged("accelThresholdMg", kCfgAccelThresholdMgMin, kCfgAccelThresholdMgMax, tmp);
  if (tmp) s.accelThresholdMg = static_cast<uint16_t>(tmp);
  tmp = 0;
  ranged("confirmWindowSec", kCfgConfirmWindowSecMin, kCfgConfirmWindowSecMax, tmp);
  if (tmp) s.confirmWindowSec = static_cast<uint16_t>(tmp);
  tmp = 0;
  ranged("minSpeedKmh", 0, kCfgMinSpeedMilliKmhMax / 1000, tmp);
  s.minSpeedMilliKmh = tmp * 1000;
  tmp = 0;
  // §6.4 spells this key `detectorGain` and defines it as a multiplier in
  // 0.5…3.0, and §6.5 echoes it back under the same name. The parser below used
  // to read an integer key called "gain" in *thousandths*, so a value the app
  // sent could never be applied and the round trip silently did nothing.
  //
  // The wire value is a JSON number, which may be integral (1) or fractional
  // (1.25), so it is read as a number and scaled to the internal milli form.
  // A legacy "gain" key in thousandths is still accepted, and only when
  // `detectorGain` is absent, so an older phone keeps working.
  {
    // `json::Val` already keeps a real number as value*1000, which is exactly
    // the internal representation, so no floating point is needed at all.
    bool have = false;
    if (p.member(p.root(), "detectorGain", v)) {
      if (v.kind == json::Val::kReal) {
        s.gainMilli = static_cast<uint16_t>(v.milli);
        have = true;
      } else if (v.kind == json::Val::kInt) {
        // An integral JSON number, e.g. `1`. `milli` is not populated for
        // kInt, so scale it here.
        const int64_t scaled = v.i * 1000;
        if (scaled >= kCfgGainMilliMin && scaled <= kCfgGainMilliMax) {
          s.gainMilli = static_cast<uint16_t>(scaled);
          have = true;
        }
      }
    }
    // Legacy key, in thousandths, accepted only when the documented key was
    // absent so an older app build keeps working.
    if (!have && p.member(p.root(), "gain", v) && v.kind == json::Val::kInt) {
      if (v.i >= kCfgGainMilliMin && v.i <= kCfgGainMilliMax) {
        s.gainMilli = static_cast<uint16_t>(v.i);
      }
    }
  }
  tmp = 0;
  ranged("muteUntil", 0, 0xFFFFFFFFu, tmp);
  s.muteUntilUnixS = tmp;
  ranged("telemetryHz", kTelemetryHzMin, kTelemetryHzMax, tmp);
  if (tmp) Comm::instance().setTelemetryHz(static_cast<uint16_t>(tmp));

  flag("vibrationRequired", s.vibrationRequired);
  flag("buzzerEnabled", s.buzzerEnabled);
  flag("ledEnabled", s.ledEnabled);
  flag("autoArm", s.autoArm);
  flag("armed", s.armed);

  // Push the subset the detector actually reads back into it, so one CONFIG
  // document cannot leave Settings and DetectorCfg disagreeing.
  DetectorCfg dc = g_detector.config();
  dc.accelThresholdMg = s.accelThresholdMg;
  dc.vibrationRequired = s.vibrationRequired;
  dc.debounceMs = s.debounceMs;
  dc.minSpeedMilliKmh = s.minSpeedMilliKmh;
  dc.gainMilli = s.gainMilli;
  dc.armed = s.armed;
  g_detector.configure(dc);
}

static void handleParsedRequest(uint8_t type, json::Parser& p, const char* doc, size_t len) {
  const uint32_t now = millis();
  (void)doc;
  (void)len;
  json::Val v;
  char op[24] = {0};

  switch (type) {
    case proto::kTypePing:
      sendAck(proto::kTypePing, 0, "PING", nullptr);
      return;

    case proto::kTypeHello: {
      // HELLO is answered with HELLO_ACK (type 0x12), not a generic ACK, and it
      // uses seq 0 because it is the handshake the app waits on.
      static char out[kJsonBufSize];
      static uint8_t frame[kFrameBufSize];
      json::HelloAckView hv{};
      hv.fwVersion = SAAS_FW_VERSION;
      hv.hw = SAAS_HW_NAME;
      hv.chipId = g_chipId;
      hv.mac = g_mac;
      hv.name = g_name;
      hv.batteryMv = batteryMvCached();
      hv.batteryPct = hv.batteryMv ? batteryPercent(hv.batteryMv) : 255;
      hv.charging = g_charging();
      hv.uptimeMs = now;
      hv.accelPresent = g_accel.present();
      static char addrBuf[8];
      snprintf(addrBuf, sizeof(addrBuf), "0x%02X", g_accel.address());
      hv.accelAddr = addrBuf;
      hv.deviceId = g_accel.present() ? static_cast<int>(g_accel.deviceId()) : -1;
      hv.oledPresent = Ui::instance().oledOk();
      hv.oledAddr = "0x3C";
      hv.sw420 = g_pipeline.sw420Level();
      hv.calibrated = g_pipeline.primed();
      hv.sensorRateHz = kSensorHz;
      hv.state = g_sm.state();
      const size_t n = json::buildHelloAck(out, sizeof(out), hv);
      const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeHelloAck, out, n);
      if (fn) Comm::instance().notifyCtrlFrameNow(frame, fn);
      return;
    }

    case proto::kTypeConfig:
      applyConfig(p);
      // The log is sent for a CONFIG too: it is how the app shows the values
      // that actually took effect, including the ones it was told to clamp.
      sendAck(proto::kTypeConfig, 0, "CONFIG", nullptr);
      return;

    case proto::kTypeCalibrate: {
      uint16_t durMs = kCalibDefaultMs;
      if (p.member(p.root(), "durationMs", v) && v.kind == json::Val::kInt) {
        durMs = static_cast<uint16_t>(v.i < kCalibMinMs   ? kCalibMinMs
                                      : v.i > kCalibMaxMs ? kCalibMaxMs
                                                            : v.i);
      }
      g_pipeline.beginCalibration(now, durMs);
      // A CALIBRATE that is acknowledged but never reports anything is
      // indistinguishable from a calibration that failed, and the app's
      // calibration chart would simply stay empty. §6.8 expects the samples
      // back, so the log is streamed as soon as one is available.
      g_calibLogPending = true;
      sendAck(proto::kTypeCalibrate, 0, "CALIBRATE", nullptr);
      return;
    }

    case proto::kTypeCommand: {
      if (p.member(p.root(), "op", v) && v.kind == json::Val::kStr && p.str(v, op, sizeof(op))) {
        // fall through to the op table below
      } else {
        sendError(2 /* BAD_ARGS */, "COMMAND needs an \"op\" string");
        return;
      }
      const bool isConfirm = !strcmp(op, "CONFIRM");
      const bool isCancel = !strcmp(op, "CANCEL");
      const bool isArm = !strcmp(op, "ARM");
      const bool isDisarm = !strcmp(op, "DISARM");
      const bool isMute = !strcmp(op, "MUTE");
      const bool isResetStats = !strcmp(op, "RESET_STATS");
      const bool isFlash = !strcmp(op, "FLASH_TEST");
      const bool isSelftest = !strcmp(op, "SELFTEST");
      const bool isTest = !strcmp(op, "TEST");
      const bool isMode = !strcmp(op, "MODE");

      if (isArm || isDisarm) {
        g_sm.settings().armed = isArm;
        DetectorCfg dc = g_detector.config();
        dc.armed = isArm;
        g_detector.configure(dc);
        if (isArm && g_sm.state() == proto::kStateMuted) g_sm.sensorsOk();
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isMute) {
        uint32_t until = 0;
        if (p.member(p.root(), "untilUnixS", v) && v.kind == json::Val::kInt && v.i > 0) {
          until = static_cast<uint32_t>(v.i);
        } else {
          // No expiry given: mute for an hour rather than forever, so a stuck
          // MUTE cannot silence the node permanently by accident.
          until = static_cast<uint32_t>(time(nullptr)) + 3600;
        }
        g_sm.settings().muteUntilUnixS = until;
        Ui::instance().stopPattern();
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isMode) {
        // {"op":"MODE","mode":"DEMO"|"NORMAL"} or {"op":"MODE"} to query.
        uint8_t want = g_demo.mode();
        char mode[16] = {0};
        if (p.member(p.root(), "mode", v) && v.kind == json::Val::kStr &&
            p.str(v, mode, sizeof(mode))) {
          if (!strcmp(mode, "DEMO")) {
            want = kModeDemo;
          } else if (!strcmp(mode, "NORMAL")) {
            want = kModeNormal;
          } else if (!strcmp(mode, "DIAG") || !strcmp(mode, "DIAGNOSTIC")) {
            want = kModeDiag;
          } else {
            // Refused rather than coerced. Silently treating an unknown mode
            // string as NORMAL would ACK a command the caller believes it
            // issued, and the node would quietly be in the other mode.
            sendError(2 /* BAD_ARGS */, "mode must be NORMAL, DEMO or DIAG");
            return;
          }
          g_demo.setMode(want);
          if (want == kModeDiag) g_health.reset();
        }
        // Echo the mode that is actually in force, whatever was asked for. A
        // caller that gets back a mode it did not set can act on it; a caller
        // that gets back a bare ACK has to guess. Sent as a COMMAND payload
        // because that is the only unsolicited-on-request frame type that
        // carries a body here, and the app is already parsing it.
        static char doc[96];
        static uint8_t frame[kFrameBufSize];
        const int len = snprintf(doc, sizeof(doc),
                                 "{\"op\":\"MODE\",\"mode\":\"%s\",\"triggers\":%lu}",
                                 runModeName(g_demo.mode()),
                                 static_cast<unsigned long>(g_demo.triggerCount()));
        if (len > 0) {
          const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeCommand,
                                              doc, static_cast<size_t>(len));
          if (fn) Comm::instance().notifyCtrlFrameNow(frame, fn);
        }
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isResetStats) {
        g_detector.resetStats();
        g_demo.resetStats();
        Ui::instance().clearTrace();
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isFlash) {
        g_flashTestUntil = now + 1500;
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isSelftest) {
        static char out[kJsonBufSize];
        static uint8_t frame[kFrameBufSize];
        const size_t n = buildDiagDoc(out, sizeof(out), nullptr);
        const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeDiag, out, n);
        if (fn) Comm::instance().notifyCtrlFrameNow(frame, fn);
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isTest) {
        // The app's Test Alert button: drive the detector with a synthetic crash
        // so the user can verify the whole path end to end.
        Sample s{};
        s.tMs = now;
        s.axMg = 820; s.ayMg = 0; s.azMg = 570;
        s.magMg = 1000;
        s.speedMilliKmh = 50000;
        s.flags = kSfSensorOk;
        const Decision d = g_detector.process(s, now);
        const Transition tr = g_sm.trip(now);
        if (tr.legal) queueEvent(proto::kEvAccidentDetected, d, d.score);
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      if (isConfirm || isCancel) {
        const Transition tr = g_sm.dispatch(isConfirm ? Trigger::kConfirm : Trigger::kCancel, now);
        if (tr.legal) {
          // Hold the detector off after an alert is acknowledged, and drop the
          // pre-crash window so the next report starts clean.
          g_detector.setRefractory(now, kDetectorRefractoryMs);
          g_detector.resetStats();
        }
        if (!tr.legal) {
          // BAD_STATE is the documented answer, and it matters: telling the app
          // "cannot CANCEL from IDLE" is far more useful than silently ignoring it.
          sendError(3 /* BAD_STATE */, isConfirm ? "cannot CONFIRM from this state"
                                                 : "cannot CANCEL from this state");
          return;
        }
        sendAck(proto::kTypeCommand, 0, "COMMAND", op);
        return;
      }
      sendError(1 /* UNSUPPORTED */, "unknown COMMAND op");
      return;
    }

    default:
      sendError(1 /* UNSUPPORTED */, "unknown request type");
      return;
  }
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

static void sensorTask(void*) {
  TickType_t last = xTaskGetTickCount();
  for (;;) {
    RawSample raw{};
    // Adxl345::read hands back milli-g directly, so the raw-count conversion
    // stays inside the driver where the part's bit layout is known.
    raw.sensorOk = g_accel.read(raw.axMg, raw.ayMg, raw.azMg);
    raw.sw420Raw = digitalRead(kPinSw420) == HIGH;

    Sample s{};
    const uint32_t now = millis();
    g_pipeline.step(now, raw, s);
    s.tMs = now;
    pushSample(s);

    // The live trace is fed here, at the full 50 Hz, and not from uiTask. An
    // impact peak is about 40 ms wide; a trace sampled at the 10 Hz redraw rate
    // catches it one time in five and draws a small bump for what was a 5 g
    // event. Someone shaking the node to watch the display would conclude the
    // detector was broken.
    Ui::instance().pushTrace(g_pipeline.rawMagMg());
    g_sampleCount++;

    // The detector needs a 20 ms cadence, not a 20 ms delay, so the wake time is
    // computed from the previous wake. A drift-corrected loop: adding vTaskDelay
    // to the *work* time accumulates every I2C stall into permanent lag.
    vTaskDelayUntil(&last, pdMS_TO_TICKS(kSensorPeriodMs));
    Power::instance().feed(kWdSensor);
  }
}

static void detectTask(void*) {
  TickType_t last = xTaskGetTickCount();
  for (;;) {
    Sample s{};
    if (popSample(s)) {
      const saas::Decision d = g_detector.process(s, s.tMs);
      saas::proto::Telemetry t{};
      t.tMs = s.tMs;
      t.axMg = static_cast<int16_t>(s.axMg);
      t.ayMg = static_cast<int16_t>(s.ayMg);
      t.azMg = static_cast<int16_t>(s.azMg);
      t.magMg = s.magMg;
            t.peakMg = d.magMg;
      t.score = d.score;
      t.state = g_sm.state();
      t.batteryPct = batteryPctCached();
      t.flags = g_sm.flags(false, false, false, Ui::instance().oledOk(),
                           Ui::instance().buttonDown(), g_charging());
      pushTelemetry(t);

      if (d.tripped) {
        const saas::Transition tr = g_sm.trip(s.tMs);
        if (tr.legal) queueEvent(proto::kEvAccidentDetected, d, d.score);
        if (tr.to == proto::kStatePending) Ui::instance().chirp();
      }

      // Sensor-health evidence, accumulated in every mode. Fed here rather than
      // from uiTask so it sees the same unfiltered sample the detector does, at
      // the full 50 Hz: a diagnostic that sampled at the display rate could miss
      // the one-second window in which a frozen bus is distinguishable from a
      // still sensor.
      g_health.feed(s.tMs, g_pipeline.rawMagMg(), (s.flags & kSfSw420) != 0,
                    digitalRead(kPinSw420) == HIGH, (s.flags & kSfSensorOk) != 0,
                    g_accel.present());

      // The demo trigger runs *after* the real detector and cannot suppress it.
      // In NORMAL it returns false and costs one comparison; in DEMO it raises
      // the same event through the same state machine, so a demonstration
      // exercises the real BLE and app path rather than a parallel mock of it.
      if (g_demo.feed(s.tMs, s.magMg, (s.flags & kSfSw420) != 0, (s.flags & kSfSensorOk) != 0)) {
        const saas::Transition tr = g_sm.trip(s.tMs);
        if (tr.legal) {
          // A plausible-looking impact, not a bare flag: the app's event screen
          // has a chart and a magnitude, and an event with zeros in it would
          // demonstrate the transport while showing nothing about the detector.
          saas::Decision demo = d;
          demo.score = d.score > 70 ? d.score : 82;
          demo.magMg = static_cast<uint16_t>(
              s.magMg > 65535 ? 65535 : (s.magMg < 0 ? 0 : s.magMg));
          demo.peakAccMg = demo.magMg;
          queueEvent(proto::kEvAccidentDetected, demo, demo.score);
        }
        Ui::instance().chirp();
      }
    }
    vTaskDelayUntil(&last, pdMS_TO_TICKS(kSensorPeriodMs));
    Power::instance().feed(kWdDetect);
  }
}

static void bleTask(void*) {
  for (;;) {
    Comm::instance().loop(millis());
    vTaskDelay(pdMS_TO_TICKS(5));
    Power::instance().feed(kWdBle);
  }
}

static void uiTask(void*) {
  for (;;) {
    const uint32_t now = millis();
    UiModel m{};
    m.state = g_sm.state();
    m.uptimeMs = now;
    m.batteryMv = batteryMvCached();
    m.batteryPct = m.batteryMv ? batteryPercent(static_cast<uint16_t>(m.batteryMv)) : 255;
    m.charging = g_charging();
    m.sw420 = g_pipeline.sw420Level();
    m.sosHeld = Ui::instance().buttonDown();

    // The one physical button, two meanings.
    //
    //   click  (< kSosHoldMs)  ->  toggle NORMAL <-> DEMO
    //   hold   (>= kSosHoldMs) ->  manual SOS
    //
    // This inverts an earlier mapping that had it the other way round, on the
    // grounds that an emergency should not need a 2-second commitment while
    // mode-switching is a thing you do deliberately and can watch the screen to
    // confirm. Holding is still required for SOS, because the alternative — SOS
    // on any press — means a single accidental touch raises an emergency call
    // about a parked car.
    //
    // The two are checked in this order and cannot collide. sosLongPressed()
    // latches on the frame the hold threshold is crossed, while the button is
    // still down; sosPressed() only fires on *release*, and by then the release
    // is the far edge of a long press. Ui is built so that a press that was
    // promoted to a long press never also produces a click.
    if (Ui::instance().sosLongPressed()) {
      const saas::Transition tr = g_sm.dispatch(Trigger::kManualSos, now);
      if (tr.legal) {
        saas::Decision d{};
        d.score = 100;
        queueEvent(tr.emit == saas::proto::kEvAlertConfirmed
                       ? proto::kEvAlertConfirmed
                       : proto::kEvManualSos,
                   d, d.score);
        Ui::instance().chirp();
        Ui::instance().showBanner(Banner::kSos);
        Serial.printf("SOS (hold %lums) -> %s\n",
                      static_cast<unsigned long>(Ui::instance().lastHeldMs()),
                      proto::stateName(tr.to));
      } else {
        // BOOT and FAULT have no SOS row on purpose — there is nothing
        // meaningful to dispatch while the detector is not trustworthy.
        Ui::instance().chirp();
        Serial.printf("SOS ignored from %s\n", proto::stateName(g_sm.state()));
      }
    } else if (Ui::instance().sosPressed()) {
      // Cycle NORMAL -> DEMO -> DIAGNOSTIC -> NORMAL.
      //
      // A cycle rather than a two-way toggle because the three modes answer three
      // different questions and someone holding a node down a cable wants the
      // diagnostic one just as much as the demo one. It lands back on NORMAL
      // after three clicks, so a node left on a bench does not need a fourth
      // click to be safe.
      const uint8_t next = (m.runMode == kModeNormal)  ? kModeDemo
                           : (m.runMode == kModeDemo)  ? kModeDiag
                                                        : kModeNormal;
      g_demo.setMode(next);
      Ui::instance().clearTrace();
      Ui::instance().chirp();
      // Entering DIAGNOSTIC starts a fresh check: reporting the previous mode's
      // accumulated evidence as a diagnosis would be answering a question nobody
      // asked yet.
      if (next == kModeDiag) g_health.reset();
      Ui::instance().showBanner(next == kModeDemo   ? Banner::kModeDemo
                                 : next == kModeDiag ? Banner::kModeDiag
                                                     : Banner::kModeNormal);
      Serial.printf("click -> mode %s\n", runModeName(g_demo.mode()));
    }
    m.muted = g_sm.mutedByClock(time(nullptr)) || m.state == proto::kStateMuted;
    m.score = g_detector.lastScore();
    m.speedKmh = static_cast<uint8_t>(g_detector.lastSpeedMilliKmh() / 1000);
    m.sensorOk = !g_sensorFault;
    m.accelPresent = g_accel.present();

    // Live sensor readout. The raw axes, not the filtered ones: this is the
    // "what is the part actually reading" view, and an impact peak is too short
    // for the 5 Hz section to report honestly.
    m.rawAxMg = static_cast<int16_t>(clamp32(g_pipeline.rawAxMg(), -32768, 32767));
    m.rawAyMg = static_cast<int16_t>(clamp32(g_pipeline.rawAyMg(), -32768, 32767));
    m.rawAzMg = static_cast<int16_t>(clamp32(g_pipeline.rawAzMg(), -32768, 32767));
    m.rawMagMg = g_pipeline.rawMagMg();
    m.tiltDeg = static_cast<int16_t>(tiltDegrees(g_pipeline.gravityX(),
                                                 g_pipeline.gravityY(),
                                                 g_pipeline.gravityZ()));
    m.sampleCount = g_sampleCount;

    // Run mode. Read across from the detect task; a torn read costs at most a
    // stale demo counter on the display, never a missed or spurious trigger.
    m.runMode = g_demo.mode();
    m.demoShakeRun = g_demo.shakeRun();
    m.demoTriggers = static_cast<uint16_t>(g_demo.triggerCount() > 0xFFFF
                                               ? 0xFFFF
                                               : g_demo.triggerCount());
    m.demoPeakMagMg = g_demo.peakMagMg();
    m.demoCooldownMs = g_demo.cooldownRemaining(now);
    m.accelThresholdMg = g_detector.config().accelThresholdMg;
    m.diagAccel = g_health.accel();
    m.diagSw420 = g_health.sw420();
    m.diagBus = g_health.bus();
    m.diagReadFailures = g_health.readFailures();
    m.diagSwToggles = g_health.sw420Toggles();

    // The same numbers the OLED is drawing, as text. Gated on kSerialDataMs
    // rather than every tick: uiTask runs at 10 Hz and Serial.printf blocks for
    // the duration of the write, so printing every tick would put a visible
    // notch in the display's own update rate.
    static uint32_t lastSerialMs = 0;
    if (now - lastSerialMs >= kSerialDataMs) {
      lastSerialMs = now;
      if (m.sensorOk && m.accelPresent) {
        Serial.printf(
            "%-6s %-7s t=%5us X%6.3f Y%6.3f Z%6.3f |a|=%6.3fg peak=%6.3fg"
            " sw=%d sc=%3d n=%lu\n",
            runModeName(m.runMode), proto::stateName(m.state), m.uptimeMs / 1000,
            m.rawAxMg / 1000.0, m.rawAyMg / 1000.0, m.rawAzMg / 1000.0,
            m.rawMagMg / 1000.0, m.demoPeakMagMg / 1000.0, m.sw420 ? 1 : 0,
            m.score, static_cast<unsigned long>(g_sampleCount));
        if (m.runMode == kModeDemo) {
          // shakeRun is the count toward kDemoShakeHoldSamples, and it only
          // advances while *both* sensors agree — so a reader watching it sit at
          // zero can tell which sensor is not contributing without guessing.
          Serial.printf("  DEMO  shake %u/%u  hits=%u  cooldown=%lums"
                        "  (needs |a|>=%dmg AND SW-420)\n",
                        m.demoShakeRun, kDemoShakeHoldSamples, m.demoTriggers,
                        static_cast<unsigned long>(m.demoCooldownMs),
                        static_cast<int>(kDemoShakeMagMg));
        } else if (m.runMode == kModeDiag) {
          Serial.printf(
              "  DIAG  ADXL345 %-8s SW-420 %-8s BUS %-8s\n"
              "        gravity=%s motion=%s |a|min=%ldmg max=%ldmg"
              "  swEdges=%lu  readFails=%u/%u\n",
              healthText(m.diagAccel), healthText(m.diagSw420), healthText(m.diagBus),
              g_health.sawGravity() ? "yes" : "no",
              g_health.sawMotion() ? "yes" : "no",
              static_cast<long>(g_health.minMagMg()),
              static_cast<long>(g_health.maxMagMg()),
              static_cast<unsigned long>(g_health.sw420Toggles()),
              static_cast<unsigned>(g_health.readFailures()),
              static_cast<unsigned>(g_health.worstReadFailures()));
        }
      } else {
        // The fault line, printed instead of the data rather than after it, so a
        // node that is not reading its sensor is obviously not reading its sensor.
        Serial.printf(
            "%-6s %-7s t=%5us *** SENSOR FAULT *** %s"
            " addr=0x%02X id=0x%02X failRuns=%u\n",
            runModeName(m.runMode), proto::stateName(m.state), m.uptimeMs / 1000,
            m.accelPresent ? "read failing" : "not found", g_accel.address(),
            g_accel.deviceId(), static_cast<unsigned>(g_accel.consecutiveFailures()));
        // Gravity is ~1 g on whichever axis the mount puts it on. Sitting far
        // below that is the signature of a part that answers I2C but is not
        // powered, or of a scaling mistake in the firmware — and those two look
        // identical on the wire, so it is worth saying which is expected.
        Serial.printf(
            "        |a|=%.3fg  (a still node must read ~1.00g; near 0 means no"
            " gravity, i.e. the part is not really powered)\n",
            m.rawMagMg / 1000.0);
      }
    }
    m.calibrating = g_pipeline.calibrating();
    m.calibProgressPct = 0;
    m.eventUndelivered = Comm::instance().eventUndelivered();
    m.queueDepth = Comm::instance().queueDepth();
    m.bleClients = Comm::instance().connected() ? static_cast<int8_t>(Comm::instance().clientCount()) : -1;
    m.rssi = Comm::instance().rssi();
    m.flashTest = now < g_flashTestUntil;
    Ui::instance().loop(now, m);
    vTaskDelay(pdMS_TO_TICKS(kUiPeriodMs));
    Power::instance().feed(kWdUi);
  }
}

static void sysTask(void*) {
  for (;;) {
    const uint32_t now = millis();

    // The battery ADC is sampled here and nowhere else — see refreshBattery().
    // kSysPeriodMs is the natural cadence: a LiPo divider cannot resolve a
    // useful change faster than that, and the OLED and the BLE packets read
    // this cache rather than the pin.
    refreshBattery();

    // Countdown expiry: PENDING and SOS both escalate to ALARM here, so the
    // state machine never depends on a busy wait.
    const saas::Transition tr = g_sm.onTick(now);
    if (tr.emit != kEvNone) Ui::instance().setPattern(kPatternAlarm, 4);

    if (g_pipeline.calibrating()) {
      if (g_pipeline.calibrationDone(now)) {
        g_pipeline.applyCalibration();
        Ui::instance().chirp();
      }
    }

    // Fault detection, and leaving BOOT.
    //
    // Two bugs lived here and both are visible on a bench.
    //
    // 1. The state machine was never told the node had booted. `sensorsOk()` was
    //    only reachable from the *recovery* branch of a fault transition, and
    //    g_sensorFault starts false and stays false on a healthy node — so that
    //    branch could never run. Every node sat in BOOT forever, the detector
    //    never armed, and no event could ever be raised. Now the boot
    //    completion is an explicit condition: a primed pipeline, a healthy
    //    sensor, and a calibration that has finished.
    //
    // 2. The fault test was `!g_accel.present()`, and present() is fixed at
    //    begin(). Unplugging the accelerometer from a running node therefore
    //    changed nothing at all. It now watches consecutiveFailures(), which is
    //    a runtime streak that a good read clears.
    const bool sensorHealthy = g_accel.present() && g_accel.consecutiveFailures() < kSensorFaultFailRuns;
    const bool calibrated = g_pipeline.primed() && !g_pipeline.calibrating();

    // DIAGNOSTIC and DEMO both disarm the production detector. DEMO because a
    // bench node must not page anyone from a road joint; DIAGNOSTIC because a
    // health check that raises accidents is not a health check. The guarantee
    // that matters is the one in modeCanRaiseEvents(), which the demo trigger
    // consults before firing — this is the belt to that braces.
    if (g_demo.mode() != kModeNormal) {
      DetectorCfg dc = g_detector.config();
      if (dc.armed) {
        dc.armed = false;
        g_detector.configure(dc);
      }
    }

    if (sensorHealthy && calibrated && g_sm.state() == proto::kStateBoot) {
      // Only out of BOOT. Calling this every tick would also yank the node out
      // of MUTED, which is a user decision and not a sensor fact.
      g_stateSinceMs = now;
      g_sm.sensorsOk();
    }

    if (!sensorHealthy && g_accel.consecutiveFailures() >= kSensorFaultFailRuns) {
      if (!g_sensorFault) {
        g_sensorFault = true;
        g_stateSinceMs = now;
        g_sm.dispatch(saas::Trigger::kFault, now);
        queueEvent(proto::kEvDeviceFault, saas::Decision{}, 0);
      }
    } else if (sensorHealthy && g_sensorFault) {
      g_sensorFault = false;
      g_stateSinceMs = now;
      if (g_sm.state() == proto::kStateFault) g_sm.sensorsOk();
    }

    // Drain any pending calibration log (see g_calibLogPending). Done here
    // rather than inline in the command handler so the ACK is sent immediately
    // and the (potentially multi-frame) log does not delay it.
    if (g_calibLogPending) {
      g_calibLogPending = false;
      streamCalibLog();
    }

    Power::instance().checkWatchdog(now);
    vTaskDelay(pdMS_TO_TICKS(kSysPeriodMs));
    Power::instance().feed(kWdSys);
  }
}

static void wdtTask(void*) {
  for (;;) {
    // Feed its own slot first, then judge everyone else.
    //
    // It did not do this, and that is why the node rebooted roughly every
    // kWatchdogTimeoutS seconds. `checkWatchdog` walks all kTaskSlots looking for
    // one that has not been fed, and kWdWatchdog is a real slot with a real
    // index — nothing exempts it. So five seconds after boot, the watchdog found
    // its own slot stale and called ESP.restart(), in a loop, forever.
    //
    // The ordering matters: feed, then check. The reverse would work only by
    // accident of the first iteration.
    Power::instance().feed(kWdWatchdog);
    Power::instance().checkWatchdog(millis());
    vTaskDelay(pdMS_TO_TICKS(100));
  }
}

// ---------------------------------------------------------------------------
// Arduino entry points
// ---------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  Wire.begin(kPinI2cSda, kPinI2cScl, kI2cClockHz);
  g_jsonLock = xSemaphoreCreateMutex();
  buildIdentity();
  Power::instance().begin();

  const bool oledOk = Ui::instance().begin();
  const bool accelOk = g_accel.begin();

  g_detector.configure(saas::DetectorCfg{});
  g_sm.reset();

  g_hooks.onFrame = onFrame;
  g_hooks.nextTelemetry = nextTelemetryDoc;
  g_hooks.buildStatus = buildStatusDoc;
  g_hooks.buildDeviceInfo = buildDeviceInfoDoc;
  g_hooks.buildDiag = buildDiagDoc;
  g_hooks.onEventAck = onEventAck;
  g_hooks.ctx = nullptr;


  Comm::instance().begin(&g_hooks, g_name);
  g_pipeline.attachInterrupts();

  // Boot calibration: the device must still be, and a node that boots with a
  // wrong gravity baseline reports every corner as an orientation change.
  g_pipeline.beginCalibration(millis(), kBootCalibMs);

  // Always. A node that hangs in BOOT used to be undiagnosable from the serial
  // monitor, because the only thing it printed was a repeating data line and the
  // only boot line came out on the failure path.
  Serial.println();
  Serial.println(F("=== SAAS node boot ==="));
  Serial.printf("  accelerometer : %s  addr=0x%02X  DEVID=0x%02X  range=+/-16g  odr=100Hz\n",
                accelOk ? "found" : "NOT FOUND", g_accel.address(),
                accelOk ? g_accel.deviceId() : 0);
  Serial.printf("  oled          : %s\n", oledOk ? "found" : "NOT FOUND");
  Serial.printf("  run mode      : %s  (always NORMAL on boot; click SOS to toggle)\n",
                runModeName(g_demo.mode()));
  Serial.printf("  boot calib    : %ums\n", static_cast<unsigned>(kBootCalibMs));
  Serial.println(F("  button        : click = mode, hold 800ms = SOS"));
  if (!accelOk) {
    // The single most useful line on a bench. Without it the natural reaction to
    // a node that reports 0.1 g is to suspect the firmware's scaling.
    Serial.println(F(
        "  !! no accelerometer: check VS (3.3V), GND, and SDA/SCL (21/22)."));
    Serial.println(F(
        "     an unpowered ADXL345 still answers I2C on some breakouts, so DEVID"));
    Serial.println(F("     can read 0xE5 while the data registers read zero."));
  }
  Serial.println(F("  live |a| and raw axes print below; OLED shows the same"));
  Serial.println();

  xTaskCreatePinnedToCore(sensorTask, "sensor", kStackSensor, nullptr, kPrioSensor, &g_handle[kWdSensor], 1);
  xTaskCreatePinnedToCore(detectTask, "detect", kStackDetect, nullptr, kPrioDetect, &g_handle[kWdDetect], 1);
  xTaskCreatePinnedToCore(bleTask, "ble", kStackBle, nullptr, kPrioBle, &g_handle[kWdBle], 0);
  xTaskCreatePinnedToCore(uiTask, "ui", kStackUi, nullptr, kPrioUi, &g_handle[kWdUi], 0);
  xTaskCreatePinnedToCore(sysTask, "sys", kStackSys, nullptr, kPrioSys, &g_handle[kWdSys], 0);
  xTaskCreatePinnedToCore(wdtTask, "wdt", kStackWdt, nullptr, kPrioWdt, &g_handle[kWdWatchdog], 0);
}

void loop() {
  // Every real decision happens in the tasks above. loop() exists because the
  // Arduino framework requires it, and it does exactly one thing: stay out of
  // the way. Sleeping here rather than spinning is what keeps the idle core off
  // the bus and lets light sleep engage between samples.
  vTaskDelay(pdMS_TO_TICKS(1000));
}
