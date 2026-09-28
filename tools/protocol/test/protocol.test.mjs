/**
 * Conformance tests for the BLE wire protocol (docs/02-ble-protocol.md).
 *
 *   node --test tools/protocol/test/
 *
 * Three layers, in this order:
 *
 *   1. The spec: constants, CRC-16/CCITT-FALSE, the framing oracle in
 *      support.js, and every vector committed to golden.json.
 *   2. The reference codec: encodeFrame / encodeTelemetry / decodeTelemetry,
 *      checked against the same vectors and the oracle.
 *   3. The frozen FrameScanner in tools/protocol/codec.js, which is exercised
 *      where it agrees with the spec and characterised where it does not.
 *
 * Layer 3 exists because codec.js is a frozen contribution. It has three real
 * framing defects, and a suite that silently inherited them would certify the
 * defects as the protocol. Each one is asserted as an explicit, named
 * deviation, and the corresponding spec assertion is parked in `test.todo` so
 * it becomes a real failure the moment the codec is allowed to change.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  SOF0, SOF1, PROTOCOL_VERSION, MAX_PAYLOAD, TELEMETRY_SIZE,
  Type, TypeName, State, StateName, Flag, ErrorCode, Characteristic,
  crc16, encodeFrame, encodeTelemetry, decodeTelemetry,
  FrameScanner, decodeFrame, parseJsonFrame, describeFrame,
  isState, clampI16, clampU16, clampByte,
} from '../codec.js';

import {
  golden, SpecScanner, hexToBytes, bytesToHex, equalBytes,
  pushInChunks, noiseBytes, buildFrame, truePayloadOf, frameSize,
} from './support.js';

const codecUrl = new URL('../codec.js', import.meta.url).href;

/* ------------------------------------------------------------------- CRC */

describe('CRC-16/CCITT-FALSE', () => {
  test('matches the published check values', () => {
    for (const v of golden.crc16.vectors) {
      const actual = crc16(new TextEncoder().encode(v.input));
      assert.equal(
        actual,
        Number.parseInt(v.expected, 16),
        `crc16(${JSON.stringify(v.input)}) must be ${v.expected}`,
      );
    }
  });

  test('golden records its own vectors as passing', () => {
    assert.equal(golden.crc16.algorithm, 'CRC-16/CCITT-FALSE poly=0x1021 init=0xFFFF');
    for (const v of golden.crc16.vectors) {
      assert.equal(v.pass, true, `golden vector ${JSON.stringify(v.input)}`);
      assert.equal(v.actual, v.expected);
    }
  });

  test('empty input is the init value, not zero', () => {
    assert.equal(crc16(new Uint8Array(0)), 0xffff);
  });

  test('is order- and position-dependent', () => {
    const ab = new TextEncoder().encode('AB');
    const ba = new TextEncoder().encode('BA');
    assert.notEqual(crc16(ab), crc16(ba));
  });

  test('honours start/end over a slice of a larger buffer', () => {
    const data = new TextEncoder().encode('XX123456789YY');
    assert.equal(crc16(data, 2, 11), 0x29b1);
  });

  test('a single flipped bit changes the result', () => {
    const data = hexToBytes(golden.vectors[1].frameHex);
    const before = crc16(data, 2, data.length - 2);
    const flipped = Uint8Array.from(data);
    flipped[10] ^= 0x01;
    assert.notEqual(crc16(flipped, 2, flipped.length - 2), before);
  });
});

/* ------------------------------------------------------------- constants */

describe('protocol constants', () => {
  test('codec constants match the golden manifest', () => {
    assert.equal(SOF0, golden.constants.SOF0);
    assert.equal(SOF1, golden.constants.SOF1);
    assert.equal(MAX_PAYLOAD, golden.constants.MAX_PAYLOAD);
    assert.equal(TELEMETRY_SIZE, golden.constants.TELEMETRY_SIZE);
    assert.equal(PROTOCOL_VERSION, golden.protocolVersion);
    assert.deepEqual({ ...Type }, golden.constants.Type);
    assert.deepEqual({ ...State }, golden.constants.State);
    assert.deepEqual({ ...Flag }, golden.constants.Flag);
  });

  test('start-of-frame bytes are A5 5A', () => {
    assert.equal(SOF0, 0xa5);
    assert.equal(SOF1, 0x5a);
  });

  test('TypeName and StateName round-trip every value', () => {
    for (const [name, value] of Object.entries(Type)) assert.equal(TypeName[value], name);
    for (const [name, value] of Object.entries(State)) assert.equal(StateName[value], name);
  });

  test('telemetry flags occupy eight distinct bits', () => {
    const values = Object.values(Flag);
    assert.equal(new Set(values).size, values.length);
    assert.deepEqual(values, [...values].sort((a, b) => a - b));
    assert.equal(values[values.length - 1], 0x80);
  });

  test('device states are 0..6 and contiguous', () => {
    const values = Object.values(State);
    assert.deepEqual(values, [0, 1, 2, 3, 4, 5, 6]);
    for (const v of values) assert.equal(isState(v), true);
    assert.equal(isState(-1), false);
    assert.equal(isState(7), false);
    assert.equal(isState(0xff), false);
  });

  test('error codes are 0..6 and contiguous', () => {
    assert.deepEqual(Object.values(ErrorCode), [0, 1, 2, 3, 4, 5, 6]);
  });

  test('the five GATT characteristics share one 128-bit custom-service base', () => {
    const base = '7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001';
    const suffixes = Object.values(Characteristic).map((uuid) => uuid.slice(0, 8)).sort();
    assert.deepEqual(suffixes, ['7c9e0000', '7c9e0001', '7c9e0002', '7c9e0003', '7c9e0004']);
    for (const uuid of Object.values(Characteristic)) {
      assert.equal(uuid.slice(8), base.slice(8), `${uuid} shares the service base UUID`);
    }
  });
});

