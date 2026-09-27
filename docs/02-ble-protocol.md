# BLE Wire Protocol Specification (v1)

> **Status:** FROZEN — this document is the single source of truth.
> Every implementation in this repository (firmware, Flutter app, simulator, tests) MUST match it.
> Reference byte-order: **little-endian** everywhere. Reference checksum: **CRC-16/CCITT-FALSE**.

---

## 1. Why a framed binary protocol

Naive implementations send plain newline-delimited JSON on every sensor sample. That is a
performance trap on a 3.3 V / 240 MHz microcontroller:

| Approach | Bytes / sample @ 50 Hz | CPU (ESP32 @ 240 MHz) | Notes |
| --- | --- | --- | --- |
| JSON per sample | ~180 B | ~1.9 ms | `snprintf` + float formatting dominates |
| Plain CSV per sample | ~34 B | ~0.35 ms | fragile, unframed, no CRC |
| **This protocol** | **24 B** | **~0.02 ms** | fixed memcpy, no allocator, no `printf` |

The design splits the traffic by nature:

* **Telemetry** (the high-rate path, 50 Hz) → **24-byte fixed binary record**. Zero parsing,
  zero allocation, one `memcpy`.
* **Events** (rare, latency-critical, must be human-debuggable in nRF Connect) → **UTF-8 JSON**.

This gives the best of both: 7.5× less radio air-time than JSON telemetry, and events a human
can read off a sniff.

---

## 2. GATT Layout

### 2.1 Service

| Item | UUID |
| --- | --- |
| Primary service | `7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001` |
| Characteristic `TX` (device → phone, **notify** + **read**) | `7c9e0001-1e4a-4f6b-9c2d-5a1b7c30d001` |
| Characteristic `RX` (phone → device, **write without response** + **read**) | `7c9e0002-1e4a-4f6b-9c2d-5a1b7c30d001` |
| Characteristic `CTRL` (device → phone, **notify**) | `7c9e0003-1e4a-4f6b-9c2d-5a1b7c30d001` |
| Characteristic `INFO` (device → phone, **read**) | `7c9e0004-1e4a-4f6b-9c2d-5a1b7c30d001` |

### 2.2 Why three notify characteristics

Congestion control. Android's GATT stack silently drops notifications when the app does not
drain fast enough; a single stream would drop *events* (the important ones) along with telemetry.

* `CTRL` — **highest priority.** Carries `ACCIDENT_DETECTED`, `MANUAL_SOS`, `ALERT_CANCELLED`,
  `ALERT_CONFIRMED`, `ALERT_SENT`, `HELLO_ACK`, `ACK`, `ERROR`. Events are re-sent
  (idempotently, up to 3 times) if unacknowledged.
* `TX` — **best-effort telemetry.** 50 Hz. Dropped without consequence when congested.
* `INFO` — static device identity, read once on connect.

### 2.3 Connection parameters

| Parameter | Value | Reason |
| --- | --- | --- |
| MTU | 247 (request), 23 fallback | 24 B telemetry fits one packet with room for framing |
| Connection interval | 15 ms (24 units @ 1 ms) | ≤ 67 Hz, comfortably above 50 Hz telemetry |
| Slave latency | 4 | allows the peripheral to sleep 4 intervals between events |
| Supervision timeout | 4 s (4000 units @ 10 ms) | fast disconnect detection |
| TX power | +9 dBm | vehicle metal body attenuation |

### 2.4 Advertising

| Field | Value |
| --- | --- |
| Name | `SAAS-<chipIdLow4hex>` (max 29 chars) |
| Service UUID | primary service UUID |
| Appearance | `0x03` — Generic Sensor |
| TX Power level | included, 3 dBm → `-33 dBm` → `-9 dBm` |

The app filters scans by the service UUID, so a user never has to pick from a list of a hundred
unknown peripherals.

---

## 3. Frame Format

```
 0      1      2      3      4      5             5+LEN-1     5+LEN    6+LEN
 +------ +------+------+------+--------+---------------+-----------+--------+
 | 0xA5 | 0x5A | VER  | TYPE | LEN(2) |  PAYLOAD      | CRC16(2)  | (pad)  |
 +------+------+------+------+--------+---------------+-----------+--------+
   SOF0   SOF1   0x01   u8     LE      LEN bytes      LE
```

