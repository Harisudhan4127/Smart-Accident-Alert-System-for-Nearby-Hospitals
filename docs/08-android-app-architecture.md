# 08 — The App

The Flutter application. One codebase, **Android and iOS**.

- [Why Flutter](#why-flutter)
- [Layering](#layering)
- [The offline-first outbox](#the-offline-first-outbox-the-most-important-path-in-the-app)
- [Handling 50 Hz without melting](#handling-50-hz-without-melting)
- [The hospital index](#the-hospital-index)
- [Notifications: the only thing that wakes the phone](#notifications-the-only-thing-that-wakes-the-phone)
- [Routing](#routing)
- [Running without hardware](#running-without-hardware)
- [Provider reference](#provider-reference)

---

## Why Flutter

The system is one codebase that must target **both** Android and iOS. The
alternatives:

| Option | Verdict |
| --- | --- |
| Native Android (Kotlin) + native iOS (Swift) | Two implementations of the BLE state machine, the protocol codec and the outbox. The codec especially is a liability: a divergence between the two is a bug that only reproduces on one platform. |
| React Native | Closer to one codebase, but the BLE and notification modules are thin wrappers whose APIs still differ per platform, and the BLE path here is performance-sensitive enough to want direct control. |
| **Flutter** | One Dart implementation of everything below `main()`. Renders natively, so 60 fps on both. Hot reload, which materially shortens the BLE integration loop. |

The cost is honest and worth stating: BLE, location and notifications all reach
native code through **platform channels**, so the app is not "pure Dart". The
mitigation is that every plugin is confined to one file in `data/datasources/`
or `data/ble/`, behind an interface the rest of the app depends on. A plugin
upgrade is a one-file change with a compiler to check it.

---

## Layering

```
   lib/
   ├── core/                     no domain knowledge
   │   ├── theme/                design system (ThemeExtension tokens)
   │   ├── router/               go_router config
   │   ├── di/                   Riverpod providers
   │   ├── result.dart           Result<T> / Failure / FailureKind
   │   ├── formatters.dart       all user-facing formatting
   │   └── logger.dart           the only place that writes logs
   │
   ├── domain/entities/          pure Dart — no Flutter, no plugins
   │   ├── geo_point.dart  hospital.dart  accident.dart
   │   └── telemetry.dart  paired_device.dart  user_profile.dart
   │
   ├── data/
   │   ├── protocol/             the frozen wire codec
   │   ├── ble/                  transport + in-memory ESP32 simulator
   │   ├── datasources/          location, firestore, sqlite, sms, notifications
   │   ├── hospital/             spatial index + isolate worker
   │   ├── mappers/              JSON ↔ entity
   │   └── repositories/         orchestration
   │
   ├── features/<screen>/        one folder per screen
   │   └── <name>_state.dart     the screen's Notifier, when it has state
   │
   └── widgets/ui_kit.dart       shared components
```

Two rules, and breaking either causes real problems:

**`domain/` imports nothing.** Not `package:flutter`, not a plugin. That is what
makes the entities testable in isolation and keeps the protocol and detection
logic portable to a test harness or a future server-side implementation.

**`data/` never imports `features/`.** Data flows one way. The reverse edge is
how a repository ends up knowing what a widget wants, and then a different
screen cannot reuse it.

### Why `Result<T>` and not exceptions

`core/result.dart` exists because PROJECT_PLAN §25 lists five failure modes that
must be *rendered*: BLE disconnected, GPS unavailable, internet unavailable,
low battery, false alarm. An exception is swallowed by the nearest `catch` and
becomes a red screen; a `Result` makes the failure part of the signature, so
`Future<Result<GeoPoint?>>` tells the caller at the call site that this can
fail, and that a `null` here means "no fix", not "bug".

```dart
// Wrong: the caller cannot tell this can fail.
Future<GeoPoint> currentPosition();

// Right: failure is in the type, and the switch is exhaustive.
Future<Result<GeoPoint?>> currentPosition();
```

`FailureKind` is a closed enum, so a UI that switches over it is *checked* to
have handled every failure mode. Adding a case there is a compile error in every
screen that renders it — which is the point.

`FailureKind.protocol` is worth singling out. It means the firmware and the app
disagree about the wire format, and it is deliberately **not** marked
`retryable`. §8's stop-and-wait retries on top of a schema mismatch is how an
alert gets silently lost, so the UI must offer "update the node" instead of a
Retry button that cannot work.

---

## The offline-first outbox: the most important path in the app

`AccidentRepository.recordAccident` has exactly one ordering rule:

```dart
1. build the record              (in memory)
2. write to sqflite              ← durable, instant, UNCONDITIONAL
3. attempt Firestore             ← may fail; retried later
```

and it **returns as soon as step 2 completes**. Step 3 is fire-and-forget.

This ordering is the whole design. An accident detected in a tunnel, a
basement car park or a rural area with no signal must still exist on the phone,
because it is the only copy anyone will ever have. Attempting the network call
first would mean the record exists only if the network cooperated — losing
precisely the accidents that happen where there is no coverage.

The outbox table:

```sql
CREATE TABLE outbox (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  accident_id     TEXT    NOT NULL UNIQUE,   -- ← idempotence
  payload         TEXT    NOT NULL,          -- the Firestore doc, pre-encoded
  created_at      INTEGER NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_error      TEXT
);
CREATE INDEX idx_outbox_due ON outbox(next_attempt_at);
```

### Why SQLite and not SharedPreferences

SharedPreferences is one blob with no queries, no indexes and no atomic
multi-row write. The drain query is *"the 20 oldest rows due for retry,
ordered by `next_attempt_at`"* — an `ORDER BY` + `LIMIT` over an index, run on
every reconnect. In SharedPreferences that means deserialising the whole queue,
sorting it in Dart and writing it all back, every time. SQLite does it in the
engine in O(log n + k). It is also crash-safe: a process death mid-write cannot
leave a half-written row that then retries forever.

### Why `UNIQUE(accident_id)`

The protocol **retransmits events** until acknowledged (§8), and the outbox
retries, so the same accident arrives many times. `INSERT OR IGNORE` on a unique
accident id makes a duplicate submission a no-op. Without it, one flaky BLE link
would create three Firestore documents for one crash.

### Backoff

`5s → 10s → 20s → … → 5min` (capped), with `attempts` persisted so the schedule
survives a restart. The **ceiling matters**: an unbounded backoff on a long
outage means the app reconnects to the network and then sits silent for an hour,
which for an emergency log is unacceptable. The floor keeps a transient blip
from becoming a permanent loss.

Draining stops at the **first** failure, so a genuinely offline device does not
burn its battery attempting 20 doomed uploads.

### Status transitions are written back into the queue

When an accident is cancelled or resolved, the updated status is rewritten into
the queued payload *and* pushed to Firestore. Without this, an accident uploaded
*after* it was resolved would carry `DETECTED` — resurrecting a closed incident
in the cloud. For an emergency system that is a genuinely alarming failure mode,
not a cosmetic one.

---

## Handling 50 Hz without melting

Telemetry arrives 50 times a second. Rebuilding a dashboard at that rate would
compete with the alert screen's countdown for the UI thread, so a driver
glancing at the dashboard while an alert is running would see it stutter.

Two mechanisms, in `features/home/home_state.dart`:

**1. Separate streams by importance.** `DeviceRepository` exposes `telemetry`
(50 Hz, lossy by design) and `messages` (rare, must not be dropped) separately.
Conflating them would force every consumer to either rebuild at 50 Hz or drop
events.

**2. A coalescing sampler.** `TelemetrySampler` keeps exactly **one** sample and
publishes it on a timer:

```dart
final key = '${(sample.magMg / 1000).toStringAsFixed(2)}|'
    '${(sample.accZ / 1000).toStringAsFixed(2)}|'
    '${(sample.peakMg / 1000).toStringAsFixed(1)}|'
    '${sample.flags.sw420}|${sample.state.byte}|'
    '${sample.batteryPctOrNull}';

if (key == _lastPublishedKey) return;   // nothing on screen would change
```

Three properties make it cheap:

- holds one sample, not a queue → O(1) memory;
- publishes at a fixed low rate regardless of input rate → O(rate), not O(input);
- compares the **rounded display values** → at rest, which is most of a drive,
  the numbers barely move, so nearly every sample is suppressed.

Output is 4 Hz, which is the point where a value changing by ~0.05 g per tick
still looks smooth. Faster is invisible; slower looks choppy.

### Backpressure

```dart
if (_telemetry.hasListener) {
  _telemetry.add(record);
} else {
  _backpressureDrops++;
}
```

A broadcast controller with no listener buffers. If a consumer is slow, the
sample is **dropped** rather than queued. Telemetry is the one thing in this
system that is safe to lose, and an unbounded queue would eventually take the
app down.

---

## The hospital index

Documented in [05-hospital-search.md](05-hospital-search.md). The app-side
summary:

- `HospitalIndex` buckets hospitals into a 0.02° (~2.2 km) grid at build time.
  A query finds the overlapping cell window in **O(1)** and touches only the
  hospitals actually inside the radius — **O(k)**, not O(N).
- Ranking filters on **distance** (that is what a radius means) and orders on
  `Hospital.searchScore`, which is *higher-is-better* and rewards emergency
  capability. Conflating the two was a real bug caught by the brute-force test.
- Ties are broken by `id`, so the same query returns the same order every time.
  The score saturates beyond 5 km, so exact ties are common.
- `HospitalSearchWorker` runs the query on a **worker isolate** when the dataset
  is large enough to be worth it. The index is transferred **once** as a
  `TransferableTypedData` blob; each query sends only the origin, radius and
  limit.

Measured on the 320-record seed dataset, after JIT warm-up:

```
~160 µs per 25 km query   (~6 200 queries/sec)
```

The correctness guarantee matters more than the speed. The test suite compares
every index result against a naive full scan at 76 query/radius combinations,
including the poles and the antimeridian. That comparison found three real bugs
(score inversion, non-deterministic ties, a serialisation bug that wrote string
lengths but no string bytes).

---

## Notifications: the only thing that wakes the phone

If the app is backgrounded at the moment of a crash, **the local notification is
the only thing that can wake the screen.** If it does not fire, the entire
system fails silently. It is therefore treated as the critical path.

```dart
AndroidNotificationDetails(
  'saas_emergency', 'Emergency alerts',
  category: AndroidNotificationCategory.alarm,   // ← the load-bearing line
  fullScreenIntent: true,
  channelBypassDnd: true,
  playSound: true,
  enableVibration: true,
  visibility: NotificationVisibility.public,
  actions: [ 'I\'m safe', 'Send help' ],
)
```

`category: alarm` is what matters. Android grants a full-screen intent — and the
right to bypass Do Not Disturb — **only** to `ALARM` and `CALL` categories.
Without it the alert sits silently in the shade, which for this app is
indistinguishable from not firing at all.

The second always-on notification ("Monitoring active", low importance, silent)
is what keeps Android from killing the app's BLE connection in the background.
Android grants a foreground-service notification for exactly this.

### Notification actions route to the same place as the buttons

Tapping "I'm safe" on the lock screen calls `AlertController.dismiss()` — the
identical code path as the in-app button. Two paths to the same behaviour that
can diverge is how a user ends up unable to cancel a real alert.

---

## Routing

`go_router` with named routes and a fullscreen-dialog route for the emergency
alert (`core/router/app_router.dart`).

The alert is registered as a **root-level** route, not a child of `home`,
because a crash can be detected before the app has finished setting up — during
the splash, or during pairing.

It sets `PopScope(canPop: false)`, which blocks both the system back button and
the back gesture. A driver reaching for the hazard light must not be able to
swipe away the only thing that will call for help. The only exits are the two
buttons.

An unknown route renders a quiet explanation and a button back to the dashboard,
**not** a red error screen. A safety app must never look like it has crashed,
least of all at the moment it matters.

---

## Running without hardware

`FakeBleTransport` implements the same `BleTransport` interface as the real one
and is a **complete in-memory ESP32**: real protocol frames, a real state
machine, and synthetic telemetry that distinguishes the cases that matter —

| Scenario | Behaviour |
| --- | --- |
| `normalDrive` | ~1 g on Z, engine vibration, gentle noise. No alert. |
| `potholes` | Sharp fast spikes with a short ring-down. **Deliberately does not alert** — a fused detector must reject these, and a simulator that alarmed on every spike would teach the wrong lesson. |
| `crash` | Hard spike → free-fall → attitude change, with SW-420. Alerts exactly once. |
| `sensorFault` | The ADXL345 stops answering, or freezes on one value; the node reports `FAULT`. |

```bash
cd app
flutter run --dart-define=DEMO=true
```

The substitution happens in exactly one place — `effectiveBleTransportProvider`
in `core/di/providers.dart` — so no other file knows whether it is talking to
hardware or a simulator.

`FakeLocationDatasource` does the same for GPS, with a scripted position so a
test can assert *"the hospital list at these coordinates is exactly these
three"* rather than a fuzzy assertion.

---

## Provider reference

Everything is constructed in `core/di/providers.dart` and overridable, which is
what makes the whole app testable with no hardware.

### Datasources

| Provider | Type | Notes |
| --- | --- | --- |
| `bleTransportProvider` | `Provider<BleTransport>` | Real hardware |
| `locationDatasourceProvider` | `Provider<LocationDatasource>` | geolocator |
| `localDatasourceProvider` | `Provider<LocalDatasource>` | sqflite outbox |
| `firestoreDatasourceProvider` | `Provider<FirestoreDatasource>` | Cloud |
| `mapsDatasourceProvider` | `Provider<MapsDatasource>` | `url_launcher` |
| `notificationDatasourceProvider` | `Provider<NotificationDatasource>` | Local + system |
| `sharedPreferencesProvider` | `FutureProvider<SharedPreferences>` | Settings |
| `isOnlineProvider` | `StreamProvider<bool>` | A **hint** only; the real signal is the write attempt |

`isOnlineProvider` is deliberately not trusted. A phone can report "connected"
to a captive portal that cannot reach Firestore, so the outbox retry scheduler
uses it only to try *sooner*.

### Repositories

| Provider | Exposes |
| --- | --- |
| `deviceRepositoryProvider` | `telemetry`, `messages`, `linkState`, `device`, `telemetryStats`; `connect`, `sayHello`, `sendConfig`, `command`, `confirm`, `cancel`, `testAlert`, `calibrate` |
| `accidentRepositoryProvider` | `alerts`, `pendingUploadCount`, `current`; `recordAccident`, `confirm`, `cancel`, `syncOutbox` |
| `hospitalRepositoryProvider` | `index`, `source`; `load`, `loadSummary`, `nearby` |
| `contactRepositoryProvider` | `profile`, `callableContacts`; `addContact`, `removeContact` |
| `settingsRepositoryProvider` | `isOnboarded`, `deviceId`, `themeMode` |

### Effective (demo-aware)

| Provider | Behaviour |
| --- | --- |
| `effectiveBleTransportProvider` | `FakeBleTransport` when `DEMO=true` |
| `effectiveLocationProvider` | `FakeLocationDatasource` when `DEMO=true` |

### Feature state

| Provider | Screen |
| --- | --- |
| `splashControllerProvider` | Boot checks |
| `homeStateProvider` | Dashboard (owns the 50 Hz → 4 Hz sampler) |
| `alertControllerProvider` | **The emergency flow** |
| `locationViewProvider` | Location |
| `hospitalsViewProvider` | Hospital list |
| `contactsViewProvider` | Contacts |
| `historyViewProvider` | History |
| `settingsViewProvider` | Settings + diagnostics |
| `pairingViewProvider` | BLE pairing |

---

## The alert controller

`features/alerts/alert_controller.dart` owns the entire emergency sequence and
exposes one immutable `AlertState`. Putting the orchestration in a controller
rather than the widget means it is testable without a single `Widget`, and means
the screen cannot accidentally skip a step.

`begin()` runs, in order:

1. **record the accident** — durable and offline, independent of everything
   below. A failure in GPS, hospitals or contacts must not prevent the record
   from existing.
2. **fire the system notification** — so a backgrounded phone wakes up.
3. **in parallel:** load contacts, search hospitals, and collect any *problems*.

Nothing in step 3 may block the countdown.

`AlertState.problems` is a list, not a single error, because several things can
be wrong at once (no GPS **and** no network **and** no contacts), and a user
fixing them one at a time by dismissing each error is a poor experience during
an emergency.

### Why the app never hard-codes coordinates

`MapsDatasource.mapsUrl` builds
`https://www.google.com/maps/search/?api=1&query=LAT,LON` from the live fix at
6 decimal places (~0.11 m). §15 forbids hard-coding them, and this is the only
place they are formatted — which is also why the whole §20 message format is a
pure function and therefore unit-testable on a machine with no phone.

### A note on a placeholder coordinate

When there is no GPS fix, the record is written with `(0, 0)` and an accuracy of
`999999`. A zero coordinate is in the Gulf of Guinea and would read as a real
location; an explicitly absurd accuracy marks it as "location unknown" for
anything that filters on quality, and the fact travels with the record instead
of being lost.

---

## Next

- [09 — Security and privacy](09-security-and-privacy.md)
- [10 — Testing](10-testing.md)
- [11 — Deployment](11-deployment.md)
