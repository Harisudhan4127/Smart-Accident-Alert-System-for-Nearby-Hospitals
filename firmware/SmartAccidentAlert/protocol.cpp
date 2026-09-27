// protocol.cpp — see protocol.h. Host-portable by design.
#include "protocol.h"

#include <string.h>

namespace saas {
namespace proto {

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

const char* typeName(uint8_t type) {
  switch (type) {
    case kTypeHello: return "HELLO";
    case kTypePing: return "PING";
    case kTypeConfig: return "CONFIG";
    case kTypeCalibrate: return "CALIBRATE";
    case kTypeCommand: return "COMMAND";
    case kTypeAck: return "ACK";
    case kTypeError: return "ERROR";
    case kTypeEvent: return "EVENT";
    case kTypeTelemetry: return "TELEMETRY";
    case kTypeStatus: return "STATUS";
    case kTypeHelloAck: return "HELLO_ACK";
    case kTypeCalibLog: return "CALIB_LOG";
    case kTypeDiag: return "DIAG";
    case kTypeDeviceInfo: return "DEVICE_INFO";
    default: return "UNKNOWN";
  }
}

const char* stateName(uint8_t state) {
  switch (state) {
    case kStateBoot: return "BOOT";
    case kStateIdle: return "IDLE";
    case kStatePending: return "PENDING";
    case kStateAlarm: return "ALARM";
    case kStateSos: return "SOS";
    case kStateMuted: return "MUTED";
    case kStateFault: return "FAULT";
    default: return "UNKNOWN";
  }
}

uint8_t stateFromName(const char* name, size_t len) {
  for (uint8_t s = 0; s < kStateCount; s++) {
    const char* n = stateName(s);
    if (strlen(n) == len && memcmp(n, name, len) == 0) return s;
  }
  return 0xFF;
}

const char* eventTypeName(uint8_t t) {
  switch (t) {
    case kEvAccidentDetected: return "ACCIDENT_DETECTED";
    case kEvManualSos: return "MANUAL_SOS";
    case kEvAlertCancelled: return "ALERT_CANCELLED";
    case kEvAlertConfirmed: return "ALERT_CONFIRMED";
    case kEvAlertSent: return "ALERT_SENT";
    case kEvResolved: return "RESOLVED";
    case kEvDeviceFault: return "DEVICE_FAULT";
    default: return "UNKNOWN";
  }
}

uint8_t eventTypeFromName(const char* name, size_t len) {
  for (uint8_t e = 0; e < kEvCount; e++) {
    const char* n = eventTypeName(e);
    if (strlen(n) == len && memcmp(n, name, len) == 0) return e;
  }
  return 0xFF;
}

const char* errorCodeName(uint8_t code) {
  switch (code) {
    case kErrBadFrame: return "BAD_FRAME";
    case kErrUnsupported: return "UNSUPPORTED";
    case kErrBadArgs: return "BAD_ARGS";
    case kErrBadState: return "BAD_STATE";
    case kErrNotArmed: return "NOT_ARMED";
    case kErrBusy: return "BUSY";
    case kErrInternal: return "INTERNAL";
    default: return "INTERNAL";
  }
}

// ---------------------------------------------------------------------------
// CRC-16/CCITT-FALSE
//
// kCrcTable and crc16() are constexpr in the header so a host test can use the
// exact same implementation the firmware links. Nothing to define here.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

namespace {
inline int16_t clampI16(int32_t v) {
  if (v > 32767) return 32767;
  if (v < -32768) return -32768;
  return static_cast<int16_t>(v);
}
inline uint16_t clampU16(int32_t v) {
  if (v > 65535) return 65535;
  if (v < 0) return 0;
  return static_cast<uint16_t>(v);
}
inline void putU16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v & 0xFFu);
  p[1] = static_cast<uint8_t>(v >> 8);
}
/// Signed field: clamp to [-32768, 32767] then reinterpret, so a negative value
/// survives (clamping to the *unsigned* range would zero it out).
inline void putI16(uint8_t* p, int32_t v) {
  if (v > 32767) v = 32767;
  if (v < -32768) v = -32768;
  putU16(p, static_cast<uint16_t>(static_cast<int16_t>(v)));
}
inline uint16_t getU16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
inline int16_t getI16(const uint8_t* p) {
  return static_cast<int16_t>(getU16(p));
}
}  // namespace

size_t packTelemetry(uint8_t* out, const Telemetry& t) {
  out[0] = static_cast<uint8_t>(t.tMs & 0xFFu);
  out[1] = static_cast<uint8_t>((t.tMs >> 8) & 0xFFu);
  out[2] = static_cast<uint8_t>((t.tMs >> 16) & 0xFFu);
  out[3] = static_cast<uint8_t>((t.tMs >> 24) & 0xFFu);
  int o = 4;
  // Clamping (not truncation) matches codec.js clampI16/clampU16, so the saturation
  // golden vector round-trips byte-for-byte.
  putI16(out + o, t.axMg); o += 2;
  putI16(out + o, t.ayMg); o += 2;
  putI16(out + o, t.azMg); o += 2;
  putI16(out + o, t.gxDps10); o += 2;
  putI16(out + o, t.gyDps10); o += 2;
  putI16(out + o, t.gzDps10); o += 2;
  putU16(out + o, clampU16(t.magMg)); o += 2;
  putU16(out + o, clampU16(t.peakMg)); o += 2;
  out[o++] = t.flags;
  out[o++] = t.score;
  out[o++] = t.batteryPct;
  out[o++] = t.state;
  return kTelemetrySize;
}

