# Documentation

Documentation for the **Smart Accident Alert System for Nearby Hospitals** — an
ESP32 + Flutter system that detects a possible vehicle collision, resolves the
driver's location, finds hospitals that can take an emergency, and alerts a
human inside a window the driver can still use for a false alarm.

Every document here is written against the code in this repository. Where the
code and a plan disagree, the code is described and the disagreement is named.

---

## Read this first

This is a **prototype**. It is not a certified emergency-response system, and
`PROJECT_PLAN.md` §27 is not a disclaimer to skim past:

- Sensor-based detection produces false positives, and some real accidents
  produce no detection at all. **The detection thresholds in
  `config.h` are unvalidated defaults** — they have never seen real crash data.
- The phone's GPS may be unavailable or wrong, and Bluetooth may drop at exactly
  the wrong moment. An event raised while the link is down is **lost**: BLE has
  no store-and-forward.
- **A hospital appearing in the nearby list does not mean that hospital was told
  anything.** Nothing here pages a hospital, sends it an SMS, or accepts a
  patient. It is a directory lookup, and the backend says so in every response
  payload. See §16 and §27 of the plan.
- Emergency services require separate official integration this project does
  not have.

---

## Index

| # | Document | What it covers |
| --- | --- | --- |
| 01 | [System architecture](01-system-architecture.md) | The three tiers, data paths, the two independent state machines, and what happens when a link drops |
| 02 | [BLE protocol](02-ble-protocol.md) | **The wire contract.** Frozen, and the authoritative document for the protocol |
| 03 | [Hardware and wiring](03-hardware-and-wiring.md) | Pin map, power budget, wiring tables, and the mismatch between `config.h` and `firmware/README.md` |
| 04 | [Firestore schema](04-firestore-schema.md) | Every collection, field, type and range, and why each rule exists |
| 05 | [Hospital search](05-hospital-search.md) | The spatial grid index, the haversine pass, ranking, and the 320-row seed dataset |
| 06 | [Accident detection](06-accident-detection.md) | The fused scoring, the thresholds, and the road tests §24 requires before trusting any of it |
| 07 | [Memory and power](07-memory-and-power.md) | Task stacks, the RAM budget, the sleep policy, and which parts are actually reachable |
| 08 | [App architecture](08-android-app-architecture.md) | Layering, the offline outbox, 50 Hz handling, the hospital index, and the provider reference |
| 09 | [Security and privacy](09-security-and-privacy.md) | Threat model, what the rules can and cannot do, PII handling, and the BLE weakness |
| 10 | [Testing](10-testing.md) | The suites, how to run them, and the cases nobody has run yet |
| 11 | [Deployment](11-deployment.md) | Flashing the node, running the app, deploying the backend, and CI |
| 12 | [API reference](12-api-reference.md) | The repository and datasource APIs, the Firestore schema, and the Cloud Functions |
| 13 | [Troubleshooting](13-troubleshooting.md) | Symptoms → cause → fix, ordered by how often each actually happens |
| 14 | [Permissions](14-permissions.md) | Every permission the app can request, why it needs it, and the exact moment it asks |

### Reading order, by audience