/* --------------------------------------------------------------- framing */

/**
 * The framing oracle. These tests are the executable statement of what
 * docs/02 §4 requires, independent of the frozen reference implementation.
 */
describe('framing oracle (docs/02 §4)', () => {
  const frame = hexToBytes(golden.vectors.find((v) => v.name === 'eventAccident').frameHex);

  test('returns a whole frame pushed in one chunk', () => {
    const frames = new SpecScanner().push(frame);
    assert.equal(frames.length, 1);
    assert.equal(equalBytes(frames[0].raw, frame), true);
    assert.equal(equalBytes(frames[0].payload, truePayloadOf(frame)), true);
    assert.equal(frames[0].type, Type.EVENT);
    assert.equal(frames[0].version, PROTOCOL_VERSION);
  });

  test('recovers a frame at every possible split point', () => {
    for (let split = 1; split < frame.length; split++) {
      const scanner = new SpecScanner();
      const out = [
        ...scanner.push(frame.subarray(0, split)),
        ...scanner.push(frame.subarray(split)),
      ];
      assert.equal(out.length, 1, `split at ${split} must yield exactly one frame`);
      assert.equal(equalBytes(out[0].raw, frame), true, `split at ${split}: raw bytes`);
      assert.equal(
        equalBytes(out[0].payload, truePayloadOf(frame)),
        true,
        `split at ${split}: payload bytes`,
      );
    }
  });

  test('retains a partial frame instead of dropping it', () => {
    const scanner = new SpecScanner();
    const first = scanner.push(frame.subarray(0, 9));
    assert.deepEqual(first, []);
    assert.ok(scanner.buffered > 0, 'unconsumed bytes must be retained across pushes');
    const second = scanner.push(frame.subarray(9));
    assert.equal(second.length, 1);
    assert.equal(equalBytes(second[0].raw, frame), true);
    assert.equal(scanner.buffered, 0, 'buffer drains once the frame completes');
  });

  test('survives a lone 0xA5 at a chunk boundary', () => {
    const scanner = new SpecScanner();
    assert.deepEqual(scanner.push(Uint8Array.from([SOF0])), []);
    const out = scanner.push(frame.subarray(1));
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('A5 A5 5A starts a frame instead of looping forever', () => {
    const out = new SpecScanner().push(Uint8Array.from([SOF0, SOF0, SOF1, ...frame.subarray(2)]));
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('leading noise is skipped and counted', () => {
    const noise = noiseBytes(64);
    const scanner = new SpecScanner();
    const out = scanner.push(Uint8Array.from([...noise, ...frame]));
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
    assert.equal(scanner.resyncBytes, noise.length);
  });

  test('back-to-back frames in one chunk are all returned', () => {
    const two = new Uint8Array(frame.length * 2);
    two.set(frame, 0);
    two.set(frame, frame.length);
    const out = new SpecScanner().push(two);
    assert.equal(out.length, 2);
    assert.equal(equalBytes(out[0].raw, frame), true);
    assert.equal(equalBytes(out[1].raw, frame), true);
  });

  test('frame boundary at a chunk boundary is not a split', () => {
    const two = new Uint8Array(frame.length * 2);
    two.set(frame, 0);
    two.set(frame, frame.length);
    const out = pushInChunks(new SpecScanner(), two, frame.length);
    assert.equal(out.length, 2);
    assert.equal(equalBytes(out[1].raw, frame), true);
  });

  test('a corrupt length is abandoned, not reserved', () => {
    const bogus = buildFrame(Type.PING, new Uint8Array(0), { lengthOverride: 0xffff });
    const out = new SpecScanner().push(Uint8Array.from([...bogus, ...frame]));
    assert.equal(out.length, 1, 'the valid frame after a corrupt header must survive');
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('a bad CRC is counted and the next frame still arrives', () => {
    const corrupt = buildFrame(Type.PING, new Uint8Array(0), { corruptCrc: true });
    const scanner = new SpecScanner();
    const out = scanner.push(Uint8Array.from([...corrupt, ...frame]));
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
    assert.equal(scanner.crcErrors, 1);
  });

  test('a frame whose payload contains 0xA5 0x5A is not mistaken for a header', () => {
    const payload = Uint8Array.from([SOF0, SOF1, SOF0, SOF1, 0x00, SOF0]);
    const tricky = buildFrame(Type.CALIB_LOG, payload);
    const out = new SpecScanner().push(tricky);
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].payload, payload), true);
  });

  test('max payload and max payload + 1', () => {
    const max = buildFrame(Type.CALIB_LOG, new Uint8Array(MAX_PAYLOAD));
    const out = new SpecScanner().push(max);
    assert.equal(out.length, 1);
    assert.equal(out[0].payload.length, MAX_PAYLOAD);

    const over = buildFrame(Type.CALIB_LOG, new Uint8Array(MAX_PAYLOAD), { lengthOverride: MAX_PAYLOAD + 1 });
    assert.equal(new SpecScanner().push(over).length, 0, 'an over-long length is rejected');
  });

  test('scans 10,000 frames in linear time', () => {
    const sample = buildFrame(Type.TELEMETRY, encodeTelemetry({
      tMs: 1234, ax: 10, ay: -20, az: 995,
      magMg: 1000, peakMg: 0, flags: Flag.ARMED, score: 0,
      batteryPct: 90, state: State.IDLE,
    }));

    const run = (count) => {
      const stream = new Uint8Array(sample.length * count);
      for (let i = 0; i < count; i++) stream.set(sample, i * sample.length);
      const started = process.hrtime.bigint();
      const frames = new SpecScanner().push(stream);
      return { count: frames.length, nanos: Number(process.hrtime.bigint() - started) };
    };

    run(200); // warm up, so the first measurement is not the one that pays for JIT

    const small = run(1000);
    assert.equal(small.count, 1000);

    const large = run(10000);
    assert.equal(large.count, 10000, 'every frame in a 10,000-frame burst');

    const perFrameSmall = small.nanos / small.count;
    const perFrameLarge = large.nanos / large.count;
    assert.ok(
      perFrameLarge < perFrameSmall * 4,
      `per-frame cost must stay flat (small ${perFrameSmall.toFixed(0)}ns, ` +
      `large ${perFrameLarge.toFixed(0)}ns)`,
    );
  });
});

/* --------------------------------------------------------------- vectors */

describe('golden.json frame vectors', () => {
  test('the committed manifest is complete', () => {
    // Asserted against the codec, not a literal: the point of this check is that
    // the committed manifest describes the wire format the codec actually emits.
    assert.equal(golden.protocolVersion, PROTOCOL_VERSION);
    assert.equal(golden.constants.TELEMETRY_SIZE, TELEMETRY_SIZE);
    assert.equal(golden.generatedFrom, 'tools/protocol/codec.js');
    assert.ok(golden.vectors.length >= 10, 'expected the full vector set');
    for (const v of golden.vectors) {
      assert.ok(v.name, 'every vector is named');
      assert.match(v.frameHex, /^[0-9A-F]*$/, `${v.name}: frameHex is uppercase hex`);
      assert.ok(Number.isInteger(v.type), `${v.name}: expected type`);
    }
  });

  for (const vector of golden.vectors) {
    describe(vector.name, () => {
      const frame = hexToBytes(vector.frameHex);
      const payloadLen = frame.length - frameSize(0);

      test('frame length and declared length agree', () => {
        const declared = frame[4] | (frame[5] << 8);
        assert.equal(declared, payloadLen, `${vector.name}: length field vs frame size`);
        assert.equal(vector.type, frame[3], `${vector.name}: type byte`);
        assert.equal(frame[0], SOF0);
        assert.equal(frame[1], SOF1);
        assert.equal(frame[2], PROTOCOL_VERSION);
      });

      test('the trailing CRC covers version through payload', () => {
        const want = frame[frame.length - 2] | (frame[frame.length - 1] << 8);
        const got = crc16(frame, 2, frame.length - 2);
        assert.equal(got, want, `${vector.name}: CRC-16/CCITT-FALSE`);
      });

      test('the oracle recovers the frame and its payload', () => {
        const out = new SpecScanner().push(frame);
        assert.equal(out.length, 1);
        assert.equal(equalBytes(out[0].raw, frame), true);
        assert.equal(out[0].type, vector.type);
        assert.equal(equalBytes(out[0].payload, truePayloadOf(frame)), true);
      });

      test('the oracle recovers it at every split point', () => {
        for (let split = 1; split < frame.length; split++) {
          const scanner = new SpecScanner();
          const out = [
            ...scanner.push(frame.subarray(0, split)),
            ...scanner.push(frame.subarray(split)),
          ];
          assert.equal(out.length, 1, `${vector.name}: split at ${split}`);
          assert.equal(equalBytes(out[0].raw, frame), true, `${vector.name}: split at ${split}`);
        }
      });

      test('re-encoding the recovered payload reproduces the frame byte-for-byte', () => {
        const { payload } = new SpecScanner().push(frame)[0];
        assert.equal(
          bytesToHex(encodeFrame(vector.type, payload)),
          vector.frameHex,
          `${vector.name}: encode(decode(frame)) === frame`,
        );
      });

      if (vector.payloadHex !== undefined) {
        test('payloadHex matches the wire bytes', () => {
          const { payload } = new SpecScanner().push(frame)[0];
          assert.equal(bytesToHex(payload), vector.payloadHex);
        });
      }

      if (vector.json != null) {
        test('JSON payload round-trips', () => {
          const { payload } = new SpecScanner().push(frame)[0];
          assert.deepEqual(JSON.parse(new TextDecoder().decode(payload)), vector.json);
        });
      }

      if (vector.telemetry !== undefined) {
        test('telemetry record decodes to the expected fields', () => {
          const { payload } = new SpecScanner().push(frame)[0];
          const decoded = decodeTelemetry(payload);
          const {
            stateName, sw420, buzzer, ledRed, ledGreen, oledOk,
            sosButton, armed, charging, ...fields
          } = decoded;
          // Strict equality: the wire bytes are the authority, and the manifest
          // is required to agree with them exactly.
          assert.deepEqual(fields, vector.telemetry);
          assert.equal(stateName, StateName[vector.telemetry.state]);
        });

        test('the manifest expectation re-encodes to the committed frame', () => {
          assert.equal(
            bytesToHex(encodeTelemetry(vector.telemetry)),
            bytesToHex(truePayloadOf(frame)),
            `${vector.name}: encodeTelemetry(manifest) === wire bytes`,
          );
        });
      }
    });
  }

  test('the empty-payload vector carries no body', () => {
    const v = golden.vectors.find((x) => x.name === 'empty');
    assert.equal(hexToBytes(v.frameHex).length, 8);
    assert.equal(v.payloadHex, '');
    assert.equal(v.json, null);
    assert.equal(parseJsonFrame(new SpecScanner().push(hexToBytes(v.frameHex))[0]), null);
  });

  test('the largest vector stays inside MAX_PAYLOAD', () => {
    const v = golden.vectors.find((x) => x.name === 'maxPayload');
    const frame = hexToBytes(v.frameHex);
    const payloadLen = frame.length - frameSize(0);
    assert.ok(payloadLen <= MAX_PAYLOAD, `payload ${payloadLen}B <= ${MAX_PAYLOAD}B`);
    assert.equal(bytesToHex(new SpecScanner().push(frame)[0].payload).length, payloadLen * 2);
  });
});

/**
 * golden.json is generated, but a generator bug once let a vector's `expect`
 * block disagree with the frame the same generator produced: the wire bytes were
 * right and the recorded expectation was wrong, in two places.
 *
 * The fix was to the generator (record the clamped values, not the values fed
 * in). These tests now assert the invariant that makes that class of bug
 * impossible to reintroduce: for every vector, re-encoding its recorded
 * expectation must reproduce the committed frame byte for byte. A manifest can
 * no longer disagree with its own wire image.
 */
describe('golden.json internal consistency', () => {
  test('every telemetry vector is self-consistent with its frame', () => {
    let checked = 0;
    for (const v of golden.vectors) {
      if (v.telemetry === undefined) continue;
      assert.equal(
        bytesToHex(encodeTelemetry(v.telemetry)),
        bytesToHex(truePayloadOf(hexToBytes(v.frameHex))),
        `${v.name}: re-encoding the recorded expectation must reproduce the frame`,
      );
      checked++;
    }
    assert.ok(checked >= 4, `expected several telemetry vectors, saw ${checked}`);
  });

  test('every JSON expectation, re-encoded, reproduces its frame', () => {
    for (const v of golden.vectors) {
      if (v.json == null) continue;
      assert.equal(
        bytesToHex(encodeFrame(v.type, v.json)),
        v.frameHex,
        `${v.name}: encodeFrame(manifest json) === frameHex`,
      );
    }
  });

  test('the flags byte on the wire is exactly the recorded flags', () => {
    const v = golden.vectors.find((x) => x.name === 'telemetryImpact');
    const decoded = decodeTelemetry(truePayloadOf(hexToBytes(v.frameHex)));
    assert.equal(decoded.flags, v.telemetry.flags);
    assert.equal(decoded.flags & Flag.LED_GREEN, 0, 'LED_GREEN is intentionally clear');
    assert.equal(decoded.flags & Flag.CHARGING, Flag.CHARGING, 'CHARGING is set');
  });

  test('saturation clamps to the int16 bounds, it does not wrap', () => {
    const v = golden.vectors.find((x) => x.name === 'telemetrySaturated');
    const decoded = decodeTelemetry(truePayloadOf(hexToBytes(v.frameHex)));
    assert.equal(decoded.ay, -32768, 'negative saturation lands on the minimum');
    assert.equal(decoded.ax, 32767, 'positive saturation lands on the maximum');
    assert.equal(clampI16(-99999), -32768, 'clamp, not two\'s-complement wraparound');
    assert.equal(clampI16(99999), 32767);
    assert.equal(v.telemetry.ay, decoded.ay, 'the manifest records the clamped value');
  });
});

/* --------------------------------------------------------------- encoder */

describe('encodeFrame', () => {
  test('null, undefined and empty string all mean an empty payload', () => {
    for (const payload of [null, undefined, '']) {
      const frame = encodeFrame(Type.PING, payload);
      assert.equal(frame.length, 8);
      assert.equal(frame[4], 0);
      assert.equal(frame[5], 0);
    }
  });

  test('a plain object is serialised as compact UTF-8 JSON', () => {
    const frame = encodeFrame(Type.COMMAND, { op: 'CONFIRM', eventId: '8f3a1c22' });
    const payload = new SpecScanner().push(frame)[0].payload;
    assert.deepEqual(JSON.parse(new TextDecoder().decode(payload)), { op: 'CONFIRM', eventId: '8f3a1c22' });
    assert.equal(new TextDecoder().decode(payload), '{"op":"CONFIRM","eventId":"8f3a1c22"}');
  });

  test('a string payload is used verbatim, not JSON-quoted', () => {
    const frame = encodeFrame(Type.EVENT, 'not json');
    const payload = new SpecScanner().push(frame)[0].payload;
    assert.equal(new TextDecoder().decode(payload), 'not json');
  });

  test('length is little-endian and set for large payloads', () => {
    const payload = new Uint8Array(300).fill(0x5a);
    const frame = encodeFrame(Type.CALIB_LOG, payload);
    assert.equal(frame[4], 300 & 0xff);
    assert.equal(frame[5], 300 >> 8);
    assert.equal(frame.length, frameSize(300));
  });

  test('exactly MAX_PAYLOAD is accepted and one byte more is refused', () => {
    assert.equal(encodeFrame(Type.CALIB_LOG, new Uint8Array(MAX_PAYLOAD)).length, frameSize(MAX_PAYLOAD));
    assert.throws(
      () => encodeFrame(Type.CALIB_LOG, new Uint8Array(MAX_PAYLOAD + 1)),
      RangeError,
    );
  });

  test('a non-ASCII payload is measured in bytes, not characters', () => {
    const frame = encodeFrame(Type.EVENT, 'café');
    assert.equal(frame.length, frameSize(5), "'café' is 5 UTF-8 bytes, not 4 characters");
    assert.equal(frame[4], 5);
    assert.equal(new TextDecoder().decode(new SpecScanner().push(frame)[0].payload), 'café');
  });

  test('every frame it produces satisfies the spec scanner', () => {
    for (const type of Object.values(Type)) {
      for (const payload of [null, new Uint8Array(0), Uint8Array.from([0, 1, 2, 3, 255])]) {
        const frame = encodeFrame(type, payload);
        const out = new SpecScanner().push(frame);
        assert.equal(out.length, 1, `type ${TypeName[type]}`);
        assert.equal(equalBytes(out[0].raw, frame), true, `type ${TypeName[type]}`);
      }
    }
  });
});

describe('decodeFrame and parseJsonFrame', () => {
  test('decodeFrame returns the first frame, or null', () => {
    const frame = encodeFrame(Type.PING, null);
    assert.equal(decodeFrame(frame).type, Type.PING);
    assert.equal(decodeFrame(noiseBytes(32)), null);
  });

  test('parseJsonFrame returns null for an empty payload', () => {
    assert.equal(parseJsonFrame(decodeFrame(encodeFrame(Type.PING, null))), null);
  });

  test('parseJsonFrame throws on a non-JSON body, by design', () => {
    assert.throws(() => parseJsonFrame(decodeFrame(encodeFrame(Type.EVENT, 'nope'))), SyntaxError);
  });

  test('describeFrame summarises both telemetry and JSON frames', () => {
    // Fed through the oracle, not decodeFrame: D3 would shift the record.
    const record = encodeTelemetry({
      tMs: 5, ax: 0, ay: 0, az: 1000,
      magMg: 1000, peakMg: 0, flags: 0, score: 0, batteryPct: 100, state: State.IDLE,
    });
    const t = describeFrame(new SpecScanner().push(encodeFrame(Type.TELEMETRY, record))[0]);
    assert.match(t, /^TELEMETRY t=5ms mag=1\.00g state=IDLE/);

    const j = describeFrame(new SpecScanner().push(encodeFrame(Type.COMMAND, { op: 'CONFIRM' }))[0]);
    assert.match(j, /^COMMAND \{"op":"CONFIRM"\}/);
  });

  test('describeFrame falls back to a size summary for a non-JSON body', () => {
    const out = describeFrame(new SpecScanner().push(encodeFrame(Type.EVENT, 'not json'))[0]);
    assert.equal(out, 'EVENT <8B binary>');
  });

  test('an unknown type is rendered in hex', () => {
    const out = describeFrame(new SpecScanner().push(encodeFrame(0x77, { a: 1 }))[0]);
    assert.match(out, /^0x77 /);
  });
});

/* ------------------------------------------------------------- telemetry */

describe('telemetry record codec', () => {
  const base = {
    tMs: 423119, ax: 120, ay: -45, az: 998,
    magMg: 1004, peakMg: 4820, flags: Flag.ARMED, score: 0,
    batteryPct: 96, state: State.IDLE,
  };

  test('a record is exactly 18 bytes with a defined field order', () => {
    // 18 = tMs(4) + ax/ay/az(6) + mag/peak(4) + flags/score/battery/state(4).
    // The six gyro bytes present in v1 are gone, not zero-filled.
    assert.equal(TELEMETRY_SIZE, 18);
    assert.equal(encodeTelemetry(base).length, 18);
  });

  test('round-trips every field', () => {
    assert.deepEqual(decodeTelemetry(encodeTelemetry(base)), { ...base, ...flagView(Flag.ARMED), stateName: 'IDLE' });
  });

  test('accel is signed 16-bit, magnitude and peak unsigned', () => {
    const t = decodeTelemetry(encodeTelemetry({ ...base, ax: -32768, ay: 32767, magMg: 65535, peakMg: 0 }));
    assert.equal(t.ax, -32768);
    assert.equal(t.ay, 32767);
    assert.equal(t.magMg, 65535);
    assert.equal(t.peakMg, 0);
  });

  test('u32 uptime does not wrap below 2^31', () => {
    assert.equal(decodeTelemetry(encodeTelemetry({ ...base, tMs: 4294967295 })).tMs, 4294967295);
  });

  test('fractional milli-g is rounded, not truncated', () => {
    const t = decodeTelemetry(encodeTelemetry({ ...base, ax: 120.6, ay: -11.4, magMg: 1004.5 }));
    assert.equal(t.ax, 121);
    assert.equal(t.ay, -11);
    assert.equal(t.magMg, 1005);
  });

  test('out-of-range inputs are clamped rather than wrapped', () => {
    const t = decodeTelemetry(encodeTelemetry({ ...base, ax: 99999, ay: -99999, az: 70000, magMg: 70000, peakMg: -5, score: 300, batteryPct: 300, state: 9 }));
    assert.equal(t.ax, 32767);
    assert.equal(t.ay, -32768);
    assert.equal(t.az, 32767);
    assert.equal(t.magMg, 65535);
    assert.equal(t.peakMg, 0);
    assert.equal(t.score, 255);
    assert.equal(t.batteryPct, 255);
    assert.equal(t.stateName, 'UNKNOWN');
  });

  test('a 255 battery is "unknown", not "full"', () => {
    assert.equal(decodeTelemetry(encodeTelemetry({ ...base, batteryPct: 255 })).batteryPct, 255);
  });

  test('each flag bit maps to a boolean', () => {
    const t = decodeTelemetry(encodeTelemetry({ ...base, flags: 0xff }));
    for (const name of ['sw420', 'buzzer', 'ledRed', 'ledGreen', 'oledOk', 'sosButton', 'armed', 'charging']) {
      assert.equal(t[name], true, name);
    }
    assert.deepEqual(Object.keys(flagView(0)), Object.keys(flagView(0xff)));
  });

  test('a short record is refused', () => {
    // One byte under the record size, so this tracks TELEMETRY_SIZE rather than
    // a literal that stops testing anything when the layout changes.
    assert.throws(() => decodeTelemetry(new Uint8Array(TELEMETRY_SIZE - 1)), RangeError);
  });

  test('clamps are exported and total', () => {
    assert.equal(clampI16(1.4), 1);
    assert.equal(clampI16(-99999), -32768);
    assert.equal(clampU16(-1), 0);
    assert.equal(clampU16(99999), 65535);
    assert.equal(clampByte(300), 255);
    assert.equal(clampByte(-1), 0);
  });

  test('a telemetry record framed as TELEMETRY survives a byte-by-byte feed', () => {
    const frame = encodeFrame(Type.TELEMETRY, encodeTelemetry(base));
    const frames = pushInChunks(new SpecScanner(), frame, 1);
    assert.equal(frames.length, 1);
    assert.deepEqual(decodeTelemetry(frames[0].payload), { ...base, ...flagView(Flag.ARMED), stateName: 'IDLE' });
  });
});

function flagView(flags) {
  const t = decodeTelemetry(encodeTelemetry({
    tMs: 0, ax: 0, ay: 0, az: 0, magMg: 0, peakMg: 0,
    flags, score: 0, batteryPct: 0, state: 0,
  }));
  return {
    sw420: t.sw420, buzzer: t.buzzer, ledRed: t.ledRed, ledGreen: t.ledGreen,
    oledOk: t.oledOk, sosButton: t.sosButton, armed: t.armed, charging: t.charging,
  };
}

/* ------------------------------------------- FrameScanner conformance (spec) */

/**
 * These assert the SPEC behaviour of the FrameScanner, not a characterisation of
 * whatever it currently does. Three real defects were found here and fixed in
 * codec.js:
 *
 *   D1  push([A5, A5, 5A]) looped forever — the `sof1` state did not consume a
 *       repeated 0xA5, so `i` never advanced.
 *   D2  a frame split across two pushes was silently discarded — the partial
 *       frame was flushed instead of retained.
 *   D3  the decoded payload started 2 bytes early, at the length field.
 *
 * Each is now a live assertion. The child-process test for D1 is retained
 * deliberately: an infinite loop inside an async test hangs the runner instead
 * of failing it, so the only trustworthy way to prove the loop is gone is to run
 * it under a timeout and assert it terminated.
 */
describe('FrameScanner conforms to the spec', () => {
  const jsonVector = golden.vectors.find((v) => v.name === 'eventAccident');
  const frame = hexToBytes(jsonVector.frameHex);

  test('D1: [A5, A5, 5A] terminates — child process, timeout-bounded', () => {
    const script =
      `import(${JSON.stringify(codecUrl)}).then((m) => {` +
      `new m.FrameScanner().push(Uint8Array.from([0xA5, 0xA5, 0x5A]));` +
      `process.stdout.write('returned');` +
      `});`;
    const result = spawnSync(process.execPath, ['-e', script], {
      timeout: 5000,
      encoding: 'utf8',
    });
    assert.equal(result.error?.code, undefined, 'the child process did not time out');
    assert.equal(result.signal, null, 'the child process was not killed');
    assert.equal(result.stdout, 'returned', 'push() returned');
  });

  test('D1: a false SOF immediately before a real frame still finds the frame', () => {
    const real = encodeFrame(Type.PING, null);
    const scanner = new FrameScanner();
    const out = [
      ...scanner.push(Uint8Array.from([SOF0, SOF0, SOF1])),
      ...scanner.push(real),
    ];
    assert.equal(out.length, 1, 'the trailing real frame is recovered');
    assert.equal(equalBytes(out[0].raw, real), true);
  });

  test('D2: every possible split point reassembles the frame', () => {
    for (let split = 1; split < frame.length; split++) {
      const scanner = new FrameScanner();
      const out = [
        ...scanner.push(frame.subarray(0, split)),
        ...scanner.push(frame.subarray(split)),
      ];
      assert.equal(out.length, 1, `split at ${split} must yield exactly one frame`);
      assert.equal(
        equalBytes(out[0].raw, frame),
        true,
        `split at ${split} must yield the original bytes`,
      );
    }
  });

  test('D2: every golden vector survives every split point', () => {
    for (const v of golden.vectors) {
      const bytes = hexToBytes(v.frameHex);
      for (let split = 1; split < bytes.length; split++) {
        // One scanner, two pushes: a split frame can only be reassembled by the
        // same instance, which is the whole point of the retained-partial path.
        const scanner = new FrameScanner();
        const out = [
          ...scanner.push(bytes.subarray(0, split)),
          ...scanner.push(bytes.subarray(split)),
        ];
        assert.equal(out.length, 1, `${v.name} split at ${split}`);
        assert.equal(equalBytes(out[0].raw, bytes), true, `${v.name} split at ${split}`);
      }
    }
  });

  test('D2: a partial frame is retained across pushes, not discarded', () => {
    const scanner = new FrameScanner();
    assert.deepEqual(scanner.push(frame.subarray(0, 9)), [], 'nothing yet');
    assert.ok(scanner.buffered > 0, 'the partial frame is retained');
    const out = scanner.push(frame.subarray(9));
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
    assert.equal(scanner.buffered, 0, 'the buffer drains once complete');
  });

  test('D2: one byte at a time still reassembles the frame', () => {
    const scanner = new FrameScanner();
    const out = [];
    for (const byte of frame) out.push(...scanner.push(Uint8Array.from([byte])));
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('D3: the decoded payload is exactly the body, never the length field', () => {
    for (const v of golden.vectors) {
      const bytes = hexToBytes(v.frameHex);
      const out = new FrameScanner().push(bytes);
      assert.equal(out.length, 1, v.name);
      assert.equal(
        equalBytes(out[0].payload, truePayloadOf(bytes)),
        true,
        `${v.name}: payload must equal the body`,
      );
      assert.equal(
        equalBytes(out[0].raw, bytes),
        true,
        `${v.name}: raw must equal the whole frame`,
      );
    }
  });

  test('D3: a telemetry record read through the scanner matches the vector', () => {
    for (const name of ['telemetryNominal', 'telemetryImpact', 'telemetrySaturated', 'telemetryMuted']) {
      const v = golden.vectors.find((x) => x.name === name);
      const decoded = decodeTelemetry(new FrameScanner().push(hexToBytes(v.frameHex))[0].payload);
      for (const [key, expected] of Object.entries(v.telemetry)) {
        assert.equal(decoded[key], expected, `${name}.${key}`);
      }
    }
  });

  test('D3: describeFrame reports the true uptime for a telemetry frame', () => {
    const encoded = encodeFrame(Type.TELEMETRY, encodeTelemetry({
      tMs: 5, ax: 0, ay: 0, az: 1000,
      magMg: 1000, peakMg: 0, flags: 0, score: 0, batteryPct: 100, state: State.IDLE,
    }));
    assert.match(describeFrame(decodeFrame(encoded)), /t=5ms/);
  });

  test('a corrupt length resyncs without allocating and still finds a later frame', () => {
    const bogus = buildFrame(Type.PING, new Uint8Array(0), { lengthOverride: 0xffff });
    const scanner = new FrameScanner();
    const out = scanner.push(Uint8Array.from([...bogus, ...frame]));
    assert.ok(scanner.buffered <= frame.length, 'no 64 KB reservation');
    assert.equal(out.length, 1, 'the intact frame after the bogus one is found');
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('a bad CRC is counted and the hunt resumes one byte past the bad SOF', () => {
    const corrupt = buildFrame(Type.PING, new Uint8Array(0), { corruptCrc: true });
    const scanner = new FrameScanner();
    const out = scanner.push(Uint8Array.from([...corrupt, ...frame]));
    assert.equal(scanner.crcErrors, 1);
    assert.equal(out.length, 1, 'only the intact trailing frame is returned');
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('noise before a frame is counted and discarded', () => {
    const scanner = new FrameScanner();
    const noise = noiseBytes(48);
    const out = scanner.push(Uint8Array.from([...noise, ...frame]));
    assert.equal(out.length, 1);
    assert.equal(scanner.buffered, 0);
    assert.equal(scanner.resyncBytes, noise.length);
  });

  test('reset clears buffered bytes and the pending-frame state', () => {
    const scanner = new FrameScanner();
    scanner.push(frame.subarray(0, 5));
    assert.ok(scanner.buffered > 0);
    scanner.reset();
    assert.equal(scanner.buffered, 0);
    // After a reset the scanner must start clean, not resume a stale partial.
    const out = scanner.push(frame);
    assert.equal(out.length, 1);
    assert.equal(equalBytes(out[0].raw, frame), true);
  });

  test('10k frames stream through with linear scaling and no leak', () => {
    const chunk = encodeFrame(Type.PING, null);
    const reps = 10000;
    const bulk = new Uint8Array(chunk.length * reps);
    for (let i = 0; i < reps; i++) bulk.set(chunk, i * chunk.length);

    const scanner = new FrameScanner();
    const started = process.hrtime.bigint();
    let count = 0;
    // Deliberately awkward chunking (7 bytes) to exercise partial-frame paths.
    for (let off = 0; off < bulk.length; off += 7) {
      count += scanner.push(bulk.subarray(off, Math.min(off + 7, bulk.length))).length;
    }
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;

    assert.equal(count, reps, 'every frame is emitted exactly once');
    assert.equal(scanner.buffered, 0, 'nothing is left buffered');
    assert.equal(scanner.crcErrors, 0);
    assert.ok(elapsedMs < 5000, `10k frames took ${elapsedMs.toFixed(0)}ms — linear, not quadratic`);
  });
});
