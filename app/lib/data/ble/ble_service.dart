/// `flutter_blue_plus` implementation of [BleTransport].
///
/// This is the **only** file in the app that imports `flutter_blue_plus`. The
/// plugin has changed its API across major versions — `License` became a
/// required argument to `connect()`, and the scanning entry point moved — so
/// isolating it here means an upgrade is a one-file change with a compiler to
/// check it, rather than a grep-and-hope across the codebase.
///
/// Verified against `flutter_blue_plus` 2.3.x.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../../core/logger.dart';
import 'ble_transport.dart';

/// Concrete [BleTransport] over BLE GATT.
class BleService implements BleTransport {
  BleService({AppLogger? log}) : _log = log ?? AppLogger();

  final AppLogger _log;

  fbp.BluetoothAdapterState _adapterState = fbp.BluetoothAdapterState.unknown;
  BlePeripheral? _peripheral;
  StreamSubscription<fbp.BluetoothAdapterState>? _adapterSub;
  bool _started = false;

  final StreamController<BleAdapterStatus> _adapterController =
      StreamController<BleAdapterStatus>.broadcast();

  @override
  BleAdapterStatus get adapterStatus => BleAdapterStatus.fromName(_adapterState.name);

  @override
  Stream<BleAdapterStatus> get adapterStatusStream => _adapterController.stream;

  @override
  BlePeripheral? get connected => _peripheral;

  /// Start watching the radio.
  ///
  /// Android can turn Bluetooth off at any moment (battery saver, another app),
  /// so this is a permanent subscription rather than a one-shot check. Idempotent,
  /// because both the splash and the pairing screen may call it.
  void start() {
    if (_started) return;
    _started = true;

    _adapterState = fbp.FlutterBluePlus.adapterStateNow;
    _adapterController.add(adapterStatus);

    // `adapterState` is a broadcast stream seeded with the current value.
    _adapterSub = fbp.FlutterBluePlus.adapterState.listen((
      fbp.BluetoothAdapterState state,
    ) {
      _adapterState = state;
      _adapterController.add(adapterStatus);
    });
  }

  @override
  Future<bool> ensureReady() async {
    // The runtime BLE *permission* is requested by the plugin inside scan(); it
    // is not separately callable. What is callable — and what the splash screen
    // needs in order to say something useful — is switching the radio on.
    if (_adapterState == fbp.BluetoothAdapterState.unavailable) return false;
    if (_adapterState == fbp.BluetoothAdapterState.on) return true;

    try {
      // No-op if the radio is already on. On Android 13+ this can raise the
      // "turn on Bluetooth?" system dialog, and the user may decline it — which
      // is a normal outcome to report, not an error to throw on.
      await fbp.FlutterBluePlus.turnOn().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } catch (e) {
      // Declined, or the platform refused. `warning`, not `error`: `error` logs
      // at fatal level, and a user who says no to a Bluetooth dialog has not hit
      // a fatal condition — the app degrades and says why.
      _log.warning('ble', 'could not turn the radio on', e);
    }

    // Re-read rather than trusting the call: the adapterState stream may not have
    // emitted yet, and acting on a stale value is what produces "it says ready
    // but nothing scans".
    _adapterState = fbp.FlutterBluePlus.adapterStateNow;
    _adapterController.add(adapterStatus);
    return adapterStatus.isUsable;
  }

