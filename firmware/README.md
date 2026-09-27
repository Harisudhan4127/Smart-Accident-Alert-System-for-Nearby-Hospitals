# Smart Accident Alert — firmware

ESP32 firmware for the accident-alert node. Detects an impact with an MPU6050,
corroborates it with speed and free-fall, and alerts the nearest hospital over
BLE to the phone paired with it.

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

Gyro gets a 2-tap average: long enough to reject the aliasing the 50 Hz sample
rate would otherwise fold onto, short enough to keep the impact transient.

The biquad state is Q15 and is **not** shifted each sample. Only the output
expression shifts. This is the classic Q15 filter bug: shifting the state as well
as the output divides the state by 32768 every sample, and the filter collapses
within a few hundred milliseconds. End-to-end, a 5900 mg input reaches the
detector as a 5891 mg peak.

Free-fall is latched: the detector only sees a "low g" bit after 60 ms of
sustained low-g, so a single-sample dip cannot fake it.

## Detection

Fusion is fixed-point, and the weights are in `config.h`. The z-score against a
frozen baseline, the raw magnitude, the jerk magnitude, the gyro magnitude, the
free-fall bit, the SW-420 contact and the speed floor are combined into a single
`0–100` score. Two thresholds matter: a candidate floor, and a higher trip
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
| I²C SDA / SCL | 21 / 22 | MPU6050 and the SSD1306 share the bus. |
| SW-420 | 27 | **Active HIGH** (`kSw420ActiveHigh`): the module pulls the line *high* when it vibrates. Debounced 25 ms, interrupt on both edges. Wiring it as active-low inverts the signal and disables the vibration term. |
| Buzzer | 25 | **Active LOW** (`kBuzzerActiveLow`) through an NPN — the transistor conducts to sound it. |
| SOS button | 26 | **Active LOW** (`kSosButtonActiveLow`) to GND, internal pull-up. |
| Green / red LED | 32 / 33 | **Active HIGH** (`kLedActiveHigh`) — the resistor goes to GND. |
| Battery ADC | 34 | Input-only pin, correct for a divider. |
| Charge status | 35 | TP4056 `CHRG`, open-drain, optional. |

The MPU6050 is assumed to be mounted so that the vehicle's forward axis is `+X`.
The speed integrator depends on that; the accelerometer axes are otherwise
symmetric.

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
