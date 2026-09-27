# 10 — Testing

What is tested, what is not, and how to run it.

- [The three test layers](#the-three-test-layers)
- [What the suites actually verify](#what-the-suites-actually-verify)
- [Protocol conformance](#protocol-conformance)
- [The hospital index: verified against brute force](#the-hospital-index-verified-against-brute-force)
- [Running without hardware](#running-without-hardware)
- [Hardware-in-the-loop tests](#hardware-in-the-loop-tests)
- [On-road acceptance tests](#on-road-acceptance-tests)
- [False-alarm acceptance criteria](#false-alarm-acceptance-criteria)
- [What is NOT tested](#what-is-not-tested)

---

## The three test layers

| Layer | Runner | Count | Needs hardware? |
| --- | --- | --- | --- |
| Protocol conformance | `node --test` | 138 | no |
| Dart unit + conformance | `flutter test` | 211 | no |
| Hardware-in-the-loop | manual + `DIAG` | see below | **yes** |

```bash
make test              # layers 1 and 2
make test-protocol     # layer 1 alone (~4 s, no SDK needed)
make test-app          # layer 2 alone
make verify            # lint + both, what CI runs
make doctor            # what is installed on this machine
```

---

## What the suites actually verify

### `tools/protocol/test/protocol.test.mjs` — 138 assertions

| Area | Verified |
| --- | --- |
| CRC-16/CCITT-FALSE | Against the published check values (`"123456789"` → `0x29B1`, …) |
| Golden vectors | Every vector in `golden.json` round-trips byte-identically |
| **Every split point** | For all 11 vectors, the frame is reassembled correctly at **every** possible boundary between two `push()` calls |
| Byte-at-a-time | Delivering 1 byte per push still yields exactly one frame |
| Corrupt length | Must not reserve 64 KB, and must resync to the next real frame |
| Bad CRC | Counted, no frame emitted, hunting resumes one byte past the bad SOF |
| Leading noise | Counted and discarded, does not corrupt the following frame |
| SOF edge cases | `A5 A5 5A` terminates (child process, timeout-bounded) and a real frame after a false SOF is still found |
| Throughput | 10 000 frames through a 7-byte chunk size, asserting linear scaling |
| Manifest consistency | Re-encoding each recorded expectation reproduces its frame |

The split-point test is the important one. BLE notifications are chunked
arbitrarily and routinely split a frame in two, so "works when the whole frame
arrives at once" is not a property worth having.

Three real defects were found by this suite and fixed:

| | Defect | Consequence if shipped |
| --- | --- | --- |
| **D1** | `push([A5, A5, 5A])` looped forever — the `sof1` state did not consume a repeated `0xA5`, so the index never advanced | The app freezes the moment a duplicate SOF arrives on the link |
| **D2** | A frame split across two pushes was silently discarded | Every split frame lost — i.e. a real fraction of all events |
| **D3** | The decoded payload started 2 bytes early, at the length field | Every JSON payload undecodable; the app could not talk to the node at all |

D1 is why the test for it runs in a child process under a timeout: an infinite
loop inside an async test hangs the runner instead of failing it, so the only
trustworthy way to prove the loop is gone is to assert the process terminated.

### `app/test/` — 211 assertions

| Suite | Covers |
| --- | --- |
| `protocol/crc_test.dart` | CRC against published vectors, and parity with the JS reference |
| `protocol/frame_scanner_test.dart` | The Dart scanner against the same vectors — split frames, noise, bad CRC, corrupt length |
| `protocol/golden_conformance_test.dart` | Every message type in §4–§10 round-trips; manifest matches the wire |
| `protocol/telemetry_codec_test.dart` | The 24-byte record: clamping, saturation, `jsRound` parity with JavaScript's `Math.round` |
| `protocol/messages_test.dart` | HELLO, CONFIG, COMMAND, EVENT, STATUS, HELLO_ACK, CALIB_LOG, DIAG, ACK/ERROR, DEVICE_INFO — including the spec's own ambiguity in §6.8 |
| `domain/entities_test.dart` | The §18 state machine, accident/contact/hospital invariants |

The **Dart-vs-JS parity** is the point of having three implementations of one
protocol. A change that breaks one side fails CI instead of surfacing as an
intermittent field failure in a car.

---

## The hospital index: verified against brute force

`app/test/data/hospital_index_test.dart` is the most important test in the
repository, because a fast-but-wrong proximity index is *worse* than a slow
correct one: it would send someone to a hospital 40 km away.

Every index result is cross-checked against a naive O(N log N) full scan, on real
coordinates from `backend/seed/hospitals.json`, across:

- 15 origins taken from the dataset itself, plus Bengaluru's centre, **Sydney**
  (must return nothing), **the North Pole** (the longitude window must not
  collapse to one cell) and the **antimeridian**;
- radii of 1 km, 5 km, 25 km and 100 km;
- **76 query/radius combinations in total**, compared for exact set *and* order.

This is what caught three real bugs:

| Bug | Why it mattered |
| --- | --- |
| `searchScore` is **higher-is-better**, but the index filtered on it as if it were a distance | Every radius test failed; the result was the *least* useful hospitals |
| Exact score ties were broken by bucket iteration order | The same query could return a different order on two runs — untestable, and it could reorder the recommendation the user acts on |
| The serialiser wrote four string *lengths* and no string *bytes*, and used UTF-16 lengths for UTF-8 payloads | The isolate worker read garbage; a truncated blob failed confusingly instead of cleanly |

There is also a performance assertion: a 25 km query must complete in under
2 ms (generous for CI hardware). The point is to catch an accidental
O(N log N)-per-query regression, not to benchmark a phone.

---

## Running without hardware

The whole app — BLE framing, the detector path, the emergency flow, the outbox —
runs against `FakeBleTransport`:

```bash
cd app
flutter run --dart-define=DEMO=true     # tap "Test alert"
```

The scenarios are listed in
[08 — The App](08-android-app-architecture.md#running-without-hardware). The one
that matters most is `potholes`, which **must not** produce an alert: a simulator
that alarmed on every spike would certify a detector that has not been tested
against the most common false-alarm source there is.

---

## Hardware-in-the-loop tests

These need a flashed node. Turn on `SAAS_DBG` in the firmware, or read the
`DIAG` message from the app's Settings screen.

| # | Test | Expected |
| --- | --- | --- |
| 1 | Power on, no app connected | OLED shows `ACTIVE`; green LED on; `DIAG.loopHz` ≈ 50 |
| 2 | Pair the app | `HELLO_ACK` on the serial monitor within 2 s; app shows "Live" |
| 3 | Telemetry for 10 min | `DIAG.crcErrors` = 0, `droppedFrames` = 0, heap stable |
| 4 | Leave range, return | Reconnect within ~2 s (`DIAG` shows a fresh uptime; app shows "Live") |
| 5 | MPU6050 disconnected | `state` = `FAULT`; app shows a sensor fault, does not crash |
| 6 | OLED disconnected | Node still functions; app reports the capability as absent |
| 7 | SW-420 disconnected | Detection still works on accel+gyro alone |
| 8 | Press SOS | `MANUAL_SOS` on the node and on the app; countdown is skipped |
| 9 | `SELFTEST` | `DIAG` with heap, stack high-water and counters |
| 10 | Power-cycle the node | App reconnects; no event is replayed |

---

## On-road acceptance tests

The ones that decide whether the product works. **Do not skip these** — a
passing bench test and a device that false-alarms every 200 m are both
consistent with a "working" build.

| # | Procedure | Pass criterion |
| --- | --- | --- |
| 1 | 100 km of city driving, day | **0** false alerts |
| 2 | 100 km of highway, day | **0** false alerts |
| 3 | 50 km of deliberately bad road (potholes, speed bumps, unpaved) | **0** false alerts, or at worst one *cancellable* one |
| 4 | 20 km with the device repeatedly knocked (simulating a dropped phone mount) | **0** alerts; the speed gate should suppress it |
| 5 | Phone left on the seat, vehicle driven over kerbs by a passer-by | **0** alerts |
| 6 | Hard brake at 60 km/h, repeated | **0** alerts (a brake is ~0.5 g, well under threshold) |
| 7 | Emergency cornering at the limit, repeated | **0** alerts |
| 8 | Simulated impact (drop the node from 1 m onto concrete) | 1 alert, cancellable within the window |
| 9 | Roll the vehicle (test ramp or a slow tip) | 1 alert on the gyro/orientation terms |
| 10 | Actual collision, if it happens to be available | 1 alert within ~1 s |
| 11 | GPS denied, then a crash | Accident **recorded**, location absent, and the app says so |
| 12 | Airplane mode, then a crash | Accident **recorded locally**, uploaded when connectivity returns |
| 13 | Phone battery at 5 % | Warning shown; behaviour otherwise unchanged |
| 14 | Node powered off mid-drive | App shows "Node disconnected" — no crash, no false alert |

Tests 1–3 are the ones that decide whether the thresholds are usable at all.
Until they pass, the values in `config.h` are **unvalidated defaults** and
`docs/06-accident-detection.md`'s tuning procedure has not been followed.

---

## False-alarm acceptance criteria

The threshold is deliberately strict, because the cost is asymmetric:

- **A missed crash is fatal.** A user who learned the app "didn't always
  trigger" would not rely on it.
- **A false alarm is expensive but survivable** — an unwanted phone call, some
  embarrassment, and a user who starts ignoring the thing.

So the detector is tuned for **precision**, and the 10-second cancel window is
the second line of defence. The measured false-alarm rate must be **zero over
100 km**, not "one per 100 km".

Record every false alarm with its telemetry (the app's Settings → Diagnostics
and the node's serial output). A false alarm is the most valuable data point
the system produces, because it is a labelled negative.

---

## What is NOT tested

Stated plainly, because a test suite's silence is easily mistaken for coverage:

| Not tested | Why | What would close it |
| --- | --- | --- |
| **The detection thresholds on real crash data** | No crash data exists yet | The on-road tests above, then re-tuning `config.h` |
| BLE range in a real metal vehicle | Needs a car | Test 4 above |
| Real SMS delivery | The app opens the *composer*; it does not silently send (§20) | Manual: fire a test alert and confirm the body |
| Push notification delivery while the app is killed by the OS | Needs a real device and aggressive battery settings | Manual: enable battery optimisation off, background the app, fire an alert |
| Firestore rules against a malicious client | Rules are unit-reasoned, not integration-tested | The Emulator Suite: a script that attempts each denied read/write |
| iOS specific behaviour | No macOS machine was available | Run the app on a real iPhone; the BLE and notification paths differ |
| Cloud Functions | Not deployed | `firebase emulators:start --only functions` |

The last two matter. **Nothing in this repository has run on physical iOS
hardware**, and the BLE and notification code paths on iOS are genuinely
different from Android's. Treat the iOS side as unverified.

---

## Adding a test

- **Protocol change?** Update `docs/02-ble-protocol.md`, *all three* codec
  implementations, then `make golden` and commit `golden.json`. The conformance
  suites will tell you what you broke.
- **Detector change?** Add a scenario to `FakeBleTransport`, then assert the
  outcome — including the pothole case that must *not* alert.
- **Index change?** The brute-force comparison will catch a regression
  automatically. Do not weaken it.
- **Repository change?** Test the ordering, not just the return value. The
  outbox's value is that the local write happens first and unconditionally;
  a test that only checks the result would pass even if that were removed.
