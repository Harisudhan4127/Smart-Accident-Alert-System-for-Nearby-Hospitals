# 06 — Accident detection

What the ESP32 actually decides, and why those numbers. The fusion constants live
in `firmware/SmartAccidentAlert/config.h`; the arithmetic lives in
`detector.cpp`.

## Read this first

**The detector has never been run on a road.** `PROJECT_PLAN.md` §24 lists the
experiments that would justify these thresholds, and none of them have been
performed. Every number below is a reasoned starting point, not a measured
result. Anyone who cites this detector as validated is wrong.

The same applies to the biggest design question in the project: a crash is not
a signal you can threshold your way out of. Potholes, speed bumps, kerbs,
garage doors, loading ramps and manual gearshifts all produce large
accelerometer transients. §24's real work is measuring how often a real crash
exceeds the trip threshold and how often a pothole does not.

## Signal path

```
  MPU6050 @ 50 Hz
      │
      ▼
  ┌──────────────┐   ┌────────────────────────────────────────────┐
  │ BURST READ   │──►│ SLOW path: 4-tap MA (80 ms)                 │
  │ accel + gyro │   │   → gravity vector, orientation, speed       │
  └──────────────┘   │                                            │
      │              │ FAST path: UNFILTERED                       │
      ▼              │   → magnitude, z-score, free-fall, jerk     │
  sample ring (8)    └────────────────────────────────────────────┘
      │                          │
      ▼                          ▼
  ┌──────────────────────────────────────────┐
  │ seven terms → weighted sum → 0..100      │
  │ hysteresis: trip ≥70, release ≤45        │
  └──────────────────────────────────────────┘
```

Two filtered paths, and the asymmetry is the important part. The **slow** path
(4-tap moving average, 80 ms) feeds gravity, orientation and the dead-reckoned
speed estimate, where smoothing is harmless. The **fast** path is deliberately
**unfiltered**, because the terms that detect an impact — magnitude, z-score,
free-fall, jerk — are all about *transients*, and a 4-tap average would smear
exactly the signal they exist to find. The gyro gets its own 2-tap (40 ms) MA,
the most smoothing that still leaves a 40 ms rotation pulse intact.

## MPU6050 configuration

| Register setting | Value | Note |
| --- | --- | --- |
| `ACCEL_CONFIG` AFS_SEL | ±4 g | `kAccelLsbPerG = 16384` |
| `GYRO_CONFIG` FS_SEL | ±500 °/s | `kGyroLsbPerDps = 131` |
| `CONFIG` DLPF | 3 | 44 Hz accel / 42 Hz gyro bandwidth at 1 kHz internal rate |
| Sample rate | 50 Hz | One sample pair per 20 ms |

The DLPF choice is deliberate: a 44 Hz bandwidth matched to a 50 Hz sample rate
gives anti-aliasing that matches the detector rate. A wider DLPF would pass
engine and road noise straight into the z-score.

**±4 g is a hard ceiling on what the terms can see.** Three axes at ±4 g gives a
maximum vector magnitude of `4 × √3 = 6.93 g`, which is why
`knee::kAbsFullMg` is 6 g and not the 8 g you might expect. A "full" knee above
the physical maximum would be a term that can never score, silently
redistributing its weight to the other six. `config.h` says this at the constant
and it is worth repeating here because it is an easy mistake to make while
retuning.

## The seven terms

Weights sum to exactly 1000 (`static_assert(kSum == 1000)`), so a term at full
contributes its weight as a percentage of 100.

| Term | Weight | Input | On knee | Full knee |
| --- | --- | --- | --- | --- |
| Free fall | 0.26 | \|a\| below 300 mg, sustained ≥60 ms | 0.3 g | — (binary) |
| z-score | 0.20 | \|a − mean\| / σ over a 1 s baseline | 4.0 σ | 12.0 σ |
| SW-420 | 0.15 | Vibration switch, debounced | on rising edge | — (binary) |
| Gyro | 0.12 | \|ω\| | — | 600 °/s |
| Abs magnitude | 0.11 | \|a\| | — | 6 g |
| Orientation | 0.10 | angle between gravity vectors, pre vs post | 15° | 60° |
| Jerk | 0.06 | d\|a\|/dt | 5 000 mg/s | 20 000 mg/s |

