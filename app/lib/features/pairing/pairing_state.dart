/// The pairing screen's state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../core/result.dart';
import '../../data/ble/ble_transport.dart';

/// What the pairing screen shows.
@immutable
class PairingViewState {
  const PairingViewState({
    this.found = const <BlePeripheralInfo>[],
    this.scanning = true,
    this.connecting = false,
    this.error,
  });

  final List<BlePeripheralInfo> found;
  final bool scanning;
  final bool connecting;
  final String? error;
}

/// Drives BLE pairing.
class PairingViewController extends Notifier<PairingViewState> {
  @override
  PairingViewState build() {
    unawaited(_scan());
    return const PairingViewState();
  }

  Future<void> _scan() async {
    state = const PairingViewState(scanning: true);
    final List<BlePeripheralInfo> seen = <BlePeripheralInfo>[];

    try {
      // Progressive, not batched: the list updates as each node is found
      // instead of appearing all at once when the scan times out.
      await for (final List<BlePeripheralInfo> batch
          in ref.read(deviceRepositoryProvider).scan()) {
        seen
          ..clear()
          ..addAll(batch);
        state = PairingViewState(found: seen, scanning: true);
      }
      state = PairingViewState(found: seen, scanning: false);
    } on Object catch (error) {
      state = PairingViewState(
        found: seen,
        scanning: false,
        error: 'Scanning failed: $error',
      );
    }
  }

  /// Connect to [info] and remember it.
  ///
  /// The `HELLO` handshake is sent immediately after connecting, because the
  /// node's identity — and the protocol-version compatibility check — arrives in
  /// the `HELLO_ACK`, not in the GATT connection itself.
  Future<bool> connect(BlePeripheralInfo info) async {
    state = PairingViewState(
      found: state.found,
      scanning: false,
      connecting: true,
    );

    final Result<BlePeripheral> connected =
        await ref.read(deviceRepositoryProvider).connect(info.id);

    if (connected case final FailureResult<BlePeripheral> failure) {
      state = PairingViewState(
        found: state.found,
        scanning: false,
        error: failure.failure.message,
      );
      return false;
    }

    await ref.read(deviceRepositoryProvider).sayHello();
    await ref.read(settingsRepositoryProvider).setDeviceId(info.id);

    // Give the `HELLO_ACK` a moment to arrive so the dashboard opens with the
    // node's real name and firmware rather than a placeholder.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    state = PairingViewState(found: state.found, scanning: false);
    return true;
  }
}

/// The pairing screen's state.
final NotifierProvider<PairingViewController, PairingViewState>
    pairingViewProvider =
    NotifierProvider<PairingViewController, PairingViewState>(
  PairingViewController.new,
);
