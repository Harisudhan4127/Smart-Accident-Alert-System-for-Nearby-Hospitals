# 07 — Memory and power

Two things in this document are **measured** and the rest is **derived or
estimated**. They are labelled. No firmware has been run on hardware in this
repository, so there is no current-consumption figure here that came from a
current probe.

## Flash and RAM: the only measured numbers, and they are stale

`firmware/README.md` reports, for the Arduino CLI build with ESP32 core 2.5.1,
Adafruit SSD1306 2.5.17 and Adafruit GFX 1.12.6:

| | Reported |
| --- | --- |
| Flash | 50 % |
| Static RAM | 16 % |

These come from the build output, and they are the only measured figures in this
document. They are **not** reproduced here: the Arduino toolchain is not
available in this environment, so re-running the build was not possible, and
quoting a fresh percentage would be inventing one. Re-run the build to refresh
them:

```bash
cd firmware/SmartAccidentAlert
arduino-cli compile -b esp32:esp32:esp32 .
```

The build is comfortably within budget, and it would need a very large
regression to matter — Wi-Fi is not linked in, which is most of the reason the
number is low.

### Task stacks

| Task | Stack (words) | Priority | Core |
| --- | --- | --- | --- |
| `ble` | 6144 | 4 | 0 |
| `sensor` | 4096 | 6 | 1 |
| `detect` | 4096 | 5 | 1 |
| `ui` | 4096 | 2 | 0 |
| `sys` | 4096 | 3 | 0 |
| `wdt` | 2048 | 7 | 0 |
| **Total** | **24 576 words ≈ 98 KB** | | |

Derived, not measured: on the ESP32, FreeRTOS stack depth is in 32-bit words, so
24 576 words is about 96 KiB of the ~320 KiB of DRAM. `ble` gets the largest
stack because NimBLE host parsing and the JSON scanner both recurse; `wdt` gets
the smallest because it calls one function and sleeps.

The point of the split across cores is not capacity, it is latency. The blocking
I²C read and the fusion that consumes it sit on core 1; a NimBLE radio
interrupt on core 0 cannot delay a sample, and a late sample shifts every window
the detector uses.

### Static buffers

Everything below is sized at compile time, which is what makes the memory
budget checkable by reading a header instead of by profiling:

| Buffer | Size | Bounded because |
| --- | --- | --- |
| `Sample` ring | 8 | Lossless by design: a dropped sample would silently shift the baseline window. `pushSample()` overwrites the oldest only in a state that cannot occur (the detector drains it every 20 ms). |
| Telemetry ring | 4 | **Lossy by design.** When the phone is congested the oldest sample is dropped. Losing a telemetry sample is cosmetic; losing a detector sample corrupts the algorithm. |
| Event queue | 8 slots × 320 B | Events are rare. A full queue drops the *newest* event and lights the red LED rather than blocking the detector. |
| Frame / JSON / RX buffers | 600 B each | `MAX_PAYLOAD` is 512; 600 leaves room for the 8-byte header and CRC. |
| Calibration history | 48 samples | Fixed, decimated for `CALIB_LOG`. |

No `malloc` runs on the hot path. This is a deliberate constraint, not an
accident: a fragmentation-induced failure in a node whose job is to sound a
buzzer after a crash is a failure mode with no recovery path.

## The sleep policy, and why none of it is reachable

`power.h` implements a three-part policy, and it is well designed:

| Verdict | Meaning |
| --- | --- |
| `kSleepOk` | Light sleep permitted this instant |
| `kSleepBusyBle` | A phone is connected; the radio needs the core |
| `kSleepBusyAlarm` | Alarming, or an event is still unacknowledged |
| `kSleepBusyDisarmed` | The detector is armed; never park |
| `kSleepBusyCharging` | Charging; keep the rail up |
| `kSleepNotForced` | Forced sleep declined by policy |

`mayLightSleep()` is a pure function with no I/O, so the policy is testable and
cannot drift from what actually happens. `allTasksHealthy()` also returns true
before `begin()`, so a caller that forgets to initialise does not sleep forever —
a small, correct piece of defensive design.

Deep sleep is **never automatic**, and the header says why: "a node that parks
itself at 3 V and stops detecting is worse than one that runs flat". It can only
be armed explicitly, via a command, and it refuses while the detector is armed.
The wake sources are the SW-420 pin (`ESP_EXT1_WAKEUP_ANY_HIGH`) and a timer.

### The problem

**`serviceLightSleep()` and `armDeepSleep()` have no callers.**