### Free fall (0.26) — the heaviest term

A crash decelerates the body; the MPU sees a moment where the measured
acceleration vector goes *near zero* because the accelerometer is in free fall
relative to the chassis. Requiring `|a| < 0.3 g` for 3 consecutive samples
(60 ms) rejects the single-sample glitches that a bare threshold would trip on.

This term dominates because it is the one that is genuinely hard to fake. A
pothole produces a large positive spike; it does not produce a window where the
vehicle is momentarily weightless.

### z-score (0.20) — surprise, not magnitude

The detector keeps a 50-sample (1 s) rolling mean and standard deviation of
magnitude, and scores the *deviation* from that baseline. This is what adapts to
a rough road, a bad wheel bearing, or a truck: the same pothole produces a
different z-score on different vehicles.

`kMinSigmaMg = 12` floors the denominator. A vehicle parked on a dyno can hold
magnitude to a few tenths of a milli-g, which would make any bump a 200-sigma
event. 12 mg is well below road noise (~10 mg is the floor band) but well above
that pathological case.

The baseline window of 50 samples is long enough that a single pothole strike
does not enter its own baseline before the trip decision.

### SW-420 (0.15) — corroboration, never a trigger

The project plan is emphatic that a vibration switch alone must not raise an
alert, and 0.15 is how that is honoured. The switch cannot on its own reach the
trip threshold of 70.

- Debounced 25 ms, because the module is a mechanical microswitch that chatters
  for milliseconds.
- An assertion keeps contributing for 250 ms after the last rising edge
  (`kSw420HoldMs`), because the module's pot-set dwell time is typically 1–3 s and
  correlating against *edges* alone under-counts a real impact.
- `sw420Hits` counts rising edges within a 10 s window.
- **Mounting matters more than any of this.** The module is a potentiometer plus
  a microswitch; a badly set pot makes the highest-variance input in the whole
  detector. See [03](03-hardware-and-wiring.md).

### Gyro (0.12) and orientation (0.10) — rotation

A rollover or a spin has a different signature from a frontal impact: large
angular rate, and a gravity vector that ends up somewhere else. A frontal
impact has both near zero. Together they are worth 0.22, enough to push a
moderate impact over the line and not enough to fire on a kerb strike.

The gyro is ranged ±500 °/s, giving a 3-axis maximum of 866 °/s, so the 600 °/s
"full" knee is reachable — the same reasoning as the ±4 g accelerometer ceiling.

### Absolute magnitude (0.11) and jerk (0.06) — severity and onset

Magnitude is the crudest term and the least interesting one, which is why it is
only 0.11. Jerk, the rate of change of magnitude, is the lowest at 0.06: a hard
braking event has enormous jerk and is not a crash.

## Hysteresis and refractory

```cpp
constexpr uint8_t kTripScore   = 70;   // fire
constexpr uint8_t kReleaseScore = 45;   // armed again
constexpr uint16_t kDetectorRefractoryMs = 5000;
```

Single-threshold detectors chatter. 70/45 gives a 25-point dead band, so a score
sitting near the threshold does not oscillate the state machine.

The 5 s refractory period is not optional. One crash spans dozens of samples and
the ring-down keeps reading above the candidate floor; without a refractory
window the node would report one physical event several times, and the app would
start a fresh 10 s countdown each time. The user experience of "my phone keeps
re-alerting while I am lying in the car" is the fastest way to make someone
disable the app.

## The dead-reckoned speed gate

The node knows nothing about GPS, so it estimates speed by integrating forward
acceleration, decaying to zero after 3 s of apparent rest.

| Constant | Value | Note |
| --- | --- | --- |
| `kRestAccelMg` | 60 | Below 0.06 g counts as at rest |
| `kRestResetMs` | 3000 | Decay v to zero after 3 s at rest |
| `kSpeedLeakPpm` | 1200 | 0.12 %/tick, halves about every 11 s |
| `kSpeedMaxMilliKmh` | 200 000 | Clamped at 200 km/h |
| `kPreSpeedLookbackMs` | 200 | Speed snapshot frozen 200 ms after the trip |

