# Smart Accident Alert — firmware

ESP32 firmware for the accident-alert node. Detects an impact with an ADXL345
accelerometer, corroborates it with speed and free-fall, and alerts the nearest
hospital over BLE to the phone paired with it.

**There is no gyroscope in this build.** The motion sensor is a three-axis
accelerometer, and no rotation rate is measured or inferred anywhere in this
firmware. Rotation shows up only as a change in the direction of gravity. See
`docs/06-accident-detection.md` for what that costs.

## Seeing it work

The node draws its **live sensor data on the OLED** at all times: five rows of
label-above-value, then a rolling |a| trace.

```
NORMAL / DEMO
ADXL345  NORM
X 0.00 Y 0.94 Z 0.32
|a| 1.00g SW0 S0
C3.0g up12s q0 c1
[------------ sparkline ------------]
```

| Row | What it is |
| --- | --- |
| `ADXL345  NORM` | which part is on the bus, and the current mode |
| `X … Y … Z` | the three **raw**, unfiltered axes in g |
| `|a| … SW … S` | unfiltered magnitude, the SW-420 level, the live detector score 0…100 |
| `C3.0g up… q… c…` | the trace's vertical ceiling, uptime, BLE queue depth, connected centrals |
| the bars | the last 2.56 s of \|a\|, oldest at the left |

**The axes are unfiltered on purpose.** The 5 Hz section that feeds the gravity
estimate reports about 69% of a real 40 ms impact peak, so a crash seen through
it looks like a mild bump. This is the "what is the part actually reading" view.

**`C3.0g` is the trace's ceiling**, and it is on screen because the trace is
auto-scaled. An axis whose units you cannot see is a decoration, not a
measurement. It grows to the largest magnitude seen this session and never
shrinks, so the bars do not twitch while you watch, and 20 g is a hard cap so one
absurd reading cannot squash the rest of the trace flat.

**A still node reads about 1 g on one axis**, whichever one the mount puts gravity
on. Near 0.1 g means the part is not powered — see DIAGNOSTIC below, which exists
for exactly that.

## The three run modes

The mode is the first line of the display and is printed on every serial line,
because a demo and a real crash are the same event on the wire.

| Mode | What it does | Raises events? |
| --- | --- | --- |
| `NORMAL` | the real detector, nothing simulated | yes — the only mode that does |
| `DEMO` | **shake the node** and it raises a real `ACCIDENT_DETECTED` through the real state machine and the real BLE stack | yes, simulated |
| `DIAGNOSTIC` | per-sensor health check with an on-screen verdict | **never** |

**`NORMAL` is the default on every boot, and it stays that way.** A node that
remembered DEMO across a power cycle could leave a car raising simulated alerts.
There is no persistence: the mode is reset on every power cycle, on purpose.

**`DEMO` needs both sensors to agree.** |a| at or above 1.0 g *and* the SW-420
asserted, on the same sample, for 3 consecutive samples (60 ms). An earlier
revision let the accelerometer fire on its own with the switch as a shortcut,
which meant a demo could pass on a node with the vibration switch disconnected —
exercising half the hardware and proving nothing about the other half. The SW-420
is the only input with a failure mode the accelerometer does not have.

`DEMO` and `DIAGNOSTIC` both disarm the production detector. A bench node must
not page anyone from a road joint, and a health check that raises accidents is
not a health check.

**`DIAGNOSTIC` answers three questions with three two-character verdicts:**

```
ADXL345  DIAG
X 0.00 Y 0.94 Z 0.32
|a| 1.00g SW0 S0
ADXLOK SW?? BUSOK
tap the SW-420
[------------ sparkline ------------]
```

| Verdict | Meaning |
| --- | --- |
| `OK` | observed behaving correctly |
| `??` | present and answering, but **not yet proven** |
| `XX` | present and provably wrong |
| `--` | no evidence yet — right after entering the mode |

The middle row of the display says what to *do* about a `??`, because "SW ??" on
its own is a dead end:

