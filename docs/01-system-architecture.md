# 01 — System architecture

Three tiers, two of them real-time, and a design decision at the boundary
between them that explains most of the rest of this codebase.

## The shape

```
  VEHICLE                          PHONE                        CLOUD
  ┌──────────────┐                ┌───────────────┐            ┌──────────────┐
  │ ESP32        │   BLE          │ Flutter app   │  HTTPS     │ Firestore    │
  │ ├ ADXL345    │ ─────────────► │ ├ BLE link    │ ─────────► │ ├ accidents  │
  │ ├ SW-420     │  notifications │ ├ GPS         │            │ ├ users      │
  │ ├ detector   │  + writes      │ ├ outbox      │ ◄───────── │ └ hospitals  │
  │ └ state      │                │ └ UI          │  callable  │              │
  │    machine   │                └───────────────┘            │ Cloud        │
  │ buzzer, LED, │                                             │ Functions    │
  │ OLED, button │                                             │ ├ dispatch   │
  └──────────────┘                                             │ └ nearby     │
                                                              └──────────────┘
```

## The decision everything else follows from: the phone owns location

`PROJECT_PLAN.md` §5 is the reason the prototype has no GPS or GSM module. The
Android phone is close to the ESP32, is powered, can see the sky, and has a
radio. So the node never learns where the accident is — it only knows *what*
happened, and *when*, in its own uptime clock.

| Fact | Source of truth | Why it matters |
| --- | --- | --- |
| An impact happened, with magnitude and confidence | Node (`EVENT`, §6.6) | Only the node has the accelerometer data |
| Where it happened | Phone GPS (`GeoPoint`) | Only the phone has a GPS receiver |
| Whether it is a real accident | User, via the countdown | The node cannot tell a pothole from a crash |
| When the record was stored | Server (`FieldValue.serverTimestamp()`) | A client can lie about its own clock |

Consequences that show up repeatedly:

- **A crash in a tunnel with no signal is the case that matters most, and it is
  the case this architecture handles worst.** The node detects, the phone
  receives, the phone cannot reach the cloud. The app's outbox is what saves
  this, and the outbox is not built. See [08](08-android-app-architecture.md).
- **The node's uptime clock is not wall time.** `t_ms` in the `EVENT` frame is
  milliseconds since boot. Anything displayed to a human has to come from the
  phone.
- **The two state machines are independent on purpose.** The node has
  `BOOT/IDLE/PENDING/ALARM/SOS/MUTED/FAULT`; the app has
  `DETECTED/CANCELLED/CONFIRMED/ALERT_SENT/RESOLVED`. The node can be re-armed
  and idle again while a phone is still showing an unresolved alert, because
  collapsing the two would make "alert resolved" depend on BLE staying
  connected. `AccidentStatus` in
  `app/lib/domain/entities/accident.dart` says this at length and is right to.

## Firmware: six tasks, two cores

| Task | Priority | Stack | Core | Period | Job |
| --- | --- | --- | --- | --- | --- |
| `sensor` | 6 | 4096 | 1 | 20 ms | Blocking I²C read of the ADXL345, plus the SW-420 pin |
| `detect` | 5 | 4096 | 1 | 20 ms, drift-corrected | Seven-term fusion, state machine, telemetry, alarm outputs |
| `wdt` | 7 | 2048 | 0 | 100 ms | `checkWatchdog()` — resets the chip if any task slot has starved |
| `ble` | 4 | 6144 | 0 | 5 ms | NimBLE host, connection supervision, event sequencer |
| `ui` | 2 | 4096 | 0 | 100 ms | SSD1306 OLED |
| `sys` | 3 | 4096 | 0 | 1000 ms | Serial, battery ADC, countdown expiry, sensor-fault detection |

Priorities and stacks are from `config.h`; the periods are the `vTaskDelay` /
`vTaskDelayUntil` arguments in `SmartAccidentAlert.ino`. The split across cores
is deliberate: the blocking I²C read and the fusion that depends on it stay on
core 1 so a radio interrupt on core 0 cannot delay a sample, and a sample that
arrives late is a sample that shifts every window the detector uses.

Both `sensor` and `detect` use `vTaskDelayUntil` against a stored previous-wake
tick rather than `vTaskDelay` against the work time. That is not a style choice:
adding a delay to the *work* time accumulates every I²C stall into permanent
lag, so a node that spent a week in a tunnel would be sampling tens of
milliseconds late forever.

`checkWatchdog()` is called from **two** places — `sysTask` (1 Hz) and `wdtTask`
(10 Hz). That is redundant rather than harmful, but it is worth knowing when
reading a watchdog log, because a reset can be attributed to either.


`detect` runs on the sample ring (`kSampleRingN = 8`) rather than reading
sensors itself, because a detector that blocks on I²C inherits the I²C failure
mode. The ring is lossless — a dropped sample would silently shift the baseline
window — while the telemetry ring (`kTelemRingN = 4`) is explicitly lossy and
drops the oldest sample when the phone is congested. Losing a telemetry sample
is cosmetic; losing a detector sample corrupts the algorithm.

