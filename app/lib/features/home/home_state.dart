/// The dashboard's state, including the 50 Hz → 4 Hz throttle.
///
/// ## The performance problem
///
/// Telemetry arrives 50 times a second. A naive `ref.listen` straight into
/// widget state rebuilds the dashboard 50 times a second. That is not merely
/// wasteful: it competes with the alert screen's animations for the UI thread,
/// and a driver glancing at the dashboard while an alert is running would see
/// the countdown stutter.
///
/// ## The fix
///
/// [TelemetrySampler] keeps only the *latest* sample and publishes it on a
/// timer. Three properties make it cheap:
///
/// * it holds **one** sample, not a queue, so memory is O(1) and nothing
///   accumulates while the dashboard is closed;
/// * it publishes at a fixed low rate regardless of the input rate, so cost is
///   O(rate) not O(input);
/// * it compares the rounded display values, so a sample that would not change
///   a single pixel does not trigger a rebuild at all. At rest — which is most
///   of a drive — the values barely move, so this suppresses nearly all of them.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show BuildContext, IconData, Icons, VoidCallback;
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../core/result.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../data/protocol/messages.dart';
import '../../data/repositories/device_repository.dart';
import '../../data/repositories/hospital_repository.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/paired_device.dart';
import '../../domain/entities/telemetry.dart';

/// The link's condition, flattened for display.
enum LinkCondition {
  /// Live connection.
  connected,

  /// Reconnecting.
  connecting,

  /// Paired but not connected.
  disconnected,

  /// Never paired.
  unpaired,

  /// Connected, but the node speaks a protocol this build cannot.
  incompatible,

  /// No Bluetooth radio.
  unavailable,
}

/// Everything the dashboard renders.
@immutable
class HomeState {
  const HomeState({
    this.device,
    this.link = LinkCondition.disconnected,
    this.location,
    this.telemetry,
    this.telemetryHz = 0,
    this.pendingUploads = 0,
    this.online = true,
    this.busy = false,
    this.banner,
    this.bannerSeverity = StatusSeverity.warning,
  });

  final PairedDevice? device;
  final LinkCondition link;
  final GeoPoint? location;

  /// The throttled sample, or `null` before the first one.
  final TelemetryRecord? telemetry;
  final double telemetryHz;
  final int pendingUploads;
  final bool online;
  final bool busy;
  final String? banner;
  final StatusSeverity bannerSeverity;

  /// The user's own name for the node.
  String get deviceLabel {
    final PairedDevice? d = device;
    if (d == null) return 'No node paired';
    return d.displayName;
  }

  String get linkLabel => switch (link) {
        LinkCondition.connected => 'Node connected',
        LinkCondition.connecting => 'Reconnecting…',
        LinkCondition.disconnected => 'Node disconnected',
        LinkCondition.unpaired => 'No node paired',
        LinkCondition.incompatible => 'Node needs a firmware update',
        LinkCondition.unavailable => 'Bluetooth unavailable',
      };

  String get linkShortLabel => switch (link) {
        LinkCondition.connected => 'Live',
        LinkCondition.connecting => 'Linking',
        LinkCondition.disconnected => 'Offline',
        LinkCondition.unpaired => 'None',
        LinkCondition.incompatible => 'Update',
        LinkCondition.unavailable => 'No BLE',
      };

  String get linkDetail => switch (link) {
        LinkCondition.connected => device == null
            ? 'Streaming telemetry'
            : '${device!.deviceName} · fw ${device!.firmwareVersion}',
        LinkCondition.connecting => 'Looking for the node…',
        LinkCondition.disconnected =>
          'Alerts will resume automatically when it comes back into range.',
        LinkCondition.unpaired => 'Pair a node to start monitoring for crashes.',
        // Not a transient: retrying cannot help, so the hint is an action the
        // user can actually take.
        LinkCondition.incompatible =>
          'This app cannot talk to the node\'s firmware. Update the node or install a newer app build.',
        LinkCondition.unavailable => 'This device has no Bluetooth radio.',
      };