| Field | Size | Notes |
| --- | --- | --- |
| `SOF0` `SOF1` | 2 | Start-of-frame. Resynchronises the parser after garbage on the link. |
| `VER` | 1 | Protocol version, currently `0x01`. Receiver drops frames with an unknown version. |
| `TYPE` | 1 | See §4. |
| `LEN` | 2 u16 LE | Payload byte count, `0 … 512`. |
| `PAYLOAD` | LEN | Binary record or UTF-8 JSON (no BOM, no trailing NUL). |
| `CRC16` | 2 u16 LE | CRC-16/CCITT-FALSE over `VER … last PAYLOAD byte`. |

**Padding.** A 24-byte telemetry record in a 247-byte MTU does not need padding. For
compatibility with 23-byte-MTU phones the writer MAY pad to a 4-byte boundary; the `LEN` field
governs parsing, so padding is always ignored. Readers MUST ignore trailing bytes after `LEN`.

**Scanner (O(n) per byte, O(1) memory).** A ring buffer tracks whether a plausible `SOF` is
pending. On `0xA5` the parser latches; on `0x5A` it proceeds, else it re-latches. `TYPE` and
`LEN` are sanity-checked before the buffer is reserved, so a corrupt length can never cause a
large allocation. This is the difference between a 60-byte static buffer (used) and a
`malloc(65535)` on a corrupt length (a classic ESP32 crash).

**Compute why this matters.** A 512 KB PSRAM heap with a 24 B telemetry record at 50 Hz is
1.2 KB/s of garbage. Over a 6-hour drive that is 26 MB of allocation churn through the ESP32's
slow heap path, which is exactly what causes the classic "works for 20 minutes, then crashes"
failure. A single static SPSC ring buffer per channel removes the allocator from the hot path
entirely.

---

## 4. Message Types

`→` = phone → device, `←` = device → phone.

| Code | Name | Dir | Chars | Payload |
| --- | --- | --- | --- | --- |
| `0x01` | `HELLO` | → | RX | JSON |
| `0x02` | `PING` | → | RX | JSON |
| `0x04` | `CONFIG` | → | RX | JSON |
| `0x05` | `CALIBRATE` | → | RX | JSON |
| `0x06` | `COMMAND` | → | RX | JSON |
| `0x07` | `ACK` | ← | CTRL | JSON |
| `0x08` | `ERROR` | ← | CTRL | JSON |
| `0x09` | `EVENT` | ← | CTRL | JSON |
| `0x10` | `TELEMETRY` | ← | TX | **binary 24 B** |
| `0x11` | `STATUS` | ← | CTRL | JSON |
| `0x12` | `HELLO_ACK` | ← | CTRL | JSON |
| `0x13` | `CALIB_LOG` | ← | CTRL | JSON array |
| `0x14` | `DIAG` | ← | CTRL | JSON |
| `0x20` | `DEVICE_INFO` | ← | INFO | JSON |

**EVENT envelope.** Every user-relevant event uses type `0x09` with a discriminator, so the app
has exactly one event parser to keep in sync with the firmware rather than a dozen.

---

## 5. Telemetry Record (binary, 24 bytes, TYPE `0x10`)

| Off | Type | Field | Unit | Range |
| --- | --- | --- | --- | --- |
| 0 | `u32` | `t_ms` | ms since boot | wraps at ~49.7 days |
| 4 | `i16` | `acc_x` | milli-g | ±32000 |
| 6 | `i16` | `acc_y` | milli-g | ±32000 |
| 8 | `i16` | `acc_z` | milli-g | ±32000 |
| 10 | `i16` | `gyr_x` | 0.1 °/s | ±32000 |
| 12 | `i16` | `gyr_y` | 0.1 °/s | ±32000 |
| 14 | `i16` | `gyr_z` | 0.1 °/s | ±32000 |
| 16 | `u16` | `mag_mg` | milli-g | 0…65535 |
| 18 | `u16` | `peak_mg` | milli-g | 0…65535 |
| 20 | `u8` | `flags` | bitfield | §5.1 |
| 21 | `u8` | `impact_score` | 0…100 | detector confidence |
| 22 | `u8` | `battery_pct` | 0…100 | 255 = unknown |
| 23 | `u8` | `state` | enum | §5.2 |

### 5.1 `flags` bitfield

