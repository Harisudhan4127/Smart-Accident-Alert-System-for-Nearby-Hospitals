// json.h — zero-allocation JSON for the control / event / identity plane.
//
// Why hand-rolled: ArduinoJson would work, but it is a third-party dependency and
// the hot path would still memcpy into its Document. The protocol only ever needs
// (a) a compact writer into a caller-owned buffer and (b) a flat-value reader for
// phone->device messages, whose payloads are all one level deep. 200 lines of
// explicit code removes the dependency and the allocation entirely, and makes the
// whole JSON plane host-testable (see the conformance notes in firmware/README.md).
//
// Float policy: NOTHING in this file uses floating point. Every fractional field
// is carried as an integer in thousandths and rendered by fmtFixed(), which
// reproduces JSON.stringify()'s number formatting (minimal digits, no exponent) for
// the magnitude range the protocol uses. This is a hard requirement: printf("%f")
// pulls in the float formatter, costs ~1.9 ms/sample on a 240 MHz core, and would
// violate the zero-allocation rule.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace saas {
namespace json {

// ---------------------------------------------------------------------------
// fmtFixed — integer-based decimal rendering
// ---------------------------------------------------------------------------

/// Renders `scaled / 10^decimals` with EXACTLY `decimals` fractional digits (0..3)
/// and no zero padding. `scaled` is the value pre-multiplied by 10^decimals, so the
/// caller chooses the resolution: fmtFixed(482, 2) -> "4.82" (a 4820 milli-g peak
/// printed as g), fmtFixed(4021, 1) -> "402.1" (0.1 deg/s units printed as deg/s).
/// Returns the number of characters written; does not NUL-terminate.
size_t fmtFixed(char* out, int32_t scaled, uint8_t decimals);

/// Same, but trims trailing zeros and a bare '.', making the output byte-identical
/// to JavaScript's JSON.stringify for the same value: fmtFixedTrim(4820, 3) ->
/// "4.82", fmtFixedTrim(4021, 1) -> "402.1", fmtFixedTrim(4000, 3) -> "4".
size_t fmtFixedTrim(char* out, int32_t scaled, uint8_t decimals);

/// Rounds `v / d` half away from zero. Used to re-scale a value from one fixed
/// point resolution to another without the truncation bias of plain division.
constexpr int32_t scaleDiv(int32_t v, int32_t d) {
  if (d <= 0) return v;
  return (v >= 0) ? ((v + d / 2) / d) : -((-v + d / 2) / d);
}

/// Unsigned decimal, zero padded to `width`. Returns chars written.
size_t fmtU32(char* out, uint32_t v, uint8_t width = 0);

/// Lowercase hex, zero padded to `width`. Returns chars written.
size_t fmtHex(char* out, uint32_t v, uint8_t width);

/// 8 lowercase hex chars from a MAC + "AA:BB:CC:DD:EE:FF" form.
size_t fmtMac(char* out, const uint8_t mac[6]);

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

/// Compact JSON writer over a caller-owned buffer. Every method returns false once
/// the buffer is full; the buffer is always left NUL-terminated when there is room
/// so a partially built document can still be logged. Overflow is *never* a
/// silent truncation of a value: check `ok()` before sending.
class Writer {
 public:
  Writer(char* buf, size_t cap) : buf_(buf), cap_(cap) {}

  bool ok() const { return !overflow_; }
  size_t size() const { return len_; }
  const char* c_str() const { return buf_; }

  void beginObject();
  void endObject();
  void beginArray();
  void endArray();
  void comma();

  void key(const char* k);
  void null();
  void boolean(bool v);
  void integer(int64_t v);
  void uinteger(uint32_t v);
  /// Integer expressed in thousandths, rendered as a minimal-decimal float.
  void realMilli(int32_t milli);
  /// Fixed decimals, no trimming. Same scaling rule as fmtFixed().
  void fixed(int32_t scaled, uint8_t decimals);
  void string(const char* s);
  void stringEscaped(const char* s, size_t len);

 private:
  void put(char c);
  void put(const char* s);

  char* buf_;
  size_t cap_;
  size_t len_ = 0;
  bool overflow_ = false;
  bool needComma_ = false;
  bool afterKey_ = false;
  uint8_t depth_ = 0;
};

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// Value descriptor: a span into the source buffer plus a decoded scalar. The span
/// lets the caller re-read strings/objects without copying.
struct Val {
  enum Kind : uint8_t { kNull, kBool, kInt, kReal, kStr, kObj, kArr };
  Kind kind = kNull;
  bool boolean = false;
  int64_t i = 0;     ///< exact value for kInt
  int32_t milli = 0;  ///< value * 1000 for kReal (rounded half away from zero)
  uint16_t begin = 0;  ///< first byte of the raw token
  uint16_t end = 0;    ///< one past the last byte of the raw token
};

/// Minimal strict-enough JSON parser. Rejects trailing garbage, validates that
/// strings are terminated and that numbers are well formed, but does not attempt
/// to be a complete RFC 8259 implementation (no \u surrogate handling, no
/// duplicate-key detection) — none of which the protocol uses.
class Parser {
 public:
  /// Parses a NUL-terminated document. `len` may be 0 to auto-detect with strlen.
  bool parse(const char* src, size_t len = 0);

  const Val& root() const { return root_; }
  bool valid() const { return valid_; }

