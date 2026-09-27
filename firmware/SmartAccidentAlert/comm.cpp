// comm.cpp — NimBLE/Bluedroid transport.
//
// The version shims below are the whole reason this file exists separately from
// the application. NimBLE-Arduino 1.x, 2.x and ESP32's Bluedroid stack disagree
// on: how a characteristic declares its properties, how write callbacks are
// registered, what a connect callback receives, and how to read RSSI. All of
// that is confined here; nothing above this file mentions NimBLE.
#include "comm.h"

#if defined(ARDUINO)
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLECppVersion.h>

#include "json.h"

namespace saas {
namespace {

Comm* g_comm = nullptr;

// NimBLE-Arduino 2.x removed the PROPERTY_* enums, made setProperties()
// protected, and changed every callback to take a NimBLEConnInfo&. The library
// publishes its version in NimBLECppVersion.h, which is the only reliable test:
// guessing from NimBLEConnInfo.h's presence depends on the include path, and
// `defined(__has_include)` is always false because __has_include is a
// preprocessor operator rather than a macro.
// A MACRO, not a constexpr: every use below is in an #if, and #if only ever
// sees macros -- a constexpr bool silently reads as 0 there, which compiles the
// NimBLE 1.x branch of every shim and produces a page of "not a member of
// NimBLECharacteristic" errors against a 2.x library.
#if defined(NIMBLE_CPP_VERSION_MAJOR) && NIMBLE_CPP_VERSION_MAJOR >= 2
#define SAAS_NIMBLE_V2 1
#else
#define SAAS_NIMBLE_V2 0
#endif

// ---------------------------------------------------------------------------
// Write callback: reassembles frames out of a write-without-response stream
// ---------------------------------------------------------------------------

/// A single write-without-response chunk can carry a fraction of a frame, several
/// frames, or the middle of one. Feeding the scanner byte-at-a-time is the only
/// thing that survives all three, and it costs one array read per byte.
void onRxWrite(const uint8_t* data, size_t len) {
  if (g_comm && data) g_comm->feedRx(data, len);
}

/// Property bits, and the translation to whichever stack is compiled in. 2.x
/// moved the constants into the NIMBLE_PROPERTY namespace and 1.x kept them as
/// NimBLECharacteristic::PROPERTY_*, but both accept them as the `properties`
/// argument of createCharacteristic(), so that is where they are applied: 2.x
/// protects setProperties(), and there is no public setter to call afterwards.
enum PropBits : uint32_t { kRead = 1, kWriteNoRsp = 2, kNotify = 4 };

uint32_t propBits(uint8_t bits) {
  uint32_t p = 0;
#if SAAS_NIMBLE_V2
  if (bits & kRead) p |= NIMBLE_PROPERTY::READ;
  if (bits & kWriteNoRsp) p |= NIMBLE_PROPERTY::WRITE_NR;
  if (bits & kNotify) p |= NIMBLE_PROPERTY::NOTIFY;
#else
  if (bits & kRead) p |= NimBLECharacteristic::PROPERTY_READ;
  if (bits & kWriteNoRsp) p |= NimBLECharacteristic::PROPERTY_WRITE_NR;
  if (bits & kNotify) p |= NimBLECharacteristic::PROPERTY_NOTIFY;
#endif
  return p;
}

/// The written value. 2.x exposes the raw attribute value; 1.x hands back a
/// std::string, which is why the 1.x branch copies out of it.
void feedWrite(NimBLECharacteristic* chr);
void feedWrite(NimBLECharacteristic* chr) {
#if SAAS_NIMBLE_V2
  const NimBLEAttValue v = chr->getValue();
  onRxWrite(v.data(), v.length());
#else
  const std::string v = chr->getValue();
  onRxWrite(reinterpret_cast<const uint8_t*>(v.data()), v.size());
#endif
}

void setReadValue(NimBLECharacteristic* chr, const char* buf, size_t n) {
#if SAAS_NIMBLE_V2
  chr->setValue(reinterpret_cast<const uint8_t*>(buf), n);
#else
  chr->setValue(std::string(buf, n));
#endif
}

/// The stack actually compiled in. Exactly one is true for any given build.
#if defined(CONFIG_BT_NIMBLE_ENABLED)
#define SAAS_NIMBLE 1
#else
#define SAAS_NIMBLE 0
#endif


// NimBLE-Arduino 2.x replaced the characteristic callback object with a single
// handler class, and the payload moved from a bare pointer to a NimBLEConnInfo&.
#if SAAS_NIMBLE_V2
class RxHandler : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo& /*info*/) override { feedWrite(chr); }
};
#else
class RxHandler : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic* chr) override {
    std::string v = chr->getValue();
    if (v.empty()) return;
    onRxWrite(reinterpret_cast<const uint8_t*>(v.data()), v.size());
  }
};
#endif

