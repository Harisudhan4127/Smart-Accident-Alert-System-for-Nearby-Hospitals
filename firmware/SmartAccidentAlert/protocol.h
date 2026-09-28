// protocol.h — BLE wire codec. Frozen contract: docs/02-ble-protocol.md.
//
// This file and protocol.cpp are deliberately free of every Arduino / ESP-IDF
// dependency so the exact bytes this firmware puts on the air can be checked
// against tools/protocol/golden.json on a host compiler. Nothing here allocates,
// prints, or blocks.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace saas {
namespace proto {

// ---------------------------------------------------------------------------
// §2 GATT layout and §3 framing constants
// ---------------------------------------------------------------------------

constexpr uint8_t kSof0 = 0xA5;
constexpr uint8_t kSof1 = 0x5A;
constexpr uint16_t kMaxPayload = 512;
/// Telemetry record size.
///
/// v1 was 24 bytes: tMs(4) + accel(6) + gyro(6) + mag(2) + peak(2) + 4 bytes of
/// flags/score/battery/state. The ADXL345 has no gyroscope, so the six gyro
/// bytes were removed outright rather than zero-filled. Sending zeros would
/// have been the cheaper change and the worse one: a stream of exactly-zero
/// rotation rate reads as a healthy gyro on a node that has none, and any trend
/// or alerting built on it would be confidently wrong.
///
/// 18 bytes is also a third fewer to move at the default 10 Hz, and the record
/// is already well under the 20-byte-att characteristic-level floor that
/// fragmentation and power draw care about, so the saving is real but modest.
constexpr size_t kTelemetrySize = 18;
/// Wire version. v2 is the ADXL345 layout above; v1 was the six-axis MPU6050
/// record. The scanner refuses anything but the version it implements, so an
/// old app and a new node cannot half-talk.
constexpr uint8_t kProtocolVersion = 2;
/// SOF0 SOF1 VER TYPE LEN_L LEN_H. The payload always starts at offset 6.
constexpr size_t kHeaderSize = 6;
/// Frame overhead: header + CRC_L CRC_H.
constexpr size_t kFrameOverhead = 8;

constexpr char kUuidService[] = "7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001";
constexpr char kUuidTx[] = "7c9e0001-1e4a-4f6b-9c2d-5a1b7c30d001";
constexpr char kUuidRx[] = "7c9e0002-1e4a-4f6b-9c2d-5a1b7c30d001";
constexpr char kUuidCtrl[] = "7c9e0003-1e4a-4f6b-9c2d-5a1b7c30d001";
constexpr char kUuidInfo[] = "7c9e0004-1e4a-4f6b-9c2d-5a1b7c30d001";

// ---------------------------------------------------------------------------
// §4 message types
// ---------------------------------------------------------------------------

enum Type : uint8_t {
  kTypeHello = 0x01,
  kTypePing = 0x02,
  kTypeConfig = 0x04,
  kTypeCalibrate = 0x05,
  kTypeCommand = 0x06,
  kTypeAck = 0x07,
  kTypeError = 0x08,
  kTypeEvent = 0x09,
  kTypeTelemetry = 0x10,
  kTypeStatus = 0x11,
  kTypeHelloAck = 0x12,
  kTypeCalibLog = 0x13,
  kTypeDiag = 0x14,
  kTypeDeviceInfo = 0x20,
};

/// §4 EVENT envelope discriminators.
enum EventType : uint8_t {
  kEvAccidentDetected = 0,
  kEvManualSos,
  kEvAlertCancelled,
  kEvAlertConfirmed,
  kEvAlertSent,
  kEvResolved,
  kEvDeviceFault,
  kEvCount,
};
const char* eventTypeName(uint8_t t);
/// Returns 0xFF when unknown.
uint8_t eventTypeFromName(const char* name, size_t len);

const char* typeName(uint8_t type);  ///< "HELLO", "TELEMETRY", ...

// ---------------------------------------------------------------------------
// §5 telemetry
// ---------------------------------------------------------------------------

enum State : uint8_t {
  kStateBoot = 0,
  kStateIdle = 1,
  kStatePending = 2,
  kStateAlarm = 3,
  kStateSos = 4,
  kStateMuted = 5,
  kStateFault = 6,
  kStateCount = 7,
};
const char* stateName(uint8_t state);
/// Returns 0xFF when out of range.
uint8_t stateFromName(const char* name, size_t len);

/// §5.1 flags bitfield.
enum Flag : uint8_t {
  kFlagSw420 = 0x01,
  kFlagBuzzer = 0x02,
  kFlagLedRed = 0x04,
  kFlagLedGreen = 0x08,
  kFlagOledOk = 0x10,
  kFlagSosButton = 0x20,
  kFlagArmed = 0x40,
  kFlagCharging = 0x80,
};

/// The 18-byte record as plain fields. Packing is one memcpy, no branches.
struct Telemetry {
  uint32_t tMs;
  int16_t axMg;
  int16_t ayMg;
  int16_t azMg;
  uint16_t magMg;
  uint16_t peakMg;
  uint8_t flags;
  uint8_t score;       ///< 0..100
  uint8_t batteryPct;  ///< 255 = unknown
  uint8_t state;
};

/// Serialises `t` into exactly 18 little-endian bytes. Returns kTelemetrySize.
size_t packTelemetry(uint8_t* out, const Telemetry& t);
/// Parses 18 bytes. Returns false when `len < 18`.
bool unpackTelemetry(const uint8_t* in, size_t len, Telemetry& out);

// ---------------------------------------------------------------------------
// §6.10 error codes
// ---------------------------------------------------------------------------

enum ErrorCode : uint8_t {
  kErrBadFrame = 0,
  kErrUnsupported = 1,
  kErrBadArgs = 2,
  kErrBadState = 3,
  kErrNotArmed = 4,
  kErrBusy = 5,
  kErrInternal = 6,
};
const char* errorCodeName(uint8_t code);

// ---------------------------------------------------------------------------
// §3 CRC-16/CCITT-FALSE
// ---------------------------------------------------------------------------

/// 256-entry table, generated at compile time (constexpr) so it lives in .rodata
/// and costs no boot time. poly 0x1021, init 0xFFFF, no reflection, no xorout —
/// the check values in golden.json are: "" -> 0xFFFF, "123456789" -> 0x29B1.
namespace detail {
constexpr uint16_t crcEntry(uint16_t i) {
  uint16_t crc = static_cast<uint16_t>(i << 8);
  for (int bit = 0; bit < 8; bit++) {
    crc = (crc & 0x8000u) ? static_cast<uint16_t>((crc << 1) ^ 0x1021u)
                          : static_cast<uint16_t>(crc << 1);
  }
  return crc;
}
struct CrcTableBuilder {
  uint16_t v[256];
};
constexpr CrcTableBuilder makeCrcTable() {
  CrcTableBuilder t{};
  for (int i = 0; i < 256; i++) t.v[i] = crcEntry(static_cast<uint16_t>(i));
  return t;
}
}  // namespace detail

/// `inline constexpr` (C++17) so every translation unit shares one .rodata copy and
/// a host conformance test links the exact table the firmware uses.
inline constexpr detail::CrcTableBuilder kCrcTable = detail::makeCrcTable();
constexpr uint16_t crc16Init = 0xFFFF;

/// Same algorithm as tools/protocol/codec.js `crc16`: table-driven, byte at a
/// time, seedable so a caller can chain over discontiguous spans.
constexpr uint16_t crc16(const uint8_t* data, size_t len,
                         uint16_t seed = crc16Init) {
  uint16_t crc = seed;
  for (size_t i = 0; i < len; i++) {
    crc = static_cast<uint16_t>(
        (crc << 8) ^ kCrcTable.v[((crc >> 8) ^ data[i]) & 0xFFu]);
  }
  return crc;
}

// ---------------------------------------------------------------------------
// §3 encoding
// ---------------------------------------------------------------------------

/// Serialises VER/TYPE/LEN/PAYLOAD/CRC16 into `out` (little-endian LEN and CRC).
/// Returns the frame length, or 0 if the payload is too large for `cap`.
size_t encode(uint8_t* out, size_t cap, uint8_t type, const uint8_t* payload,
              size_t len);
/// Convenience for JSON documents already NUL-terminated in a buffer.
size_t encodeJson(uint8_t* out, size_t cap, uint8_t type, const char* json,
                  size_t len);

// ---------------------------------------------------------------------------
// §3 scanner
// ---------------------------------------------------------------------------

/// One decoded frame. `payload` points into the scanner's own static buffer and is
/// valid only until the next push().
struct Frame {
  uint8_t version;
  uint8_t type;
  const uint8_t* payload;
  uint16_t len;
};

/// Incremental scanner, O(1) amortised per byte, O(1) memory, no allocation.
///
/// Byte-for-byte the same state machine as tools/protocol/codec.js `FrameScanner`:
///   sync  --0xA5--> sof1 --0x5A--> header --> body --> crc --> sync
/// A repeated 0xA5 while in sof1 re-latches without consuming, a length above
/// MAX_PAYLOAD abandons the frame instead of reserving 64 KB, and a CRC mismatch
/// returns to sync after consuming the two CRC bytes.
class FrameScanner {
 public:
  /// Scanner states. Deliberately NOT named kSync/kSof1/... : member enumerators
  /// hide namespace-scope names, and `kSof1` here would silently shadow the 0x5A
  /// start-of-frame byte.
  enum State8 : uint8_t { stSync = 0, stSof1, stHeader, stBody, stCrc };

  /// Feeds one byte. Returns true when `out` was filled with a complete frame.
  /// Never allocates, never blocks; safe to call from the BLE callback.
  bool push(uint8_t byte, Frame& out);

  /// Diagnostic counters (surfaced in DIAG).
  uint32_t resyncBytes() const { return resyncBytes_; }
  uint32_t crcErrors() const { return crcErrors_; }
  void reset();

  /// Bytes currently held in the reservoir.
  uint16_t buffered() const { return static_cast<uint16_t>(len_); }

 private:
  uint8_t buf_[600];  // == kFrameBufSize; 6 header + 512 payload + 2 CRC
  uint16_t len_ = 0;
  uint8_t state_ = stSync;
  uint16_t need_ = 0;
  uint8_t type_ = 0;
  uint8_t version_ = 0;
  uint16_t payloadLen_ = 0;
  uint32_t resyncBytes_ = 0;
  uint32_t crcErrors_ = 0;
};

}  // namespace proto
}  // namespace saas
