/// App-wide constants.
///
/// Split by concern, and every value that could drift from `docs/02-ble-protocol.md`
/// is defined **once** in the protocol layer instead (see
/// `lib/data/protocol/ble_frame.dart`), so there is exactly one source of truth
/// for the wire format. What lives here is *app policy*: timeouts, thresholds,
/// limits, identifiers.
library;

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show License;

/// Identity of this app, as it appears on the wire in `HELLO` (§6.1).
const String kAppId = 'smart-accident-alert';

/// Semver of the app, sent in `HELLO.appVersion`.
const String kAppVersion = '1.0.0';

/// Default locale for `HELLO.locale` (§6.1 shows `en-IN`).
const String kDefaultLocale = 'en-IN';

/// Size of the sqflite database file.
const String kDatabaseName = 'smart_accident_alert.db';

/// sqflite schema version. Bump + add a migration branch in
/// `LocalDataSource._onUpgrade` when this changes.
const int kDatabaseVersion = 1;

/* ------------------------------------------------------------------ BLE policy */

/// GATT service UUID advertised by the ESP32 (§2.1). Scans are filtered on this,
/// so the user never picks from a list of a hundred unknown peripherals.
const String kServiceUuid = '7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001';

/// `TX` — device → phone, notify + read. 50 Hz telemetry (§2.2).
const String kTxUuid = '7c9e0001-1e4a-4f6b-9c2d-5a1b7c30d001';

/// `RX` — phone → device, write without response + read.
const String kRxUuid = '7c9e0002-1e4a-4f6b-9c2d-5a1b7c30d001';

/// `CTRL` — device → phone, notify. Events, ACK/ERROR, STATUS (§2.2).
const String kCtrlUuid = '7c9e0003-1e4a-4f6b-9c2d-5a1b7c30d001';

/// `INFO` — device → phone, read. Static identity (§2.2).
const String kInfoUuid = '7c9e0004-1e4a-4f6b-9c2d-5a1b7c30d001';

/// The three notify-capable characteristics, with the priority the firmware
/// assigns them (§2.2). CTRL is highest priority: a congested link may lose
/// telemetry, never events.
const String kCtrlChannelName = 'ctrl';

/// GATT short name the node advertises for the 50 Hz telemetry characteristic.
const String kTxChannelName = 'tx';

/// GATT short name for the INFO characteristic (`DEVICE_INFO`, `CALIB_LOG`).
const String kInfoChannelName = 'info';

/// Requested ATT MTU (§2.3). 247 lets a 24 B telemetry record plus framing fit
/// in one notification with room to spare. Phones that refuse fall back to 23.
const int kPreferredMtu = 247;

/// Lowest MTU we will accept. Below 23 the protocol cannot carry a telemetry
/// record in a single notification, but framing still works, so we keep going.
const int kMinimumMtu = 23;

/// How long a scan runs looking for our device before we give up and tell the
/// user to check that the node is powered.
const Duration kScanTimeout = Duration(seconds: 12);

/// Connection attempt budget. ESP32 + Android in a vehicle needs headroom.
const Duration kConnectTimeout = Duration(seconds: 20);

/// Service discovery budget.
const Duration kDiscoverTimeout = Duration(seconds: 15);

/// Reconnect backoff, used with jitter by `BleService` (§25 "Bluetooth
/// disconnected": the app must recover on its own when the link returns, and
/// must not hammer the radio while the user is walking away from the car).
const List<Duration> kReconnectBackoff = <Duration>[
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
];

/// Give up auto-reconnecting after this long and surface a "press to retry"
/// button, so we are not silently reconnecting for hours.
const Duration kReconnectGiveUpAfter = Duration(minutes: 5);

/// Jitter applied to the backoff. Full jitter (0…delay) is the right choice for
/// a fleet of phones reconnecting to the same node after the same event.
const double kReconnectJitterFactor = 0.3;

/// Periodic poll interval for device STATUS frames while connected. The device
/// also pushes STATUS on demand; this is a safety net for a wedged firmware.
const Duration kStatusPollInterval = Duration(seconds: 5);

/// RSSI poll interval for the connection-strength indicator.
const Duration kRssiPollInterval = Duration(seconds: 10);

/// How long to wait for a frame we asked for before counting it as lost.
const Duration kFrameAckTimeout = Duration(milliseconds: 750);

/// Stop-and-wait attempts the *phone* makes when writing a request that expects
/// a response (mirrors the device's own retry ladder in §8, so both ends are
/// bounded).
const int kMaxWriteAttempts = 3;

/// flutter_blue_plus 2.x requires an explicit licence on `connect()`.
///
/// This repository is an academic/education prototype, so [License.nonprofit] is
/// the correct declaration. **If this app is used commercially, switch this to
/// [License.commercial] and obtain a licence** — see the plugin's LICENSE file.
/// Kept as a single constant so the switch is a one-line change, and so tests
/// never hard-code it.
const License kBleLicense = License.nonprofit;

/* -------------------------------------------------- telemetry → UI throttling */

/// Telemetry arrives at 50 Hz (§2.3). Rebuilding a widget 50 times a second is
/// both a frame-rate problem and a battery problem, so the *UI* subscribes to a
/// throttled projection of the stream instead.
///
/// 10 Hz is chosen deliberately: faster than the eye can read a changing number,
/// slower than a 60 Hz frame budget cares about. A 10 Hz update of a sparkline
/// costs ~1/6 of the layout work of 60 Hz and is visually identical.
const Duration kTelemetryUiInterval = Duration(milliseconds: 100);