/// Static handles. NimBLE objects live for the process lifetime and the callbacks
/// are free functions, so there is nowhere better to put them.
NimBLECharacteristic* g_chr[kCharCount] = {};

class ServerHandler : public NimBLEServerCallbacks {
 public:
#if SAAS_NIMBLE_V2
  void onConnect(NimBLEServer* /*srv*/, NimBLEConnInfo& /*info*/) override { bump(+1); }
  void onDisconnect(NimBLEServer* /*srv*/, NimBLEConnInfo& /*info*/, int /*reason*/) override {
    bump(-1);
  }
#else
  void onConnect(NimBLEServer* /*srv*/) override { bump(+1); }
  void onDisconnect(NimBLEServer* /*srv*/) override { bump(-1); }
#endif
  static void bump(int8_t d) { if (g_comm) g_comm->bumpClient(d); }
};

/// Read path for TX/INFO. A notification-only characteristic still needs a
/// readable value for the app that polls instead of subscribing.
class ReadHandler : public NimBLECharacteristicCallbacks {
 public:
#if SAAS_NIMBLE_V2
  void onRead(NimBLECharacteristic* chr, NimBLEConnInfo& /*info*/) override {
#else
  void onRead(NimBLECharacteristic* chr) override {
#endif
    Comm* c = g_comm;
    if (!c) return;
    static char buf[kJsonBufSize];
    buf[0] = '\0';
    const bool info = (chr == g_chr[kCharInfo]);
    size_t n = info ? c->readInfo(buf, sizeof(buf)) : c->readTx(buf, sizeof(buf));
    if (!n) n = static_cast<size_t>(snprintf(buf, sizeof(buf), "{\"err\":\"no doc\"}"));
    setReadValue(chr, buf, n);
  }
};

}  // namespace

Comm& Comm::instance() {
  static Comm c;
  return c;
}

bool Comm::begin(const BleHooks* hooks, const char* deviceName) {
  hooks_ = hooks;
  scanner_.reset();
  events_.reset();
  g_comm = this;

  NimBLEDevice::init(deviceName);
  // MTU 247 is what the protocol asks for (§2.3); the core falls back to 23 on
  // its own if the phone refuses, and a 24-byte telemetry record still fits.
  NimBLEDevice::setMTU(247);
#if SAAS_NIMBLE_V2
  NimBLEDevice::setPower(kBleTxPowerDbm, NimBLETxPowerType::Advertise);
#else
  NimBLEDevice::setPower(kBleTxPowerDbm);
#endif

  NimBLEServer* srv = NimBLEDevice::createServer();
  srv->setCallbacks(new ServerHandler());
  // Advertising payload: name, 128-bit service UUID, and the 16-bit appearance
  // from §2.4, so a phone can filter on the node without connecting.
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
#if SAAS_NIMBLE_V2
  adv->addServiceUUID(proto::kUuidService);
  adv->setAppearance(kBleAppearance);
  adv->setMinInterval(kConnIntervalMinMs);
  adv->setMaxInterval(kConnIntervalMaxMs);
  adv->enableScanResponse(true);
#else
  adv->addServiceUUID(proto::kUuidService);
  adv->setAppearance(kBleAppearance);
  adv->setMinInterval(kConnIntervalMinMs);
  adv->setMaxInterval(kConnIntervalMaxMs);
  adv->enableScanResponse(true);
  NimBLEDevice::startAdvertising();
#endif
  advertising_ = true;

  NimBLEService* svc = srv->createService(proto::kUuidService);

  // TX: notify + read. Telemetry, best-effort, dropped rather than queued.
  g_chr[kCharTx] = svc->createCharacteristic(proto::kUuidTx, propBits(kRead | kNotify));
  // RX: write-without-response. Requests must not be throttled by the phone's
  // confirmation interval, and a 512-byte payload exceeds the default MTU anyway.
  g_chr[kCharRx] = svc->createCharacteristic(proto::kUuidRx, propBits(kRead | kWriteNoRsp));
  // CTRL: notify only. Carries the events that must not be dropped (§2.2).
  g_chr[kCharCtrl] = svc->createCharacteristic(proto::kUuidCtrl, propBits(kNotify));
  // INFO: read only. Static identity, fetched once on connect.
  g_chr[kCharInfo] = svc->createCharacteristic(proto::kUuidInfo, propBits(kRead));

  g_chr[kCharRx]->setCallbacks(new RxHandler());
  g_chr[kCharInfo]->setCallbacks(new ReadHandler());
  g_chr[kCharTx]->setCallbacks(new ReadHandler());

  svc->start();
  // Start advertising only once the GATT server is serving the service, otherwise
  // a scanner sees the UUID but a connect finds nothing.
  NimBLEDevice::startAdvertising();
  return g_chr[kCharCtrl] != nullptr;
}

