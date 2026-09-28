/**
 * Smart Accident Alert System — BLE wire protocol codec.
 * Reference implementation. See docs/02-ble-protocol.md.
 *
 * Zero dependencies, Node >= 18. Also loadable in a browser (used by the web-based
 * protocol inspector in tools/simulator).
 */

export const SOF0 = 0xa5;
export const SOF1 = 0x5a;
export const PROTOCOL_VERSION = 2;
export const MAX_PAYLOAD = 512;
// v1 was 24 bytes and carried three gyro axes. The node now uses an ADXL345,
// which has no gyroscope, so v2 drops those six bytes instead of zero-filling
// them: a stream of exact zeros reads as a working gyro that never turns.
export const TELEMETRY_SIZE = 18;

/** Frame types. Direction is informational — the codec is symmetric. */
export const Type = Object.freeze({
  HELLO: 0x01,
  PING: 0x02,
  CONFIG: 0x04,
  CALIBRATE: 0x05,
  COMMAND: 0x06,
  ACK: 0x07,
  ERROR: 0x08,
  EVENT: 0x09,
  TELEMETRY: 0x10,
  STATUS: 0x11,
  HELLO_ACK: 0x12,
  CALIB_LOG: 0x13,
  DIAG: 0x14,
  DEVICE_INFO: 0x20,
});

export const TypeName = Object.freeze(
  Object.fromEntries(Object.entries(Type).map(([k, v]) => [v, k])),
);

export const State = Object.freeze({
  BOOT: 0,
  IDLE: 1,
  PENDING: 2,
  ALARM: 3,
  SOS: 4,
  MUTED: 5,
  FAULT: 6,
});

export const StateName = Object.freeze({
  0: 'BOOT',
  1: 'IDLE',
  2: 'PENDING',
  3: 'ALARM',
  4: 'SOS',
  5: 'MUTED',
  6: 'FAULT',
});

export const Flag = Object.freeze({
  SW420: 0x01,
  BUZZER: 0x02,
  LED_RED: 0x04,
  LED_GREEN: 0x08,
  OLED_OK: 0x10,
  SOS_BUTTON: 0x20,
  ARMED: 0x40,
  CHARGING: 0x80,
});

export const ErrorCode = Object.freeze({
  BAD_FRAME: 0,
  UNSUPPORTED: 1,
  BAD_ARGS: 2,
  BAD_STATE: 3,
  NOT_ARMED: 4,
  BUSY: 5,
  INTERNAL: 6,
});

export const Characteristic = Object.freeze({
  SERVICE: '7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001',
  TX: '7c9e0001-1e4a-4f6b-9c2d-5a1b7c30d001',
  RX: '7c9e0002-1e4a-4f6b-9c2d-5a1b7c30d001',
  CTRL: '7c9e0003-1e4a-4f6b-9c2d-5a1b7c30d001',
  INFO: '7c9e0004-1e4a-4f6b-9c2d-5a1b7c30d001',
});

/* ------------------------------------------------------------------ CRC-16 */

/** CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR. */
const CRC_TABLE = (() => {
  const table = new Uint16Array(256);
  for (let i = 0; i < 256; i++) {
    let crc = i << 8;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
    table[i] = crc;
  }
  return table;
})();

export function crc16(bytes, start = 0, end = bytes.length) {
  let crc = 0xffff;
  for (let i = start; i < end; i++) {
    crc = ((crc << 8) ^ CRC_TABLE[((crc >> 8) ^ bytes[i]) & 0xff]) & 0xffff;
  }
  return crc;
}

/* ---------------------------------------------------------------- encoding */

/**
 * Build a complete frame.
 * @param {number} type
 * @param {Uint8Array|string|object} payload binary buffer, UTF-8 JSON string, or
 *        plain object (serialised as JSON). `null`/`undefined` for empty.
 * @returns {Uint8Array}
 */
export function encodeFrame(type, payload) {
  let body;
  if (payload == null) {
    body = new Uint8Array(0);
  } else if (payload instanceof Uint8Array) {
    body = payload;
  } else if (typeof payload === 'string') {
    body = new TextEncoder().encode(payload);
  } else {
    body = new TextEncoder().encode(JSON.stringify(payload));
  }
  if (body.length > MAX_PAYLOAD) {
    throw new RangeError(
      `payload ${body.length}B exceeds MAX_PAYLOAD ${MAX_PAYLOAD}B`,
    );
  }

  const frame = new Uint8Array(6 + body.length + 2);
  frame[0] = SOF0;
  frame[1] = SOF1;
  frame[2] = PROTOCOL_VERSION;
  frame[3] = type & 0xff;
  frame[4] = body.length & 0xff;
  frame[5] = (body.length >> 8) & 0xff;
  frame.set(body, 6);

  const crc = crc16(frame, 2, 6 + body.length);
  frame[6 + body.length] = crc & 0xff;
  frame[7 + body.length] = (crc >> 8) & 0xff;
  return frame;
}

export const encodeJsonFrame = (type, obj) => encodeFrame(type, obj);

/* ---------------------------------------------------------------- decoding */

