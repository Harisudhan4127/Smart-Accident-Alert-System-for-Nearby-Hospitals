# Smart Accident Alert System for Nearby Hospitals

Detect a vehicle collision with an **ESP32 + MPU6050 + SW-420** node, resolve the
driver's location from the paired phone, identify the nearest hospitals that can
actually take an emergency, and alert a human — all inside a cancel window the
driver can still use for a false alarm.

> ### ⚠ This is a prototype, not a certified emergency system
>
> It can produce false alarms, it can miss real crashes, and it depends on the
> phone being present, powered, connected and online. It has **not** been
> validated for production safety use. See [PROJECT_PLAN.md §27](PROJECT_PLAN.md)
> for the full, honest list of limitations. Do not rely on it as your only
> safety system.

---

## Contents

- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)
- [The BLE protocol](#the-ble-protocol)
- [How accident detection works](#how-accident-detection-works)
- [Performance](#performance)
- [Testing](#testing)
- [Documentation](#documentation)
- [Safety and privacy](#safety-and-privacy)
- [Status and limitations](#status-and-limitations)
- [Licence](#licence)

---

## How it works

```
   VEHICLE
      │
      ▼
 ┌─────────────────┐   MPU6050 (accel + gyro)      ┌──────────────┐
 │      ESP32      │   SW-420   (vibration)    ───►│  Detector    │
 │                 │                                  │  (fused      │
 │  FreeRTOS:      │◄─────────────────────────────────│   scoring)   │
 │   • sensor 50Hz │                                  └──────┬───────┘
 │   • BLE         │                                         │ score
 │   • OLED 10Hz   │   ┌─────────┐   ┌──────────┐             │
 └────────┬────────┘   │ Buzzer  │   │   OLED   │◄────────────┘
          │            └─────────┘   └──────────┘
          │  BLE  (§ docs/02-ble-protocol.md)
          ▼
 ┌─────────────────┐
 │   Flutter app   │   Android + iOS, one codebase
 │                 │
 │  ┌───────────┐  │   ★ 10-second cancel window — the false-alarm guard
 │  │  ALERT    │  │
 │  └───────────┘  │
 └────┬─────┬──────┘
      │     │
      │     └──────────►  Google Maps  (location)
      │
      ├─► GPS fix ────►  nearest hospitals (spatial index)
      │
      └─► ┌─────────┐
         │  SQLITE │  ← written FIRST, always. Offline-safe.
         │ outbox  │
         └────┬────┘
              │
              ▼  (when a network exists)
        ┌───────────┐        ┌──────────────┐
        │ Firestore │───────►│ SMS + call   │  ← the part that reaches a human
        └───────────┘        └──────────────┘
```

The three decisions that matter most:

1. **The local write happens first, unconditionally.** An accident detected in a
   tunnel, an underground car park or a rural area with no signal is written to
   SQLite *before* any network call. It is the only copy anyone will have, and it
   exists within milliseconds. The cloud upload is retried later from an outbox
   with exponential backoff.
2. **The user gets a cancel window.** A magnitude-only detector false-alarms on
   potholes, kerbs and dropped phones. This one scores several independent
   signals and gives the driver 10 seconds to call it a false alarm before
   anyone is contacted.
3. **Findings are ranked by usefulness, not by distance.** A 3 km emergency
   department outranks an 800 m clinic. A purely geometric sort routes a
   responder past the place that can actually help.

---

## What you need

### Hardware — the node

| # | Component | Qty | ~Cost | Purpose |
|---|---|---:|---:|---|
| 1 | ESP32 DevKit (30-pin) | 1 | ₹400 | Main controller, BLE |
| 2 | MPU6050 IMU | 1 | ₹120 | Acceleration + rotation |
| 3 | SW-420 vibration switch | 1 | ₹60 | Impact corroboration |
| 4 | SSD1306 0.96" OLED (I²C) | 1 | ₹250 | On-device status |
| 5 | Active buzzer + NPN transistor | 1 | ₹40 | Local audible warning |
| 6 | Emergency push button | 1 | ₹30 | Manual SOS |
| 7 | LEDs (red, green) + 220 Ω | 2 | ₹10 | Status indication |
| 8 | Resistors, breadboard, jumpers | 1 set | ₹200 | Prototype wiring |
| 9 | USB cable / power bank | 1 | — | Power |
| | | | **≈ ₹1 150** | |

Wiring is in [`firmware/SmartAccidentAlert/config.h`](firmware/SmartAccident-Alert-System-for-Nearby-Hospitals/firmware/SmartAccidentAlert/config.h)
and documented in [`docs/03-hardware-and-wiring.md`](docs/03-hardware-and-wiring.md).

### Software

| Component | Version | Notes |
|---|---|---|
| Arduino IDE **or** `arduino-cli` | 2.x | Any ESP32 board package works |
| NimBLE-Arduino | 1.4.x | Lighter and lower-power than Bluedroid |
| Adafruit MPU6050 / SSD1306 / GFX / BusIO | latest | |
| Flutter | ≥ 3.24 | One codebase → **Android and iOS** |
| Node.js | ≥ 18 | Protocol tooling and tests only |
| Firebase CLI *(optional)* | latest | Cloud backend; the app works without it |

Run `make doctor` to see what is present on your machine.

---

## Quick start

### 0. See it work with no hardware at all

The app ships with a **complete in-memory ESP32 simulator**. It emits real
protocol frames, runs the real state machine, and synthesises plausible driving
telemetry — including a pothole that must *not* trigger an alert, and a crash
that must.

```bash
cd app
flutter pub get
flutter run --dart-define=DEMO=true
```

Then tap **Test alert**. This is the fastest way to see the whole product.

### 1. Flash the node

```bash
# Arduino IDE: open firmware/SmartAccidentAlert/SmartAccidentAlert.ino and upload.
# Or, from the command line:
make firmware-upload PORT=/dev/ttyUSB0

# Then watch it:
make monitor          # 115200 baud
```

The OLED should show `ACTIVE`, and the serial monitor prints a `HELLO_ACK` once
the phone connects.

### 2. Run the app

```bash
make pub
make app
```

Pair the node (it is filtered by service UUID, so only compatible nodes appear),
add one emergency contact, and you are set.

### 3. Optional — the cloud backend

The app is **fully functional offline**. The backend is only needed for
cross-device history and a shared hospital directory.

```bash
node backend/seed/generate.mjs        # 320-hospital dataset for Bengaluru
firebase emulators:start --only firestore
```

Then drop your own `google-services.json` / `GoogleService-Info.plist` into
`app/android/app/` and `app/ios/Runner/`. Without them the app logs a warning
and runs locally — it does not refuse to start.

---

## Repository layout

```
.
├── Makefile                  # every dev task (make help)
├── PROJECT_PLAN.md           # the original specification
│
├── firmware/SmartAccidentAlert/
│   ├── SmartAccidentAlert.ino   # ← the whole sketch; open this in Arduino IDE
│   ├── config.h                 # pins, thresholds, timing — tune here
│   ├── detector.{h,cpp}         # the fused scoring algorithm
│   ├── sensors.{h,cpp}          # MPU6050 + SW-420 drivers
│   ├── comm.{h,cpp}             # NimBLE GATT server + event sequencing
│   ├── state_machine.{h,cpp}    # O(1) state dispatch
│   └── ui.{h,cpp}               # OLED rendering, change-gated
│
├── app/lib/
│   ├── core/                 # theme, routing, DI, Result<T>
│   ├── domain/entities/      # pure Dart, no Flutter, no plugins
│   ├── data/
│   │   ├── protocol/         # the wire codec (frozen contract)
│   │   ├── ble/              # transport + a full ESP32 simulator
│   │   ├── datasources/      # GPS, Firestore, SQLite, SMS, notifications
│   │   ├── hospital/         # spatial index + isolate worker
│   │   └── repositories/     # orchestration, incl. the offline outbox
│   ├── features/             # one folder per screen
│   └── widgets/ui_kit.dart   # the shared component library
│
├── backend/
│   ├── firestore.rules       # security rules, with rationale
│   ├── firestore.indexes.json
│   ├── functions/            # dispatch + nearbyHospitals
│   └── seed/                 # generated hospital dataset
│
├── tools/protocol/
│   ├── codec.js              # reference implementation of the wire format
│   ├── golden.json           # conformance vectors
│   └── test/                 # 138 assertions
│
└── docs/                     # see the documentation index
```

---

## The BLE wire protocol

The firmware, the app and the test tooling all speak **one** protocol, frozen in
[`docs/02-ble-protocol.md`](docs/02-ble-protocol.md) and pinned by
`tools/protocol/golden.json`.

It is **framed binary** for the high-rate path and **JSON** for the low-rate
path, because they have opposite requirements:

| Traffic | Rate | Format | Why |
|---|---|---|---|
| Telemetry | 50 Hz | **24-byte binary record** | 7.5× less air-time than JSON, zero parsing, no allocator |
| Events & control | rare | **UTF-8 JSON** | Readable in nRF Connect when a field goes wrong |

At 50 Hz that is **1.2 KB/s**, versus roughly 9 KB/s for the obvious
"JSON per sample" design — and the difference is radio time, which on a vehicle
is battery and, more importantly, a saturated link that drops the *events*.

Three characteristics, not one, so congestion control can be honest: `CTRL`
carries events and is retried until acknowledged; `TX` carries telemetry and is
safe to drop; `INFO` is read once.

**Any protocol change must update all three codec implementations and
regenerate the golden vectors** — see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## How accident detection works

A single accelerometer threshold is the wrong algorithm. It false-alarms on
potholes and misses gentle low-speed impacts.

The detector instead **scores several independent signals** and sums normalised
terms (`firmware/SmartAccidentAlert/detector.cpp`):

| Signal | What it catches | What suppresses |
|---|---|---|
| **Free-fall** (`\|a\| < 0.3 g`) | The single strongest crash indicator | Never occurs for a pothole or a bump |
| **Gyro magnitude** | Rollover and spin | Smooth cornering stays low |
| **Attitude change** | Post-crash reorientation | A pothole returns to the same attitude |
| **Jerk** (`d\|a\|/dt`) | Suddenness, not size | Slow potholes have low jerk |
| **SW-420** | Physical impact corroboration | Requires the independent sensor to agree |
| **Z-score vs. rolling baseline** | Adapts to rough roads | A smooth highway uses a stricter bar than a pothole street |
| **Dead-reckoned speed** | Movement at the time | A device dropped while parked is ignored |

The rolling **z-score** is the important one: the detector maintains a 1-second
Welford baseline, so it measures how unusual an impact is *for this vehicle on
this road* rather than against one fixed number.

Thresholds in `config.h` are **unvalidated defaults**. They need a road test
before anyone trusts them — see
[`docs/06-accident-detection.md`](docs/06-accident-detection.md).

---

## Performance

This is a system that must work while a car is moving, on a phone that is also
running navigation, for hours. The engineering log is in
[`docs/07-memory-and-power.md`](docs/07-memory-and-power.md); the headline:

| Where | Problem | Technique | Effect |
|---|---|---|---|
| **Firmware** | 50 Hz sensor loop on a 240 MHz MCU | FreeRTOS tasks **pinned per core**; I²C on core 1, BLE on core 0 | Zero added jitter on the BLE supervision timer |
| | Heap exhaustion after hours | Lock-free SPSC ring buffers, **zero allocation** in the hot path | No allocator on the 50 Hz path at all |
| | Detector cost | Integer milli-g math, single-pass Welford | No `float` in the sample loop |
| | OLED flicker + bus contention | Content-hash change gating | Full-screen push only on change, not 10×/s |
| | SW-420 chatter | GPIO interrupt + debounce, not polling | Removes a whole 50 Hz scan |
| **App** | 50 Hz telemetry → 50 Hz rebuilds | Coalescing sampler at 4 Hz, keyed on **rounded display values** | Near-zero rebuilds at rest |
| | Hospital search O(N) per query | **Spatial grid index**: O(1) cell lookup, O(k) candidates | Measured ~160 µs/query over 320 records |
| | Search janking the UI | Runs on a **worker isolate**, index transferred once | UI thread never blocks |
| | Backpressure on telemetry | Drop samples, never grow a queue | O(1) memory, no OOM |
| **Protocol** | 9 KB/s of JSON telemetry | 24-byte binary record | 1.2 KB/s |

Verified measurements (Dart SDK, 320-record dataset, after JIT warm-up):

```
HospitalIndex query      ~160 µs   (~6 200 queries/sec)
Index build              O(N), single pass, pre-sized buckets
Frame reassembly         O(1) memory, linear in stream length
10 000-frame scan        linear, no quadratic re-chunking
```

Reproduce the last two with `make test-protocol`; the first with
`cd app && flutter test test/data/hospital_index_test.dart`.

---

## Testing

```bash
make test              # everything
make test-protocol     # wire-format conformance (no hardware needed)
make test-app          # Flutter unit + widget tests
make verify            # what CI runs
```

| Suite | Count | Covers |
|---|---|---|
| `tools/protocol/test/` | 138 | CRC check values, every golden vector, every **split point** of every frame, corrupt lengths, bad CRCs, 10 k-frame throughput |
| `app/test/protocol/` | conformance | The Dart codec against the same golden vectors — a protocol change that breaks one side fails CI |
| `app/test/data/` | index | The spatial index against a **brute-force O(N) reference** over real seed coordinates |

The hospital-index suite is the one worth knowing about. A fast but wrong
proximity index is worse than a slow correct one — it would send someone to a
hospital 40 km away. So every index result is cross-checked against a naive full
scan, at 76 query/radius combinations including the poles and the antimeridian.
That comparison has already caught three real bugs.

Run the whole app with **no hardware** via `flutter run --dart-define=DEMO=true`,
or drive the simulator from a test with `FakeBleTransport`.

---

## Documentation

[`docs/README.md`](docs/README.md) is the index. The reading order depends on who
you are:

| If you are… | Read |
|---|---|
| Assembling the demo | [01-system-architecture](docs/01-system-architecture.md) → [03-hardware-and-wiring](docs/03-hardware-and-wiring.md) → [quick start](#quick-start) |
| Reviewing the code | [01](docs/01-system-architecture.md) → [02-ble-protocol](docs/02-ble-protocol.md) → [06-accident-detection](docs/06-accident-detection.md) |
| Extending it | [02-ble-protocol](docs/02-ble-protocol.md) (the contract) → [04-firestore-schema](docs/04-firestore-schema.md) → [05-hospital-search](docs/05-hospital-search.md) |
| Debugging at 2 a.m. | [07-memory-and-power](docs/07-memory-and-power.md) → the DIAG counters in the app's Settings screen |

---

## Safety and privacy

Handled in [`docs/04-firestore-schema.md`](docs/04-firestore-schema.md) and
`backend/firestore.rules`. The short version:

- **Anonymous auth by default.** A real, rules-enforceable identity that collects
  no PII. Upgrade to an account without changing the document layout.
- **Owner-only access.** `users` and `accidents` are owner-read/owner-write.
  Contact phone numbers are never publicly listable.
- **Location is treated as sensitive.** A responder role is granted access to
  *one specific accident*, not to a user's history.
- **Server timestamps.** A device with a wrong clock cannot forge arrival order.
- **Only the permissions the app needs**, and every one is explained in the app
  when it is requested.
- The `nonoftprofit` BLE licence in `ble_service.dart` is correct for this
  prototype. A commercial deployment must change it and buy a licence.

---

## Status and limitations

**Complete and tested:** the wire protocol (138 conformance assertions), the
firmware build (0 warnings, 50% flash, 16% RAM), the hospital index (verified
against brute force), the offline outbox, the app's data layer, and all nine
screens.

**Not validated:** the detection thresholds. They are plausible defaults that
have never seen real crash data. A road test is required.

**Known constraints:**

- The phone must be present, connected, powered and online. Without a phone
  there is no GPS and no network.
- Bluetooth disconnects when the car leaves range; the app reconnects with
  exponential backoff and jitter, but events raised while disconnected are lost.
- BLE notifications are not reliable; the protocol mitigates this with
  stop-and-wait retries and event de-duplication, but it is a mitigation, not a
  guarantee.
- GPS in a basement or a tunnel may be unusable. The app says so explicitly
  rather than sending a misleading pin.
- A hospital appearing in the results means it is **nearby** — not that it was
  ever notified, and not that it has agreed to respond. §16 and §27 of the plan
  are explicit about this, and the UI does not overclaim.

Full list: [PROJECT_PLAN.md §27](PROJECT_PLAN.md).

---

## Licence

[MIT](LICENSE). The FlutterBluePlus dependency uses its own licence, which
requires a commercial purchase for commercial use.