```bash
$ grep -rn "serviceLightSleep|armDeepSleep" firmware/SmartAccidentAlert/
power.cpp:116:SleepVerdict Power::serviceLightSleep(...)
power.h:62:  SleepVerdict serviceLightSleep(...)
```

Both are defined and never called. The consequence is not subtle: **the node
runs at full power, always.** No light sleep between sensor samples, no deep
sleep, no wake-on-vibration. The `esp_sleep` calls in `power.cpp` are
unreachable code.

So every current figure below describes hardware the firmware does not
currently put into a low-power state.

## Power budget

**Estimated**, from component datasheets and duty cycle, with no measurement
behind it.

| State | Component | Current | Duty | Contribution |
| --- | --- | --- | --- | --- |
| Active | ESP32 CPU, both cores, Wi-Fi off | 80–120 mA | 100 % | **~100 mA** |
| Active | ESP32 BLE advertising + 50 Hz telemetry | +20–30 mA | while connected | ~0–30 mA |
| Active | ADXL345 at 100 Hz ODR | 0.1–0.2 mA | 100 % | **~0.14 mA** |
| Active | SSD1306 OLED | 10–20 mA | 100 % | **~15 mA** |
| Active | Buzzer | 20–30 mA | when alarming | ~0 mA idle |
| Active | LDO quiescent + divider | 1–5 mA | 100 % | ~3 mA |
| **Total, idling with the radio connected** | | | | **~120–150 mA** |
| **Total, radio disconnected (advertising)** | | | | **~100–120 mA** |

Against a 2000 mAh cell that is **8–17 hours**, not the weeks a reader might
assume from "battery powered". The two dominant terms are the CPU running flat
and the OLED, and they are the two that a working sleep policy would attack.

**The sensor swap improved the power budget for free.** The MPU6050 ran its
internal rate at 1 kHz — set by `kMpuDlpf` — and cost ~3.5 mA whether or not
anyone read a sample. The ADXL345 at its 100 Hz output rate draws ~140 µA. That
is roughly 3.4 mA off the idle total, about 2% here, and it was not a change
anyone had to design for. The accelerometer does have a low-power mode that
would save less again; it is not implemented.

## What implementing the sleep policy would buy

**Estimated**, and dependent on the detector continuing to work, which is the
part nobody has tested.

| Change | Expected saving | Risk |
| --- | --- | --- |
| Light sleep between 20 ms samples, radio able to stay connected | 20–40 mA average | Missed BLE deadlines if the wake is late; the `ble` task runs at 5 ms so there is little idle window on that core |
| OLED off after 30 s of no interaction | ~15 mA | The user loses the status display; needs a button press to wake it |
| Deep sleep when disarmed and unconnected, wake on SW-420 | 100 mA → <1 mA | **The detector stops working while parked.** This is why `armDeepSleep` refuses while armed — it is a battery-versus-safety trade, and the firmware's default is safety |
| Accelerometer low-power mode between reads | 2–3 mA | Loses the 1 kHz internal rate; the DLPF anti-aliasing argument weakens |

A realistic "long battery life" design for this node is: light sleep between
samples with the radio connected, OLED off when idle, and deep sleep only when
disarmed *and* charging-state-appropriate. That is a firmware change, and this
repository does not make it.

## The battery gauge

`batteryPercent(batteryMilliVolts(g_batteryAdc()))` runs in the `detect` task
against the GPIO 34 divider, and `kBatteryAdcIgnoreMv = 1200` treats a reading
below 1.2 V as "no battery connected" — i.e. USB only. Without that floor, a
floating ADC input reads as a full cell, which is a particularly bad failure
mode for a low-battery warning.

Two things follow:

- The percentage is derived from a 2:1 divider and a load-dependent LDO, so it
  is an estimate with a few percent of error and no calibration curve.
- **The app never reads it.** `batteryPct` is in the telemetry frame and the
  `STATUS` message, and nothing in `app/lib/` consumes it. §25's low-battery
  warning is not implemented.

## Known gaps in this document

| Gap | Consequence |
| --- | --- |
| No sleep calls wired up | The node is a 120–150 mA device, not a low-power one |
| No current measurement | Every mA figure above is from datasheets |
| No runtime heap high-water mark | Static RAM is accounted for; fragmentation headroom is not |
| OLED dominates and is never dimmed | 15 mA for a status display nobody is looking at |
| Battery telemetry is not consumed by the app | §25's low-battery warning cannot fire |
| `cpuLoadPct` and `brownoutCount` are hardcoded to 0 | The telemetry stream reports reassuring numbers it did not measure |