  /// The remedy for [link], as a callback, or `null` when nothing would help.
  ///
  /// The controller is passed in rather than read from a `Ref`, because this is
  /// a plain value object: reaching for a `Ref` from inside it would tie the
  /// dashboard's state to Riverpod, and make the type untestable on its own.
  /// [context] is likewise only used for the pairing navigation.
  VoidCallback? linkAction(HomeController controller, BuildContext context) =>
      switch (link) {
        LinkCondition.disconnected || LinkCondition.connecting =>
          controller.reconnect,
        LinkCondition.unpaired =>
          () => context.goNamed(AppRoutes.pairing),
        _ => null,
      };

  /// What to offer as the remedy, or `null` when nothing would help.
  String? get linkHint => switch (link) {
        LinkCondition.disconnected || LinkCondition.connecting => 'Reconnect now',
        LinkCondition.unpaired => 'Pair a node',
        _ => null,
      };

  StatusSeverity get linkSeverity => switch (link) {
        LinkCondition.connected => StatusSeverity.good,
        LinkCondition.connecting => StatusSeverity.warning,
        LinkCondition.disconnected => StatusSeverity.warning,
        LinkCondition.unpaired => StatusSeverity.neutral,
        LinkCondition.incompatible => StatusSeverity.critical,
        LinkCondition.unavailable => StatusSeverity.critical,
      };

  IconData get linkIcon => switch (link) {
        LinkCondition.connected => Icons.bluetooth_connected,
        LinkCondition.connecting => Icons.bluetooth_searching,
        LinkCondition.disconnected => Icons.bluetooth_disabled,
        LinkCondition.unpaired => Icons.bluetooth,
        LinkCondition.incompatible => Icons.system_update,
        LinkCondition.unavailable => Icons.bluetooth_disabled,
      };

  String get gpsValue => location == null ? '—' : 'Ready';
  String? get gpsCaption => location == null
      ? 'No fix yet'
      : '±${location!.accuracyM.round()} m';
  StatusSeverity get gpsSeverity =>
      location == null ? StatusSeverity.neutral : (location!.accuracyM > 50 ? StatusSeverity.warning : StatusSeverity.good);

  String get networkValue => online ? 'Online' : 'Offline';
  StatusSeverity get networkSeverity => online ? StatusSeverity.good : StatusSeverity.warning;

  /// Combined gyroscope magnitude in °/s, for the dashboard's rotation tile.
  double get gyrationDps {
    final TelemetryRecord? t = telemetry;
    if (t == null) return 0;
    final double x = t.gyrXDps;
    final double y = t.gyrYDps;
    final double z = t.gyrZDps;
    return math.sqrt(x * x + y * y + z * z);
  }

  StatusSeverity get stateSeverity => switch (telemetry?.state) {
        DeviceState.alarm || DeviceState.sos => StatusSeverity.critical,
        DeviceState.pending => StatusSeverity.warning,
        DeviceState.fault => StatusSeverity.critical,
        DeviceState.idle => StatusSeverity.good,
        _ => StatusSeverity.neutral,
      };

  /// Derive the offline banner text, or `null`.
  String? get computedBanner {
    if (!online && pendingUploads > 0) {
      return pendingUploads == 1
          ? 'Offline — 1 accident waiting to upload.'
          : 'Offline — $pendingUploads accidents waiting to upload.';
    }
    if (!online) return 'Offline. Alerts are being saved on this phone.';
    if (location == null) return 'Waiting for a GPS fix. Alerts will record without a location.';
    return null;
  }

