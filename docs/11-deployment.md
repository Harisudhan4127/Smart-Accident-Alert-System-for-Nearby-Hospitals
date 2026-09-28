# 11 — Building and deploying

Exact commands for every path. If a target here does not match your machine,
that is a bug in this document.

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [The firmware](#the-firmware)
- [The app](#the-app)
- [The backend](#the-backend)
- [Release builds](#release-builds)
- [Versioning](#versioning)
- [CI](#ci)

---

## Prerequisites

| Tool | Version | Needed for | Install |
| --- | --- | --- | --- |
| `arduino-cli` | 2.x | Firmware | `curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \| sh` |
| ESP32 board package | — | Firmware | `arduino-cli core install esp32:esp32` |
| Flutter | ≥ 3.24 | App | https://docs.flutter.dev/get-started/install |
| Node.js | ≥ 18 | Protocol tools, seed data | https://nodejs.org |
| Firebase CLI | latest | Backend | `npm i -g firebase-tools` |

Check what you have:

```bash
make doctor
```

```
Toolchain
  ok      node           v22.22.1
  ok      flutter        3.35.1
  ok      arduino-cli    0.35.3
  ok      java           openjdk 21.0.12.1

Optional
  missing platformio
```

---

## Quick start

```bash
# 1. The app, with no hardware at all.
cd app && flutter pub get && flutter run --dart-define=DEMO=true

# 2. The protocol suite (no SDK needed, ~4 s).
make test-protocol

# 3. The app's tests.
make test-app
```

Step 1 is the fastest way to see the whole product. The simulator produces real
protocol frames, so the alert flow, the countdown, the hospital search and the
offline outbox are all genuinely exercised.

---

## The firmware

### Arduino IDE (the primary path)

1. Install the **ESP32 Boards** package via Boards Manager.
2. Install these libraries via Library Manager:

   | Library | Needed for |
   | --- | --- |
   | **NimBLE-Arduino** 1.4.x | The BLE stack |
   | **Adafruit ADXL345** | The accelerometer |
   | **Adafruit SSD1306** + **Adafruit GFX Library** + **Adafruit BusIO** | The OLED |
   | **Adafruit Unified Sensor** | A dependency of the above |

   > NimBLE rather than the built-in Bluedroid: smaller, and materially better
   > on power — which matters for a node that runs off a power bank for a whole
   > drive.

3. Open `firmware/SmartAccidentAlert/SmartAccidentAlert.ino` and **Upload**.

### arduino-cli (scriptable — what `make` uses)

```bash
arduino-cli core update-index
arduino-cli core install esp32:esp32

make firmware                       # compile only
make firmware-upload PORT=/dev/ttyUSB0
make monitor                        # 115200 baud
```

On Windows use `COM3`; on macOS `/dev/cu.usbserial-*`.

Expected on success:

```
Sketch uses 666276 bytes (50%) of program storage space.
Global variables use 53044 bytes (16%) of dynamic memory.
```

**Zero warnings** is the bar. Warnings on embedded code are usually real bugs
waiting for the right optimisation level.

### PlatformIO (alternative)

```bash
make firmware-pio        # or: pio run -d firmware
pio run -d firmware -t upload
```

`platformio.ini` is maintained, but **`make firmware` (arduino-cli) is the
verified path** — the PlatformIO build has not been executed in CI.

### Toggling the self-test

Hold **BOOT** while powering on. The firmware runs a full hardware self-test
(ADXL345 identity, OLED presence, SW-420 state) and prints the result to the
serial monitor before starting normal operation.

### Tuning

Everything adjustable is in `firmware/SmartAccidentAlert/config.h`:

| Constant | Meaning |
| --- | --- |
| Pin map | `PIN_SDA`, `PIN_SCL`, `PIN_SW420`, `PIN_BUZZER`, `PIN_SOS`, … |
| `kAccelThresholdMg` | Impact threshold (default 3000) |
| `kConfirmWindowSec` | Cancel window (default 10) |
| `kSensorRateHz` | Sample rate (default 50) |
| `kRefractoryMs` | Lockout after a trigger |
| Detector weights | The scoring terms in `detector.cpp` |

**These are unvalidated defaults.** See
[06 — Accident detection](06-accident-detection.md#tuning-procedure) before
trusting them.

---

## The app

```bash
make pub                       # flutter pub get
make app                       # run on the attached device/emulator
make app-demo                  # run with the simulated node
make format                    # dart format
make lint-app                  # analyze + format check
```

### Firebase configuration (optional)

The app **runs without it** — `main()` logs a warning and continues, because a
safety app that refuses to start without a cloud project is worse than one that
works offline.

To enable the cloud:

1. `firebase init firestore functions` in the repo root.
2. Firebase console → Project settings → your app's package
   (`dev.saas.smart_accident_alert`).
3. Place the files:
   - `app/android/app/google-services.json`
   - `app/ios/Runner/GoogleService-Info.plist`

   Both are gitignored. They are project identifiers, not secrets, but an
   open-source repo should not silently inherit one project's config.

### Platform permissions

Already declared. See [09 — Security](09-security-and-privacy.md#permissions)
for what each one is for and why.

### Seed the hospital dataset

```bash
make seed          # node backend/seed/generate.mjs → 320 hospitals
```

The bundled asset the app reads is `app/assets/data/hospitals.json`. Copy the
generated file there, or symlink it, so the app works with no network.

---

## The backend

```bash
make seed                                   # the dataset
make backend-emu                            # Firestore emulator + functions
make backend-deploy                         # rules, indexes, functions
```

`make backend-emu` starts the emulator with **this project's** rules loaded, so
a rule change is visible immediately without deploying.

Deploy order matters: **rules and indexes before functions.** A function that
writes a document the rules reject will fail at runtime, not at deploy.

---

## Release builds

### Android

```bash
make app-build-apk                          # app/build/app/outputs/flutter-apk/
```

Produces a ~60 MB universal APK containing `arm64-v8a`, `armeabi-v7a` and
`x86_64`. For distribution, build per-ABI instead — a real phone only needs one:

```bash
cd app
flutter build apk --release --split-per-abi   # ~20 MB each
flutter build appbundle --release             # what Play actually wants
```

### Three build requirements that are not obvious

Each of these was a real failure during the build, and each has a comment in the
file that enforces it. They are listed here because the error messages point
somewhere unhelpful.

**1. `cupertino_icons` must be a dependency.** Nothing in `lib/` references
`CupertinoIcons`, but the release build's icon tree-shaker still expects the
font and fails with:

```
Expected to find fonts for (packages/cupertino_icons/CupertinoIcons, MaterialIcons)
```

It is the default `flutter create` dependency for exactly this reason.

**2. Core library desugaring must be enabled** in
`android/app/build.gradle.kts`:

```kotlin
compileOptions {
    isCoreLibraryDesugaringEnabled = true
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
```

`flutter_local_notifications` uses `java.time` for alarm scheduling, and the
failure surfaces as an AAR-metadata error naming the plugin rather than the
missing flag:

```
Dependency ':flutter_local_notifications' requires core library desugaring to be enabled
```

Without it the alternative is raising `minSdk` to 26 to get `java.time` natively.

**3. Do not chase the Gradle / AGP / Kotlin "support will soon be dropped"
warnings.** The build passes with Gradle 8.14, AGP 8.11.1 and Kotlin 2.2.20 —
the versions this Flutter SDK generates and is tested against. Upgrading to the
versions the warning suggests (Gradle 9.1, AGP 9.0.1, Kotlin 2.3.20) **does not
build**, because AGP 9 turns on `android.newDsl` by default and retires both the
`android { }` and `kotlinOptions { }` blocks:

```
'fun Project.android(...)' is deprecated ... will be removed in AGP 10.0
'fun BaseAppModuleExtension.kotlinOptions(...)' is deprecated
```

Those warnings are about a *future* Flutter release. Move the versions when
the SDK templates do.

**4. An unused dependency can dictate your SDK level.** `permission_handler` was
declared "for the permission flow" but never imported; `geolocator` requests its
own permissions. Its Android implementation compiles against **SDK 37** and uses
the AGP 9 Kotlin DSL, so merely depending on it forced `compileSdk = 37` and
broke the release build. It has been removed, and the current graph's highest
requirement is the SDK 36 default. If a plugin ever demands a higher
`compileSdk`, check whether the app actually uses it before raising the level.


Signing (not in the repo — `key.properties` and `*.jks` are gitignored):

```bash
keytool -genkey -v -keystore ~/saas-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias saas
```

Then `app/android/key.properties`:

```properties
storePassword=...
keyPassword=...
keyAlias=saas
storeFile=/absolute/path/to/saas-release.jks
```

### iOS

Requires macOS with Xcode.

```bash
make app-build-ios                          # no codesign, for a device test
cd app/ios && pod install
open Runner.xcworkspace                      # set the signing team
```

Nothing here has been run on physical iOS hardware — see
[10 — Testing](10-testing.md#what-is-not-tested). Treat the iOS BLE and
notification paths as unverified.

---

## Versioning

| Thing | Where | Rule |
| --- | --- | --- |
| App version | `app/pubspec.yaml` `version:` | SemVer. `1.0.0+1` = version, build number. |
| Protocol version | `docs/02-ble-protocol.md` §3, `kProtocolVersion` in **all three** codecs | **Frozen.** Changing it is a breaking change requiring all three implementations and new golden vectors. |
| Firmware version | `config.h`, reported in `HELLO_ACK.fwVersion` | SemVer |
| Seed dataset | `backend/seed/hospitals.json` `$comment` | Regenerate; never hand-edit |

**The protocol version is the compatibility contract.** A node speaking a
version this build does not know is marked `DeviceLinkState.incompatible`, and
the app says "update the node" rather than showing an indefinite spinner. See
[13 — Troubleshooting](13-troubleshooting.md).

---

## CI

`make verify` is what CI runs: `lint` + `test`. It needs no hardware and no
credentials.

```yaml
# Minimal working GitHub Actions job.
name: verify
on: [push, pull_request]

jobs:
  protocol:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: make test-protocol      # 138 assertions, ~4 s

  app:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable, cache: true }
      - run: cd app && flutter pub get
      - run: make lint-app
      - run: make test-app          # 211 assertions

  # A golden.json that changed without a protocol-doc change is a red flag.
  protocol-frozen:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: make golden
      - run: git diff --exit-code tools/protocol/golden.json
```

That last job is the one worth having. It is what makes "someone changed the
protocol and only updated one codec" a build failure.

**Not in CI:** the firmware build (needs the ESP32 toolchain and ~700 MB of
board support), and anything requiring Firebase credentials.

---

## Troubleshooting the build

| Symptom | Cause | Fix |
| --- | --- | --- |
| `A5 A5 5A` / `Wrong bootloader` when flashing | Wrong board selected | Boards Manager → ESP32 Dev Module |
| `Could not find a compatible version` | A dependency pin needs a newer Dart than installed | `python3 app/tool/pin_dependencies.py app/pubspec.yaml` |
| BLE connects, no telemetry | MTU refused, or the node crashed | `make monitor`; check `DIAG` in Settings |
| `flutter test` passes locally, fails in CI | A test depends on the CWD | The suite walks up to find the seed file; keep it that way |
| `git diff` shows `golden.json` changed | A protocol change, or non-deterministic generation | Generation is deterministic; a diff means a real change. Update the doc and all three codecs. |

---

**Previous:** [10 — Testing](10-testing.md) · **Next:** [12 — API reference](12-api-reference.md)
