/// The paired node — a device the user has bound to their account.
///
/// Deliberately **not** the same thing as [DeviceState] or `TelemetryFlags`.
/// A [PairedDevice] is what the app remembers between launches: identity from
/// §6.2's `HELLO_ACK`, plus the local pairing facts (which account owns it,
/// when it was last heard from, what the user called it) that no firmware can
/// know. Live readings stay in the telemetry stream; this is the durable row.
library;

import 'telemetry.dart';

/// How a node is attached to this phone right now.
///
/// Distinct from "is the node switched on", which the app cannot know: BLE is
/// silent when a device is out of range, and treating that silence as
/// "disconnected" is how a UI ends up nagging about a car parked in a basement.
enum DeviceLinkState {
  /// Never paired, or explicitly unpaired.
  unpaired,

  /// Paired, and the phone has a live connection.
  connected,

  /// Paired, not connected right now. Normal, not an error.
  disconnected,

  /// Paired, and the phone is actively reconnecting.
  connecting,

  /// Paired, but the node answered a `HELLO` with a protocol version this build
  /// does not speak. The user needs to update the app, not retry harder.
  incompatible,
}

/// A node paired with this account.
final class PairedDevice {
  /// Creates a paired device from a §6.2 `HELLO_ACK` plus the local facts.
  ///
  /// [name] is the user's label, which is *not* [deviceName]: people rename
  /// these things ("Dad's car"), and the factory name `SAAS-A1B2C3D4` is
  /// useless in a list of three.
  const PairedDevice({
    required this.id,
    required this.userId,
    required this.deviceName,
    required this.mac,
    required this.chipId,
    required this.firmwareVersion,
    required this.protocolVersion,
    required this.pairedAt,
    this.label,
    this.hardware = '',
    this.lastSeenAt,
    this.lastKnownBatteryPct,
    this.batteryMv,
    this.isCharging = false,
    this.lastKnownState = DeviceState.unknown,
    this.isCalibrated = false,
    this.hasVibrationSensor = false,
    this.hasOled = false,
    this.whoAmIName,
    this.linkState = DeviceLinkState.disconnected,
  });

  /// Stable identifier for this pairing.
  ///
  /// The node's BLE MAC, lowercased — not the Firebase Auth uid, because a
  /// device can be unpaired and re-paired by a different account while keeping
  /// its identity, and the telemetry history on the node stays with it.
  final String id;

  /// The account that owns this pairing.
  final String userId;

  /// The factory name from `HELLO_ACK.name`, e.g. `SAAS-A1B2C3D4`.
  final String deviceName;

  /// The node's BLE MAC as the device reported it, e.g. `24:6F:28:A1:B2:C3:D4`.
  final String mac;

  /// The chip id from `HELLO_ACK.chipId`.
  final String chipId;

  /// Firmware version string, e.g. `1.0.0`.
  final String firmwareVersion;

  /// The protocol version the node speaks.
  ///
  /// Compared against `kProtocolVersion` at connect time so an old node produces
  /// [DeviceLinkState.incompatible] — a clear "update the app" — instead of a
  /// silently dropped `HELLO_ACK`.
  final int protocolVersion;

  /// When the user paired this node.
  final DateTime pairedAt;

  /// The user's own name for it. Falls back to [deviceName].
  String get displayName {
    final String trimmed = (label ?? '').trim();
    return trimmed.isEmpty ? deviceName : trimmed;
  }

  /// The user's label, or `null` when they never set one.
  final String? label;

  /// The hardware string from `HELLO_ACK.hw`, e.g. `esp32-devkit-v1`.
  final String hardware;

  /// When the phone last heard from this node.
  ///
  /// `null` until the first successful connect. A `HELLO_ACK` updates it; a
  /// telemetry frame does not, because a silent car is exactly the case where
  /// this timestamp is the most important number on the screen.
  final DateTime? lastSeenAt;

  /// The last reported battery percentage.
  final int? lastKnownBatteryPct;

  /// The last reported battery voltage in millivolts.
  final int? batteryMv;

  /// Whether the node was charging when last heard from.
  final bool isCharging;

  /// The last reported [DeviceState].
  final DeviceState lastKnownState;

  /// Whether the node has completed MPU calibration (§6.5 `calibrated`).
  final bool isCalibrated;

  /// Whether an SW-420 vibration sensor answered.
  final bool hasVibrationSensor;

  /// Whether an SSD1306 answered.
  final bool hasOled;

  /// The identified IMU part, e.g. `MPU-6050/MPU-6500`, when recognised.
  final String? whoAmIName;

  /// The current link state.
  final DeviceLinkState linkState;