/// Length of the rolling window kept for sparklines. At 10 Hz this is 30 s of
/// history, which is the right scale for "did that spike look like an impact?".
const int kTelemetryWindowSize = 300;

/// Hard cap on samples retained in the ring buffer, independent of the UI rate.
/// The feed downsamples into the window; this bounds the raw buffer.
const int kTelemetryRawBufferSize = 512;

/* ------------------------------------------------------------------ GPS policy */

/// Deadline for a fresh fix. 12 s is generous because the *first* fix of a cold
/// start can be slow; subsequent fixes use the shorter "refine" deadline.
const Duration kGpsFixTimeout = Duration(seconds: 12);

/// Deadline for refining a position we already displayed (we always show
/// last-known first, so refinement is an improvement, not a blocker).
const Duration kGpsRefineTimeout = Duration(seconds: 6);

/// A fix older than this is stale: we still show it, but labelled as such,
/// because during an accident "position from 4 minutes ago" is misleading.
const Duration kGpsStaleAfter = Duration(minutes: 2);

/// Default accuracy for a hospital search (§16). 25 km covers a city; the
/// hospital list is not useful beyond that and a huge radius would make the
/// spatial index scan the whole dataset.
const double kDefaultHospitalRadiusKm = 25;

/// Maximum hospitals returned. The UI shows a list, not a map of 4000 pins.
const int kMaxHospitals = 20;

/* ------------------------------------------------------------- outbox / network */

/// §25 "Internet unavailable": retry the outbox with exponential backoff. These
/// are the base delays; the actual delay is base x 2^attempts with jitter,
/// capped at [kOutboxMaxBackoff].
const List<Duration> kOutboxBackoff = <Duration>[
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 45),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 15),
];

/// Ceiling for the computed outbox delay. After 30 minutes of no connectivity
/// something else is wrong, and continuing to grow the delay just means the
/// record is never uploaded.
const Duration kOutboxMaxBackoff = Duration(minutes: 30);

/// Give up on a queued record after this long and surface it in the UI as
/// "not uploaded" rather than retrying silently forever. The local record is
/// never deleted (§26: the accident happened whether or not the cloud knows).
const int kOutboxMaxAttempts = 12;

/// How often the outbox drains when connectivity returns.
const Duration kOutboxDrainInterval = Duration(seconds: 20);

/* --------------------------------------------------------------- notifications */

/// Android notification channel ids (§8 uses importance/criticality to decide
/// whether the app may show a heads-up).
const String kChannelMonitoring = 'saas_monitoring';

/// Android notification channel id for the full-screen emergency alert.
const String kChannelAlert = 'saas_alert_critical';

/// Android notification channel id for low-priority informational notices.
const String kChannelInfo = 'saas_info';

/// Notification ids. Stable, so a re-notification replaces rather than stacks.
const int kNotificationAccident = 1001;

/// Id of the foreground "monitoring" notification.
const int kNotificationMonitoring = 1002;

/// Id of the cancel-countdown notification, updated in place once per second.
const int kNotificationCountdown = 1003;

/// Id of the "alert resolved" notification shown once dispatch completes.
const int kNotificationResolved = 1004;

/* ------------------------------------------------------------------- emergency */

/// Default cancel window (§6.6 `confirmWindowSec`, §12 Screen 3: 10 seconds).
const int kDefaultConfirmWindowSeconds = 10;

/// §12 Screen 3. Used when the device does not report a window.
const Duration kFallbackConfirmWindow = Duration(seconds: 10);

/// How long the emergency SMS composer stays open / how long we wait for the
/// user to return before considering the dispatch abandoned.
const Duration kSmsLaunchTimeout = Duration(seconds: 30);

/// De-duplication window for device events, keyed by `(eventId, type)`.
/// §8: events are re-sent up to 3 times, and retransmission must be idempotent.
const Duration kEventDedupWindow = Duration(minutes: 10);

/* ---------------------------------------------------------------------- health */

/// Below this the phone warns about its own battery (§25 "Phone battery low").
/// 20 % is roughly 20 minutes of navigation with BLE scanning — enough to get
/// somewhere and make a call.
const int kLowPhoneBatteryPercent = 20;

/// Below this the *device* battery is surfaced as a warning, because a
/// disconnected node cannot detect anything.
const int kLowDeviceBatteryPercent = 15;

/// Link quality thresholds in dBm. -59 is "good", -75 is "poor" — the standard
/// thresholds from BLE literature, good enough for a 3-state indicator.
const int kRssiExcellent = -55;

/// RSSI in dBm at or above which the link is considered good.
const int kRssiGood = -67;

/// RSSI in dBm at or below which the link is considered poor.
const int kRssiPoor = -80;

/* ------------------------------------------------------------------- simulator */

/// Device id used by the fake BLE transport so the fake and the real transport
/// are indistinguishable above the transport boundary.
const String kSimulatedDeviceId = 'sim:SAAS-A1B2C3D4';

/// Default simulated telemetry rate.
const int kSimulatedTelemetryHz = 50;