  HomeState copyWith({
    PairedDevice? device,
    LinkCondition? link,
    GeoPoint? location,
    TelemetryRecord? telemetry,
    double? telemetryHz,
    int? pendingUploads,
    bool? online,
    bool? busy,
    String? banner,
    StatusSeverity? bannerSeverity,
  }) {
    return HomeState(
      device: device ?? this.device,
      link: link ?? this.link,
      location: location ?? this.location,
      telemetry: telemetry ?? this.telemetry,
      telemetryHz: telemetryHz ?? this.telemetryHz,
      pendingUploads: pendingUploads ?? this.pendingUploads,
      online: online ?? this.online,
      busy: busy ?? this.busy,
      banner: banner ?? this.banner,
      bannerSeverity: bannerSeverity ?? this.bannerSeverity,
    );
  }
}

/// Coalesces a high-rate sample stream into a low-rate one.
///
/// See the library docs for why this is a sampler and not a debounce.
class TelemetrySampler {
  TelemetrySampler({
    this.publishHz = 4,
    this.onSample,
  }) {
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / publishHz).round()),
      (_) => _publish(),
    );
  }

  /// Output rate. 4 Hz is the point where a value changing by ~0.05 g per tick
  /// is still visually smooth — faster is invisible, slower looks choppy.
  final int publishHz;

  final void Function(TelemetryRecord sample)? onSample;

  late final Timer _timer;
  TelemetryRecord? _latest;

  /// What the previous publish displayed, so no-op samples can be suppressed.
  String? _lastPublishedKey;

  /// Samples received, including suppressed ones. Diagnostic.
  int received = 0;
  int published = 0;

  /// Offer a sample. O(1), no allocation beyond the value itself.
  void offer(TelemetryRecord sample) {
    received++;
    _latest = sample;
  }

  void _publish() {
    final TelemetryRecord? sample = _latest;
    if (sample == null) return;

    // The display key: only the values the dashboard actually shows, rounded to
    // the precision it shows them at. Two samples with the same key are
    // indistinguishable on screen, so publishing the second would be a wasted
    // rebuild.
    final String key =
        '${(sample.magMg / 1000).toStringAsFixed(2)}|'
        '${_gyrationDps(sample).toStringAsFixed(0)}|'
        '${(sample.peakMg / 1000).toStringAsFixed(1)}|'
        '${sample.flags.sw420}|${sample.state.byte}|'
        '${sample.batteryPctOrNull}';
    if (key == _lastPublishedKey) return;

    _lastPublishedKey = key;
    published++;
    onSample?.call(sample);
  }

  void dispose() => _timer.cancel();
}

/// Combined gyroscope magnitude in degrees per second.
///
/// `TelemetryRecord` exposes the axes but not the magnitude, and the dashboard
/// shows one "rotation" figure — so it is computed here rather than adding a
/// getter to the entity for one caller.
double _gyrationDps(TelemetryRecord sample) {
  final double x = sample.gyrXDps;
  final double y = sample.gyrYDps;
  final double z = sample.gyrZDps;
  return math.sqrt(x * x + y * y + z * z);
}

/// The dashboard's controller.
class HomeController extends Notifier<HomeState> {
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  TelemetrySampler? _sampler;
  String? _lastDeviceId;

