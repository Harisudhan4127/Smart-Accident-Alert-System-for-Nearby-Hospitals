# 13 — Troubleshooting

Symptom → cause → fix. Ordered by how often each one actually happens.

- [The node](#the-node)
- [BLE pairing and connection](#ble-pairing-and-connection)
- [Telemetry](#telemetry)
- [Detection](#detection)
- [The app](#the-app)
- [The backend](#the-backend)
- [Build problems](#build-problems)

---

## The node

### The OLED is blank

| Cause | Check | Fix |
| --- | --- | --- |
| No power to the module | `3V3` and `GND` connected? | Power it from the ESP32's 3V3, **not** 5V — an SSD1306 module with a regulator can take 5V, one without cannot |
| Wrong I²C address | Most are `0x3C`; some are `0x3D` | Try the other. The firmware prints the address it found at boot |
| I²C wires swapped | SDA/SCL reversed | SDA→GPIO21, SCL→GPIO22. Reversed looks identical to "not present" |
| Firmware not running | Any output on the serial monitor at 115200? | `make firmware-upload PORT=…` |

The serial monitor is authoritative here. If it prints a boot banner, the
firmware is alive and the problem is display-only.

### Everything resets when the buzzer fires

**A brownout.** The buzzer draws ~30 mA; on a weak power source that can pull
the rail below the ESP32's minimum and reset the chip.

- power the buzzer through a transistor (it must be, if you are driving more
  than ~12 mA) and from `VIN`, not the 3V3 pin;
- put **100 µF** across the buzzer's supply and **100 nF** at the ESP32's 3V3;
- check `DIAG.brownoutCount` in the app — it counts exactly these events.

### `DIAG` shows `crcErrors` climbing

The BLE link is corrupting frames. Almost always RF, not software:

- move the node away from the ESP32's antenna and any USB cable;
- check the power rails with a multimeter under load;
- lower the TX power in `comm.cpp` if the phone is very close — full power at
  10 cm is more likely to cause distortion than to help.

A handful of errors during a connect is normal. Hundreds means a physical
problem.

### `DIAG.heapFree` is falling over time

A real leak. The firmware's hot paths are allocation-free by design, so a
falling free-heap figure points at something outside them — most likely a BLE
characteristic read or a JSON parse on a path that should be using the static
buffer.

Compare `heapFree` against `heapMin` over a 30-minute drive. If `heapMin`
tracks `heapFree`, the high-water mark is not being recovered.

---

## BLE pairing and connection

### The node does not appear in the scan list

| Cause | Check | Fix |
| --- | --- | --- |
| It is not advertising | Is the green LED lit? Is the board powered? | `make monitor` — the firmware should print `advertising` |
| The scan filter is not matching | — | The app filters on the service UUID `7c9e0000-…`. Confirm the node advertises it (`nRF Connect` will show it) |
| Bluetooth is off / not permitted | — | The splash screen reports this and blocks with a "Check again" button |
| The phone is filtering too | iOS does not return unnamed peripherals | The node advertises `SAAS-<id>`, so it is named |
| Stale pairing on iOS | — | iOS caches bonded devices. "Forget this device" in Settings, then re-pair |

Test with **nRF Connect** first. If the node does not appear there either, the
problem is the node; if it does appear but not in the app, the problem is the
app's filter.

### Pairs, then drops after a few seconds

- **MTU.** Some Android builds refuse 247. The firmware falls back and pads; if
  the app does not, telemetry gets truncated. Check `DIAG` after reconnecting.
- **Another app is holding the GATT connection.** Bluetooth headphones are the
  usual culprit. Disconnect them.
- **The supervision timeout is too tight** for the link quality. §2.3 specifies
  4 s; if the node is at the edge of range, raise it in `comm.cpp`.

### Reconnects in a loop

Expected behaviour when the car is moving — the phone and node are ~10 m apart
with a metal body in between. The app uses **exponential backoff with jitter**
(the jitter matters: without it, every phone in a car park reconnects in the
same millisecond).

If it never settles, the node is probably rebooting — check for brownouts above.

---

## Telemetry

### No telemetry, but the link is up

1. Is `HELLO_ACK` arriving? Without it the app has no device identity and will
   not subscribe.
2. Check the MTU. If it is 23, a 32-byte telemetry frame does not fit one
   notification. The protocol's padding handles this, but if the firmware is
   older than the padding change, frames will be truncated and fail CRC.
3. `DIAG.loopHz` should read ~50. If it reads 0, the sensor task is not running
   — the usual cause is an MPU6050 that is not answering, so `sensors.cpp` is
   retrying forever.

### Telemetry arrives but the app shows `—`

The app shows `—` for a GPS fix, not for telemetry. Check the notification
permission and that location services are on.

### Values are frozen but the app is connected

`DIAG.droppedFrames` climbing means the phone cannot drain 50 Hz. Close other
BLE apps, and check the phone is not thermally throttled.

---

## Detection

### No alerts, ever

Work down this list:

1. **`state` is not `IDLE`.** `FAULT` means a sensor is not answering;
   `MUTED` means the buzzer is suppressed (detection still runs);
   `DISARM`/`autoArm` may be off.
2. **`armed` flag.** `flags.ARMED` (bit 6) in telemetry.
3. **Threshold too high.** `kAccelThresholdMg` in `config.h`, default 3000
   (3 g). A gentle impact will not reach it.
4. **`minSpeedKmh` gate.** The dead-reckoned speed gate suppresses anything
   below ~5 km/h — a device dropped while parked is ignored *by design*. Test
   while the car is genuinely moving.
5. **`vibrationRequired`.** On by default: without an SW-420 hit, a pure
   accelerometer impact is ignored. Test with the switch physically pressed.

### False alarms on rough roads

Expected, and the reason the detector is fused rather than a threshold. In order
of effect:

1. raise `kAccelThresholdMg` (in `config.h`) toward 4000;
2. raise `kGyroThresholdDps`;
3. increase the debounce window;
4. raise `minSpeedKmh` — a pothole at 80 km/h should still trigger, one at
   20 km/h need not;
5. if the false alarms are on *bump* sensors rather than potholes, check the
   **mounting**: a node flexing in a bracket is a motion the IMU cannot
   distinguish from a crash.

**Record every false alarm's telemetry.** A false alarm is a labelled negative
and is the most valuable data the system produces.

### Alerts but the buzzer is silent

- `buzzerEnabled` in CONFIG;
- `muteUntil` is non-zero (a night-mute is set);
- the transistor is wired wrong, or the buzzer is passive where an active one
  was assumed;
- the buzzer is on `PIN_BUZZER` (GPIO25) — **active-LOW** in this firmware, so
  the transistor is driven low to sound.

### A real crash was missed

The most important failure. Log what happened, then:

- was the impact above `kAccelThresholdMg`? A low-speed impact at 2 g will not
  be, and that is a known trade-off in the opposite direction to false alarms;
- was `vibrationRequired` on and the SW-420 failed to trip? A sensor mounted
  where the chassis absorbs the shock will not;
- did the link drop at that moment? An event raised while disconnected is lost —
  BLE has no store-and-forward. This is a genuine gap, not a bug;
- was the countdown cancelled? Someone may have hit "I'm safe" reflexively while
  reaching for the hazard lights.

---

## The app

### The alert screen will not dismiss

It is **designed** not to: `PopScope(canPop: false)` blocks the back gesture,
because a driver reaching for the hazard light must not be able to swipe away
the only thing that will call for help. Use "I'm safe" or "Send help".

If the countdown has expired and help has gone out, the app navigates onward on
its own.

### No notification when the app is backgrounded

In priority order:

1. **Notification permission** — Android 13+ requires an explicit grant.
2. **Do Not Disturb** — the alert uses `category: alarm` with
   `channelBypassDnd: true`, which should get through, but some OEMs override
   it. Check Settings → notification categories.
3. **Battery optimisation** — Android kills a backgrounded app's BLE connection
   after a few minutes unless the app is exempted. Settings → Apps → Battery →
   "Unrestricted".
4. **The app was swiped away** — a foreground-service notification is required
   for the monitoring notification to survive that.

### "Offline — N accidents waiting to upload"

Correct behaviour, not an error. The outbox is durable; it drains when
connectivity returns. The count clears on its own.

If it never clears, check `attempts` and `last_error` in the outbox table (via
`adb shell` / a debug build), and whether the device clock is right — a skewed
clock makes `next_attempt_at` comparisons wrong.

### The hospital list is empty

- no GPS fix yet — the search needs an origin;
- the bundled dataset is missing (`app/assets/data/hospitals.json`);
- the accident is > 25 km from the seed dataset (it covers Bengaluru);
- the index failed to build. `HospitalIndex.fromRaw` drops records that cannot
  be mapped and logs each one; a log full of "invalid location" means the seed
  file is malformed.

### The app will not start without Firebase

It should not. `main()` catches the initialisation failure and continues in
offline mode by design. If you are seeing a hard failure, the error is
somewhere else — check `flutter run` output.

### Numbers jitter as they update

They should not: every numeric readout uses `fontFeatures: [FontFeature
tabularFigures()]`. If a value visibly shifts, something is not going through
the app's formatters.

---

## The backend

### `PERMISSION_DENIED` on an accident write

The rules rejected it. In order of likelihood:

1. **`userId` does not match `request.auth.uid`.** The app derives the document
   from the signed-in uid; if the user was signed out and back in, the cached
   uid is stale. Reinstall or clear app data.
2. **A field failed validation** — `latitude` out of range, `status` not in the
   §18 enum, `timestamp` not a Firestore `timestamp`.
3. **An illegal state transition.** The rules only permit forward moves in §18.
   Writing `DETECTED` over a `RESOLVED` record is refused **by design**.
4. **Not authenticated.** Anonymous sign-in failed — check network.

### The composite index is missing

```
The query requires an index. You can enable automatic index creation...
```

Deploy `firestore.indexes.json`, or click the link in the error. The indexes
exist for the `accidents` history query and the `hospitals` bounding-box search.

### Emulator rules are not applied

`firebase emulators:start` loads `firestore.rules` only if it is in the
configured project. Check `firebase.json` points at the right paths, and that
the emulator is actually running (a silently-dead emulator falls back to no
rules at all, which looks like "everything is permitted").

---

## Build problems

### `Could not find a compatible version` for a dependency

A `pubspec.yaml` pin needs a newer Dart than the local SDK provides.

```bash
python3 app/tool/pin_dependencies.py app/pubspec.yaml
```

This rewrites every pin to the newest release compatible with the installed
Dart, and prints what it changed.

### `Wrong key(s) supplied` / `invalid string offset` when compiling

**A corrupted Arduino build cache.** Not a code fault — it is a known
`arduino-cli` failure mode, and it produces phantom `undefined reference`
errors for symbols that plainly exist.

```bash
arduino-cli cache clean
rm -rf ~/.cache/arduino
arduino-cli compile --fqbn esp32:esp32:esp32 --clean
```

### `golden.json` differs after regenerating

Generation is deterministic, so a diff is a **real** protocol change. Either you
changed a codec, or the constants in `docs/02-ble-protocol.md` no longer match.
The CI job in [11 — Deployment](11-deployment.md#ci) makes this a build failure
on purpose.

### A test passes locally and fails in CI

Usually a working-directory dependency. The hospital-index suite walks up to
find `backend/seed/hospitals.json` for exactly this reason; keep that pattern
rather than a fixed relative path.

---

**Previous:** [12 — API reference](12-api-reference.md) · **Back to** [the docs index](README.md)
