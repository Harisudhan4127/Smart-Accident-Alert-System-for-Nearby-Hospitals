// json.cpp — see json.h.
#include "json.h"

#include <string.h>

#include "protocol.h"  // errorCodeName(), a protocol constant (docs §6.10)

namespace saas {
namespace json {

// ---------------------------------------------------------------------------
// Integer fixed-point formatting
// ---------------------------------------------------------------------------

size_t fmtU32(char* out, uint32_t v, uint8_t width) {
  char tmp[10];
  uint8_t n = 0;
  do {
    tmp[n++] = static_cast<char>('0' + (v % 10u));
    v /= 10u;
  } while (v != 0 && n < sizeof(tmp));
  while (n < width && n < sizeof(tmp)) tmp[n++] = '0';
  for (uint8_t i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
  return n;
}

size_t fmtHex(char* out, uint32_t v, uint8_t width) {
  static const char kHex[] = "0123456789abcdef";
  char tmp[8];
  uint8_t n = 0;
  do {
    tmp[n++] = kHex[v & 0xFu];
    v >>= 4;
  } while (v != 0 && n < sizeof(tmp));
  while (n < width && n < sizeof(tmp)) tmp[n++] = '0';
  for (uint8_t i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
  return n;
}

size_t fmtMac(char* out, const uint8_t mac[6]) {
  size_t o = 0;
  for (uint8_t i = 0; i < 6; i++) {
    if (i) out[o++] = ':';
    o += fmtHex(out + o, mac[i], 2);
  }
  if (o < 32) out[o] = '\0';
  return o;
}

namespace {

/// Writes `value / 10^decimals` with a fractional part of exactly `decimals` digits.
/// Handles the sign and the degenerate "-0" case (a negative milli value smaller
/// than the resolution rounds to zero and must not print "-0.0").
size_t fmtFixedRaw(char* out, int32_t scaled, uint8_t decimals) {
  size_t o = 0;
  if (scaled < 0) {
    out[o++] = '-';
    // Guard int32_t minimum: -2147483648 negates out of range.
    scaled = (scaled == INT32_MIN) ? INT32_MAX : -scaled;
  }
  static const uint32_t kPow10[4] = {1u, 10u, 100u, 1000u};
  const uint32_t div = kPow10[decimals & 3u];
  const uint32_t ip = static_cast<uint32_t>(scaled) / div;
  const uint32_t fp = static_cast<uint32_t>(scaled) % div;
  o += fmtU32(out + o, ip);
  if (decimals) {
    out[o++] = '.';
    // Zero-pad the fraction to `decimals` digits.
    char frac[4];
    uint32_t f = fp;
    for (int8_t i = static_cast<int8_t>(decimals) - 1; i >= 0; i--) {
      frac[i] = static_cast<char>('0' + (f % 10u));
      f /= 10u;
    }
    for (int8_t i = 0; i < static_cast<int8_t>(decimals); i++) out[o++] = frac[i];
  }
  return o;
}

}  // namespace

size_t fmtFixed(char* out, int32_t scaled, uint8_t decimals) {
  return fmtFixedRaw(out, scaled, decimals > 3 ? 3 : decimals);
}

size_t fmtFixedTrim(char* out, int32_t scaled, uint8_t decimals) {
  if (decimals > 3) decimals = 3;
  const size_t n = fmtFixedRaw(out, scaled, decimals);
  if (decimals == 0) return n;
  // Walk back over the fraction, then over the '.' and any sign.
  size_t end = n;
  while (end > 0 && out[end - 1] == '0') end--;
  if (end > 0 && out[end - 1] == '.') end--;
  // "-0" is not a number JSON.stringify would ever emit.
  if (end == 1 && out[0] == '-') end = 0;
  out[end] = '\0';
  return end;
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

void Writer::put(char c) {
  if (len_ + 1 < cap_) {
    buf_[len_++] = c;
    buf_[len_] = '\0';
  } else {
    overflow_ = true;
  }
}

void Writer::put(const char* s) {
  while (*s) put(*s++);
}

void Writer::comma() {
  if (afterKey_) {
    afterKey_ = false;
    return;
  }
  if (needComma_) put(',');
  needComma_ = true;
}

void Writer::beginObject() {
  comma();
  put('{');
  needComma_ = false;
  depth_++;
}

void Writer::endObject() {
  put('}');
  if (depth_) depth_--;
  needComma_ = true;
}

void Writer::beginArray() {
  comma();
  put('[');
  needComma_ = false;
  depth_++;
}

void Writer::endArray() {
  put(']');
  if (depth_) depth_--;
  needComma_ = true;
}

void Writer::key(const char* k) {
  comma();
  put('"');
  put(k);
  put('"');
  put(':');
  afterKey_ = true;
}

void Writer::null() {
  comma();
  put("null");
}

void Writer::boolean(bool v) {
  comma();
  put(v ? "true" : "false");
}

void Writer::integer(int64_t v) {
  if (v >= 0) {
    uinteger(static_cast<uint32_t>(v));
    return;
  }
  comma();
  put('-');
  // Negate in unsigned space so INT64_MIN does not overflow.
  uint64_t mag = static_cast<uint64_t>(-(v + 1)) + 1u;
  char tmp[20];
  uint8_t n = 0;
  do {
    tmp[n++] = static_cast<char>('0' + (static_cast<uint32_t>(mag % 10u)));
    mag /= 10u;
  } while (mag);
  while (n) put(tmp[--n]);
}

void Writer::uinteger(uint32_t v) {
  comma();
  char tmp[10];
  uint8_t n = 0;
  do {
    tmp[n++] = static_cast<char>('0' + (v % 10u));
    v /= 10u;
  } while (v);
  while (n) put(tmp[--n]);
}

void Writer::realMilli(int32_t milli) {
  comma();
  char tmp[16];
  const size_t n = fmtFixedTrim(tmp, milli, 3);
  tmp[n] = '\0';
  put(tmp);
}

void Writer::fixed(int32_t scaled, uint8_t decimals) {
  comma();
  char tmp[16];
  const size_t n = fmtFixed(tmp, scaled, decimals);
  tmp[n] = '\0';
  put(tmp);
}

void Writer::string(const char* s) {
  comma();
  if (!s) {
    put("\"\"");
    return;
  }
  put('"');
  stringEscaped(s, strlen(s));
  put('"');
}

void Writer::stringEscaped(const char* s, size_t len) {
  // Writes the *body* only; string() supplies the surrounding quotes. Exposed for
  // callers that assemble a quoted value manually.
  for (size_t i = 0; i < len; i++) {
    const char c = s[i];
    if (c == '"' || c == '\\') {
      put('\\');
      put(c);
    } else if (c == '\n') {
      put("\\n");
    } else if (c == '\r') {
      put("\\r");
    } else if (c == '\t') {
      put("\\t");
    } else if (static_cast<unsigned char>(c) < 0x20) {
      static const char kHex[] = "0123456789abcdef";
      put("\\u00");
      put(kHex[(static_cast<unsigned char>(c) >> 4) & 0xF]);
      put(kHex[static_cast<unsigned char>(c) & 0xF]);
    } else {
      put(c);
    }
  }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

namespace {

constexpr uint8_t kMaxDepth = 8;  // protocol payloads nest at most 2 deep

inline void skipWs(const char* s, size_t n, size_t& i) {
  while (i < n) {
    const char c = s[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
    } else {
      break;
    }
  }
}

}  // namespace

bool Parser::parse(const char* src, size_t len) {
  s_ = src;
  n_ = len ? len : (src ? strlen(src) : 0);
  valid_ = false;
  root_ = Val{};
  if (!s_) return false;

  size_t i = 0;
  skipWs(s_, n_, i);
  if (!value(root_, i, 0)) return false;
  skipWs(s_, n_, i);
  if (i != n_) return false;  // trailing garbage
  valid_ = true;
  return true;
}

// Forward declaration of the recursive-descent worker, defined below.
bool Parser::value(Val& out, size_t& i, uint8_t depth) const {
  if (depth > kMaxDepth || i >= n_) return false;
  skipWs(s_, n_, i);
  if (i >= n_) return false;

  const char c = s_[i];
  out.begin = static_cast<uint16_t>(i);

  if (c == '{' || c == '[') {
    const char close = (c == '{') ? '}' : ']';
    out.kind = (c == '{') ? Val::kObj : Val::kArr;
    size_t j = i + 1;
    skipWs(s_, n_, j);
    if (j < n_ && s_[j] == close) {
      out.end = static_cast<uint16_t>(j + 1);
      i = j + 1;
      return true;
    }
    for (;;) {
      skipWs(s_, n_, j);
      if (c == '{') {
        if (j >= n_ || s_[j] != '"') return false;
        // Key: validate the string, then the colon.
        size_t k = j + 1;
        while (k < n_ && s_[k] != '"') {
          if (s_[k] == '\\') k++;
          k++;
        }
        if (k >= n_) return false;
        j = k + 1;
        skipWs(s_, n_, j);
        if (j >= n_ || s_[j] != ':') return false;
        j++;
      }
      Val child;
      if (!value(child, j, static_cast<uint8_t>(depth + 1))) return false;
      skipWs(s_, n_, j);
      if (j < n_ && s_[j] == ',') {
        j++;
        continue;
      }
      if (j < n_ && s_[j] == close) {
        out.end = static_cast<uint16_t>(j + 1);
        i = j + 1;
        return true;
      }
      return false;
    }
  }

  if (c == '"') {
    out.kind = Val::kStr;
    size_t j = i + 1;
    while (j < n_) {
      if (s_[j] == '\\') {
        j += 2;
        continue;
      }
      if (s_[j] == '"') {
        out.end = static_cast<uint16_t>(j + 1);
        i = j + 1;
        return true;
      }
      j++;
    }
    return false;
  }

  if (c == 't' || c == 'f' || c == 'n') {
    const char* lit = (c == 't') ? "true" : (c == 'f') ? "false" : "null";
    const size_t l = (c == 't') ? 4 : (c == 'f') ? 5 : 4;
    if (i + l > n_ || memcmp(s_ + i, lit, l) != 0) return false;
    out.kind = (c == 'n') ? Val::kNull : Val::kBool;
    out.boolean = (c == 't');
    out.end = static_cast<uint16_t>(i + l);
    i += l;
    return true;
  }

  if (c == '-' || (c >= '0' && c <= '9')) {
    size_t j = i;
    bool isReal = false;
    if (s_[j] == '-') j++;
    if (j >= n_) return false;
    if (s_[j] == '0') {
      j++;
    } else if (s_[j] >= '1' && s_[j] <= '9') {
      while (j < n_ && s_[j] >= '0' && s_[j] <= '9') j++;
    } else {
      return false;
    }
    if (j < n_ && s_[j] == '.') {
      isReal = true;
      j++;
      if (j >= n_ || s_[j] < '0' || s_[j] > '9') return false;
      while (j < n_ && s_[j] >= '0' && s_[j] <= '9') j++;
    }
    if (j < n_ && (s_[j] == 'e' || s_[j] == 'E')) {
      isReal = true;
      j++;
      if (j < n_ && (s_[j] == '+' || s_[j] == '-')) j++;
      if (j >= n_ || s_[j] < '0' || s_[j] > '9') return false;
      while (j < n_ && s_[j] >= '0' && s_[j] <= '9') j++;
    }
    out.end = static_cast<uint16_t>(j);
    if (isReal) {
      // Fixed-point parse: value * 1000, rounded half away from zero. The protocol
      // only ever sends values with <= 4 significant decimals, so 3 places of
      // milliscale is lossless for every field the app writes.
      int32_t sign = 1;
      size_t k = i;
      if (s_[k] == '-') {
        sign = -1;
        k++;
      }
      int32_t ip = 0;
      while (k < j && s_[k] >= '0' && s_[k] <= '9' && s_[k] != '.' &&
             s_[k] != 'e' && s_[k] != 'E') {
        if (ip < 1000000) ip = ip * 10 + (s_[k] - '0');
        k++;
      }
      int32_t fp = 0;
      uint8_t fd = 0;
      uint8_t dig[6] = {0, 0, 0, 0, 0, 0};
      if (k < j && s_[k] == '.') {
        k++;
        while (k < j && s_[k] >= '0' && s_[k] <= '9') {
          if (fd < 6) dig[fd++] = static_cast<uint8_t>(s_[k] - '0');
          k++;
        }
      }
      for (uint8_t d = 0; d < fd; d++) fp = fp * 10 + dig[d];
      if (fd > 3) {
        // Round half away from zero on the 4th fractional digit, then truncate.
        fp = (fp + 500) / 1000;
      } else {
        while (fd < 3) {
          fp *= 10;
          fd++;
        }
      }
      out.kind = Val::kReal;
      out.milli = sign * (ip * 1000 + fp);
    } else {
      out.kind = Val::kInt;
      int64_t v = 0;
      bool neg = s_[i] == '-';
      for (size_t k = neg ? i + 1 : i; k < j; k++) v = v * 10 + (s_[k] - '0');
      out.i = neg ? -v : v;
      out.milli = static_cast<int32_t>(out.i);
    }
    i = j;
    return true;
  }

  return false;
}

bool Parser::member(const Val& obj, const char* key, Val& out) const {
  if (obj.kind != Val::kObj) return false;
  size_t i = obj.begin;
  // Step over '{'.
  i++;
  skipWs(s_, n_, i);
  if (i < n_ && s_[i] == '}') return false;
  while (i < n_) {
    skipWs(s_, n_, i);
    if (i >= n_ || s_[i] != '"') return false;
    const size_t kStart = ++i;
    while (i < n_ && s_[i] != '"') {
      if (s_[i] == '\\') i++;
      i++;
    }
    if (i >= n_) return false;
    const size_t kLen = i - kStart;
    i++;  // closing quote
    skipWs(s_, n_, i);
    if (i >= n_ || s_[i] != ':') return false;
    i++;
    skipWs(s_, n_, i);
    const size_t vStart = i;
    Val v;
    if (!value(v, i, 0)) return false;
    (void)vStart;
    if (kLen == strlen(key) && memcmp(s_ + kStart, key, kLen) == 0) {
      out = v;
      return true;
    }
    skipWs(s_, n_, i);
    if (i < n_ && s_[i] == ',') {
      i++;
      continue;
    }
    if (i < n_ && s_[i] == '}') return false;
    return false;
  }
  return false;
}

bool Parser::element(const Val& arr, uint16_t index, Val& out,
                     uint16_t* count) const {
  if (arr.kind != Val::kArr) return false;
  size_t i = arr.begin + 1;
  uint16_t idx = 0;
  uint16_t n = 0;
  skipWs(s_, n_, i);
  if (i < n_ && s_[i] == ']') {
    if (count) *count = 0;
    return false;
  }
  while (i < n_) {
    Val v;
    if (!value(v, i, 0)) return false;
    n++;
    if (idx == index) {
      out = v;
      if (count) *count = n;  // partial count; use countElements() for the total
      return true;
    }
    idx++;
    skipWs(s_, n_, i);
    if (i < n_ && s_[i] == ',') {
      i++;
      continue;
    }
    break;
  }
  if (count) *count = n;
  return false;
}

bool Parser::str(const Val& v, char* out, size_t cap) const {
  if (v.kind != Val::kStr || !cap) return false;
  size_t i = v.begin + 1;
  size_t o = 0;
  while (i < v.end) {
    const char c = s_[i++];
    if (c == '"') break;
    if (c != '\\') {
      if (o + 1 < cap) out[o++] = c;
      continue;
    }
    if (i >= v.end) return false;
    const char e = s_[i++];
    switch (e) {
      case 'n': if (o + 1 < cap) out[o++] = '\n'; break;
      case 'r': if (o + 1 < cap) out[o++] = '\r'; break;
      case 't': if (o + 1 < cap) out[o++] = '\t'; break;
      case 'b': if (o + 1 < cap) out[o++] = '\b'; break;
      case 'f': if (o + 1 < cap) out[o++] = '\f'; break;
      case 'u': {
        // Only the BMP Latin-1 subset the protocol could ever send.
        if (i + 4 > v.end) return false;
        uint16_t cp = 0;
        for (int k = 0; k < 4; k++) {
          const char h = s_[i + k];
          cp <<= 4;
          if (h >= '0' && h <= '9') cp |= (uint16_t)(h - '0');
          else if (h >= 'a' && h <= 'f') cp |= (uint16_t)(h - 'a' + 10);
          else if (h >= 'A' && h <= 'F') cp |= (uint16_t)(h - 'A' + 10);
          else return false;
        }
        i += 4;
        if (cp < 0x80) {
          if (o + 1 < cap) out[o++] = (char)cp;
        } else {
          return false;  // non-Latin1: the protocol never sends this
        }
        break;
      }
      default:
        if (o + 1 < cap) out[o++] = e;
        break;
    }
  }
  out[o] = '\0';
  return true;
}

// ---------------------------------------------------------------------------
// Document builders
// ---------------------------------------------------------------------------

size_t buildHelloAck(char* out, size_t cap, const HelloAckView& v) {
  Writer w(out, cap);
  w.beginObject();
  w.key("fwVersion");
  w.string(v.fwVersion);
  w.key("hw");
  w.string(v.hw);
  w.key("proto");
  // The advertised version must be the one the frame encoder stamps, or a
  // client that trusts the JSON will parse frames the scanner would have
  // rejected. One constant, so the two cannot drift.
  w.uinteger(proto::kProtocolVersion);
  w.key("chipId");
  w.string(v.chipId);
  w.key("mac");
  w.string(v.mac);
  w.key("name");
  w.string(v.name);
  w.key("batteryMv");
  w.uinteger(v.batteryMv);
  w.key("batteryPct");
  w.uinteger(v.batteryPct);
  w.key("charging");
  w.boolean(v.charging);
  w.key("uptimeMs");
  w.uinteger(v.uptimeMs);
  w.key("sensor");
  w.beginObject();
  w.key("part");
  w.string("ADXL345");
  w.key("present");
  w.boolean(v.accelPresent);
  w.key("addr");
  w.string(v.accelAddr);
  w.key("deviceId");
  w.integer(v.deviceId);
  w.endObject();
  w.key("oled");
  w.beginObject();
  w.key("present");
  w.boolean(v.oledPresent);
  w.key("addr");
  w.string(v.oledAddr);
  w.endObject();
  w.key("sw420");
  w.boolean(v.sw420);
  w.key("calibrated");
  w.boolean(v.calibrated);
  w.key("sensorRateHz");
  w.uinteger(v.sensorRateHz);
  w.key("state");
  w.uinteger(v.state);
  w.endObject();
  return w.size();
}

size_t buildDeviceInfo(char* out, size_t cap, const DeviceInfoView& v) {
  Writer w(out, cap);
  w.beginObject();
  w.key("name");
  w.string(v.name);
  w.key("model");
  w.string(v.model);
  w.key("hw");
  w.string(v.hw);
  w.key("fwVersion");
  w.string(v.fwVersion);
  w.key("fwBuild");
  w.uinteger(v.fwBuild);
  w.key("serial");
  w.string(v.serial);
  w.endObject();
  return w.size();
}

size_t buildEffectiveConfig(Writer& w, const EffectiveConfigView& v) {
  // Key order is the CONFIG table order from docs §6.4, not alphabetical: the spec
  // calls for a stable, diff-friendly order and the table order is that order.
  w.key("accelThresholdMg");
  w.uinteger(v.accelThresholdMg);
  w.key("vibrationRequired");
  w.boolean(v.vibrationRequired);
  w.key("debounceMs");
  w.uinteger(v.debounceMs);
  w.key("confirmWindowSec");
  w.uinteger(v.confirmWindowSec);
  w.key("minSpeedKmh");
  // Stored in 0.001 km/h; the wire wants km/h with one decimal.
  w.fixed(scaleDiv(v.minSpeedMilliKmh, 100), 1);
  w.key("detectorGain");
  w.fixed(scaleDiv(v.gainMilli, 100), 1);
  w.key("telemetryHz");
  w.uinteger(v.telemetryHz);
  w.key("buzzerEnabled");
  w.boolean(v.buzzerEnabled);
  w.key("ledEnabled");
  w.boolean(v.ledEnabled);
  w.key("muteUntil");
  w.uinteger(v.muteUntil);
  w.key("autoArm");
  w.boolean(v.autoArm);
  return w.size();
}

size_t buildStatus(char* out, size_t cap, const StatusView& v) {
  Writer w(out, cap);
  w.beginObject();
  w.key("state");
  w.uinteger(v.state);
  w.key("stateName");
  w.string(v.stateName);
  w.key("sinceMs");
  w.uinteger(v.sinceMs);
  w.key("effectiveConfig");
  w.beginObject();
  buildEffectiveConfig(w, v.cfg);
  w.endObject();
  w.key("peakMagMg");
  w.uinteger(v.peakMagMg);
  w.key("sw420");
  w.boolean(v.sw420);
  w.key("sw420Hits");
  w.uinteger(v.sw420Hits);
  w.key("score");
  w.uinteger(v.score);
  w.key("queueDepth");
  w.uinteger(v.queueDepth);
  w.key("heapFree");
  w.uinteger(v.heapFree);
  w.key("uptimeMs");
  w.uinteger(v.uptimeMs);
  w.key("watchdogResets");
  w.uinteger(v.watchdogResets);
  w.key("loopOverageCount");
  w.uinteger(v.loopOverageCount);
  w.endObject();
  return w.size();
}

namespace {
void writeImpact(Writer& w, const ImpactView& i) {
  w.key("impact");
  w.beginObject();
  w.key("magG");
  // milli-g -> g with two decimals.
  w.fixed(scaleDiv(i.magMg, 10), 2);
  w.key("peakAccMg");
  w.uinteger(i.peakAccMg);
  w.key("sw420");
  w.boolean(i.sw420);
  w.key("orientationChangeDeg");
  w.fixed(i.orientDeg10, 1);
  w.key("preImpactSpeedKmh");
  // 0.001 km/h -> km/h with one decimal.
  w.fixed(scaleDiv(i.speedMilliKmh, 100), 1);
  w.key("freeFall");
  w.boolean(i.freeFall);
  w.key("jerkMgPerS");
  w.uinteger(i.jerkMgPerS);
  w.endObject();
}
}  // namespace

size_t buildEvent(char* out, size_t cap, const EventView& v) {
  Writer w(out, cap);
  w.beginObject();
  w.key("type");
  w.string(v.type);
  w.key("eventId");
  w.string(v.eventId);
  w.key("seq");
  w.uinteger(v.seq);
  w.key("t_ms");
  w.uinteger(v.tMs);
  w.key("uptimeMs");
  w.uinteger(v.tMs);
  w.key("score");
  w.uinteger(v.score);
  writeImpact(w, v.impact);
  w.key("confirmWindowSec");
  w.uinteger(v.confirmWindowSec);
  if (v.canCancel >= 0) {
    w.key("canCancel");
    w.boolean(v.canCancel != 0);
  }
  w.endObject();
  return w.size();
}

void calibBegin(Writer& w) {
  w.beginObject();
  w.key("samples");
  w.beginArray();
}

void calibElement(Writer& w, const CalibSampleView& s) {
  w.beginObject();
  w.key("t_ms");
  w.uinteger(s.tMs);
  w.key("acc_x");
  w.integer(s.accX);
  w.key("acc_y");
  w.integer(s.accY);
  w.key("acc_z");
  w.integer(s.accZ);
  w.key("sw420");
  w.boolean(s.sw420);
  w.endObject();
}

void calibEnd(Writer& w) {
  w.endArray();
  w.endObject();
}

size_t buildDiag(char* out, size_t cap, const DiagView& v) {
  Writer w(out, cap);
  w.beginObject();
  w.key("uptimeMs");
  w.uinteger(v.uptimeMs);
  w.key("cpuLoadPct");
  w.uinteger(v.cpuLoadPct);
  w.key("loopHz");
  w.uinteger(v.loopHz);
  w.key("heapFree");
  w.uinteger(v.heapFree);
  w.key("heapMin");
  w.uinteger(v.heapMin);
  w.key("stackHighWater");
  w.uinteger(v.stackHighWater);
  w.key("queueDepth");
  w.uinteger(v.queueDepth);
  w.key("droppedFrames");
  w.uinteger(v.droppedFrames);
  w.key("crcErrors");
  w.uinteger(v.crcErrors);
  w.key("bleClients");
  w.uinteger(v.bleClients);
  w.key("sensorI2cErrors");
  w.uinteger(v.accelI2cErrors);
  w.key("oledOk");
  w.boolean(v.oledOk);
  w.key("brownoutCount");
  w.uinteger(v.brownoutCount);
  w.key("watchdogResets");
  w.uinteger(v.watchdogResets);
  w.key("batteryMv");
  w.uinteger(v.batteryMv);
  w.key("rssi");
  w.integer(v.rssi);
  w.endObject();
  return w.size();
}

size_t buildAck(char* out, size_t cap, uint8_t of, uint16_t seq,
                const char* ofName, const char* op) {
  Writer w(out, cap);
  w.beginObject();
  w.key("of");
  w.uinteger(of);
  w.key("seq");
  w.uinteger(seq);
  w.key("ofName");
  w.string(ofName);
  if (op) {
    w.key("op");
    w.string(op);
  }
  w.endObject();
  return w.size();
}

size_t buildError(char* out, size_t cap, uint8_t code, const char* message) {
  Writer w(out, cap);
  w.beginObject();
  w.key("code");
  w.uinteger(code);
  w.key("codeName");
  w.string(proto::errorCodeName(code));
  w.key("message");
  w.string(message ? message : "");
  w.endObject();
  return w.size();
}

}  // namespace json
}  // namespace saas