bool Comm::notify(const void* data, size_t len, uint8_t which) {
  if (!clientCount_ || which >= kCharCount || !g_chr[which]) return false;
  const uint8_t* p = static_cast<const uint8_t*>(data);
#if SAAS_NIMBLE_V2
  g_chr[which]->setValue(p, len);
  const bool ok = g_chr[which]->notify();
#else
  g_chr[which]->setValue(std::string(reinterpret_cast<const char*>(p), len));
  const bool ok = g_chr[which]->notify();
#endif
  if (ok) bytesOut_ += len;
  return ok;
}

bool Comm::queueEvent(const EventQueue::Slot& s, uint32_t nowMs) {
  return events_.push(s, nowMs);
}

void Comm::notifyCtrlFrameNow(const void* frame, size_t len) {
  if (notify(frame, len, kCharCtrl)) {
    bytesOut_ += len;
    eventInFlight_ = true;
  }
}

void Comm::onEventAck(uint16_t seq) {
  if (hooks_ && hooks_->onEventAck) hooks_->onEventAck(proto::kTypeEvent, seq, hooks_->ctx);
  if (!eventInFlight_) return;
  if (seq != eventSeq_) return;  // a stale or duplicated ACK: keep the event, retry it
  eventInFlight_ = false;
  events_.retire();
  eventSeq_++;
}

void Comm::setTelemetryHz(uint16_t hz) {
  if (hz < kTelemetryHzMin) hz = kTelemetryHzMin;
  if (hz > kTelemetryHzMax) hz = kTelemetryHzMax;
  telemetryHz_ = hz;
}

void Comm::loop(uint32_t nowMs) {
  serviceTick(nowMs);
  drainEvents(nowMs);
}

void Comm::serviceTick(uint32_t nowMs) {
  if (!clientCount_ || !hooks_ || !hooks_->nextTelemetry) return;
  // Unsigned compare, so a clock that steps back does not spin the loop
  // re-sending until it catches up.
  if (nowMs < nextTelemetryMs_) return;
  const uint32_t period = 1000u / (telemetryHz_ ? telemetryHz_ : kTelemetryHzDefault);
  // Never schedule in the past: an overrun must not turn into a burst of
  // back-to-back notifies, which is exactly what makes Android drop them.
  nextTelemetryMs_ = (nowMs > 0xFFFFFFFFu - period) ? nowMs : nowMs + period;

  proto::Telemetry t{};
  if (!hooks_->nextTelemetry(&t, hooks_->ctx)) return;
  uint8_t buf[proto::kTelemetrySize];
  const size_t n = proto::packTelemetry(buf, t);
  if (!n) return;
  if (!notify(buf, n, kCharTx)) droppedFrames_++;
}

void Comm::drainEvents(uint32_t nowMs) {
  if (!clientCount_) return;

  const EventQueue::Slot* head = events_.head();
  if (!head) return;

  // First pass: send whatever the head is. armRetry is called *after* the send
  // so a queue that was never sent is never treated as overdue.
  if (events_.attempt() == 0 && !events_.retryDue(nowMs)) {
    // attempt 0 with no timer armed means "not sent yet"; send and arm.
    if (notify(head->data, head->len, kCharCtrl)) {
      events_.armRetry(nowMs, 0);
    }
    return;
  }

  if (!events_.retryDue(nowMs)) return;

  if (events_.exhausted()) {
    // §8 step 5: three failed attempts. The event stays at the head so the UI
    // can report it undelivered and it is drained on the next connection; the
    // red-LED flash is driven off eventUndelivered().
    return;
  }
  const uint8_t attempt = events_.attempt();
  if (notify(head->data, head->len, kCharCtrl)) {
    events_.armRetry(nowMs, static_cast<uint8_t>(attempt + 1));
  } else {
    // The link refused it: re-arm without consuming an attempt, otherwise a
    // congested phone burns all three retries without ever transmitting.
    events_.armRetry(nowMs, attempt);
  }
}

