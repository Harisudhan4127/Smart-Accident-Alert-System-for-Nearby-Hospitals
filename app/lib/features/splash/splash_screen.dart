/// Bootstrap: the first screen, and the gate every other screen sits behind.
///
/// Runs the pre-flight checks in parallel and reports each one's outcome
/// separately. It deliberately does **not** block on any of them: a phone
/// without GPS can still pair a node and receive alerts, and a phone without
/// Firebase can still work entirely offline. Only a hard failure (no usable
/// Bluetooth) is fatal, and even that is presented as an explanation with a way
/// forward rather than a crash.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/providers.dart';
import '../../core/result.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/theme/spacing.dart';
import '../../data/ble/ble_transport.dart';
import '../../data/datasources/location_datasource.dart';
import '../../data/repositories/hospital_repository.dart';
import '../../widgets/ui_kit.dart';

/// The outcome of each pre-flight check.
enum CheckState { pending, running, ok, warning, failed }

/// One pre-flight result.
class CheckResult {
  const CheckResult({
    required this.label,
    required this.state,
    this.detail,
    this.fatal = false,
  });

  final String label;
  final CheckState state;
  final String? detail;
  final bool fatal;

  StatusSeverity get severity => switch (state) {
        CheckState.ok => StatusSeverity.good,
        CheckState.warning => StatusSeverity.warning,
        CheckState.failed =>
          fatal ? StatusSeverity.critical : StatusSeverity.warning,
        CheckState.pending || CheckState.running => StatusSeverity.neutral,
      };
}

/// Runs startup checks and routes onwards.
final splashControllerProvider =
    NotifierProvider<SplashController, List<CheckResult>>(SplashController.new);

/// The splash screen's logic, extracted so it is testable without pumping a
/// widget.
class SplashController extends Notifier<List<CheckResult>> {
  @override
  List<CheckResult> build() => const <CheckResult>[
        CheckResult(label: 'Bluetooth', state: CheckState.pending),
        CheckResult(label: 'Location access', state: CheckState.pending),
        CheckResult(label: 'Hospital directory', state: CheckState.pending),
        CheckResult(label: 'Cloud sync', state: CheckState.pending),
        CheckResult(label: 'Notifications', state: CheckState.pending),
      ];

  /// Run every check, then report whether the app may proceed.
  Future<bool> run() async {
    _set(0, const CheckResult(label: 'Bluetooth', state: CheckState.running));
    _set(1, const CheckResult(label: 'Location access', state: CheckState.running));
    _set(2, const CheckResult(label: 'Hospital directory', state: CheckState.running));
    _set(3, const CheckResult(label: 'Cloud sync', state: CheckState.running));
    _set(4, const CheckResult(label: 'Notifications', state: CheckState.running));

    // Independent checks run concurrently: they touch different subsystems, and
    // serialising them would add their latencies for no benefit. A GPS
    // permission prompt can take a user ten seconds, and nothing else should
    // wait on that.
    final List<Future<void>> checks = <Future<void>>[
      _checkBluetooth(),
      _checkLocation(),
      _checkHospitals(),
      _checkCloud(),
      _checkNotifications(),
    ];
    await Future.wait(checks);

    // Only a hard Bluetooth failure is fatal.
    return !state.any((CheckResult c) => c.fatal && c.state == CheckState.failed);
  }