| Shown | What it means and what to do |
| --- | --- |
| `tap the SW-420` | the switch has never asserted. It is wired, it is debounced, it has simply never been asked. Tap it. |
| `shake the node` | gravity seen, but \|a\| has never moved. Pick the node up. |
| `fix accel wiring` | no gravity for 3 s. Check `VS` (3.3 V) and GND. |
| `all sensors OK` | everything proven working. |

Two of these are the cases that cost the most bench time, and **neither is
visible to a firmware that only counts I2C errors**:

* **A part that answers I2C but is not powered.** Some ADXL345 breakouts hold the
  bus up from the regulator's standby rail with `VS` unconnected, so `DEVID` reads
  `0xE5` and the part looks present. The data registers read nothing, and |a| sits
  at 0.1 g. The only honest evidence is a gravity test.
* **A bus that has gone open.** Every read "succeeds" and the value never
  changes, so a bus-error count stays at zero. What gives it away is that |a| is
  *constant*: a real accelerometer on a desk jitters by tens of milli-g. Note
  that a constant 1 g is also a valid gravity reading, which is why the
  accelerometer verdict checks gravity and motion separately.

## Reading the serial monitor

```bash
make monitor      # 115200 baud
```

Everything the node knows is printed here, and this is the authoritative view —
the OLED is a summary and the serial is the record.

### The boot banner

Printed once, always, on every boot:

```
=== SAAS node boot ===
  accelerometer : found  addr=0x53  DEVID=0xE5  range=+/-16g  odr=100Hz
  oled          : found
  run mode      : NORMAL  (always NORMAL on boot; click SOS to toggle)
  boot calib    : 1200ms
  button        : click = mode, hold 800ms = SOS
  live |a| and raw axes print below; OLED shows the same
```

| Field | Read it for |
| --- | --- |
| `accelerometer` | `found` or `NOT FOUND`. **`DEVID=0xE5` is necessary but not sufficient** — see DIAGNOSTIC. |
| `addr` | `0x53` normal, `0x1D` if SDO is tied high. The firmware handles both. |
| `run mode` | always `NORMAL` on boot. If you expected otherwise, the node rebooted. |
| `boot calib` | the node refuses to arm until this completes, so the vehicle must be still for 1.2 s after power-up. |

If no accelerometer is found, two extra lines appear telling you what to check —
`VS` (3.3 V), GND, and SDA/SCL on 21/22.

### The repeating data line

Once every 200 ms (5 lines/s):

```
NORMAL IDLE   t=   12s X 0.003 Y 0.937 Z-0.344 |a|= 1.000g peak= 1.000g sw=0 sc=  0 n=598
```

| Field | Meaning | What a healthy value looks like |
| --- | --- | --- |
| mode | `NORMAL`, `DEMO` or `DIAG` | — |
| state | `BOOT` `IDLE` `PENDING` `ALARM` `SOS` `MUTED` `FAULT` | `IDLE`. **`BOOT` for more than ~2 s is a fault** — see below. |
| `t=` | seconds since boot | rising steadily |
| `X Y Z` | raw axes in g, **unfiltered** | one of them ≈ **1.0**; the others near 0 |
| `\|a\|` | raw magnitude in g | **≈ 1.00 when still.** 0.1 means the part is not powered. |
| `peak` | largest \|a\| this session | rises when you shake it, then holds |
| `sw` | SW-420 level, 0 or 1 | toggles when you tap the module |
| `sc` | fused score 0…100 | 0 at rest. Trip is at 70. |
| `n` | samples since boot | ≈ **50 per second**. If it stops, the sensor task is wedged. |

Two checks worth memorising, because together they tell you whether the node is
alive, whether the sensor is *powered*, and whether it is *responding*:

* `n` climbing at 50/s and `t=` climbing at 1/s → the node is running.
* `|a|` ≈ **1.00** → the accelerometer is powered and mounted. This is the single
  most useful number in the whole output.

### The DEMO line

```
  DEMO  shake 0/3  hits=0  cooldown=0ms  (needs |a|>=1000mg AND SW-420)
```

| Field | Meaning |
| --- | --- |
| `shake n/3` | samples counted toward the 60 ms hold window. **It only advances while both sensors agree**, so if it sits at 0 you can tell which one is not contributing. |
| `hits` | simulated accidents raised this session |
| `cooldown` | time left before the next trigger is allowed (5 s) |

