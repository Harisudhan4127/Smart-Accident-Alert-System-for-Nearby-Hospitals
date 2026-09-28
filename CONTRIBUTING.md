# Contributing

## The one rule that matters

**The BLE protocol is frozen.** `docs/02-ble-protocol.md` is a contract shared
by three independent implementations, and `tools/protocol/golden.json` is the
thing that holds them together.

If you change the wire format, you must change **all** of:

| Implementation | File |
| --- | --- |
| C++ (firmware) | `firmware/SmartAccidentAlert/protocol.{h,cpp}` |
| Dart (app) | `app/lib/data/protocol/{ble_frame,messages,telemetry}.dart` |
| JavaScript (tools) | `tools/protocol/codec.js` |

…update the document, then:

```bash
make golden && make test-protocol && cd app && flutter test test/protocol/
```

A change that updates only one side is a bug that reproduces on exactly one
platform, in exactly one direction, and it will surface in a car rather than in
CI. The CI job in `docs/11-deployment.md` makes a stray `golden.json` diff a
build failure for exactly this reason.

## Setup

```bash
make doctor      # what is installed
make test        # the whole suite, no hardware needed
```

## Before you open a PR

```bash
make verify      # lint + every test. This is what CI runs.
```

Which is `dart analyze --fatal-warnings`, a format check, 138 protocol
assertions and 211 Dart assertions.

## Code style

Follow what is already in each file. The codebase has a deliberate voice —
comments explain **why**, not what — and a new file that is quietly worded will
read as a stranger in the codebase.

Specifics:

- **Dart** — `dart format`; `flutter_lints` plus the repo's
  `analysis_options.yaml`. No `dynamic`, no `print` (use `core/logger.dart`), no
  `!` on a nullable.
- **C++** — C++17, `constexpr` where possible, **no `String`**, no `malloc` and
  no `printf` in any task or hot path. Guard everything that can be absent (no
  OLED, no accelerometer, no SW-420) so the sketch still builds and runs on a bare
  ESP32.
- **Never leave a field at zero as a placeholder for a sensor you do not
  have.** This is the rule the MPU6050 → ADXL345 change turned on: an earlier
  revision allocated gyro accumulators it never wrote, and `CALIB_LOG` duly
  emitted `"gyr_x": 0` on every row. A zero in a telemetry field is not an
  absence — it is a reading, and a plausible-looking one. Delete the field, bump
  the protocol version, and let the reader see that it is gone.
- **Comments earn their place.** A comment that restates the code is noise. One
  that explains why a threshold is 3 g, or why a buffer is a ring rather than a
  list, is the most useful line in the file.

## Things that will be rejected

| | Why |
| --- | --- |
| A protocol change touching one codec | See the rule above |
| A hand-edited `golden.json` | It is generated. Run `make golden`. |
| A hand-edited `backend/seed/hospitals.json` | It is generated. Run `make seed`. |
| An exception crossing a layer boundary | Everything fallible returns `Result<T>`. |
| A `print` or `Serial.println` in a hot path | Costs milliseconds, and on the firmware it costs real-time jitter. |
| Widgets that read a 50 Hz stream directly | Use `TelemetrySampler`; see [08](docs/08-android-app-architecture.md#handling-50-hz-without-melting). |
| A hospital search that does not use `HospitalIndex` | It is O(N) per query and runs during a countdown. |
| A new dependency | Justify it in the PR. Hand-written immutable classes are the house style; `build_runner` is deliberately absent (see the note at the top of `pubspec.yaml`). |
| Bumping `pubspec.lock` to a version the CI Dart cannot resolve | Run `python3 app/tool/pin_dependencies.py app/pubspec.yaml`. |

## Commit messages

```
<area>: <what changed, in the imperative>

<why it changed, and what it fixes>
```

Areas: `protocol`, `firmware`, `app`, `backend`, `tools`, `docs`.

```
firmware: clamp the acceleration threshold to 16 g

config.h allowed values the detector divides by, so a slider at the top
of its range produced a NaN score and silenced the alarm entirely.
Bounds now match the ADXL345's configured full scale and
docs/02-ble-protocol.md §6.4.
```

## Adding a test

- **Protocol change** → `make golden`, then run both suites.
- **Detector change** → add a scenario to `FakeBleTransport` and assert the
  outcome, *including* the pothole case that must **not** alert.
- **Index change** → the brute-force comparison catches a regression on its
  own. Do not weaken it.
- **Repository change** → test the *ordering*, not just the return value. The
  outbox's value is that the local write happens first and unconditionally; a
  test that only checks the result would still pass if that were removed.

## Reporting a bug

Useful bug reports include:

- the node's serial output at 115200 (`make monitor`);
- the app's Settings → **Diagnostics** screen, which shows the node's live
  `DIAG` counters (CRC errors, dropped frames, free heap, I²C errors,
  brownouts, watchdog resets);
- what you expected and what happened;
- whether it reproduces with `flutter run --dart-define=DEMO=true`.

The `DIAG` counters answer most hardware questions directly. Include them.

## Safety

This project touches road safety. Two things follow:

1. **A detection threshold change is a safety change.** It needs a road test
   ([10 — Testing](docs/10-testing.md#on-road-acceptance-tests)), not a unit
   test alone.
2. **Do not weaken a user-facing warning** to make a test pass. The app names
   its limitations — no GPS fix, poor accuracy, offline, a missing emergency
   contact — because someone relying on it during a real emergency needs to
   know what is degraded. Removing one of those notices to tidy a UI is a
   regression.
