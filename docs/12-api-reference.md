# 12 — API reference

The interfaces other code depends on. Anything not listed here is an
implementation detail and may change.

- [The wire protocol](#the-wire-protocol)
- [Repository APIs](#repository-apis)
- [Datasource interfaces](#datasource-interfaces)
- [Provider surface](#provider-surface)
- [Firestore schema](#firestore-schema)
- [Cloud Functions](#cloud-functions)
- [Detection thresholds](#detection-thresholds)

For the wire format in full, see [02 — BLE protocol](02-ble-protocol.md). For
Firestore, see [04 — Firestore schema](04-firestore-schema.md).

---

## The wire protocol

Frozen. **Changing any of it requires updating the document, all three codec
implementations, and regenerating `golden.json`.**

| Constant | Value | Where |
| --- | --- | --- |
| Service UUID | `7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001` | `kServiceUuid` |
| `TX` (notify) | `…0001-…` | `AppBleChannel.tx` |
| `RX` (write) | `…0002-…` | `AppBleChannel.rx` |
| `CTRL` (notify) | `…0003-…` | `AppBleChannel.ctrl` |
| `INFO` (read) | `…0004-…` | `AppBleChannel.info` |
| Protocol version | `1` | `kProtocolVersion` |
| Preferred MTU | `247` | `kPreferredMtu` |
| Max payload | `512` B | `MAX_PAYLOAD` |
| Telemetry record | `24` B | `TELEMETRY_SIZE` |
| CRC | CRC-16/CCITT-FALSE, LE | `crc16` |

### Message types

| Code | Name | Dir | Payload |
| --- | --- | --- | --- |
| `0x01` | `HELLO` | phone → node | JSON |
| `0x02` | `PING` | phone → node | JSON |
| `0x04` | `CONFIG` | phone → node | JSON patch (absent keys are unchanged) |
| `0x05` | `CALIBRATE` | phone → node | JSON |
| `0x06` | `COMMAND` | phone → node | JSON |
| `0x07` | `ACK` | node → phone | JSON |
| `0x08` | `ERROR` | node → phone | JSON |
| `0x09` | `EVENT` | node → phone | JSON |
| `0x10` | `TELEMETRY` | node → phone | **binary 18 B** |
| `0x11` | `STATUS` | node → phone | JSON |
| `0x12` | `HELLO_ACK` | node → phone | JSON |
| `0x13` | `CALIB_LOG` | node → phone | JSON |
| `0x14` | `DIAG` | node → phone | JSON |
| `0x20` | `DEVICE_INFO` | node → phone | JSON |

### Codecs

| Language | Entry points |
| --- | --- |
| C++ | `protocol.h` — `FrameScanner`, `crc16`, `TelemetryCodec` |
| Dart | `ble_frame.dart` — `FrameScanner`, `encodeFrame`, `MessageCodec`, `BleFrameView` |
| JavaScript | `tools/protocol/codec.js` — `FrameScanner`, `encodeFrame`, `encodeTelemetry` |

The Dart hot path avoids allocation:

```dart
scanner.scan(chunk, (BleFrameView view) { /* no copy */ return true; });
```

`scanToList` exists for tests and cold paths, and is documented as allocating
one frame plus one payload copy per frame.

---

## Repository APIs

### `DeviceRepository`

```dart
// Streams — high frequency and loss-critical are separate, on purpose.
Stream<TelemetryRecord> get telemetry;        // 50 Hz, lossy by design
Stream<DeviceUpdate>    get messages;          // rare, must not drop
Stream<DeviceLinkState> get linkState;
Stream<PairedDevice>   get device;
TelemetryStats          get telemetryStats;
PairedDevice?          get snapshot;
DeviceLinkState        get linkStatus;
bool                   get isIncompatible;

// Lifecycle
Future<Result<BlePeripheral>> connect(String id);
void onLinkLost([String? reason]);            // triggers backoff reconnect
Future<void> disconnect();
Future<void> dispose();

// Outbound
Future<Result<void>> sayHello({String appVersion, String deviceName});
Future<Result<void>> ping();
Future<Result<void>> sendConfig(ConfigPatch patch);
Future<Result<void>> calibrate({int durationMs, CalibrationKind kind});
Future<Result<void>> command(CommandOp op, {String? eventId, int? untilUnixS});
Future<Result<void>> confirm(String? eventId);
Future<Result<void>> cancel(String? eventId);
Future<Result<void>> testAlert();
Future<Result<DeviceInfoMessage?>> readInfo();
```

Events are acknowledged automatically (§8 stop-and-wait), which is why callers
do not need to.

### `AccidentRepository`

```dart
Stream<PendingAlert> get alerts;
Stream<int>          get pendingUploadCount;
AccidentRecord?      get current;
Set<String>          get seenEventIds;       // (eventId, type) de-duplication

/// Local write first, always. Returns as soon as the record is durable.
Future<Result<AccidentRecord>> recordAccident({
  required GeoPoint location,
  AccidentSource source,
  String? deviceId,
  double impactG,
  int? impactScore,
  int confirmWindowSec,
  String? eventId,
});

Future<Result<AccidentRecord>> confirm();
Future<Result<AccidentRecord>> cancel();
Future<Result<AccidentRecord>> markAlertSent();
Future<Result<AccidentRecord>> transition(AccidentStatus status);
Future<Result<AccidentRecord>> notifyContact(EmergencyContact contact);
List<EmergencyContact>        pendingContacts(List<EmergencyContact> all);

/// Drains the outbox. Bounded to 20; stops at the first failure.
Future<Result<int>> syncOutbox();
Stream<List<AccidentRecord>>  watchHistory({int limit});
```

`recordAccident` returning a `FailureKind.storage` means the record exists
**nowhere** — that is a severe condition, not a retryable one.

### `HospitalRepository`

```dart
HospitalIndex?     get index;
HospitalSource?    get source;          // bundled | cache | cloud | none
DateTime?          get loadedAt;

Future<Result<HospitalIndex>>       load({bool preferCloud = true});
Future<Result<HospitalLoadSummary>> loadSummary({bool preferCloud = true});
Future<Result<HospitalSearchResult>> nearby({
  required GeoPoint origin,
  double radiusM,      // default 25000
  int limit,           // default 20
});
Future<Result<void>> cacheFromCloud(List<Hospital> hospitals);
```

`load` falls through **cloud → local cache → bundled**, and only fails if all
three are unavailable. An empty hospital list during an emergency is the worst
possible outcome, so the bundled set is better than nothing.

### `HospitalIndex`

```dart
factory HospitalIndex.fromIterable(Iterable<Hospital>, {double cellSizeDeg});
factory HospitalIndex.fromRaw(List<Map<String, Object?>>, {double cellSizeDeg});

/// Filter on distance, rank on score, tie-break on id — O(1) + O(k).
List<Hospital> nearby(GeoPoint origin, {double radiusM, int limit});
```

Complexity: **O(1)** to find the cell window, **O(k)** to visit the candidates
inside it, **O(k)** to rank (bounded insertion list, not a sort). See
[05 — Hospital search](05-hospital-search.md).

### `ContactRepository` / `SettingsRepository`

```dart
// ContactRepository
UserProfile?  get profile;
Stream<UserProfile?> get profileStream;
List<EmergencyContact> get callableContacts;
Future<Result<UserProfile?>> load();
Future<Result<UserProfile>>   addContact(EmergencyContact);
Future<Result<UserProfile>>   removeContact(String id);
Future<Result<UserProfile>>   save(UserProfile);

// SettingsRepository
Future<bool>   isOnboarded();  Future<void> setOnboarded(bool);
Future<String> themeMode();     Future<void> setThemeMode(String);
Future<String?> deviceId();     Future<void> setDeviceId(String?);
Future<String>  deviceLabel();  Future<void> setDeviceLabel(String);
Future<int>     confirmWindowSec();
```

`addContact` **replaces** rather than appends on an id collision, so editing a
contact cannot create a duplicate.

---

## Datasource interfaces

Every one has a fake, so the whole app is testable with no hardware and no
network.

| Interface | Production | Test double |
| --- | --- | --- |
| `BleTransport` | `BleService` | `FakeBleTransport` |
| `LocationDatasource` | `GeolocatorDatasource` | `FakeLocationDatasource` |
| `LocalDatasource` | `SqfliteDatasource` | `InMemoryLocalDatasource` |
| `FirestoreDatasource` | `FirestoreDatasourceImpl` | — |
| `MapsDatasource` | `UrlLauncherMapsDatasource` | `RecordingMapsDatasource` |
| `NotificationDatasource` | `LocalNotificationDatasource` | `RecordingNotificationDatasource` |

The recording fakes capture their inputs, so a test can assert *"the SMS body
contained these coordinates and this maps link"* without a platform channel.

`InMemoryLocalDatasource` implements the same semantics as the sqflite one —
including the `UNIQUE(accident_id)` de-duplication and the backoff schedule — so
a test that passes there is testing the real ordering guarantees.

---

## Provider surface

See [08 — The App](08-android-app-architecture.md#provider-reference) for the
full table. The ones worth knowing:

```dart
// Swap in the simulator and the whole app follows.
ProviderScope(
  overrides: [
    bleTransportProvider.overrideWithValue(fakeBle),
    locationDatasourceProvider.overrideWithValue(fakeLocation),
    localDatasourceProvider.overrideWithValue(InMemoryLocalDatasource()),
  ],
  child: const SaasApp(),
)
```

`effectiveBleTransportProvider` / `effectiveLocationProvider` are the single
substitution point for `DEMO=true`.

---

## Firestore schema

Full detail in [04 — Firestore schema](04-firestore-schema.md).

```
users/{userId}
  name, phone, vehicleNumber
  emergencyContacts[] { id, name, phone, relationship? }

accidents/{accidentId}
  userId, latitude, longitude, accuracy, timestamp,
  impactValue, status, deviceId
  impactG?, impactScore?, detectedDeviceState?
  hospitalId?, hospitalName?
  notifiedContactIds[]        ← ids, not contact objects
  confirmedAt?, alertSentAt?, resolvedAt?, cancelledAt?
  uploadedAt                  ← server timestamp

hospitals/{hospitalId}
  name, address, latitude, longitude, phone
  type?, beds?, emergency, rating?

responders/{uid}
  incidentIds[]
```

Coordinates are **separate scalars**, not a Firestore `GeoPoint`: a native
GeoPoint does not participate in composite indexes, so it would make "hospitals
near this accident" an unindexable collection scan.

`notifiedContactIds` stores ids rather than contact objects so a leaked
accident record leaks no third party's phone number.

### Status values

`DETECTED` · `CANCELLED` · `CONFIRMED` · `ALERT_SENT` · `RESOLVED`

Legal transitions (enforced in the security rules, not only in the app):

```
DETECTED  → CANCELLED | CONFIRMED | RESOLVED
CONFIRMED → ALERT_SENT | RESOLVED
ALERT_SENT → RESOLVED
RESOLVED  → RESOLVED
```

---

## Cloud Functions

`backend/functions/src/index.ts`

| Function | Type | Purpose |
| --- | --- | --- |
| `dispatchAccident` | callable | Validates an incoming accident, attaches a **server** timestamp, and returns candidate hospitals ranked by a geohash bounding-box prefilter plus precise distance |
| `nearbyHospitals` | HTTP | Same search for non-Firebase clients, with CORS, input validation and rate limiting |

**Server truth overrides client claims.** `timestamp` and `uploadedAt` come from
the server, not the device, so a phone with a wrong clock cannot forge arrival
order.

> **Being in this list does not mean a hospital was notified.** There is no
> hospital notification path in this prototype. §16 and §27 of the plan are
> explicit about this, and neither the app nor the API overclaims.

---

## Detection thresholds

`firmware/SmartAccidentAlert/config.h`. **Unvalidated defaults** — see
[06 — Accident detection](06-accident-detection.md#tuning-procedure).

| Constant | Default | Bounds |
| --- | --- | --- |
| `kAccelThresholdMg` | 3000 | 1500–8000 |
| `kDebounceMs` | 60 | 20–500 |
| `kConfirmWindowSec` | 10 | 5–120 |
| `kMinSpeedKmh` | 5.0 | 0–60 |
| `kDetectorGain` | 1.0 | 0.5–3.0 |
| `kSensorRateHz` | 50 | 5–100 |

Out-of-range values are **clamped, not rejected**, and the clamped result comes
back in `STATUS.effectiveConfig` — a settings slider that silently fails is
worse than one that clamps visibly.

---

**Previous:** [11 — Deployment](11-deployment.md) · **Next:** [13 — Troubleshooting](13-troubleshooting.md)
