/// The BLE boundary the whole app is written against.
///
/// **Why an interface at all.** Two reasons, and the second is the important
/// one.
///
/// 1. It keeps `flutter_blue_plus` — a plugin with a documented history of
///    platform-channel breaking changes between major versions — behind exactly
///    one file. A plugin bump touches [BleService] and nothing else.
///
/// 2. It lets the entire application run with **no hardware**. [FakeBleTransport]
///    implements this same interface and synthesises a plausible driving
///    scenario, so the UI, the detectors, the hospital search, the offline
///    outbox and the whole emergency flow are all developable, demonstrable and
///    CI-testable on a laptop. For a project whose central claim is "this
///    detects a crash and pages a human", being able to *rehearse* that end to
///    end without a car is worth a lot.
///
/// The interface is deliberately shaped around *this app's* needs (notify per
/// channel, MTU negotiation, RSSI) rather than being a general BLE wrapper.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The GATT characteristics defined in `docs/02-ble-protocol.md` §2.1.
///
/// The values are duplicated from the protocol doc rather than imported,
/// because the protocol document is the contract and this is a copy of it. The
/// conformance test in `app/test/protocol/` asserts these four UUIDs still match
/// the committed `golden.json`, so drift is a test failure rather than a
/// mystery disconnect in the field.
enum AppBleChannel {
  /// Device → phone, 50 Hz telemetry. Best-effort; safe to drop when congested.
  tx('TX', '7c9e0001-1e4a-4f6b-9c2d-5a1b7c30d001'),

  /// Phone → device, commands and configuration.
  rx('RX', '7c9e0002-1e4a-4f6b-9c2d-5a1b7c30d001'),

  /// Device → phone, **events**. Highest priority; retried until acknowledged.
  ctrl('CTRL', '7c9e0003-1e4a-4f6b-9c2d-5a1b7c30d001'),

  /// Device → phone, static identity. Read once on connect.
  info('INFO', '7c9e0004-1e4a-4f6b-9c2d-5a1b7c30d001');

  const AppBleChannel(this.wireName, this.uuid);

  /// Short name as used in the protocol document.
  final String wireName;

  /// The 128-bit characteristic UUID.
  final String uuid;

  /// Whether the *device* notifies on this channel.
  bool get isNotify => this != AppBleChannel.rx;

  /// Whether the *phone* writes on this channel.
  bool get isWritable => this == AppBleChannel.rx;

  @override
  String toString() => 'AppBleChannel.$wireName';
}

/// The primary GATT service UUID (`docs/02-ble-protocol.md` §2.1).
const String kServiceUuid = '7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001';

/// The MTU requested per §2.3. 247 lets a 32-byte telemetry frame ride alone in
/// one notification, which is what keeps 50 Hz off the radio's back.
const int kPreferredMtu = 247;

/// Adapter-level state.
///
/// Collapses Android's `BluetoothAdapterState` and iOS's `CBManagerState` into
/// one enum so the UI never branches on `Platform.isAndroid`. The five states are
/// the union of the two platforms' *actionable* states — anything finer is not
/// something a user can act on from inside this app.
enum BleAdapterStatus {
  /// Bluetooth hardware is present and usable.
  ready,

  /// The radio is switched off. Actionable: send the user to system settings.
  poweredOff,

  /// The OS has not granted the app a Bluetooth permission.
  unauthorized,

  /// No Bluetooth hardware on this device.
  unsupported,

  /// Transient/unknown. Treated as "not ready", retried.
  unknown;

  /// Whether a scan or connect can be attempted at all.
  bool get isUsable => this == BleAdapterStatus.ready;

  /// Whether retrying later is worthwhile.
  bool get isTransient =>
      this == BleAdapterStatus.unknown || this == BleAdapterStatus.poweredOff;

  static BleAdapterStatus fromName(String? name) => switch (name) {
        'ready' || 'on' || 'poweredOn' => BleAdapterStatus.ready,
        'poweredOff' || 'off' => BleAdapterStatus.poweredOff,
        'unauthorized' || 'unsupported' || 'resetting' => BleAdapterStatus.unknown,
        _ => BleAdapterStatus.unknown,
      };
}

/// Link state of a single peripheral.
enum BleLinkState {
  /// Discovered, not connected.
  discovered,

