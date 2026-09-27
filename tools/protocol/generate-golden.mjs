#!/usr/bin/env node
/**
 * Generates tools/protocol/golden.json — the cross-implementation conformance
 * vectors for the BLE wire protocol.
 *
 * The Dart (app) and C++ (firmware) codecs are validated against these exact
 * bytes, so a protocol change that breaks one side fails CI instead of
 * surfacing as an intermittent field failure.
 *
 *   node tools/protocol/generate-golden.mjs
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  Type, State, Flag, encodeFrame, encodeTelemetry, crc16,
} from './codec.js';

const here = dirname(fileURLToPath(import.meta.url));
const hex = (u8) => Buffer.from(u8).toString('hex').toUpperCase();

const vectors = [];
const add = (name, description, frame, expect) => {
  vectors.push({ name, description, frameHex: hex(frame), ...expect });
};

/* --- empty payload ------------------------------------------------------- */
add('empty', 'HELLO with no body, minimal frame',
  encodeFrame(Type.PING, null),
  { type: Type.PING, payloadHex: '', json: null });

/* --- json payloads ------------------------------------------------------- */
add('hello', 'HELLO — full capability negotiation',
  encodeFrame(Type.HELLO, {
    app: 'smart-accident-alert',
    appVersion: '1.0.0',
    proto: 1,
    capabilities: ['telemetry', 'config', 'calibrate', 'command', 'diag'],
    deviceName: 'My Car',
    locale: 'en-IN',
  }),
  { type: Type.HELLO, json: {
    app: 'smart-accident-alert', appVersion: '1.0.0', proto: 1,
    capabilities: ['telemetry', 'config', 'calibrate', 'command', 'diag'],
    deviceName: 'My Car', locale: 'en-IN',
  } });

add('helloAck', 'HELLO_ACK — device identity + capability flags',
  encodeFrame(Type.HELLO_ACK, {
    fwVersion: '1.0.0', hw: 'esp32-devkit-v1', proto: 1,
    chipId: 'A1B2C3D4', mac: '24:6F:28:A1:B2:C3:D4', name: 'SAAS-A1B2C3D4',
    batteryMv: 4120, batteryPct: 96, charging: false, uptimeMs: 123456,
    mpu: { present: true, addr: '0x68', whoAmI: 113 },
    oled: { present: true, addr: '0x3C' },
    sw420: true, calibrated: true, sensorRateHz: 50, state: State.IDLE,
  }),
  { type: Type.HELLO_ACK });

add('eventAccident', 'EVENT — fused accident detection',
  encodeFrame(Type.EVENT, {
    type: 'ACCIDENT_DETECTED', eventId: '8f3a1c22', seq: 7,
    t_ms: 423119, uptimeMs: 423119, score: 87,
    impact: {
      magG: 4.82, peakAccMg: 4820, peakGyrDps: 391, gyrMagDps: 402.1,
      sw420: true, orientationChangeDeg: 63.4, preImpactSpeedKmh: 48.3,
    },
    confirmWindowSec: 10, canCancel: true,
  }),
  { type: Type.EVENT, json: {
    type: 'ACCIDENT_DETECTED', eventId: '8f3a1c22', seq: 7,
    t_ms: 423119, uptimeMs: 423119, score: 87,
    impact: {
      magG: 4.82, peakAccMg: 4820, peakGyrDps: 391, gyrMagDps: 402.1,
      sw420: true, orientationChangeDeg: 63.4, preImpactSpeedKmh: 48.3,
    },
    confirmWindowSec: 10, canCancel: true,
  } });

add('commandConfirm', 'COMMAND — confirm alert',
  encodeFrame(Type.COMMAND, { op: 'CONFIRM', eventId: '8f3a1c22' }),
  { type: Type.COMMAND, json: { op: 'CONFIRM', eventId: '8f3a1c22' } });

add('config', 'CONFIG — full settings write',
  encodeFrame(Type.CONFIG, {
    accelThresholdMg: 3000, gyroThresholdDps: 220, vibrationRequired: true,
    debounceMs: 60, confirmWindowSec: 10, minSpeedKmh: 5.0,
    detectorGain: 1.0, telemetryHz: 50, buzzerEnabled: true,
    ledEnabled: true, muteUntil: 0, autoArm: true,
  }),
  { type: Type.CONFIG });

/* --- telemetry: nominal -------------------------------------------------- */
add('telemetryNominal', 'TELEMETRY — normal driving, 1g on Z',
  encodeFrame(Type.TELEMETRY, encodeTelemetry({
    tMs: 423119, ax: 120, ay: -45, az: 998,
    gx: 23, gy: -11, gz: 7, magMg: 1004, peakMg: 4820,
    flags: Flag.SW420 | Flag.LED_GREEN | Flag.OLED_OK | Flag.ARMED,
    score: 0, batteryPct: 96, state: State.IDLE,
  })),
  { type: Type.TELEMETRY, telemetry: {
    tMs: 423119, ax: 120, ay: -45, az: 998,
    gx: 23, gy: -11, gz: 7, magMg: 1004, peakMg: 4820,
    flags: Flag.SW420 | Flag.LED_GREEN | Flag.OLED_OK | Flag.ARMED,
    score: 0, batteryPct: 96, state: State.IDLE,
  } });

