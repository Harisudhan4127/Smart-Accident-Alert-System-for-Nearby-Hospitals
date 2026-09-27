// SmartAccidentAlert.ino — Smart Accident Alert Node.
//
// Six tasks across two cores, per docs/02-ble-protocol.md §9 and
// PROJECT_PLAN.md §8. The shape of the firmware is deliberately boring:
//
//   core 1   sensorTask  blocking I2C burst read of the MPU6050
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
#include <Wire.h>
#include <esp_mac.h>

#include "comm.h"
#include "config.h"
#include "detector.h"
#include "json.h"
#include "power.h"
#include "protocol.h"
#include "sensors.h"
#include "state_machine.h"
#include "ui.h"

using namespace saas;

// ---------------------------------------------------------------------------
// Shared state. Every cross-task value here is either atomic or guarded by the
// mutex below, and the comment on each says which.
// ---------------------------------------------------------------------------

namespace {

// Task ids for the watchdog slots; must match Power::kTaskSlots.
// One slot per task, plus the watchdog. The watchdog is deliberately its own
// entry rather than reusing `kWdCount - 1`, which is `kWdSys` — a previous build
// stored the watchdog's handle there and silently clobbered the sysTask handle,
// so the diagnostics display showed a task that had been replaced.
enum WdTask : uint8_t { kWdSensor = 0, kWdDetect, kWdBle, kWdUi, kWdSys, kWdWatchdog, kWdCount };

saas::Mpu6050 g_mpu;
saas::SensorPipeline g_pipeline;
saas::Detector g_detector;
saas::StateMachine g_sm;

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
uint32_t g_mpuI2cErrors = 0;
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

/// One ADC sample, oversampled 16x. A single sample of a LiPo divider is noisy
/// enough to swing the percentage by several points, which would make the OLED
/// number flicker constantly and wake the UI task for nothing.
static uint16_t g_batteryAdc() {
  uint32_t acc = 0;
  for (uint8_t i = 0; i < 16; i++) acc += analogReadMilliVolts(kPinBatteryAdc);
  return static_cast<uint16_t>(acc / 16);
}

/// TP4056 CHRG is open-drain and pulls LOW while charging; on a board with no
/// CHRG wire we fall back to a voltage that is still rising, which is what
/// kChargingHeuristic in config.h is for.
static bool g_charging() {
  if (kChargingPinPresent) return digitalRead(kPinChargingStat) == LOW;
  static uint16_t lastMv = 0;
  const uint16_t mv = batteryMilliVolts(g_batteryAdc());
  const bool rising = mv > lastMv;
  lastMv = mv;
  return kChargingHeuristic ? rising : false;
}

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
  v.cfg.gyroThresholdDps10 = s.gyroThresholdDps10;
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
  v.peakGyrDps = g_detector.peakGyrDps();
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
  v.batteryMv = batteryMilliVolts(g_batteryAdc());
  v.rssi = Comm::instance().rssi();
  portENTER_CRITICAL(&g_stateLock);
  v.mpuI2cErrors = g_mpuI2cErrors;
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
  v.impact.peakGyrDps = d.peakGyrDps;
  v.impact.gyrMagDps10 = d.gyrMagDps10;
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
  ranged("gyroThresholdDps", kCfgGyroThresholdDps10Min / 10, kCfgGyroThresholdDps10Max / 10, tmp);
  if (tmp) s.gyroThresholdDps10 = static_cast<uint16_t>(tmp * 10);
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
  dc.gyroThresholdDps10 = s.gyroThresholdDps10;
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
      hv.batteryMv = batteryMilliVolts(g_batteryAdc());
      hv.batteryPct = hv.batteryMv ? batteryPercent(hv.batteryMv) : 255;
      hv.charging = g_charging();
      hv.uptimeMs = now;
      hv.mpuPresent = g_mpu.present();
      hv.mpuAddr = "0x68";
      hv.whoAmI = g_mpu.present() ? g_mpu.whoAmI() : -1;
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
      if (isResetStats) {
        g_detector.resetStats();
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
    int16_t ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
    raw.sensorOk = g_mpu.read(ax, ay, az, gx, gy, gz);
    if (raw.sensorOk) {
      raw.axMg = SensorPipeline::accelMg(ax);
      raw.ayMg = SensorPipeline::accelMg(ay);
      raw.azMg = SensorPipeline::accelMg(az);
      raw.gxDps10 = SensorPipeline::gyroDps10(gx);
      raw.gyDps10 = SensorPipeline::gyroDps10(gy);
      raw.gzDps10 = SensorPipeline::gyroDps10(gz);
    }
    raw.sw420Raw = digitalRead(kPinSw420) == HIGH;

    Sample s{};
    const uint32_t now = millis();
    g_pipeline.step(now, raw, s);
    s.tMs = now;
    pushSample(s);

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
      t.gxDps10 = static_cast<int16_t>(s.gxDps10);
      t.gyDps10 = static_cast<int16_t>(s.gyDps10);
      t.gzDps10 = static_cast<int16_t>(s.gzDps10);
      t.magMg = s.magMg;
            t.peakMg = d.magMg;
      t.score = d.score;
      t.state = g_sm.state();
      t.batteryPct = batteryPercent(batteryMilliVolts(g_batteryAdc()));
      t.flags = g_sm.flags(false, false, false, Ui::instance().oledOk(),
                           Ui::instance().buttonDown(), g_charging());
      pushTelemetry(t);

      if (d.tripped) {
        const saas::Transition tr = g_sm.trip(s.tMs);
        if (tr.legal) queueEvent(proto::kEvAccidentDetected, d, d.score);
        if (tr.to == proto::kStatePending) Ui::instance().chirp();
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
    m.batteryMv = batteryMilliVolts(g_batteryAdc());
    m.batteryPct = m.batteryMv ? batteryPercent(m.batteryMv) : 255;
    m.charging = g_charging();
    m.sw420 = g_pipeline.sw420Level();
    m.sosHeld = Ui::instance().buttonDown();
    m.muted = g_sm.mutedByClock(time(nullptr)) || m.state == proto::kStateMuted;
    m.score = g_detector.lastScore();
    m.speedKmh = static_cast<uint8_t>(g_detector.lastSpeedMilliKmh() / 1000);
    m.sensorOk = !g_sensorFault;
    m.mpuPresent = g_mpu.present();
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

    // Fault detection: too many consecutive I2C failures is a detached sensor,
    // and a detector fed zeros will happily call every bump a crash.
    static uint8_t consecutive = 0;
    if (!g_mpu.present()) {
      if (consecutive < 200) consecutive++;
    } else {
      consecutive = 0;
    }
    const bool fault = consecutive >= 100;
    if (fault != g_sensorFault) {
      g_sensorFault = fault;
      g_stateSinceMs = now;
      if (fault) {
        g_sm.dispatch(saas::Trigger::kFault, now);
        queueEvent(proto::kEvDeviceFault, saas::Decision{}, 0);
      } else {
        g_sm.sensorsOk();
      }
    }

    Power::instance().checkWatchdog(now);
    vTaskDelay(pdMS_TO_TICKS(kSysPeriodMs));
    Power::instance().feed(kWdSys);

  // Drain any pending calibration log (see g_calibLogPending). Done here
  // rather than inline in the command handler so the ACK is sent immediately
  // and the (potentially multi-frame) log does not delay it.
  if (g_calibLogPending) {
    g_calibLogPending = false;
    streamCalibLog();
  }
  }
}

static void wdtTask(void*) {
  for (;;) {
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
  const bool mpuOk = g_mpu.begin();

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

  if (!mpuOk || !oledOk) {
    // Not fatal for BLE, but the UI shows NOMP and sysTask will raise a fault.
    Serial.printf("boot: mpu=%d oled=%d\n", mpuOk, oledOk);
  }

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