### The DIAGNOSTIC lines

```
  DIAG  ADXL345 OK       SW-420 UNPROVEN  BUS OK
        gravity=yes motion=no |a|min=980mg max=1020mg  swEdges=0  readFails=0/0
```

| Field | Meaning |
| --- | --- |
| `gravity` | has \|a\| been inside 500…3000 mg? A still node must say `yes`. |
| `motion` | has \|a\| moved by more than 150 mg? A real sensor on a desk says `yes`. A `no` with `gravity=yes` is a frozen bus. |
| `\|a\|min`/`max` | the range seen. **min ≈ max over minutes means the value is frozen.** |
| `swEdges` | raw SW-420 pin edges, counted *before* debounce. Chatter here is a wiring fault the detector's debounce would hide. |
| `readFails` | consecutive / worst-ever failed reads. Non-zero means the bus is unhealthy. |

### The fault line

Replaces the data line entirely when the sensor is not usable, so a node that is
not reading its sensor cannot be mistaken for one idling quietly:

```
NORMAL FAULT   t=   12s *** SENSOR FAULT *** read failing addr=0x53 id=0xE5 failRuns=31
        |a|=0.117g  (a still node must read ~1.00g; near 0 means no gravity, i.e. the part is not really powered)
```

`DIAG.watchdogResets` in the `DIAG` JSON counts reboots and survives a soft reset,
so it is the number to read if the node seems to restart.

## The parameters

Everything tunable lives in `config.h`, and nothing is tunable at runtime except
through the protocol (below).

### Pin map and polarity

| Constant | Default | Note |
| --- | --- | --- |
| `kPinI2cSda` / `kPinI2cScl` | 21 / 22 | shared by the ADXL345 and the SSD1306 |
| `kPinSw420` | 27 | **active HIGH** — the module pulls the line *high* when it vibrates |
| `kPinBuzzer` | 25 | **active LOW**, through an NPN |
| `kPinSosButton` | 26 | **active LOW** to GND, internal pull-up |
| `kPinLedGreen` / `kPinLedRed` | 32 / 33 | **active HIGH** |
| `kPinBatteryAdc` | 34 | input-only, correct for a divider |
| `kSw420ActiveHigh`, `kBuzzerActiveLow`, … | — | **flipping any of these inverts that input.** The SW-420 is the most dangerous: inverted, the vibration term is silently dead. |

### Sensor

| Constant | Default | Note |
| --- | --- | --- |
| `kAdxlAddr` / `kAdxlAddrAlt` | `0x53` / `0x1D` | probed in that order |
| `kAdxlRange16G` | ±16 g | **changing this changes the scale** — `adxlMilliTenthsPerLsb()` derives the sensitivity from it, so they cannot disagree |
| `kAdxlOdr` | 100 Hz | 2× the 50 Hz loop, so the part is the anti-aliaser |
| `kSensorHz` | 50 Hz | **every window, debounce and filter coefficient is computed for 50 Hz.** A 200 Hz build is not a build, it is a different algorithm. |
| `kSensorFaultFailRuns` | 25 | consecutive failed reads = 0.5 s before `FAULT` |

### Detector

Weights sum to exactly 1000 (`static_assert` enforces it), so the trip threshold
of 70 means the same thing after any retune.

The three `kCfg…Default` constants are the **power-on defaults**, used until a
`CONFIG` arrives or an NVS save overrides them. The detector itself reads the
live `DetectorCfg`; changing the default changes what a freshly-flashed node
starts with, not what a configured one does.

| Constant | Default | Raise it to… |
| --- | --- | --- |
| `kCfgAccelThresholdMgDefault` | 3000 | tolerate a rougher road / car |
| `kFreeFallMg` / `kFreeFallMs` | 300 mg / 60 ms | — rarely needs changing; the strongest term |
| `kCfgMinSpeedMilliKmhDefault` | 5000 | ignore low-speed impacts (a parked car being nudged) |
| `kDetectorRefractoryMs` | 5000 | allow a second, separate impact sooner |
| `kCfgConfirmWindowSecDefault` | 10 | more time to cancel a false alarm |
| `kTripScore` / `kReleaseScore` | 70 / 45 | hysteresis; keep the gap or the score chatters |
| detector weights | see `config.h` `wt::` | — the redistribution notes are there |