| Bit | Mask | Meaning |
| --- | --- | --- |
| 0 | `0x01` | `SW420` — SW-420 vibration output currently HIGH |
| 1 | `0x02` | `BUZZER` — buzzer active |
| 2 | `0x04` | `LED_RED` |
| 3 | `0x08` | `LED_GREEN` |
| 4 | `0x10` | `OLED_OK` — display responding |
| 5 | `0x20` | `SOS_BUTTON` — button currently pressed |
| 6 | `0x40` | `ARMED` — detection loop enabled |
| 7 | `0x80` | `CHARGING` |

### 5.2 `state` enum

| Value | Name |
| --- | --- |
| 0 | `BOOT` |
| 1 | `IDLE` — armed, no event |
| 2 | `PENDING` — impact candidate, inside the cancel window |
| 3 | `ALARM` — confirmed, emergency dispatch in progress |
| 4 | `SOS` — manual SOS active |
| 5 | `MUTED` — buzzer suppressed (night mode) |
| 6 | `FAULT` — sensor fault / calibration required |

---

## 6. JSON Payloads

JSON is used for the low-rate control/identity/event plane. Rules: no comments, no trailing
commas, keys sorted for stable diffing, integers for anything that must round-trip exactly,
floats rounded to 7 decimal places for coordinates.

### 6.1 `HELLO` (phone → device, `0x01`)

```json
{
  "app": "smart-accident-alert",
  "appVersion": "1.0.0",
  "proto": 1,
  "capabilities": ["telemetry", "config", "calibrate", "command", "diag"],
  "deviceName": "My Car",
  "locale": "en-IN"
}
```

### 6.2 `HELLO_ACK` (device → phone, `0x12`)

```json
{
  "fwVersion": "1.0.0",
  "hw": "esp32-devkit-v1",
  "proto": 1,
  "chipId": "A1B2C3D4",
  "mac": "24:6F:28:A1:B2:C3:D4",
  "name": "SAAS-A1B2C3D4",
  "batteryMv": 4120,
  "batteryPct": 96,
  "charging": false,
  "uptimeMs": 123456,
  "mpu": { "present": true, "addr": "0x68", "whoAmI": 113 },
  "oled": { "present": true, "addr": "0x3C" },
  "sw420": true,
  "calibrated": true,
  "sensorRateHz": 50,
  "state": 1
}
```

`mpu.present`, `oled.present` and `sw420` are the **capability negotiation** mechanism: a user
who has not yet wired the OLED still gets a fully working app, because the app renders the
degraded state instead of erroring.

### 6.3 `DEVICE_INFO` (device → phone, `0x20`, INFO characteristic)

```json
{
  "name": "SAAS-A1B2C3D4",
  "model": "Smart Accident Alert Node v1",
  "hw": "esp32-devkit-v1",
  "fwVersion": "1.0.0",
  "fwBuild": 20260927,
  "serial": "A1B2C3D4E5F60718"
}
```

### 6.4 `CONFIG` (phone → device, `0x04`)

Partial update — **absent keys keep their current value**, which makes the app's settings screen
a fire-and-forget write with no read-modify-write race.

```json
{
  "accelThresholdMg": 3000,
  "gyroThresholdDps": 220,
  "vibrationRequired": true,
  "debounceMs": 60,
  "confirmWindowSec": 10,
  "minSpeedKmh": 5.0,
  "detectorGain": 1.0,
  "telemetryHz": 50,
  "buzzerEnabled": true,
  "ledEnabled": true,
  "muteUntil": 0,
  "autoArm": true
}
```

| Key | Unit | Default | Bounds accepted |
| --- | --- | --- | --- |
| `accelThresholdMg` | milli-g | `3000` | 1500 … 8000 |
| `gyroThresholdDps` | °/s | `220` | 80 … 800 |
| `vibrationRequired` | bool | `true` | — |
| `debounceMs` | ms | `60` | 20 … 500 |
| `confirmWindowSec` | s | `10` | 5 … 120 |
| `minSpeedKmh` | km/h | `5.0` | 0 … 60 |
| `detectorGain` | × | `1.0` | 0.5 … 3.0 |
| `telemetryHz` | Hz | `50` | 5 … 100 |
| `buzzerEnabled` | bool | `true` | — |
| `ledEnabled` | bool | `true` | — |
| `muteUntil` | unix s | `0` | `0` = never |
| `autoArm` | bool | `true` | — |

Out-of-range values are **clamped, not rejected**, and the clamped result is reported in
`STATUS` so the app can show the effective value. A settings slider that silently fails is
worse than one that clamps.