  /// Looks up a member of an object value.
  bool member(const Val& obj, const char* key, Val& out) const;
  /// Array element access; also reports the element count via `count` if non-null.
  bool element(const Val& arr, uint16_t index, Val& out,
               uint16_t* count = nullptr) const;
  /// Copies a string value out, resolving the escapes JSON actually uses.
  bool str(const Val& v, char* out, size_t cap) const;

 private:
  /// Recursive-descent value scan. Advances `i` past the value it consumed.
  bool value(Val& out, size_t& i, uint8_t depth) const;

  const char* s_ = nullptr;
  size_t n_ = 0;
  Val root_;
  bool valid_ = false;
};

// ---------------------------------------------------------------------------
// Document builders — one function per response type, all into caller buffers
// ---------------------------------------------------------------------------

/// Everything HELLO_ACK (docs §6.2) needs. Strings are copied verbatim; the
/// builder assumes they are already NUL-terminated and does not allocate.
struct HelloAckView {
  const char* fwVersion;
  const char* hw;
  const char* chipId;   ///< "A1B2C3D4"
  const char* mac;      ///< "24:6F:28:A1:B2:C3:D4"
  const char* name;     ///< "SAAS-A1B2C3D4"
  uint32_t batteryMv;
  uint8_t batteryPct;  ///< 255 = unknown
  bool charging;
  uint32_t uptimeMs;
  bool accelPresent;
  const char* accelAddr;  ///< e.g. "0x53"
  int deviceId;        ///< ADXL345 DEVID; -1 when absent
  bool oledPresent;
  const char* oledAddr;  ///< "0x3C"
  bool sw420;
  bool calibrated;
  uint16_t sensorRateHz;
  uint8_t state;
};
size_t buildHelloAck(char* out, size_t cap, const HelloAckView& v);

struct DeviceInfoView {
  const char* name;
  const char* model;
  const char* hw;
  const char* fwVersion;
  uint32_t fwBuild;
  const char* serial;  ///< 16 hex chars of efuse mac
};
size_t buildDeviceInfo(char* out, size_t cap, const DeviceInfoView& v);

struct EffectiveConfigView {
  uint16_t accelThresholdMg;
  bool vibrationRequired;
  uint16_t debounceMs;
  uint16_t confirmWindowSec;
  uint16_t minSpeedMilliKmh;
  uint16_t gainMilli;
  uint16_t telemetryHz;
  bool buzzerEnabled;
  bool ledEnabled;
  uint32_t muteUntil;
  bool autoArm;
};
size_t buildEffectiveConfig(Writer& w, const EffectiveConfigView& v);

struct StatusView {
  uint8_t state;
  const char* stateName;
  uint32_t sinceMs;
  EffectiveConfigView cfg;
  uint16_t peakMagMg;
  bool sw420;
  uint16_t sw420Hits;
  uint8_t score;
  uint8_t queueDepth;
  uint32_t heapFree;
  uint32_t uptimeMs;
  uint32_t watchdogResets;
  uint32_t loopOverageCount;
};
size_t buildStatus(char* out, size_t cap, const StatusView& v);

/// One `impact` block — shared by ACCIDENT_DETECTED and MANUAL_SOS (docs §6.6).
struct ImpactView {
  uint16_t magMg;             ///< used for magG (milli-g -> 2 decimals)
  uint16_t peakAccMg;
  bool sw420;
  uint16_t orientDeg10;       ///< 0.1 degrees -> 1 decimal
  uint16_t speedMilliKmh;     ///< 0.001 km/h -> 1 decimal
  bool freeFall;              ///< extension: the strongest single indicator
  uint16_t jerkMgPerS;
};
struct EventView {
  const char* type;  ///< "ACCIDENT_DETECTED", "MANUAL_SOS", ...
  const char* eventId;
  uint16_t seq;
  uint32_t tMs;
  uint16_t score;
  ImpactView impact;
  uint16_t confirmWindowSec;
  int8_t canCancel;  ///< 1/0 = include the key, -1 = omit it entirely
};
size_t buildEvent(char* out, size_t cap, const EventView& v);

/// A single CALIB_LOG entry (docs §6.8).
struct CalibSampleView {
  uint32_t tMs;
  int16_t accX, accY, accZ;
  bool sw420;
};

/// CALIB_LOG is emitted as {"samples":[...]}. The 512-byte MAX_PAYLOAD budget
/// only fits ~5 of these, so the caller sends several frames and terminates with
/// a STATUS. `begin`/`element`/`end` let the caller chunk without any copying.
void calibBegin(Writer& w);
void calibElement(Writer& w, const CalibSampleView& s);
void calibEnd(Writer& w);

struct DiagView {
  uint32_t uptimeMs;
  uint8_t cpuLoadPct;
  uint16_t loopHz;
  uint32_t heapFree;
  uint32_t heapMin;
  uint32_t stackHighWater;
  uint8_t queueDepth;
  uint32_t droppedFrames;
  uint32_t crcErrors;
  uint8_t bleClients;
  uint32_t accelI2cErrors;
  bool oledOk;
  uint32_t brownoutCount;
  uint32_t watchdogResets;
  uint32_t batteryMv;
  int8_t rssi;  ///< 0 == unknown (no CHARGING-independent link measurement)
};
size_t buildDiag(char* out, size_t cap, const DiagView& v);

/// ACK (docs §6.10). `op` may be null; the key is then omitted.
size_t buildAck(char* out, size_t cap, uint8_t of, uint16_t seq,
                const char* ofName, const char* op);

/// ERROR (docs §6.10) with the frozen code table.
size_t buildError(char* out, size_t cap, uint8_t code, const char* message);

}  // namespace json
}  // namespace saas