  /// Whether the app can talk to this node at all.
  bool get isUsable =>
      linkState != DeviceLinkState.unpaired &&
      linkState != DeviceLinkState.incompatible;

  /// Whether the node is reporting that it is armed and watching for an impact.
  bool get isArmed => lastKnownState.isArmed;

  /// Whether the node is currently in an emergency state.
  bool get isInEmergency => lastKnownState.isEmergency;

  /// Whether the battery is low enough to warn about.
  ///
  /// 20%, not 15%: this is a node that has to survive a crash, and by the time a
  /// flat battery reads 10% the node has already dropped off the bus and can no
  /// longer detect anything at all.
  bool get isBatteryLow => (lastKnownBatteryPct ?? 100) <= 20;

  /// How long since the phone last heard from this node, at [now].
  Duration silenceAt(DateTime now) {
    final DateTime? seen = lastSeenAt;
    if (seen == null) {
      return Duration.zero;
    }
    final Duration silence = now.difference(seen);
    return silence.isNegative ? Duration.zero : silence;
  }

  /// A copy with the given fields replaced.
  PairedDevice copyWith({
    String? id,
    String? userId,
    String? deviceName,
    String? mac,
    String? chipId,
    String? firmwareVersion,
    int? protocolVersion,
    DateTime? pairedAt,
    String? label,
    String? hardware,
    DateTime? lastSeenAt,
    int? lastKnownBatteryPct,
    int? batteryMv,
    bool? isCharging,
    DeviceState? lastKnownState,
    bool? isCalibrated,
    bool? hasVibrationSensor,
    bool? hasOled,
    String? whoAmIName,
    DeviceLinkState? linkState,
  }) =>
      PairedDevice(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        deviceName: deviceName ?? this.deviceName,
        mac: mac ?? this.mac,
        chipId: chipId ?? this.chipId,
        firmwareVersion: firmwareVersion ?? this.firmwareVersion,
        protocolVersion: protocolVersion ?? this.protocolVersion,
        pairedAt: pairedAt ?? this.pairedAt,
        label: label ?? this.label,
        hardware: hardware ?? this.hardware,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastKnownBatteryPct: lastKnownBatteryPct ?? this.lastKnownBatteryPct,
        batteryMv: batteryMv ?? this.batteryMv,
        isCharging: isCharging ?? this.isCharging,
        lastKnownState: lastKnownState ?? this.lastKnownState,
        isCalibrated: isCalibrated ?? this.isCalibrated,
        hasVibrationSensor: hasVibrationSensor ?? this.hasVibrationSensor,
        hasOled: hasOled ?? this.hasOled,
        whoAmIName: whoAmIName ?? this.whoAmIName,
        linkState: linkState ?? this.linkState,
      );

  /// Applies a live reading from a telemetry frame.
  ///
  /// Only the fields a telemetry frame can actually change are touched. Battery
  /// and state come from the frame; `isCalibrated` and the hardware flags do
  /// not, because a frame that claimed otherwise would be reporting something
  /// the node can only know at boot.
  PairedDevice withTelemetry(TelemetryRecord sample) => copyWith(
        lastKnownBatteryPct: sample.hasBattery ? sample.batteryPctOrNull : null,
        lastKnownState: sample.state,
        isCharging: sample.flags.charging,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairedDevice &&
          other.id == id &&
          other.userId == userId &&
          other.deviceName == deviceName &&
          other.mac == mac &&
          other.chipId == chipId &&
          other.firmwareVersion == firmwareVersion &&
          other.protocolVersion == protocolVersion &&
          other.pairedAt == pairedAt &&
          other.label == label &&
          other.hardware == hardware &&
          other.lastSeenAt == lastSeenAt &&
          other.lastKnownBatteryPct == lastKnownBatteryPct &&
          other.batteryMv == batteryMv &&
          other.isCharging == isCharging &&
          other.lastKnownState == lastKnownState &&
          other.isCalibrated == isCalibrated &&
          other.hasVibrationSensor == hasVibrationSensor &&
          other.hasOled == hasOled &&
          other.whoAmIName == whoAmIName &&
          other.linkState == linkState;

  @override
  int get hashCode => Object.hash(
        id,
        userId,
        deviceName,
        mac,
        chipId,
        firmwareVersion,
        protocolVersion,
        pairedAt,
        label,
        hardware,
        lastSeenAt,
        lastKnownBatteryPct,
        batteryMv,
        isCharging,
        lastKnownState,
        isCalibrated,
        hasVibrationSensor,
        hasOled,
        whoAmIName,
        linkState,
      );

  @override
  String toString() => 'PairedDevice($id, $displayName, ${linkState.name})';
}