  @override
  Stream<BlePeripheralInfo> scan({
    Duration timeout = const Duration(seconds: 10),
    bool requireServiceUuid = true,
  }) async* {
    if (!adapterStatus.isUsable) {
      throw StateError('adapter ${adapterStatus.name} is not usable');
    }

    // Filter by our service UUID (§2.4). Without this the user is shown every
    // BLE device in range, which in a car park is dozens of strangers'
    // trackers and headphones.
    //
    // `withServices` is applied natively by the platform, so non-matching
    // advertisements never cross the method channel — which matters when a
    // phone sees 200 peripherals.
    //
    // `continuousUpdates: true` re-emits the full list as results arrive, so
    // the pairing screen can show a device the moment it is found. `oneByOne`
    // is deliberately off: the list form is what the UI wants, and the plugin's
    // own re-emit handles de-duplication.
    await fbp.FlutterBluePlus.startScan(
      withServices: <fbp.Guid>[fbp.Guid(kServiceUuid)],
      timeout: timeout,
      continuousUpdates: true,
      androidScanMode: fbp.AndroidScanMode.balanced,
      // Without these, Android 10+ refuses to return any results at all when
      // the app lacks a location permission — a failure that presents as
      // "scanning finds nothing" with no error at all.
      androidUsesFineLocation: true,
      androidCheckLocationServices: true,
    );

    // Emitted only for peripherals matching the filters above.
    await for (final List<fbp.ScanResult> results in fbp.FlutterBluePlus.scanResults) {
      for (final fbp.ScanResult result in results) {
        final fbp.AdvertisementData adv = result.advertisementData;
        yield BlePeripheralInfo(
          id: result.device.remoteId.str,
          name: adv.advName.isNotEmpty
              ? adv.advName
              : result.device.platformName,
          rssi: result.rssi,
          connects: adv.connectable,
          serviceUuids: adv.serviceUuids
              .map((fbp.Guid uuid) => uuid.str)
              .toList(growable: false),
        );
      }
    }
  }

  @override
  Future<BlePeripheral> connect(String id) async {
    if (!adapterStatus.isUsable) {
      throw StateError('adapter ${adapterStatus.name} is not usable');
    }

    final fbp.BluetoothDevice device = fbp.BluetoothDevice.fromId(id);

    // 2.x requires an explicit `License` on every connect, and the app aborts if
    // none is supplied. `nonprofit` is correct for this prototype (§ a teaching
    // project); a commercial deployment must switch to `License.commercial` and
    // buy one — see flutter_blue_plus/LICENSE.
    //
    // `autoConnect: false` because we want a fast, explicit attempt with a clear
    // error, not an OS-managed background reconnect that hides the failure.
    await device.connect(
      license: fbp.License.nonprofit,
      autoConnect: false,
      mtu: kPreferredMtu,
    );

    final _FbPeripheral peripheral = _FbPeripheral(device, _log);
    await peripheral._initialise();
    _peripheral = peripheral;
    return peripheral;
  }

  @override
  Future<void> disconnect() async {
    final BlePeripheral? p = _peripheral;
    _peripheral = null;
    if (p != null) await p.disconnect();
  }

  /// Release subscriptions. The app calls this on teardown.
  Future<void> dispose() async {
    await disconnect();
    await _adapterSub?.cancel();
    await _adapterController.close();
  }
}

/// A real GATT connection.
class _FbPeripheral implements BlePeripheral {
  _FbPeripheral(this._device, this._log);

  final fbp.BluetoothDevice _device;
  final AppLogger _log;

  final Map<AppBleChannel, StreamController<Uint8List>> _controllers =
      <AppBleChannel, StreamController<Uint8List>>{};
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  /// UUID → characteristic, for the channels we found.
  late final Map<String, fbp.BluetoothCharacteristic> _characteristics =
      <String, fbp.BluetoothCharacteristic>{};

  int _mtu = 23;
  bool _initialised = false;

  @override
  String get id => _device.remoteId.str;

  @override
  String get name => _device.platformName;

  /// Last known signal strength in dBm.
  ///
  /// Cached rather than read on demand: `readRssi()` is a round trip over the
  /// method channel, and a signal indicator that rebuilds a widget 50 times a
  /// second must not issue 50 platform calls. Refreshed in the background.
  @override
  int get rssi => _lastRssi;

  int _lastRssi = -100;

  /// The negotiated MTU.
  ///
  /// Defaults to the platform minimum of 23. A 32-byte telemetry frame then
  /// exceeds one notification and needs the protocol's padding, which the
  /// framing already supports — hence this degrades cleanly rather than
  /// failing the connection.
  @override
  int get mtu => _mtu;

  @override
  BleLinkState get linkState => switch (_device.connectionState) {
        fbp.BluetoothConnectionState.connected => BleLinkState.connected,
        fbp.BluetoothConnectionState.disconnected => BleLinkState.disconnected,
        _ => BleLinkState.connecting,
      };

