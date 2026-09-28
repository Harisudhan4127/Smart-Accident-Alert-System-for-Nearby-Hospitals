/// The settings screen's state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../data/protocol/messages.dart';
import '../../data/repositories/device_repository.dart';

/// What the settings screen shows.
@immutable
class SettingsViewState {
  SettingsViewState({
    DeviceConfig? config,
    this.diag,
    this.firmwareVersion,
    this.loading = true,
    this.banner,
    this.bannerSeverity = StatusSeverity.warning,
  }) : config = config ?? DeviceConfig.defaults();

  /// The **effective** config, i.e. what the node actually accepted after
  /// clamping (§6.4) — not what was requested. A slider that silently clamped
  /// its value and showed the requested number would be lying.
  final DeviceConfig config;

  /// The node's last `DIAG` (§6.9).
  final DiagMessage? diag;
  final String? firmwareVersion;
  final bool loading;
  final String? banner;
  final StatusSeverity bannerSeverity;

  SettingsViewState copyWith({
    DeviceConfig? config,
    DiagMessage? diag,
    String? firmwareVersion,
    bool? loading,
    String? banner,
    StatusSeverity? bannerSeverity,
  }) =>
      SettingsViewState(
        config: config ?? this.config,
        diag: diag ?? this.diag,
        firmwareVersion: firmwareVersion ?? this.firmwareVersion,
        loading: loading ?? this.loading,
        banner: banner,
        bannerSeverity: bannerSeverity ?? this.bannerSeverity,
      );
}

/// Drives the settings screen.
class SettingsViewController extends Notifier<SettingsViewState> {
  StreamSubscription<DeviceUpdate>? _sub;
  Timer? _flushTimer;
  ConfigPatch _pending = const ConfigPatch();

  @override
  SettingsViewState build() {
    ref.onDispose(() {
      unawaited(_sub?.cancel());
      _flushTimer?.cancel();
    });

    final DeviceRepository device = ref.read(deviceRepositoryProvider);

    // Adopt whatever the node reports, so the screen opens showing reality.
    if (device.snapshot != null) {
      state = state.copyWith(
        loading: false,
        firmwareVersion: device.snapshot!.firmwareVersion,
      );
    }

    _sub = device.messages.listen((DeviceUpdate update) {
      final DeviceMessage message = update.message;
      if (message is StatusMessage) {
        // §6.4: STATUS carries `effectiveConfig`, the clamped truth. It arrives
        // as a *partial* object, so it is overlaid on what we already hold
        // rather than replacing it — a node that reports only the threshold it
        // changed should not blank the other eleven settings in the UI.
        final ConfigPatch? reported = message.effectiveConfig;
        if (reported != null) {
          state = state.copyWith(
            loading: false,
            config: DeviceConfig.fromPatch(reported.mergedOnto(state.config.toPatch())),
            banner: null,
          );
        } else {
          state = state.copyWith(loading: false);
        }
      } else if (message is HelloAckMessage) {
        state = state.copyWith(
          loading: false,
          firmwareVersion: message.fwVersion,
        );
      } else if (message is DiagMessage) {
        state = state.copyWith(diag: message);
      }
    });

    return state.copyWith(loading: false);
  }

  /// Queue a config change and flush it after a short debounce.
  ///
  /// A slider emits continuously while dragging. Writing a `CONFIG` frame per
  /// frame would put dozens of BLE writes on the link for one gesture, and each
  /// one makes the node re-clamp and re-persist. Debouncing to 400 ms means one
  /// write per gesture, and the value the user actually let go of is the one
  /// that ships.
  void _queue(ConfigPatch patch) {
    // `mergedOnto` overlays this patch's *set* fields onto the accumulated one,
    // so a burst of slider events composes into a single frame instead of each
    // overwriting the last.
    _pending = patch.mergedOnto(_pending);
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), _flush);
  }

  void _flush() {
    final ConfigPatch patch = _pending;
    _pending = const ConfigPatch();
    if (patch.isEmpty) return;

    unawaited(
      ref.read(deviceRepositoryProvider).sendConfig(patch).then((Result<void> r) {
        if (r case final FailureResult<void> failure) {
          // A failure here is usually "not connected", which is a normal state
          // rather than an error worth shouting about.
          state = state.copyWith(
            banner: failure.failure.kind == FailureKind.bluetooth
                ? 'Changes will be sent when the node reconnects.'
                : failure.failure.message,
            bannerSeverity: StatusSeverity.warning,
          );
        }
      }),
    );
  }

  void setAccelThreshold(int millig) =>
      _queue(ConfigPatch(accelThresholdMg: millig));

  /// There is deliberately no rotation-threshold setter.
  ///
  /// The node's ADXL345 has no gyroscope, so there is no rotation rate to
  /// threshold. A slider that always read back the default would be worse than
  /// none: the user would set it and believe it had changed the detector.

  void setConfirmWindow(int seconds) =>
      _queue(ConfigPatch(confirmWindowSec: seconds));

  void setVibrationRequired(bool value) =>
      _queue(ConfigPatch(vibrationRequired: value));

  void setAutoArm(bool value) => _queue(ConfigPatch(autoArm: value));

  void setBuzzerEnabled(bool value) => _queue(ConfigPatch(buzzerEnabled: value));

  void setLedEnabled(bool value) => _queue(ConfigPatch(ledEnabled: value));

  /// Ask the node for a self-test report.
  Future<void> readDiagnostics() async {
    final Result<void> sent =
        await ref.read(deviceRepositoryProvider).command(CommandOp.selftest);
    if (sent case final FailureResult<void> failure) {
      state = state.copyWith(banner: failure.failure.message);
    }
  }
}

/// The settings screen's state.
final NotifierProvider<SettingsViewController, SettingsViewState>
    settingsViewProvider =
    NotifierProvider<SettingsViewController, SettingsViewState>(
  SettingsViewController.new,
);