`kPreSpeedLookbackMs` exists because the crash itself destroys the estimate:
the deceleration is integrated too, so reading speed at the trip instant gives
a number already falling. 200 ms back is the last moment before the event
contaminates it.

**This is dead reckoning, and it is wrong in a specific way worth knowing.**
Integrating acceleration without a reference accumulates drift; the 0.12 %/tick
leak bounds it (a long downhill decays toward zero rather than away to infinity)
and the rest detector clears it after a stop. A crash ends with the vehicle
stationary, so the rest detector is what actually makes this usable. The
estimate is displayed as an estimate and must not be presented as a speedometer
reading.

`minSpeedKmh` in the CONFIG command is the gate that ignores parking-lot
bounces. **Omitting it leaves it at 0, which disables the gate entirely** — see
[13](13-troubleshooting.md).

## Calibration

On boot, if no calibration is stored in NVS, the node calibrates for 1.2 s
(`kBootCalibMs`) before arming: the mean of each axis is taken as the offset.
It requires at least `kCalibMinMs` (500 ms, i.e. 25 samples at 50 Hz) to be
trusted, because a calibration taken while the vehicle is moving is worse than
none. A `CALIB` command can request a longer window: `kCalibDefaultMs` is
5000 ms, clamped to `kCalibMaxMs` = 10 000, with up to 48 samples retained for
`CALIB_LOG`.

A calibration taken while the vehicle is moving is worse than none: it bakes
the acceleration of the road into the offset, and every subsequent reading is
wrong by that amount.

**Two defects make this worse than it should be:**

1. **`sensors.cpp:58-60` sums the wrong axes into the gyro accumulators:**
   ```cpp
   gxSum_ += axMg;
   gySum_ += ayMg;
   gzSum_ += azMg;
   ```
   The accelerometer biases are added three times each and the gyroscope biases
   are never computed at all. The gyro correction is therefore wrong by exactly
   the gyro's own offset, on every run.
2. **`streamCalibLog()` is never called.** `CALIB_LOG` is documented in
   `docs/02-ble-protocol.md`, has a golden vector, has a Dart parser and a
   Node test — and is never sent. Nothing in the firmware asks for it.

The consequence is that gyro calibration is silently wrong and there is no
in-field way to observe the accelerometer calibration. Neither is hard to fix;
both are in `firmware/**`, which is out of scope for this documentation pass.

## Known calibration-gyro bug, concretely

`Calibrator::add()` in `sensors.cpp` is where the three lines above live. The
history arrays it fills for `CALIB_LOG` are a second instance of the same class
of bug:

```cpp
hist_[histN_]     = mag;
histX_[histN_]    = axMg;
histY_[histN_]    = ayMg;
histZ_[histN_]    = azMg;
// histGx_, histGy_, histGz_ are never written
```

and `readHistory()` reads them back at lines 94–96, clamping values that were
never initialised. So the `CALIB_LOG` gyro fields, had the message ever been
sent, would be garbage.

## Reproducing a detection

1. Flash the node and watch the serial monitor at 115200 baud.
2. Calibrate on a flat, still surface. The OLED shows `CALIBRATING`.
3. Confirm the state is `IDLE` and the green LED is lit.
4. Trigger the SW-420 by hand. The buzzer chirps, the red LED strobes, and
   `EVENT{ACCIDENT_DETECTED, seq=N}` appears on CTRL.
5. Connect the app and confirm within 10 s. The state goes `PENDING` → `SOS`.
6. Send `CANCEL` (or press SOS again) and confirm the node returns to `IDLE`.

A hand trigger of the SW-420 alone scores 0.15 and will **not** trip. To test
the detector you need a real acceleration transient — a firm downward tap on a
table the node is sitting on is enough to exercise free-fall plus jerk. If you
are only able to trigger by flicking the SW-420, you are testing the switch, not
the detector.