void Comm::feedRx(const uint8_t* data, size_t len) {
  // A write-without-response chunk can hold a fraction of a frame, several
  // frames, or the middle of one. Feeding the scanner a byte at a time is the
  // only thing that survives all three, and it costs one array read per byte.
  for (size_t i = 0; i < len; i++) {
    proto::Frame f{};
    if (!scanner_.push(data[i], f)) continue;
    bytesIn_ += f.len + proto::kFrameOverhead;
    if (hooks_ && hooks_->onFrame) hooks_->onFrame(f, hooks_->ctx);
  }
}

void Comm::bumpClient(int8_t delta) {
  if (delta > 0) {
    if (clientCount_ < 0xFF) clientCount_++;
    // A new phone gets a fresh HELLO_ACK; the old link's state is gone, and so
    // does any ACK the old phone still owed us.
    rssi_ = 0;
    eventInFlight_ = false;
  } else if (clientCount_ > 0) {
    clientCount_--;
  }
  if (clientCount_ == 0) rssi_ = 0;
}

size_t Comm::readInfo(char* out, size_t cap) {
  if (!hooks_ || !hooks_->buildDeviceInfo) return 0;
  return hooks_->buildDeviceInfo(out, cap, hooks_->ctx);
}

size_t Comm::readTx(char* out, size_t cap) {
  if (!hooks_ || !hooks_->buildStatus) return 0;
  return hooks_->buildStatus(out, cap, hooks_->ctx);
}

void Comm::sendStatus(uint32_t nowMs) {
  if (!clientCount_ || !hooks_ || !hooks_->buildStatus) return;
  char buf[kJsonBufSize];
  const size_t n = hooks_->buildStatus(buf, sizeof(buf), hooks_->ctx);
  if (!n) return;
  uint8_t frame[kFrameBufSize];
  const size_t fn = proto::encodeJson(frame, sizeof(frame), proto::kTypeStatus, buf, n);
  if (fn) notify(frame, fn, kCharCtrl);
  (void)nowMs;
}

}  // namespace saas

#else  // !ARDUINO — host build: pure logic only, so the module can be reasoned
       // about (and type-checked) without a radio stack.

namespace saas {
Comm& Comm::instance() {
  static Comm c;
  return c;
}
bool Comm::begin(const BleHooks* hooks, const char*) {
  hooks_ = hooks;
  return false;
}
void Comm::loop(uint32_t) {}
bool Comm::queueEvent(const EventQueue::Slot& s, uint32_t nowMs) { return events_.push(s, nowMs); }

void Comm::setTelemetryHz(uint16_t hz) {
  if (hz < kTelemetryHzMin) hz = kTelemetryHzMin;
  if (hz > kTelemetryHzMax) hz = kTelemetryHzMax;
  telemetryHz_ = hz;
}
void Comm::serviceTick(uint32_t) {}
void Comm::drainEvents(uint32_t) {}
bool Comm::notify(const void*, size_t, uint8_t) { return false; }
void Comm::sendStatus(uint32_t) {}
void Comm::feedRx(const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    proto::Frame f{};
    if (!scanner_.push(data[i], f)) continue;
    if (hooks_ && hooks_->onFrame) hooks_->onFrame(f, hooks_->ctx);
  }
}
void Comm::bumpClient(int8_t delta) {
  if (delta > 0) { if (clientCount_ < 0xFF) clientCount_++; rssi_ = 0; }
  else if (clientCount_ > 0) { clientCount_--; }
  if (clientCount_ == 0) rssi_ = 0;
}
size_t Comm::readInfo(char*, size_t) { return 0; }
size_t Comm::readTx(char*, size_t) { return 0; }
}  // namespace saas

#endif  // ARDUINO