### 6.5 `STATUS` (device → phone, `0x11`)

```json
{
  "state": 2,
  "stateName": "PENDING",
  "sinceMs": 8123,
  "effectiveConfig": { "accelThresholdMg": 3000, "telemetryHz": 50, "...": "..." },
  "peakMagMg": 4820,
  "peakGyrDps": 391,
  "sw420": false,
  "sw420Hits": 3,
  "score": 72,
  "queueDepth": 4,
  "heapFree": 142336,
  "uptimeMs": 423119,
  "watchdogResets": 0,
  "loopOverageCount": 0
}
```

### 6.6 `EVENT` (device → phone, `0x09`)

One envelope, discriminator `type`:

```json
{
  "type": "ACCIDENT_DETECTED",
  "eventId": "8f3a1c22",
  "seq": 7,
  "t_ms": 423119,
  "uptimeMs": 423119,
  "score": 87,
  "impact": {
    "magG": 4.82,
    "peakAccMg": 4820,
    "peakGyrDps": 391,
    "gyrMagDps": 402.1,
    "sw420": true,
    "orientationChangeDeg": 63.4,
    "preImpactSpeedKmh": 48.3
  },
  "confirmWindowSec": 10,
  "canCancel": true
}
```

| `type` | Trigger | `canCancel` |
| --- | --- | --- |
| `ACCIDENT_DETECTED` | fused detector crossed threshold | `true` |
| `MANUAL_SOS` | physical button | `true` (until dispatch) |
| `ALERT_CANCELLED` | user / button cancelled | — |
| `ALERT_CONFIRMED` | countdown elapsed or user confirmed | — |
| `ALERT_SENT` | device ACK'd that dispatch started | — |
| `RESOLVED` | user marked resolved | — |
| `DEVICE_FAULT` | sensor fault / watchdog | — |

`eventId` is a 32-bit value derived from the chip's hardware MAC, so two devices never collide
and the app can de-duplicate a re-delivered event. This is what makes event retry safe.

### 6.7 `COMMAND` (phone → device, `0x06`)

