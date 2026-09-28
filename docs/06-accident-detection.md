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
  ADXL345 @ 50 Hz
      │
      ▼
  ┌──────────────┐   ┌────────────────────────────────────────────┐
  │ 3-AXIS READ  │──►│ SLOW path: 4-tap MA (80 ms)                 │
  │ X, Y, Z      │   │   → gravity vector, orientation, speed       │
  └──────────────┘   │                                            │
      │              │ FAST path: UNFILTERED                       │
      ▼              │   → magnitude, z-score, free-fall, jerk     │
  sample ring (8)    └────────────────────────────────────────────┘
      │                          │
      ▼                          ▼
  ┌──────────────────────────────────────────┐
  │ six terms → weighted sum → 0..100        │
  │ hysteresis: trip ≥70, release ≤45        │
  └──────────────────────────────────────────┘
```

Two filtered paths, and the asymmetry is the important part. The **slow** path
(4-tap moving average, 80 ms) feeds gravity, orientation and the dead-reckoned
speed estimate, where smoothing is harmless. The **fast** path is deliberately
**unfiltered**, because the terms that detect an impact — magnitude, z-score,
free-fall, jerk — are all about *transients*, and a 4-tap average would smear
exactly the signal they exist to find. There is no second filtered path: the
ADXL345 has three axes and all three go down both of these.

## ADXL345 configuration

| Register setting | Value | Note |
| --- | --- | --- |
| `DATA_FORMAT` RANGE | ±16 g | `kAdxlRange16G = 0x0B` |
| `DATA_FORMAT` FULL_RES | on | Set by the library. Pins the scale at 3.9 mg/LSB on every range. |
| `BW_RATE` ODR | 100 Hz | `kAdxlOdr`; the part is read at 50 Hz, so this is 2× oversampled. |
| Sample rate | 50 Hz | One sample triple per 20 ms |
| I²C address | `0x53`, falling back to `0x1D` | SDO strapped low or high |

**100 Hz is an oversample, and that is the point.** The ADXL345 has no DLPF
register — bandwidth is set by the output data rate, and 100 Hz gives it well
under the 25 Hz Nyquist limit for a 50 Hz read. The firmware's own 4-tap moving
average and 5 Hz biquad then do the rest.

**±16 g is a hard ceiling on what the terms can see.** Three axes at ±16 g gives
a maximum vector magnitude of `16 × √3 = 27.7 g`, so the 6 g `knee::kAbsFullMg`
is comfortably reachable — unlike the ±4 g MPU6050 configuration it replaces,
where 6.93 g left only 15% of headroom. A "full" knee above the physical
maximum would be a term that can never score, silently redistributing its weight
to the other five. `config.h` says this at the constant and it is worth
repeating here because it is an easy mistake to make while retuning.

## The six terms

Weights sum to exactly 1000 (`static_assert(kSum == 1000)`), so a term at full
contributes its weight as a percentage of 100.

| Term | Weight | Input | On knee | Full knee |
| --- | --- | --- | --- | --- |
| Free fall | 0.30 | \|a\| below 300 mg, sustained ≥60 ms | 0.3 g | — (binary) |
| z-score | 0.23 | \|a − mean\| / σ over a 1 s baseline | 4.0 σ | 12.0 σ |
| SW-420 | 0.17 | Vibration switch, debounced | on rising edge | — (binary) |
| Abs magnitude | 0.13 | \|a\| | — | 6 g |
| Orientation | 0.11 | angle between gravity vectors, pre vs post | 15° | 60° |
| Jerk | 0.06 | d\|a\|/dt | 5 000 mg/s | 20 000 mg/s |

**The seventh term is gone, and its weight was not deleted.** The previous
revision had a gyro-only term worth 0.12. An ADXL345 measures acceleration, not
angular velocity, so there is no rotation rate to fuse — inventing one from
differentiated accelerometer data would produce a number that looks like a
physical quantity and is not one. The 0.12 was redistributed across the six
remaining terms, which keeps the total at 1000 and leaves the trip threshold
at 70 where it was. That is the important property: **the sensitivity of the
shipped detector is unchanged by the sensor swap**, and §24's false-alarm and
miss rates carry over.

### Free fall (0.30) — the heaviest term

A crash decelerates the body; the accelerometer sees a moment where the measured
acceleration vector goes *near zero* because the accelerometer is in free fall
relative to the chassis. Requiring `|a| < 0.3 g` for 3 consecutive samples
(60 ms) rejects the single-sample glitches that a bare threshold would trip on.

This term dominates because it is the one that is genuinely hard to fake. A
pothole produces a large positive spike; it does not produce a window where the
vehicle is momentarily weightless.

### z-score (0.23) — surprise, not magnitude

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

### SW-420 (0.17) — corroboration, never a trigger

The project plan is emphatic that a vibration switch alone must not raise an
alert, and 0.17 is how that is honoured. The switch cannot on its own reach the
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

### Orientation (0.11) — rotation, from gravity

A rollover has a different signature from a frontal impact: the gravity vector
the accelerometer measures ends up pointing somewhere else. A frontal impact
leaves it where it was. That difference is worth 0.11 — enough to push a
moderate impact over the line, not enough to fire on a kerb strike.

**What this term is not.** It is not a rotation rate, and it is not as sensitive
as one. It compares two *filtered, 1-second-averaged* gravity vectors — one from
before the impact, one from after — so it measures how far the vehicle ended up
tilted, over seconds, and it is blind to a spin that returns to level. A rollover
that ends flat leaves no trace here at all. With an accelerometer alone that is
an honest limit, and the reason the SW-420 term carries more weight than it used
to: the switch is the only input that feels a spin the gravity vector misses.

The 60° "full" knee is reachable inside a 90° roll, which is the same
reachability reasoning as the magnitude ceiling above.

### Absolute magnitude (0.13) and jerk (0.06) — severity and onset

Magnitude is the crudest term and the least interesting one, which is why it is
still the second-lowest. Jerk, the rate of change of magnitude, is the lowest at 0.06: a hard
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

**What the ADXL345 change fixed here.** Two defects in this area were real, and
both disappeared with the gyroscope rather than needing a separate fix:

1. *The bias accumulators were misnamed and half-wrong.* They summed the
   accelerometer axes into three fields called `gxSum_`/`gySum_`/`gzSum_`, and
   a parallel trio of `CALIB_LOG` history arrays — `histGx_`/`histGy_`/`histGz_`
   — was allocated, never written, and then read back and clamped as though it
   held data. So `CALIB_LOG` would have emitted `"gyr_x": 0` on every row: a
   value that is indistinguishable from a working gyroscope reading exactly
   zero. The sums themselves were the right *numbers* (they are the mean
   gravity vector), so only the names were wrong; there is now one accumulator
   per accelerometer axis and no second set of arrays at all.
2. *`streamCalibLog()` was never called.* `CALIB_LOG` is specified in
   [02](02-ble-protocol.md), has a golden vector and parsers on both sides, and
   was not sent by anything. It is called from the command dispatcher now, so
   the accelerometer calibration is observable in the field.

Neither was a subtle numerical error, which is worth noting: both were *reporting*
defects. The arithmetic the detector fuses was always the accelerometer's, and
it was always right. What was wrong was the story the firmware told about
itself, which is the more dangerous kind of bug in a safety system because it
survives a test pass.

The `sw420` level is recorded per history tap as well, so a `CALIB_LOG` shows
whether the node was sitting still while it baselined — a calibration taken
while the switch is chattering is a calibration of a road, not of a vehicle.

## Reproducing a detection

1. Flash the node and watch the serial monitor at 115200 baud.
2. Calibrate on a flat, still surface. The OLED shows `CALIBRATING`.
3. Confirm the state is `IDLE` and the green LED is lit.
4. Trigger the SW-420 by hand. The buzzer chirps, the red LED strobes, and
   `EVENT{ACCIDENT_DETECTED, seq=N}` appears on CTRL.
5. Connect the app and confirm within 10 s. The state goes `PENDING` → `SOS`.
6. Send `CANCEL` (or press SOS again) and confirm the node returns to `IDLE`.

A hand trigger of the SW-420 alone scores 0.17 and will **not** trip. To test
the detector you need a real acceleration transient — a firm downward tap on a
table the node is sitting on is enough to exercise free-fall plus jerk. If you
are only able to trigger by flicking the SW-420, you are testing the switch, not
the detector.