/**
 * Incremental, allocation-light frame scanner.
 *
 * Why a state machine instead of `buffer.concat` per chunk: notifications are
 * delivered as arbitrary chunks and a 24 B telemetry record can straddle two of
 * them. Concatenating on every chunk is O(n^2) in a long stream and allocates
 * once per chunk. This scanner is O(1) amortised per byte and holds at most one
 * frame in memory.
 */
export class FrameScanner {
  #buf = new Uint8Array(1024);
  #len = 0;
  #state = 'sync';
  #need = 0;
  #type = 0;
  #payloadLen = 0;
  #version = 0;
  /** Offset of the latched SOF0 for the frame currently being assembled. */
  #start = 0;
  /** Scan position within a retained partial frame; 0 when no frame is pending. */
  #parsed = 0;

  /** Number of bytes discarded as noise/framing garbage since construction. */
  resyncBytes = 0;
  /** Number of frames rejected by CRC. */
  crcErrors = 0;

  reset() {
    this.#len = 0;
    this.#start = 0;
    this.#parsed = 0;
    this.#state = 'sync';
  }

  get buffered() {
    return this.#len;
  }

  #ensure(extra) {
    if (this.#len + extra <= this.#buf.length) return;
    let cap = this.#buf.length;
    while (cap < this.#len + extra) cap *= 2;
    const next = new Uint8Array(cap);
    next.set(this.#buf.subarray(0, this.#len));
    this.#buf = next;
  }

  /**
   * Feed a chunk, return every complete frame it completed.
   * @param {Uint8Array} chunk
   * @returns {Array<{version:number,type:number,payload:Uint8Array,raw:Uint8Array}>}
   */
  push(chunk) {
    this.#ensure(chunk.length);
    this.#buf.set(chunk, this.#len);
    this.#len += chunk.length;

    const out = [];
    // When a previous push ended mid-frame the retained bytes are already
    // parsed state, so resume scanning at the saved offset instead of 0.
    let i = this.#parsed;

    while (i < this.#len) {
      switch (this.#state) {
        case 'sync': {
          const b = this.#buf[i];
          if (b === SOF0) {
            this.#state = 'sof1';
            this.#start = i;
            i++;
          } else {
            this.resyncBytes++;
            i++;
          }
          break;
        }
        case 'sof1': {
          if (this.#buf[i] === SOF1) {
            this.#state = 'header';
            i++;
          } else if (this.#buf[i] === SOF0) {
            // Repeated 0xA5: still could be the start of a real frame, so stay
            // latched but MOVE the start forward. Consuming here is essential —
            // not advancing i here is an infinite loop on [A5, A5, 5A].
            this.#start = i;
            i++;
          } else {
            this.resyncBytes++;
            this.#state = 'sync';
            i++;
          }
          break;
        }
        case 'header': {
          if (this.#len - i < 4) return this.#flush(out, i);
          this.#version = this.#buf[i];
          this.#type = this.#buf[i + 1];
          this.#payloadLen = this.#buf[i + 2] | (this.#buf[i + 3] << 8);
          i += 4;
          if (this.#payloadLen > MAX_PAYLOAD) {
            // Corrupt length: abandon this frame rather than reserving 64 KB.
            // Resume the SOF hunt one byte past the latched SOF0 instead of at
            // the current position — a real frame can begin inside the bytes we
            // just consumed as a bogus header (e.g. a false A5 5A left over from
            // a previous push immediately followed by a genuine frame).
            this.resyncBytes++;
            this.#state = 'sync';
            i = this.#start + 1;
            break;
          }
          this.#state = 'body';
          break;
        }
        case 'body': {
          if (this.#len - i < this.#payloadLen) return this.#flush(out, i);
          i += this.#payloadLen;
          this.#state = 'crc';
          break;
        }
        case 'crc': {
          if (this.#len - i < 2) return this.#flush(out, i);
          const want =
            this.#buf[i] | (this.#buf[i + 1] << 8);
          const got = crc16(this.#buf, i - this.#payloadLen - 4, i);
          if (want === got) {
            // The payload begins kHeaderBytes (6) after the latched SOF0, and
            // the CRC occupies the final 2 bytes. Deriving from #start (not from
            // i) keeps a frame split across pushes correct.
            const start = this.#start + 6;
            out.push({
              version: this.#version,
              type: this.#type,
              payload: this.#buf.slice(start, start + this.#payloadLen),
              raw: this.#buf.slice(this.#start, i + 2),
            });
            i += 2;
            this.#state = 'sync';
          } else {
            this.crcErrors++;
            // Resume the SOF hunt one byte past the bad SOF0 so a valid frame
            // that overlapped the corrupt one can still be found.
            i = this.#start + 1;
            this.#state = 'sync';
          }
          break;
        }
      }
    }
    return this.#flush(out, i);
  }

  /**
   * Settle the buffer at the end of a push.
   *
   * A partial frame is retained — BLE notifications routinely split one frame
   * across two writes, and discarding the remainder (the previous behaviour)
   * silently dropped every split frame. The retained bytes always begin at a
   * latched SOF0, and the state machine is rewound to `sync` so the next push
   * re-parses them from that SOF. Re-parsing is O(1) amortised because the
   * retained run is always shorter than one frame.
   */
  #flush(out, i) {
    if (this.#state === 'sync') {
      // Fully parsed with nothing pending: the buffer can be emptied and the
      // next push must re-scan from the beginning.
      this.#len = 0;
      this.#start = 0;
      this.#parsed = 0;
    } else {
      // A frame is mid-assembly. Drop any noise before its SOF0 and keep the
      // partial frame, remembering how far into it we got. The state machine
      // is left untouched so the next push resumes exactly where we stopped.
      const keepFrom = this.#start;
      this.#buf.copyWithin(0, keepFrom, this.#len);
      this.#len -= keepFrom;
      this.#start = 0;
      this.#parsed = i - keepFrom;
    }
    return out;
  }
}

/** Convenience: decode exactly one frame buffer (used by tests and the simulator). */
export function decodeFrame(bytes) {
  const scanner = new FrameScanner();
  const frames = scanner.push(bytes);
  return frames[0] ?? null;
}

export const parseJsonFrame = (frame) =>
  frame.payload.length ? JSON.parse(new TextDecoder().decode(frame.payload)) : null;

/* --------------------------------------------------------------- telemetry */

/**
 * Encode a telemetry sample into the 18-byte binary record.
 * @param {object} s
 * @param {number} s.tMs        ms since boot
 * @param {number} s.ax         milli-g (may be fractional)
 * @param {number} s.ay
 * @param {number} s.az
 * @param {number} s.magMg      accel magnitude, milli-g
 * @param {number} s.peakMg     session peak magnitude, milli-g
 * @param {number} s.flags      bitfield
 * @param {number} s.score      0..100
 * @param {number} s.batteryPct 0..100 or 255 unknown
 * @param {number} s.state
 * @returns {Uint8Array}
 */
export function encodeTelemetry(s) {
  const b = new Uint8Array(TELEMETRY_SIZE);
  const view = new DataView(b.buffer);
  let o = 0;
  view.setUint32(o, s.tMs >>> 0, true); o += 4;
  view.setInt16(o, clampI16(s.ax), true); o += 2;
  view.setInt16(o, clampI16(s.ay), true); o += 2;
  view.setInt16(o, clampI16(s.az), true); o += 2;
  view.setUint16(o, clampU16(s.magMg), true); o += 2;
  view.setUint16(o, clampU16(s.peakMg), true); o += 2;
  b[o++] = s.flags & 0xff;
  b[o++] = clampByte(s.score);
  b[o++] = clampByte(s.batteryPct);
  b[o++] = s.state & 0xff;
  return b;
}

export function decodeTelemetry(bytes) {
  if (bytes.length < TELEMETRY_SIZE) {
    throw new RangeError(`telemetry too short: ${bytes.length}B`);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let o = 0;
  const tMs = view.getUint32(o, true); o += 4;
  const ax = view.getInt16(o, true); o += 2;
  const ay = view.getInt16(o, true); o += 2;
  const az = view.getInt16(o, true); o += 2;
  const magMg = view.getUint16(o, true); o += 2;
  const peakMg = view.getUint16(o, true); o += 2;
  const flags = bytes[o++];
  const score = bytes[o++];
  const batteryPct = bytes[o++];
  const state = bytes[o++];
  return {
    tMs, ax, ay, az, magMg, peakMg, flags, score, batteryPct, state,
    stateName: StateName[state] ?? 'UNKNOWN',
    sw420: (flags & Flag.SW420) !== 0,
    buzzer: (flags & Flag.BUZZER) !== 0,
    ledRed: (flags & Flag.LED_RED) !== 0,
    ledGreen: (flags & Flag.LED_GREEN) !== 0,
    oledOk: (flags & Flag.OLED_OK) !== 0,
    sosButton: (flags & Flag.SOS_BUTTON) !== 0,
    armed: (flags & Flag.ARMED) !== 0,
    charging: (flags & Flag.CHARGING) !== 0,
  };
}

export const clampI16 = (v) => Math.max(-32768, Math.min(32767, Math.round(v)));
export const clampU16 = (v) => Math.max(0, Math.min(65535, Math.round(v)));
export const clampByte = (v) => Math.max(0, Math.min(255, Math.round(v)));

/* ----------------------------------------------------------------- helpers */

export const isState = (n) => n >= State.BOOT && n <= State.FAULT;

export function describeFrame(frame) {
  const name = TypeName[frame.type] ?? `0x${frame.type.toString(16).padStart(2, '0')}`;
  if (frame.type === Type.TELEMETRY) {
    const t = decodeTelemetry(frame.payload);
    return `TELEMETRY t=${t.tMs}ms mag=${(t.magMg / 1000).toFixed(2)}g state=${t.stateName} score=${t.score}`;
  }
  let body;
  try {
    body = JSON.stringify(parseJsonFrame(frame));
  } catch {
    body = `<${frame.payload.length}B binary>`;
  }
  return `${name} ${body}`;
}