  @override
  bool get isConnected =>
      _device.connectionState == fbp.BluetoothConnectionState.connected;

  /// Discover services, cache the characteristics and subscribe to notifications.
  Future<void> _initialise() async {
    if (_initialised) return;

    // Ask for the preferred MTU; a refusal is not fatal.
    try {
      _mtu = await _device.requestMtu(kPreferredMtu);
    } on Object catch (error) {
      _log.log(
        LogLevel.info,
        AppLogger.tagBle,
        'MTU request refused, falling back to padded frames',
        error,
      );
      _mtu = 23;
    }

    // `connect(mtu:)` already negotiates the MTU, but Android can still report
    // a different one once services are discovered.
    final List<fbp.BluetoothService> services = await _device.discoverServices();

    for (final fbp.BluetoothService service in services) {
      for (final fbp.BluetoothCharacteristic characteristic
          in service.characteristics) {
        final String uuid = characteristic.uuid.str.toLowerCase();
        for (final AppBleChannel channel in AppBleChannel.values) {
          if (channel.uuid.toLowerCase() == uuid) {
            _characteristics[channel.wireName] = characteristic;
          }
        }
      }
    }

    for (final AppBleChannel channel in AppBleChannel.values) {
      final fbp.BluetoothCharacteristic? characteristic =
          _characteristics[channel.wireName];
      if (characteristic == null) {
        // Capability negotiation: a node without the OLED still has the same
        // service; a node missing a whole characteristic is simply reported
        // absent, and the app renders the degraded state.
        _log.log(
          LogLevel.info,
          AppLogger.tagBle,
          '${channel.wireName} characteristic absent — capability negotiated out',
        );
        continue;
      }
      if (!channel.isNotify) continue;

      final StreamController<Uint8List> controller =
          StreamController<Uint8List>.broadcast();
      _controllers[channel] = controller;

      _subs.add(
        characteristic.onValueReceived.listen(
          (List<int> value) {
            if (!controller.isClosed) controller.add(Uint8List.fromList(value));
          },
          onError: (Object error) => _log.log(
            LogLevel.warning,
            AppLogger.tagBle,
            '${channel.wireName} notification error: $error',
          ),
        ),
      );
      await characteristic.setNotifyValue(true);
    }

    _initialised = true;
    unawaited(_watchRssi());
  }

  /// Poll RSSI in the background.
  ///
  /// 10 s is slow enough not to matter for power and fast enough that the
  /// signal indicator reflects reality. Only runs while connected, so an idle
  /// app costs nothing.
  Future<void> _watchRssi() async {
    while (isConnected && !_disposed) {
      try {
        _lastRssi = await _device.readRssi();
      } on Object {
        // A failed read is normal while the link is flapping; keep the last
        // value rather than showing a spurious 0 dBm.
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  bool _disposed = false;

  fbp.BluetoothCharacteristic? _lookup(AppBleChannel channel) =>
      _characteristics[channel.wireName];

  @override
  Stream<Uint8List> notifications(AppBleChannel channel) =>
      _controllers[channel]?.stream ?? const Stream<Uint8List>.empty();

  @override
  Future<void> writeWithoutResponse(
    AppBleChannel channel,
    Uint8List data,
  ) async {
    if (!channel.isWritable) {
      throw StateError('${channel.wireName} is not writable');
    }
    final fbp.BluetoothCharacteristic? characteristic = _lookup(channel);
    if (characteristic == null) {
      throw StateError('${channel.wireName} characteristic not found');
    }
    await characteristic.write(data, withoutResponse: true);
  }

  @override
  Future<Uint8List> read(AppBleChannel channel) async {
    final fbp.BluetoothCharacteristic? characteristic = _lookup(channel);
    if (characteristic == null) {
      throw StateError('${channel.wireName} characteristic not found');
    }
    final List<int> value = await characteristic.read();
    return Uint8List.fromList(value);
  }

  @override
  Future<void> disconnect() async {
    _disposed = true;
    for (final StreamSubscription<Object?> sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    for (final StreamController<Uint8List> controller in _controllers.values) {
      await controller.close();
    }
    _controllers.clear();
    _initialised = false;
    await _device.disconnect();
  }
}