### Run mode and demonstration

| Constant | Default | Note |
| --- | --- | --- |
| `kRunModeDefault` | `NORMAL` | **do not change this.** A node that boots in DEMO raises simulated alerts about a car that is fine. |
| `kDemoShakeMagMg` | 1000 | DEMO needs \|a\| above this **and** the SW-420 |
| `kDemoShakeHoldSamples` | 3 | 60 ms at 50 Hz |
| `kDemoCooldownMs` | 5000 | without it, continuous shaking fires 50 events/s |
| `kSosHoldMs` | 800 | below this a press is a mode click, not an SOS |
| `kRedrawMs` / `kDemoRedrawMs` | 200 / 100 | the OLED is the most expensive thing the node does; a full-frame push is ~25 ms |
| `kSerialDataMs` | 200 | 5 lines/s |
| `kDiagGravityMinMg` / `MaxMg` | 500 / 3000 | the plausible-\|a\| window for DIAGNOSTIC |
| `kDiagMotionMg` | 150 | change in \|a\| that counts as "responding" |
| `kDiagNoGravityMs` | 3000 | how long gravity may be missing before `XX` |

### Runtime, over BLE

`COMMAND` (see `docs/02-ble-protocol.md` §6.7 for the wire format):

| `op` | Effect |
| --- | --- |
| `MODE` | `{"op":"MODE","mode":"NORMAL"\|"DEMO"\|"DIAG"}`, or `{"op":"MODE"}` to query. Replies with the mode **actually in force**. |
| `CALIBRATE` | re-baseline gravity. **Requires the vehicle to be still.** |
| `ARM` / `DISARM` | toggle detection |
| `CONFIRM` / `CANCEL` | the alert window |
| `MUTE` | `{"op":"MUTE","untilUnixS":…}`; with no expiry, one hour |
| `FLASH_TEST` | drive all outputs for 1.5 s, for wiring checks |
| `SELFTEST` | replies with a full `DIAG` document |
| `RESET_STATS` | clear the peak, the counters and the trace |
| `TEST` | drive the detector with synthetic data (the app's Test Alert) |

`CONFIG` changes thresholds at runtime: `accelThresholdMg` (1500…16000),
`vibrationRequired`, `debounceMs` (20…500), `confirmWindowSec` (5…120),
`minSpeedKmh` (0…60), `detectorGain` (0.5…3.0), `telemetryHz` (5…100),
`buzzerEnabled`, `ledEnabled`, `muteUntil`, `autoArm`. Out-of-range values are
**clamped, not rejected**, and the effective values come back in the `STATUS`
reply — so read them rather than assuming yours took.

## The one button

| Gesture | Meaning |
| --- | --- |
| **click** (released under 800 ms) | next mode: `NORMAL` → `DEMO` → `DIAGNOSTIC` → `NORMAL`, with a full-screen animated banner |
| **hold** (800 ms or more) | manual **SOS** — the same path as the app's alert button |

A three-way cycle rather than a two-way toggle, because the three modes answer
three different questions and someone holding a node down a cable wants the
diagnostic one as much as the demo one. It lands back on `NORMAL` after three
clicks, so a node left on a bench does not need a fourth click to be safe.

The switch is announced by a banner that owns the whole panel for 1.2 s: a border
closing in, the mode name at 2x, and a full inversion on the last frame. A corner
label that scrolls past is not enough when a demo and a real crash are the same
event on the wire — the answer to "was that real?" has to be on screen at the
moment it is asked.

A hold is latched while the button is still down and the release is then
suppressed, so one gesture can never do both. The 800 ms is deliberate: SOS on
any press would mean a single accidental touch raises an emergency call about a
parked car, and mode-switching is a thing you do on purpose and can watch the
screen to confirm.

`DEMO` is never entered on its own. A node always boots in `NORMAL`, because a
demo event is byte-for-byte identical to a real one and nobody is going to spot
the difference on a 64-pixel screen. See
[`docs/02-ble-protocol.md` §6.7](../docs/02-ble-protocol.md) for the wire form.

The trace is fed from the **sensor** task at the full 50 Hz, not at the display
rate. An impact peak is about 40 ms wide; sampled at the 10 Hz redraw rate it
would be caught once in five and drawn as a small bump for what was a 5 g event.

The wire contract is frozen and lives outside this directory:

- `docs/02-ble-protocol.md` — GATT layout, frame format, JSON documents, state
  machine, event delivery.
- `tools/protocol/golden.json` — the exact vectors `protocol.cpp` and `json.cpp`
  are tested against.
- `tools/protocol/codec.js` — the reference codec the app side is written against.

Nothing in this directory may change those documents. Where the firmware needed
a decision the protocol did not make, the choice is recorded in the source next
to the code that depends on it.

## Layout

| File | Role |
| --- | --- |
| `config.h` | Pins, task priorities and stacks, detector thresholds and weights, range limits for every CONFIG field. The only place a tunable number lives. |
| `protocol.h/.cpp` | Frame header, CRC-16/CCITT-FALSE, telemetry packing, `FrameScanner` reassembly. |
| `json.h/.cpp` | Allocation-free JSON writer and parser, plus one builder per document in the contract. |
| `detector.h/.cpp` | Fixed-point fusion and the latching detector. No allocation, no I/O, no clock of its own — it is driven entirely by `(Sample, nowMs)`. |
| `sensors.h/.cpp` | I²C acquisition, filtering, gravity tracking, speed integration, calibration, SW-420 latch. |
| `state_machine.h/.cpp` | The 7×7 trigger/state table. Every state change in the firmware goes through it. |
| `event_queue.h/.cpp` | Stop-and-wait delivery with `750/1500/3000 ms` backoff. Pure logic, no BLE. |
| `comm.h/.cpp` | The only file that knows NimBLE exists. Adapts NimBLE-Arduino 1.x and 2.x. |
| `ui.h/.cpp` | SSD1306, LEDs, buzzer, SOS button. |
| `power.h/.cpp` | Task watchdog, brownout policy, deep-sleep entry. |
| `SmartAccidentAlert.ino` | Task wiring, request handling, and the glue between the modules above. |

The split is deliberate: everything above `comm.h` compiles and is tested on a
host with `g++ -std=c++17`, which is how the 520 host checks run. Only `comm.cpp`
and the parts of `power.cpp`/`ui.cpp` that touch hardware are excluded.

## Signal path

The design point is that **impact and gravity want opposite filters**.

- **Impact is a transient.** A 5 g crash lasts 10–30 ms. Any low-pass filter
  long enough to reject road vibration attenuates the peak the detector is
  supposed to measure, so the raw accelerometer vector goes straight to the
  detector.
- **Gravity and speed want the opposite.** They are slow and need a clean
  reference, so they run through a 4-tap moving average and a 5 Hz biquad.
  Speed is differentiated from that, not from the raw signal, or a single impact
  would integrate into a huge phantom velocity.

There is no third path. The ADXL345 has three axes and all three go down both
of these.

The biquad state is Q15 and is **not** shifted each sample. Only the output
expression shifts. This is the classic Q15 filter bug: shifting the state as well
as the output divides the state by 32768 every sample, and the filter collapses
within a few hundred milliseconds. End-to-end, a 5900 mg input reaches the
detector as a 5891 mg peak.

Free-fall is latched: the detector only sees a "low g" bit after 60 ms of
sustained low-g, so a single-sample dip cannot fake it.

## Detection

Fusion is fixed-point, and the weights are in `config.h`. The z-score against a
frozen baseline, the raw magnitude, the jerk magnitude, the free-fall bit, the
SW-420 contact, the gravity-vector rotation and the speed floor are combined
into a single `0–100` score. Two thresholds matter: a candidate floor, and a higher trip
threshold that also has to be held for `debounceMs` so a pothole cannot latch the
node. A release knee below the candidate floor provides hysteresis.

A confirmed alert arms a **5 s refractory window**. One impact spans dozens of
samples and the ring-down still reads above the candidate floor, so without the
window a single crash is reported several times.

## Building

Arduino CLI, which is what the build is verified against:

```sh
cd firmware/SmartAccidentAlert && arduino-cli compile -b esp32:esp32:esp32 .
arduino-cli upload  -b esp32:esp32:esp32 -p /dev/ttyUSB0 .
```

Verified with `arduino-cli 1.1.1`, core `esp32:esp32 3.3.11`, NimBLE-Arduino
2.5.1, Adafruit SSD1306 2.5.17 and Adafruit GFX 1.12.6. The build is at 50% of
flash and 16% of RAM, and compiles without warnings.

PlatformIO is also configured (`SmartAccidentAlert/platformio.ini`) for CI, but PlatformIO was not
available in this environment, so that path is unverified.

> If the link fails with `undefined reference to pinMode` / `digitalWrite` and
> `invalid string offset` against `core.a`, the Arduino build cache is corrupt.
> `rm -rf ~/.cache/arduino` and build again. Nothing in the source is at fault.

## Hardware

| Signal | GPIO | Notes |
| --- | --- | --- |
| I²C SDA / SCL | 21 / 22 | The ADXL345 (`0x53`, falling back to `0x1D`) and the SSD1306 (`0x3C`) share the bus. Three devices will not fit at the default addresses. |
| SW-420 | 27 | **Active HIGH** (`kSw420ActiveHigh`): the module pulls the line *high* when it vibrates. Debounced 25 ms, interrupt on both edges. Wiring it as active-low inverts the signal and disables the vibration term. |
| Buzzer | 25 | **Active LOW** (`kBuzzerActiveLow`) through an NPN — the transistor conducts to sound it. |
| SOS button | 26 | **Active LOW** (`kSosButtonActiveLow`) to GND, internal pull-up. |
| Green / red LED | 32 / 33 | **Active HIGH** (`kLedActiveHigh`) — the resistor goes to GND. |
| Battery ADC | 34 | Input-only pin, correct for a divider. |
| Charge status | 35 | TP4056 `CHRG`, open-drain, optional. |

The ADXL345 is assumed to be mounted so that the vehicle's forward axis is `+X`.
The speed integrator depends on that; the accelerometer axes are otherwise
symmetric.

## Host tests

`demomode.cpp` carries no Arduino dependency, so the DEMO trigger's timing
logic — the 60 ms hold window, the 5 s cooldown, the sensor-fault guard, the
"a mode change must not inherit a half-primed shake" rule — is unit-tested on the
host rather than by shaking a node:

```
make test-firmware-host
```

Those paths are not reachable by hand in a useful way. A detached sensor and a
bus that froze mid-shake are the two cases most worth testing and the two you
cannot produce on a desk on purpose.

**`firmware/test/` is outside the sketch directory on purpose.** The Arduino build
compiles and links every `.cpp` in the sketch folder, so a `main()` beside
`SmartAccidentAlert.ino` would be pulled into the firmware image and fight the
IDE's own entry point.

## Tasks

Sensor and detector run on core 1; BLE, UI, system and watchdog on core 0.
Priorities are in `config.h` — the watchdog is highest so it is never starved by
the OLED, and the blocking I²C reads are on the other core so they cannot delay
a BLE connection deadline.

## Testing

The host suites live in `/tmp/opencode/saas` and are not part of the repository:
they are scaffolding, not a deliverable. `run_all.sh` builds each suite against
these sources with `g++ -std=c++17 -Wall -Wextra -O2` and runs it.

| Suite | Checks | Covers |
| --- | --- | --- |
| `host_test` | 127 | `golden.json` conformance: every frame, CRC vector, and JSON document. |
| `detector_test` | 21 | Score fusion, debounce, hysteresis, refractory, and the crash/no-crash scenarios. |
| `sensors_test` | 51 | Biquad response at 0/5/20 Hz, ringing, step response, free-fall latch, end-to-end impact. |
| `state_machine_test` | 235 | Every cell of the 7×7 table, including all 24 illegal transitions. |
| `event_queue_test` | 87 | Backoff, exhaustion, wraparound, newest-drop, stop-and-wait ordering. |

What none of this covers: real I²C timing, real BLE radio behaviour, and real
crash dynamics. The detector thresholds in `config.h` need a road test with real
data before they should be trusted.