bool unpackTelemetry(const uint8_t* in, size_t len, Telemetry& out) {
  if (len < kTelemetrySize) return false;
  out.tMs = static_cast<uint32_t>(in[0]) | (static_cast<uint32_t>(in[1]) << 8) |
            (static_cast<uint32_t>(in[2]) << 16) |
            (static_cast<uint32_t>(in[3]) << 24);
  int o = 4;
  out.axMg = getI16(in + o); o += 2;
  out.ayMg = getI16(in + o); o += 2;
  out.azMg = getI16(in + o); o += 2;
  out.gxDps10 = getI16(in + o); o += 2;
  out.gyDps10 = getI16(in + o); o += 2;
  out.gzDps10 = getI16(in + o); o += 2;
  out.magMg = getU16(in + o); o += 2;
  out.peakMg = getU16(in + o); o += 2;
  out.flags = in[o++];
  out.score = in[o++];
  out.batteryPct = in[o++];
  out.state = in[o++];
  return true;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

size_t encode(uint8_t* out, size_t cap, uint8_t type, const uint8_t* payload,
              size_t len) {
  if (len > kMaxPayload) return 0;
  if (cap < len + kFrameOverhead) return 0;
  out[0] = kSof0;
  out[1] = kSof1;
  out[2] = 1;  // VER — the scanner rejects anything else
  out[3] = type;
  out[4] = static_cast<uint8_t>(len & 0xFFu);
  out[5] = static_cast<uint8_t>((len >> 8) & 0xFFu);
  if (len) memcpy(out + 6, payload, len);
  // CRC covers VER .. last payload byte, i.e. out[2 .. 6+len).
  const uint16_t crc = crc16(out + 2, len + 4);
  putU16(out + 6 + len, crc);
  return len + kFrameOverhead;
}

size_t encodeJson(uint8_t* out, size_t cap, uint8_t type, const char* json,
                  size_t len) {
  return encode(out, cap, type, reinterpret_cast<const uint8_t*>(json), len);
}

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

void FrameScanner::reset() {
  len_ = 0;
  state_ = stSync;
  need_ = 0;
  payloadLen_ = 0;
}

bool FrameScanner::push(uint8_t byte, Frame& out) {
  switch (state_) {
    case stSync:
      if (byte == kSof0) {
        // Latch: the SOF is stored too, so the reservoir layout is identical to
        // the JS reference (payload always at offset 6) and the CRC span
        // buf_[2 .. 6+len) can be computed without special cases.
        buf_[0] = byte;
        len_ = 1;
        state_ = stSof1;
      } else {
        resyncBytes_++;
      }
      break;

    case stSof1:
      if (byte == kSof1) {
        buf_[1] = byte;
        len_ = 2;
        state_ = stHeader;
      } else if (byte == kSof0) {
        // Stay latched: 0xA5 0xA5 0x5A is still a valid start.
      } else {
        resyncBytes_++;
        len_ = 0;
        state_ = stSync;
      }
      break;

    case stHeader:
      // Need 4 more bytes: VER TYPE LEN_L LEN_H.
      if (len_ < kHeaderSize) {
        buf_[len_++] = byte;
        if (len_ == kHeaderSize) {
          version_ = buf_[2];
          type_ = buf_[3];
          payloadLen_ = getU16(buf_ + 4);
          if (payloadLen_ > kMaxPayload) {
            // Corrupt length: abandon rather than reserve 64 KB. This is the whole
            // point of sanity-checking TYPE/LEN before buffering.
            resyncBytes_++;
            len_ = 0;
            state_ = stSync;
            return false;
          }
          state_ = (payloadLen_ == 0) ? stCrc : stBody;
          need_ = payloadLen_;
        }
      }
      break;

    case stBody:
      if (len_ < kHeaderSize + payloadLen_) {
        buf_[len_++] = byte;
        if (len_ == kHeaderSize + payloadLen_) state_ = stCrc;
      }
      break;

    case stCrc:
      if (len_ < kHeaderSize + payloadLen_ + 2) {
        buf_[len_++] = byte;
        if (len_ == kHeaderSize + payloadLen_ + 2) {
          const uint16_t want = getU16(buf_ + kHeaderSize + payloadLen_);
          const uint16_t got = crc16(buf_ + 2, payloadLen_ + 4);
          const bool ok = (want == got);
          if (!ok) crcErrors_++;
          out.version = version_;
          out.type = type_;
          out.len = payloadLen_;
          out.payload = buf_ + 6;
          len_ = 0;
          state_ = stSync;
          return ok;
        }
      }
      break;
  }
  return false;
}

}  // namespace proto
}  // namespace saas