  /// A GATT connection is being established.
  connecting,

  /// Connected: notifications are flowing.
  connected,

  /// The link dropped. Reconnection may be scheduled.
  disconnected,
}

/// A peripheral discovered during a scan.
@immutable
class BlePeripheralInfo {
  const BlePeripheralInfo({
    required this.id,
    required this.name,
    required this.rssi,
    required this.connects,
    this.serviceUuids = const <String>[],
  });

  /// Platform device identifier (MAC on Android, a UUID on iOS).
  final String id;

  /// Advertised local name, e.g. `SAAS-A1B2C3D4`.
  final String name;

  /// Signal strength in dBm. Negative. Closer to zero is stronger.
  final int rssi;

  /// Whether the OS reports this peripheral as connectable.
  final bool connects;

  /// Advertised service UUIDs, used to filter out unrelated peripherals.
  final List<String> serviceUuids;

  /// A human-usable label; falls back to the id when unadvertised.
  String get displayName => name.trim().isEmpty ? id : name.trim();

  /// Whether this peripheral advertises our service.
  ///
  /// This is the filter that means the user is never shown a list of a hundred
  /// unrelated BLE devices in a car park.
  bool get isOurs => serviceUuids.any(
        (String uuid) => uuid.toLowerCase() == kServiceUuid,
      );

  /// Coarse link quality bucket, for the UI's signal indicator.
  ///
  /// -40 dBm is "right next to it"; -80 is "in the next car". Bucketing rather
  /// than showing a raw number because dBm is meaningless to a driver and a
  /// number that flickers on every packet is worse than a stable word.
  String get signalLabel {
    if (rssi >= -55) return 'Excellent';
    if (rssi >= -67) return 'Good';
    if (rssi >= -78) return 'Fair';
    return 'Weak';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlePeripheralInfo &&
          other.id == id &&
          other.name == name &&
          other.rssi == rssi &&
          other.connects == connects;

  @override
  int get hashCode => Object.hash(id, name, rssi, connects);

  @override
  String toString() => 'BlePeripheralInfo($displayName, $rssi dBm)';
}

/// A connected peripheral: the live link to the ESP32.
abstract class BlePeripheral {
  /// Platform identifier, stable across reconnects for the same device.
  String get id;

  /// Advertised name.
  String get name;

  /// Current signal strength in dBm.
  int get rssi;

  /// Negotiated MTU. Defaults to the platform's 23 when unknown.
  int get mtu;

  /// The current link state.
  BleLinkState get linkState;

  /// Whether [linkState] is [BleLinkState.connected].
  bool get isConnected;

  /// Notifications for [channel].
  ///
  /// Broadcast so several listeners (the repository, the diagnostics screen, a
  /// test) can observe the same stream without stealing events from each other.
  Stream<Uint8List> notifications(AppBleChannel channel);

  /// Write [data] to [channel] without waiting for a response.
  ///
  /// Throws only programming errors; every recoverable failure is the caller's
  /// problem to classify into a `Failure` at the repository layer.
  Future<void> writeWithoutResponse(AppBleChannel channel, Uint8List data);

  /// Read [channel] (used for the INFO characteristic, §2.1).
  Future<Uint8List> read(AppBleChannel channel);

  /// Disconnect.
  Future<void> disconnect();
}

/// The transport the application uses to reach a node.
///
/// Implemented by [BleService] (real hardware) and `FakeBleTransport`.
abstract class BleTransport {
  /// The current adapter status.
  BleAdapterStatus get adapterStatus;

  /// Adapter status changes.
  Stream<BleAdapterStatus> get adapterStatusStream;

  /// The currently connected peripheral, or `null`.
  BlePeripheral? get connected;

  /// Scan for our peripherals.
  ///
  /// Emits progressively as results arrive rather than only at the end, so the
  /// pairing screen can show a device the moment it is found. Completes when
  /// [timeout] elapses.
  Stream<BlePeripheralInfo> scan({
    Duration timeout,
    bool requireServiceUuid,
  });

  /// Connect to [id].
  Future<BlePeripheral> connect(String id);

  /// Disconnect the current peripheral, if any. Idempotent.
  Future<void> disconnect();
}