| `op` | Effect |
| --- | --- |
| `CONFIRM` | cancel countdown, escalate to `ALARM` |
| `CANCEL` | cancel countdown, clear alarm, return to `IDLE` |
| `TEST` | run the detector against synthetic data (app's *Test Alert* button) |
| `ARM` / `DISARM` | toggle `flags.ARMED` |
| `MUTE` | suppress buzzer for `untilUnixS` |
| `FLASH_TEST` | blink LEDs for wiring verification |
| `SELFTEST` | full hardware self-test, replies with `DIAG` |
| `RESET_STATS` | clear peak/counters |

```json
{ "op": "CONFIRM", "eventId": "8f3a1c22" }
```

### 6.8 `CALIBRATE` (phone → device, `0x05`)

```json
{ "durationMs": 5000, "kind": "STATIC_BASELINE" }
```

Replies with `CALIB_LOG` (`0x13`) — an array of downsampled samples so the app can draw a live
calibration chart and the user can see the vehicle is genuinely still:

```json
{ "t_ms": 100, "acc_x": 12, "acc_y": -34, "acc_z": 1002, "gyr_x": 3, "gyr_y": -1, "gyr_z": 5, "sw420": false }
```

### 6.9 `DIAG` (device → phone, `0x14`)

```json
{
  "uptimeMs": 423119,
  "cpuLoadPct": 18,
  "loopHz": 50,
  "heapFree": 142336,
  "heapMin": 138204,
  "stackHighWater": 4096,
  "queueDepth": 4,
  "droppedFrames": 0,
  "crcErrors": 0,
  "bleClients": 1,
  "mpuI2cErrors": 0,
  "oledOk": true,
  "brownoutCount": 0,
  "watchdogResets": 0,
  "batteryMv": 4120,
  "rssi": -58
}
```

### 6.10 `ACK` / `ERROR`

```json
{ "of": 6, "seq": 7, "ofName": "COMMAND", "op": "CONFIRM" }
```

```json
{ "code": 3, "codeName": "BAD_STATE", "message": "cannot CONFIRM from state IDLE" }
```

| `code` | Name |
| --- | --- |
| 0 | `BAD_FRAME` — CRC or SOF failure |
| 1 | `UNSUPPORTED` — unknown type or version |
| 2 | `BAD_ARGS` — malformed JSON |
| 3 | `BAD_STATE` |
| 4 | `NOT_ARMED` |
| 5 | `BUSY` |
| 6 | `INTERNAL` |

---

## 7. State Machine

```
                 ┌────────┐
      reset ────►│  BOOT  │
                 └───┬────┘
                     │ sensors OK
                 ┌───▼────┐   DISARM     ┌────────┐
                 │  IDLE  │─────────────►│ MUTED  │
                 └──┬──┬──┘◄─────────────└────────┘
        fused trip  │  │  confirmWindowSec elapsed
                    │  └────────────────────────────┐
          ┌─────────▼─────────┐                    │
          │      PENDING      │  CANCEL / button    │
          └──┬──────────────┬─┘                    │
   CONFIRM  │              │ timeout               │
   or SOS   │              └────────────────────┐   │
      ┌─────▼─────┐   CANCEL                    │   │
      │   ALARM   │─────────┐                   │   │
      └──┬─────┬──┘         │                   │   │
   ALERT_SENT │  SELFTEST   │                   │   │
         │     │  fail      │                   │   │
         │  ┌──▼──┐         │                   │   │
         │  │FAULT│─────────┴───────────────────┴───┴──► IDLE
         │  └─────┘
      RESOLVED
         │
         └───────────────────────────────────────► IDLE
```

Legal transitions are enforced in one place (`StateMachine::dispatch`). Every illegal
combination is reachable from a *user* action — pressing the button during `PENDING` must
cancel, not crash — so the guard is exhaustive over `{event × state}`, a 7 × 7 table.

---

## 8. Event Reliability

BLE notifications are **not** reliable. The device therefore implements a stop-and-wait
sequencer for `CTRL` events only:

1. Send event with `seq = n`.
2. Start `T_retry = 750 ms` timer.
3. On `ACK{of:9, seq:n}` → clear timer, `n++`.
4. On timeout → retransmit, up to **3** attempts, doubling backoff (750 / 1500 / 3000 ms).
5. After 3 failures → flash the red LED and set `flags.QUEUED` internally, to be drained on the
   next successful connection.

`HELLO_ACK` uses `seq = 0` and is retried indefinitely (bounded to 5) because without it the app
cannot show device identity.

Because every event carries a stable `eventId` and the app's de-duplication set is
`(eventId, type)`, retransmission is **idempotent** and cannot produce a duplicate record in
Firestore — see `docs/05-app.md`.

---

## 9. Timing Budget (50 Hz configuration)

| Task | Core | Period | Budget | Typical |
| --- | --- | --- | --- | --- |
| `sensorTask` — I²C burst read MPU6050 | 1 | 20 ms | 8 ms | 1.4 ms |
| `detectTask` — filter + fuse + score | 1 | 20 ms | 1 ms | 0.05 ms |
| `bleTask` — telemetry pack + notify | 0 | 20 ms | 3 ms | 0.20 ms |
| `uiTask` — OLED redraw on change only | 0 | 100 ms | 5 ms | 1.1 ms |
| `sysTask` — heap/RSSI/battery, 1 s | 0 | 1000 ms | 2 ms | 0.15 ms |

**Why the split.** I²C is a blocking, spin-wait peripheral. Leaving it on core 0 would add up to
1.4 ms of jitter to the BLE stack, which owns the connection supervision timer — miss its
deadline and Android reports a disconnect. Pinning the sensor task to core 1 gives BLE a
guaranteed-core-0 with zero contention, at no cost, since the ESP32 is dual-core.

**Why the OLED is change-gated.** SSD1306 over I²C at 400 kHz costs ~11 ms to push a full 1 KB
frame buffer. At 10 Hz that is 11% of the I²C bus and visible flicker. The firmware hashes the
rendered text and only pushes when the hash changes, which in steady state is once per state
change — a few times per minute.

---

## 10. Reference Implementations

| Language | File |
| --- | --- |
| C++ (ESP32) | `firmware/SmartAccidentAlert/protocol.h`, `protocol.cpp` |
| Dart (Flutter) | `app/lib/data/protocol/ble_frame.dart`, `telemetry.dart` |
| JavaScript (simulator/tests) | `tools/protocol/codec.js` |

All three are cross-checked against `tools/protocol/test/protocol.test.mjs`, which runs the
golden vectors in `tools/protocol/golden.json` through all three implementations.