Nothing is allocated at run time. Every buffer in `config.h` is sized at compile
time, which is what makes the memory budget in [07](07-memory-and-power.md)
checkable by reading a header instead of by profiling.

## Detection: one trip, not a stream of them

The detector fuses six weighted terms into a 0–100 score, with hysteresis
(trip at 70, release at 45). The weights, in `config.h`:

| Term | Weight | What it catches |
| --- | --- | --- |
| Free fall | 0.30 | Loss of ground contact: `|a| < 0.3 g` for 60 ms |
| z-score | 0.23 | Acceleration surprise against a rolling 1 s baseline |
| SW-420 | 0.17 | An independent mechanical switch — a different failure mode from the accelerometer |
| Absolute magnitude | 0.13 | Severity |
| Orientation | 0.11 | Gravity-vector rotation — the only rotation evidence an accelerometer can give |
| Jerk | 0.06 | d|mag|/dt |

There is no gyroscope term. The node's motion sensor is an ADXL345, a
three-axis accelerometer; it measures acceleration and no rotation rate is
derived from it. The weight the old gyro term held (0.12) was redistributed
across the six above, so the trip threshold and the shipped sensitivity are
unchanged by the swap. See [06](06-accident-detection.md) for why a fabricated
rate was not an option.

The SW-420 is deliberately short of a threshold on its own. §9 of the project
plan is emphatic that a vibration switch alone must not trigger an alert, and
the weighting is how that is honoured: the accelerometer does the detecting and
the switch corroborates. It carries more weight than it used to (0.17, from
0.15) because with no gyroscope it is the only input that feels a spin the
gravity vector misses.

After a trip the detector is blind for `kDetectorRefractoryMs = 5000`. One
crash spans dozens of samples and the ring-down still reads above the candidate
floor, so without a refractory window a single event is reported several times
— each one a new countdown on the user's phone.

Full detail, including why each knee is where it is: [06](06-accident-detection.md).

## Message flow

```
  node                                   phone
  │                                       │
  │ ── EVENT{ACCIDENT_DETECTED, seq=7} ──► │  CTRL notify
  │                                       ├─► local alarm already sounding
  │                                       ├─► 10 s countdown
  │                                       │
  │ ◄── COMMAND{CONFIRM, eventId} ──────── │  user confirms, or timer expires
  │                                       ├─► GPS fix
  │                                       ├─► dispatchAccident (callable)
  │                                       ├─► nearbyHospitals (HTTP)
  │                                       └─► notify own emergency contacts
  │ ◄── ACK{seq=7} ────────────────────── │  phone acknowledges the event
  │                                       │
```

The `seq` number is the node's half of the stop-and-wait. Events are delivered
on the CTRL characteristic, and if the phone does not ACK within 750 ms the node
retries, twice, at 1500 ms and 3000 ms, then gives up and flashes the red LED
rather than blocking. A critical event is therefore delivered *at most once* or
*not at all* — never more than once. The app's outbox is the other half: the
phone is responsible for getting the record to the cloud, and it is not built
yet.

## What happens when each link fails

| Failure | Detected by | Actual behaviour | Intended |
| --- | --- | --- | --- |
| BLE drops mid-event | `ble` task, 4 s supervision timeout | Node retries 3×, then red LED blink at 120 ms. The record is **lost** | App outbox should retain it |
| Phone has no internet | Nothing in firmware | Node is unaffected. Nothing is stored | App queues locally (§25) |
| GPS unavailable | `geolocator` | **Not implemented** — no app UI exists | Show `GPS LOCATION UNAVAILABLE` (§25) |
| Phone battery low | Battery ADC on the node, 1 Hz | Reported in `STATUS`/telemetry; the app does not read it | Warn the user (§25) |
| Cloud unreachable | App | **Not implemented** | Retry with backoff |
| ADXL345 absent or stalled | `sysTask`: 100 consecutive 1 Hz failures | `Trigger::kFault` → `FAULT` state, `DEVICE_FAULT` event queued, red LED | Same. A detector fed zeros would call every bump a crash |
| False alarm | User presses SOS again, or `CANCEL` | Countdown cancelled, node returns to `IDLE` | Same — this one works |

The "actual behaviour" column is the honest one. Three of the six rows in the
"intended" column need app code that does not exist.

## Cloud tier

Two functions, and the split between them is a security decision:

- **`dispatchAccident`** — callable v2, requires Firebase Auth. Called by the app
  after the user confirms. Writes the accident with a server timestamp and, if
  the user picked a hospital, one grant recording that choice.
- **`nearbyHospitals`** — HTTP, no auth, because §16's list has to work before
  sign-in. Returns six public hospital fields and nothing else. Rate limited,
  CORS-restricted, cached.

Neither notifies a hospital. Details: [12](12-api-reference.md), and the threat
model in [09](09-security-and-privacy.md).

## Failure domains, honestly

| Domain | Fails when | User-visible effect |
| --- | --- | --- |
| Node crash | Watchdog 5 s per task | Buzzer stays on, no alert reaches the phone. The buzzer is the only local indication. |
| Phone crash | App killed, BLE drops | Node retries and gives up. Record lost. |
| Both | — | A local siren and nothing else. This is the real failure mode, and the project plan does not claim otherwise. |