| If you are… | Read |
| --- | --- |
| Assembling the demo | [01](01-system-architecture.md) → [03](03-hardware-and-wiring.md) → the [README quick start](../README.md#quick-start) |
| Reviewing the code | [01](01-system-architecture.md) → [02](02-ble-protocol.md) → [06](06-accident-detection.md) |
| Extending it | [02](02-ble-protocol.md) (the contract) → [08](08-android-app-architecture.md) → [12](12-api-reference.md) |
| Debugging at 2 a.m. | [13](13-troubleshooting.md) → [07](07-memory-and-power.md) → the app's Settings → Diagnostics screen |

---

## Where the code is

| Path | Contents |
| --- | --- |
| `firmware/SmartAccidentAlert/` | ESP32 firmware: `SmartAccidentAlert.ino` plus focused C++ modules |
| `app/lib/` | Flutter application (`core`, `domain`, `data`, `features`, `widgets`) |
| `app/test/` | 211 Dart assertions, incl. protocol conformance |
| `backend/` | Firestore rules, indexes, Cloud Functions, seed data |
| `tools/protocol/` | The reference JS codec, the golden vectors, and 138 Node assertions |

---

## Status of each tier

Stated plainly, because a reader should not have to infer this from a directory
listing.

| Tier | State |
| --- | --- |
| **Firmware** | Written and **compiles cleanly** under the Arduino CLI path: *50% flash, 16% RAM, zero warnings*. Not executed on hardware in this repository. The sleep policy is written but unreachable — see [07](07-memory-and-power.md). |
| **Protocol** | **Frozen and verified.** 138 Node assertions + 211 Dart assertions across three independent implementations, all agreeing byte-for-byte. |
| **App** | **Implemented**: all 9 screens, the data layer, the offline outbox, the hospital index. `flutter analyze` reports **0 errors, 0 warnings**. |
| **Backend** | Complete and deployable. Rules are **untested** — the single highest-value remaining gap. |
| **iOS** | **Unverified.** No macOS machine was available. The BLE and notification paths genuinely differ from Android's. |
| **Detection thresholds** | **Unvalidated.** Plausible defaults that have never seen real crash data. |

### Verified numbers

Reproduce with `make test-protocol`, `make test-app`, `make firmware`.

| Claim | Result |
| --- | --- |
| Protocol conformance | **138 pass / 0 fail** |
| Dart unit + widget | **211 pass / 0 fail** |
| Static analysis | **0 errors, 0 warnings** (383 style infos) |
| Firmware build | **50% flash, 16% RAM, 0 warnings** |
| Hospital index | Exact match with a brute-force O(N) scan across **76 query/radius combinations** |
| Hospital query | **~160 µs** per 25 km search over 320 records |

---

## Known inconsistencies

Found by reading the code against itself. Each is written up where it belongs.

### Fixed during this build

| Where | What | Severity |
| --- | --- | --- |
| `tools/protocol/codec.js` | **D1** — `push([A5, A5 5A])` looped forever; the `sof1` state did not consume a repeated `0xA5` | High — a freeze on duplicate SOF |
| `tools/protocol/codec.js` | **D2** — a frame split across two notifications was silently discarded | High — every split frame lost |
| `tools/protocol/codec.js` | **D3** — the payload started 2 bytes early, at the length field | High — no JSON payload decodable |
| `tools/protocol/golden.json` | Two vector expectations contradicted the frames the generator produced | Medium — a trap for anyone reading the manifest as truth |
| `app/…/hospital_index.dart` | `searchScore` is *higher-is-better* but was filtered as a distance | High — returned the *least* useful hospitals |
| `app/…/hospital_index.dart` | Exact score ties broke on bucket order, so the same query returned a different result each run | Medium — untestable, and it could reorder the recommendation the user acts on |
| `app/…/hospital_search_worker.dart` | The serialiser wrote four string *lengths* and no string *bytes*, and used UTF-16 lengths for UTF-8 | High — the isolate worker read garbage |
| `firmware/…/SmartAccidentAlert.ino` | `CONFIG` parsed an integer key `gain` in thousandths, while §6.4 defines `detectorGain` as a multiplier in 0.5–3.0 — so the app's gain slider could never be applied | **High** — a documented setting with no effect, silently |
| `firmware/…/SmartAccidentAlert.ino` | `CALIB_LOG` was never sent: `streamCalibLog()` had no caller, so a calibration was acknowledged and then reported nothing | Medium — a documented message that never happened |
| `firmware/…/SmartAccidentAlert.ino` | `wdtTask` stored its handle into `g_handle[kWdCount - 1]`, which is `kWdSys`, clobbering the sysTask handle | Low — a stale handle in the diagnostics display |
| `firmware/README.md` | Claimed active-low SW-420 and LEDs; `config.h` sets both active-**high`. Also said 200 Hz where the firmware samples at 50 Hz | Medium — following the README gives an inverted SW-420 input |

### Open

| Where | What | Severity |
| --- | --- | --- |
| `firmware/…/power.h` | `serviceLightSleep()` and `armDeepSleep()` have no callers | Medium — the documented sleep policy is unreachable, so the node runs at full power |
| `docs/02-ble-protocol.md` | The `CALIB_LOG` example is a bare sample object; the golden vector and the Dart parser use `{"samples":[…]}` | Low |
| `backend/firestore.rules` | No test suite. A rule that is wrong is a security bug that looks like a working feature | **High** — the top remaining gap |

---

## Contributing

[CONTRIBUTING.md](../CONTRIBUTING.md). The short version: **the protocol is
frozen**, and changing it means updating all three codec implementations and
regenerating the golden vectors — a CI job makes a stray `golden.json` diff a
build failure for exactly that reason.