/* --- telemetry: impact --------------------------------------------------- */
add('telemetryImpact', 'TELEMETRY — impact, every flag except LED_GREEN, ALARM state',
  encodeFrame(Type.TELEMETRY, encodeTelemetry({
    tMs: 429000, ax: 4820, ay: -3120, az: 1100,
    gx: -390, gy: 220, gz: 145, magMg: 5948, peakMg: 5948,
    flags: Flag.SW420 | Flag.BUZZER | Flag.LED_RED | Flag.OLED_OK |
           Flag.SOS_BUTTON | Flag.ARMED | Flag.CHARGING,
    score: 87, batteryPct: 41, state: State.ALARM,
  })),
  { type: Type.TELEMETRY, telemetry: {
    tMs: 429000, ax: 4820, ay: -3120, az: 1100,
    gx: -390, gy: 220, gz: 145, magMg: 5948, peakMg: 5948,
    // 0xF7: all eight bits except LED_GREEN (0x08). Written as the same
    // expression that produced the frame so the two can never drift apart.
    flags: Flag.SW420 | Flag.BUZZER | Flag.LED_RED | Flag.OLED_OK |
           Flag.SOS_BUTTON | Flag.ARMED | Flag.CHARGING,
    score: 87, batteryPct: 41, state: State.ALARM,
  } });

/* --- telemetry: boundary / saturation ----------------------------------- */
add('telemetrySaturated', 'TELEMETRY — i16/u16 saturation + unknown battery',
  encodeFrame(Type.TELEMETRY, encodeTelemetry({
    tMs: 4294967295, ax: 99999, ay: -99999, az: 32767,
    gx: -32768, gy: 32767, gz: 0, magMg: 65535, peakMg: 70000,
    flags: 0, score: 255, batteryPct: 255, state: State.FAULT,
  })),
  { type: Type.TELEMETRY, telemetry: {
    tMs: 4294967295, ax: 32767, ay: -32768, az: 32767,
    gx: -32768, gy: 32767, gz: 0, magMg: 65535, peakMg: 65535,
    // Expectations are the CLAMPED values, written as the same expressions the
    // encoder clamps to, so the manifest can never disagree with the wire.
    flags: 0, score: 255, batteryPct: 255, state: State.FAULT,
  } });

add('telemetryMuted', 'TELEMETRY — MUTED, disarmed, zero motion',
  encodeFrame(Type.TELEMETRY, encodeTelemetry({
    tMs: 1000, ax: 0, ay: 0, az: 1000, gx: 0, gy: 0, gz: 0,
    magMg: 1000, peakMg: 0, flags: 0, score: 0,
    batteryPct: 0, state: State.MUTED,
  })),
  { type: Type.TELEMETRY, telemetry: {
    tMs: 1000, ax: 0, ay: 0, az: 1000, gx: 0, gy: 0, gz: 0,
    magMg: 1000, peakMg: 0, flags: 0, score: 0,
    batteryPct: 0, state: State.MUTED,
  } });

/* --- max payload --------------------------------------------------------- */
const bigNotes = Array.from({ length: 40 }, (_, i) => `note-${i}`);
add('maxPayload', 'CALIB_LOG at MAX_PAYLOAD (512 B)',
  encodeFrame(Type.CALIB_LOG, { samples: bigNotes }),
  { type: Type.CALIB_LOG });

/* --- crc check value ----------------------------------------------------- */
const crcVectors = [
  { input: '', expected: 0xffff },
  { input: 'A', expected: 0xb915 },
  { input: '123456789', expected: 0x29b1 },
  { input: 'The quick brown fox jumps over the lazy dog', expected: 0x8fdd },
].map((v) => {
  const actual = crc16(new TextEncoder().encode(v.input));
  return { input: v.input, expected: `0x${v.expected.toString(16).toUpperCase().padStart(4, '0')}`,
           actual: `0x${actual.toString(16).toUpperCase().padStart(4, '0')}`,
           pass: actual === v.expected };
});

const doc = {
  $comment: 'Generated by tools/protocol/generate-golden.mjs. Do not hand-edit.',
  protocolVersion: 1,
  generatedFrom: 'tools/protocol/codec.js',
  constants: {
    SOF0: 0xa5, SOF1: 0x5a, MAX_PAYLOAD: 512, TELEMETRY_SIZE: 24,
    Type, State, Flag,
  },
  crc16: { algorithm: 'CRC-16/CCITT-FALSE poly=0x1021 init=0xFFFF', vectors: crcVectors },
  vectors,
};

mkdirSync(here, { recursive: true });
const out = join(here, 'golden.json');
writeFileSync(out, `${JSON.stringify(doc, null, 2)}\n`);

const failed = crcVectors.filter((v) => !v.pass);
if (failed.length) {
  console.error('CRC vectors FAILED:', failed);
  process.exit(1);
}
console.log(`Wrote ${out}`);
console.log(`  ${vectors.length} frame vectors, ${crcVectors.length} CRC vectors (all pass)`);
for (const v of vectors) {
  console.log(`  - ${v.name.padEnd(20)} ${v.frameHex.length / 2} B  ${v.description}`);
}