  @override
  HomeState build() {
    ref.onDispose(_dispose);

    final DeviceRepository device = ref.read(deviceRepositoryProvider);
    final _samplerLocal = TelemetrySampler(onSample: _onSample);
    _sampler = _samplerLocal;

    // The sampler is the only 50 Hz listener in the app.
    _subs.add(
      device.telemetry.listen((TelemetryRecord sample) {
        _samplerLocal.offer(sample);
      }),
    );

    _subs.add(
      device.messages.listen((DeviceUpdate update) {
        if (update.message is HelloAckMessage) {
          // The node identified itself, so seed the account uid that
          // `PairedDevice` requires. The value is not used here — the snapshot
          // is read from the repository, which applied it.
          device.userId = ref.read(firestoreDatasourceProvider).currentUserId ?? '';
          state = state.copyWith(device: device.snapshot);
        }
        if (update.message is DiagMessage) {
          state = state.copyWith(
            telemetryHz: (update.message as DiagMessage).loopHz.toDouble(),
          );
        }
      }),
    );

    _subs.add(
      device.device.listen((PairedDevice snapshot) {
        state = state.copyWith(device: snapshot, link: _linkFor(snapshot));
      }),
    );

    _subs.add(
      device.linkState.listen((DeviceLinkState link) {
        state = state.copyWith(link: _linkForState(link));
      }),
    );

    _subs.add(
      ref.read(accidentRepositoryProvider).pendingUploadCount.listen((int n) {
        state = state.copyWith(pendingUploads: n);
      }),
    );

    // `isOnlineProvider` is a `StreamProvider`, so its value arrives as an
    // `AsyncValue`; the reactivity is the provider's job, not a manual
    // subscription. `ref.listen` registers inside `build`, which is where
    // Riverpod expects it.
    ref.listen<AsyncValue<bool>>(isOnlineProvider, (AsyncValue<bool>? _, AsyncValue<bool> next) {
      state = state.copyWith(online: next.value ?? true);
    });

    // Get a fix so the dashboard is useful before any crash.
    unawaited(_acquireLocation());
    unawaited(_restoreDevice());

    return const HomeState();
  }

  void _onSample(TelemetryRecord sample) {
    state = state.copyWith(
      telemetry: sample,
      telemetryHz: ref.read(deviceRepositoryProvider).telemetryStats.measuredHz,
    );
  }

  Future<void> _acquireLocation() async {
    final Result<GeoPoint?> point =
        await ref.read(locationDatasourceProvider).currentPosition();
    if (point.valueOrNull != null) {
      state = state.copyWith(location: point.valueOrNull);
    }
  }

  Future<void> _restoreDevice() async {
    final SettingsRepository settings = ref.read(settingsRepositoryProvider);
    final String? id = await settings.deviceId();
    if (id == null || id.isEmpty || id == _lastDeviceId) return;
    _lastDeviceId = id;
    state = state.copyWith(busy: true);
    await ref.read(deviceRepositoryProvider).connect(id);
    await ref.read(deviceRepositoryProvider).sayHello();
    state = state.copyWith(busy: false, link: _linkForState(
      ref.read(deviceRepositoryProvider).linkStatus,
    ));
  }

  /// Manually reconnect.
  Future<void> reconnect() async {
    state = state.copyWith(busy: true, link: LinkCondition.connecting);
    final String? id = await ref.read(settingsRepositoryProvider).deviceId();
    if (id != null) {
      await ref.read(deviceRepositoryProvider).connect(id);
      await ref.read(deviceRepositoryProvider).sayHello();
    }
    state = state.copyWith(busy: false);
  }

  /// Pair a new node.
  Future<void> pair() async {
    state = state.copyWith(busy: true);
    state = state.copyWith(busy: false, link: LinkCondition.unpaired);
  }

  Future<void> refresh() async {
    state = state.copyWith(busy: true);
    await Future.wait(<Future<void>>[
      _acquireLocation(),
      _restoreDevice(),
      ref.read(accidentRepositoryProvider).syncOutbox(),
    ]);
    state = state.copyWith(busy: false);
  }

  static LinkCondition _linkFor(PairedDevice d) => _linkForState(d.linkState);

  static LinkCondition _linkForState(DeviceLinkState link) => switch (link) {
        DeviceLinkState.connected => LinkCondition.connected,
        DeviceLinkState.connecting => LinkCondition.connecting,
        DeviceLinkState.disconnected => LinkCondition.disconnected,
        DeviceLinkState.unpaired => LinkCondition.unpaired,
        DeviceLinkState.incompatible => LinkCondition.incompatible,
      };

  void _dispose() {
    for (final StreamSubscription<Object?> sub in _subs) {
      unawaited(sub.cancel());
    }
    _sampler?.dispose();
  }
}

/// The dashboard state.
final NotifierProvider<HomeController, HomeState> homeStateProvider =
    NotifierProvider<HomeController, HomeState>(HomeController.new);
