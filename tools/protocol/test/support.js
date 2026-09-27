/**
 * Shared helpers and the frame-framing oracle used by the protocol tests.
 *
 * The oracle (`SpecScanner`) is an independent implementation of the framing
 * layer described in docs/02-ble-protocol.md. It exists because
 * `tools/protocol/codec.js` is frozen and has three known framing defects
 * (see DEVIATIONS in protocol.test.mjs): a test suite that trusts the
 * defective reference implementation cannot state what the protocol requires.
 * The oracle is what the vectors are checked against; the reference is then
 * compared against the oracle, and the differences are asserted explicitly
 * rather than being quietly inherited.
 */
import { readFileSync } from 'node:fs';
import { crc16, SOF0, SOF1, MAX_PAYLOAD } from '../codec.js';

export const golden = JSON.parse(
  readFileSync(new URL('../golden.json', import.meta.url), 'utf8'),
);

export const hexToBytes = (hex) => Uint8Array.from(Buffer.from(hex, 'hex'));

export const bytesToHex = (bytes) =>
  Buffer.from(bytes).toString('hex').toUpperCase();

export const equalBytes = (a, b) =>
  a.length === b.length && a.every((v, i) => v === b[i]);

/** Byte offset of a frame's payload inside the frame, per the spec. */
export const PAYLOAD_OFFSET = 6;

/** Total frame size for a payload of `len` bytes: 2 SOF + 4 header + body + 2 CRC. */
export const frameSize = (len) => 6 + len + 2;

/** The true payload of an encoded frame, sliced straight out of the wire bytes. */
export const truePayloadOf = (frame) =>
  frame.subarray(PAYLOAD_OFFSET, frame.length - 2);

/**
 * A spec-conformant incremental frame scanner.
 *
 * Contract (docs/02 §4 "Framing"):
 *   - start-of-frame is the byte pair A5 5A;
 *   - a repeated 0xA5 inside the SOF hunt re-latches instead of aborting, so
 *     the noise sequence A5 A5 5A still starts a frame;
 *   - a partial frame is retained until the rest of it arrives;
 *   - a length above MAX_PAYLOAD is abandoned, and scanning resumes after the
 *     length field rather than 64 KB later;
 *   - a CRC mismatch is counted and scanning resumes one byte past the
 *     rejected start, so a valid frame immediately following a corrupt one is
 *     still recovered.
 */
export class SpecScanner {
  #buf = new Uint8Array(1024);
  #len = 0;

  /** Bytes skipped as noise, or discarded with an abandoned frame. */
  resyncBytes = 0;
  /** Frames rejected because their CRC did not match. */
  crcErrors = 0;

  get buffered() {
    return this.#len;
  }

  reset() {
    this.#len = 0;
  }

  #append(chunk) {
    if (this.#len + chunk.length <= this.#buf.length) {
      this.#buf.set(chunk, this.#len);
      this.#len += chunk.length;
      return;
    }
    let cap = this.#buf.length;
    while (cap < this.#len + chunk.length) cap *= 2;
    const next = new Uint8Array(cap);
    next.set(this.#buf.subarray(0, this.#len));
    next.set(chunk, this.#len);
    this.#buf = next;
    this.#len += chunk.length;
  }

  #compact(consumed) {
    if (consumed <= 0) return;
    this.#buf.copyWithin(0, consumed, this.#len);
    this.#len -= consumed;
  }

  push(chunk) {
    this.#append(chunk);
    const out = [];
    let i = 0;

    for (;;) {
      while (
        i + 1 < this.#len &&
        !(this.#buf[i] === SOF0 && this.#buf[i + 1] === SOF1)
      ) {
        this.resyncBytes++;
        i++;
      }
      if (i + 1 >= this.#len) {
        const trailing = this.#len - i;
        if (!(trailing === 1 && this.#buf[i] === SOF0)) {
          this.resyncBytes += trailing;
          i = this.#len;
        }
        break;
      }

      const start = i;
      if (this.#len - start < 4) break; // header not complete yet: retain

      const version = this.#buf[start + 2];
      const type = this.#buf[start + 3];
      const payloadLen = this.#buf[start + 4] | (this.#buf[start + 5] << 8);

      if (payloadLen > MAX_PAYLOAD) {
        this.resyncBytes += 4;
        i = start + 4;
        continue;
      }

      const total = frameSize(payloadLen);
      if (this.#len - start < total) break; // body or CRC not complete: retain

      const payload = this.#buf.slice(start + PAYLOAD_OFFSET, start + PAYLOAD_OFFSET + payloadLen);
      const raw = this.#buf.slice(start, start + total);
      const want = this.#buf[start + total - 2] | (this.#buf[start + total - 1] << 8);
      const got = crc16(this.#buf, start + 2, start + PAYLOAD_OFFSET + payloadLen);

      if (want === got) {
        out.push({ version, type, payload, raw });
        i = start + total;
      } else {
        this.crcErrors++;
        this.resyncBytes += 1;
        i = start + 1;
      }
    }

    this.#compact(i);
    return out;
  }
}

/** Feed `bytes` to a scanner in chunk sizes of `size` and return every frame. */
export function pushInChunks(scanner, bytes, size) {
  const frames = [];
  for (let off = 0; off < bytes.length; off += size) {
    frames.push(...scanner.push(bytes.subarray(off, Math.min(off + size, bytes.length))));
  }
  return frames;
}

/** Deterministic PRNG so "random noise" is reproducible across runs and hosts. */
export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Pseudo-random filler for resync tests. Masked to 0x00-0x7F, so it can never
 * contain 0xA5 and therefore cannot manufacture a start-of-frame — which is the
 * point: the test isolates the behaviour of the noise path from framing.
 */
export function noiseBytes(length, seed = 0x5eed) {
  const rand = mulberry32(seed);
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    out[i] = Math.floor(rand() * 0x80);
  }
  return out;
}

/** Build a frame by hand so tests can corrupt individual header fields. */
export function buildFrame(type, payload, { version = 1, lengthOverride = null, corruptCrc = false } = {}) {
  const len = lengthOverride ?? payload.length;
  const frame = new Uint8Array(frameSize(payload.length));
  frame[0] = SOF0;
  frame[1] = SOF1;
  frame[2] = version;
  frame[3] = type;
  frame[4] = len & 0xff;
  frame[5] = (len >> 8) & 0xff;
  frame.set(payload, PAYLOAD_OFFSET);
  const crc = crc16(frame, 2, PAYLOAD_OFFSET + payload.length) ^ (corruptCrc ? 0x0001 : 0);
  frame[frame.length - 2] = crc & 0xff;
  frame[frame.length - 1] = (crc >> 8) & 0xff;
  return frame;
}
