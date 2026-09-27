// comm.h — BLE transport: the GATT server, the RX framing path, and the TX
// pacing/sequencer loops (docs/02-ble-protocol.md §2, §8).
//
// Deliberately ignorant of the rest of the firmware. It takes a table of
// function pointers and calls back out; nothing in here knows what a detector,
// a state machine or a FreeRTOS task is. That keeps the NimBLE API surface --
// which differs between NimBLE-Arduino 1.x, 2.x and ESP32's Bluedroid stack --
// confined to comm.cpp, so a library upgrade is one file to fix.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "config.h"
#include "event_queue.h"
#include "protocol.h"

namespace saas {

/// The RX characteristic is write-without-response, so the phone may deliver
/// several frames back to back and the stack hands them over in chunks that do
/// not respect frame boundaries. Everything below a notify chunk is reassembled
/// here, which is why FrameScanner is fed byte-at-a-time rather than per-chunk.
struct BleHooks {
  /// A complete frame with a good CRC arrived. The scanner has already verified
  /// the CRC and split the header from the body, so it hands over the parsed
  /// `type`/`version` rather than a raw buffer -- the type is a header field, and
  /// passing only the payload would make the receiver guess it from payload[0],
  /// which is the first byte of the JSON document.
  void (*onFrame)(const proto::Frame& frame, void* ctx) = nullptr;

  /// Fill the next telemetry record; return false when none is ready. Telemetry
  /// is best-effort, so an empty ring here is normal and not an error.
  bool (*nextTelemetry)(proto::Telemetry* out, void* ctx) = nullptr;

  /// On-demand documents for the INFO/CTRL read paths.
  size_t (*buildDeviceInfo)(char* out, size_t cap, void* ctx) = nullptr;
  size_t (*buildStatus)(char* out, size_t cap, void* ctx) = nullptr;
  size_t (*buildDiag)(char* out, size_t cap, void* ctx) = nullptr;

  /// The phone ACKed a CTRL frame (docs §8 step 3). `seq` is the frame's seq.
  void (*onEventAck)(uint8_t type, uint16_t seq, void* ctx) = nullptr;

  void* ctx = nullptr;
};

/// The four characteristics of docs §2.1. Public because the NimBLE callbacks
/// need to name them, and because they are part of the wire contract.
enum CharId : uint8_t { kCharTx = 0, kCharRx, kCharCtrl, kCharInfo, kCharCount };

class Comm {
 public:
  /// One instance for the lifetime of the process; the NimBLE callbacks are
  /// free functions and have nowhere else to find their state.
  static Comm& instance();

  /// Brings up the stack, registers the service, and starts advertising.
  /// Returns false if the stack or the service could not be created -- a real
  /// failure the caller must surface, not paper over.
  bool begin(const BleHooks* hooks, const char* deviceName);

  /// Call from bleTask on every tick. Sends at most one telemetry record and at
  /// most one event, so a congested link can never stall the task.
  void loop(uint32_t nowMs);

  bool connected() const { return clientCount_ > 0; }
  uint8_t clientCount() const { return clientCount_; }
  /// 0 when the stack cannot report it (Bluedroid exposes no cheap RSSI on all
  /// versions), which json.cpp renders as "rssi": null via DiagView::rssi.
  int8_t rssi() const { return rssi_; }

  /// Queue a pre-rendered CTRL event. The bytes are stored and re-sent verbatim
  /// on every retry, which is what makes a retransmission idempotent.
  bool queueEvent(const EventQueue::Slot& s, uint32_t nowMs);
  uint8_t queueDepth() const { return events_.depth(); }
  bool anyDropped() const { return events_.anyDropped(); }
  uint8_t droppedCount() const { return events_.droppedCount(); }
  /// True when the current event used up its retries: the UI flashes the red LED
  /// for this (docs §8 step 5).
  bool eventUndelivered() const { return events_.exhausted(); }

  /// Send a CTRL document immediately, bypassing the queue. Used for
  /// ACK/ERROR, which are not retried and must not queue behind a backlog.
  /// Sends an already-encoded frame on CTRL as-is. The queue and the builders
  /// below both hand over a complete frame, so encoding again here would wrap a
  /// frame in a second frame and the phone would fail to parse it.
  void notifyCtrlFrameNow(const void* frame, size_t len);

  uint32_t crcErrors() const { return crcErrors_; }
  uint32_t droppedFrames() const { return droppedFrames_; }
  uint32_t bytesIn() const { return bytesIn_; }
  uint32_t bytesOut() const { return bytesOut_; }

  /// Telemetry pacing, settable by CONFIG.
  void setTelemetryHz(uint16_t hz);
  uint16_t telemetryHz() const { return telemetryHz_; }

  /// Push a STATUS the app asked for (after a CALIB_LOG chunk, for instance).
  void sendStatus(uint32_t nowMs);

  // --- called from the NimBLE callbacks (see comm.cpp) ---------------------
  /// Reassemble frames from a chunk of the RX characteristic. Public because it
  /// is the callback's only door in, and the narrower the better.
  void feedRx(const uint8_t* data, size_t len);
  /// A phone connected or disconnected. Signed so one call site covers both.
  void bumpClient(int8_t delta);
  /// The phone ACKed the CTRL event we last sent (docs §8 step 3). Retires the
  /// head so the next event goes out immediately instead of waiting out the
  /// retry timer.
  void onEventAck(uint16_t seq);
  /// Read paths for TX/INFO.
  size_t readInfo(char* out, size_t cap);
  size_t readTx(char* out, size_t cap);

 private:
  Comm() = default;
  void serviceTick(uint32_t nowMs);
  void drainEvents(uint32_t nowMs);
  bool notify(const void* data, size_t len, uint8_t which);

  const BleHooks* hooks_ = nullptr;
  EventQueue events_{};

  uint32_t crcErrors_ = 0;
  uint32_t droppedFrames_ = 0;
  uint32_t bytesIn_ = 0;
  uint32_t bytesOut_ = 0;

  uint16_t telemetryHz_ = kTelemetryHzDefault;
  uint32_t nextTelemetryMs_ = 0;

  /// Seq of the CTRL frame currently in flight, for ACK matching. Only one
  /// event is ever outstanding (stop-and-wait), so one counter is enough.
  uint16_t eventSeq_ = 0;
  bool eventInFlight_ = false;

  uint8_t clientCount_ = 0;
  int8_t rssi_ = 0;
  bool advertising_ = false;

  /// Reassembly for RX. Static, not per-connection: there is exactly one phone
  /// at a time and a partially-received frame must survive a reconnect anyway.
  proto::FrameScanner scanner_{};

  /// Chunking state for CALIB_LOG. The 512-byte payload budget fits only ~5
  /// samples per frame, so a 48-sample log is 10 frames ending with a STATUS.
  uint8_t calibTotal_ = 0;
  uint8_t calibSent_ = 0;
  bool calibActive_ = false;
};

}  // namespace saas