  Future<void> _checkBluetooth() async {
    final BleTransport transport = ref.read(effectiveBleTransportProvider);
    final BleAdapterStatus status = transport.adapterStatus;
    switch (status) {
      case BleAdapterStatus.ready:
        _set(0, const CheckResult(label: 'Bluetooth', state: CheckState.ok));
      case BleAdapterStatus.poweredOff:
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.warning,
            detail: 'Turn Bluetooth on to connect to the node.',
            fatal: true,
          ),
        );
      case BleAdapterStatus.unauthorized:
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.warning,
            detail: 'This app needs Bluetooth permission.',
            fatal: true,
          ),
        );
      case BleAdapterStatus.unsupported:
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.warning,
            detail: 'This device has no Bluetooth radio.',
            fatal: true,
          ),
        );
      case BleAdapterStatus.unknown:
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.warning,
            detail: 'Bluetooth state is not known yet. Retrying…',
          ),
        );
    }
  }

  Future<void> _checkLocation() async {
    final LocationPermissionOutcome outcome =
        await ref.read(locationDatasourceProvider).ensurePermission();
    switch (outcome) {
      case LocationPermissionOutcome.granted:
        _set(1, const CheckResult(label: 'Location access', state: CheckState.ok));
      case LocationPermissionOutcome.denied:
        // Not fatal: the app still detects crashes and records them, the
        // location is just missing. §25 lists this as a degradation, not a stop.
        _set(
          1,
          const CheckResult(
            label: 'Location access',
            state: CheckState.warning,
            detail: 'Alerts will be recorded without a location.',
          ),
        );
      case LocationPermissionOutcome.permanentlyDenied:
        _set(
          1,
          const CheckResult(
            label: 'Location access',
            state: CheckState.warning,
            detail: 'Enable location for this app in Settings.',
          ),
        );
      case LocationPermissionOutcome.unavailable:
        _set(
          1,
          const CheckResult(
            label: 'Location access',
            state: CheckState.warning,
            detail: 'Location services are off on this device.',
          ),
        );
    }
  }

  Future<void> _checkHospitals() async {
    // An await here, not a watch: the splash must not rebuild when the async
    // value lands, and the screen has its own loading state.
    final Result<HospitalLoadSummary> summary = await ref
        .read(hospitalRepositoryProvider)
        .loadSummary();
    if (summary case final Ok<HospitalLoadSummary> ok) {
      _set(
        2,
        CheckResult(
          label: 'Hospital directory',
          state: CheckState.ok,
          detail: '${ok.value.count} hospitals ready (${ok.value.source.name})',
        ),
      );
    } else {
      _set(
        2,
        CheckResult(
          label: 'Hospital directory',
          state: CheckState.warning,
          detail: '${summary.failureOrNull?.message ?? 'unavailable'}',
        ),
      );
    }
  }

  Future<void> _checkCloud() async {
    // Anonymous sign-in. A failure is a warning, never fatal: §25's promise is
    // that the app works offline, and refusing to start without a network would
    // break exactly the case that promise exists for.
    final Result<String> signedIn =
        await ref.read(firestoreDatasourceProvider).signInAnonymously();
    if (signedIn.isOk) {
      _set(3, const CheckResult(label: 'Cloud sync', state: CheckState.ok));
    } else {
      _set(
        3,
        const CheckResult(
          label: 'Cloud sync',
          state: CheckState.warning,
          detail: 'Offline. Accidents will be uploaded when a connection returns.',
        ),
      );
    }
  }

  Future<void> _checkNotifications() async {
    final bool granted =
        await ref.read(notificationDatasourceProvider).requestPermission();
    _set(
      4,
      CheckResult(
        label: 'Notifications',
        state: granted ? CheckState.ok : CheckState.warning,
        detail: granted
            ? null
            : 'Without notifications an alert may not reach you if the app is closed.',
      ),
    );
  }

  void _set(int index, CheckResult result) {
    final List<CheckResult> next = List<CheckResult>.of(state);
    next[index] = result;
    state = next;
  }
}

/// The bootstrap screen.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _ran = false;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    // Post-frame, so the first frame renders before the checks start. Starting
    // them in `initState` would delay the first paint by however long the GPS
    // permission dialog takes to be dismissed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_ran) return;
    _ran = true;
    final bool ok = await ref.read(splashControllerProvider.notifier).run();
    if (!mounted) return;
    if (ok) {
      final bool onboarded =
          await ref.read(settingsRepositoryProvider).isOnboarded();
      if (!mounted) return;
      context.goNamed(onboarded ? AppRoutes.home : AppRoutes.onboarding);
    } else {
      setState(() => _blocked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<CheckResult> checks = ref.watch(splashControllerProvider);
    final MotionResolver motion = context.motion;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              theme.colorScheme.surface,
              AppColors.emergency.withValues(alpha: 0.05),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Spacer(flex: 2),
                _wordmark(theme, motion),
                const Spacer(flex: 2),
                if (_blocked)
                  _blockedNotice(theme)
                else
                  ...checks.map((CheckResult c) => _checkRow(theme, c)),
                const Spacer(flex: 2),
                Text(
                  'A prototype, not a certified emergency system.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _wordmark(ThemeData theme, MotionResolver motion) {
    return Column(
      children: <Widget>[
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.emergency.withValues(alpha: 0.12),
            border: Border.all(
              color: AppColors.emergency.withValues(alpha: 0.4),
              width: 2,
            ),
          ),
          child: const Icon(
            Icons.health_and_safety_outlined,
            size: 42,
            color: AppColors.emergency,
          ),
        ),
        const SizedBox(height: Spacing.medium),
        Text(
          'SMART ACCIDENT',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
        Text(
          'ALERT SYSTEM',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            color: AppColors.emergency,
          ),
        ),
      ],
    );
  }

  Widget _checkRow(ThemeData theme, CheckResult check) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 18,
            height: 18,
            child: switch (check.state) {
              CheckState.pending || CheckState.running =>
                const CircularProgressIndicator(strokeWidth: 2),
              CheckState.ok => const Icon(Icons.check_circle, size: 16, color: AppColors.emerald),
              CheckState.warning || CheckState.failed =>
                const Icon(Icons.error_outline, size: 16, color: AppColors.amber),
            },
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(check.label, style: theme.textTheme.bodyMedium),
                if (check.detail != null)
                  Text(
                    check.detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blockedNotice(ThemeData theme) {
    return Column(
      children: <Widget>[
        const Icon(Icons.bluetooth_disabled, size: 48, color: AppColors.emergency),
        const SizedBox(height: Spacing.medium),
        Text(
          'Bluetooth is required',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          'This app talks to the accident-detection node over Bluetooth. '
          'Turn it on in your system settings, then try again.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.large),
        PrimaryAction(label: 'Check again', onPressed: _retry),
      ],
    );
  }

  Future<void> _retry() async {
    setState(() => _blocked = false);
    await _run();
  }
}
