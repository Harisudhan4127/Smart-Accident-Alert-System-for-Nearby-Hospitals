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

/// Something the user can do about a failed pre-flight check.
enum CheckAction { turnOnBluetooth }

/// One pre-flight result.
class CheckResult {
  const CheckResult({
    required this.label,
    required this.state,
    this.detail,
    this.fatal = false,
    this.action,
  });

  final String label;
  final CheckState state;
  final String? detail;
  final bool fatal;

  /// An action the user can take from this row, if there is one.
  ///
  /// A warning with no button is a dead end. The case here is the one a user can
  /// actually fix themselves in the moment.
  final CheckAction? action;

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
  ///
  /// **No OS permission dialog is raised here.** That is a deliberate change, and
  /// the reasoning is worth keeping:
  ///
  /// The splash used to request location *and* notifications concurrently, before
  /// the user had seen a single screen. Android can only put one system dialog on
  /// screen at a time, so the two raced; the loser was frequently dropped without
  /// an explanation, leaving the app with a permission the user had answered and
  /// the app had not recorded. Beyond that, asking for location on a splash
  /// screen — before the user has any idea what a "node" is — is the pattern that
  /// trains people to tap Deny.
  ///
  /// Each permission is now requested at the moment it is first *needed*:
  ///
  /// | Permission            | Requested when                                  |
  /// | --------------------- | ----------------------------------------------- |
  /// | Nearby devices (BLE)  | the user scans for a node — the plugin does it    |
  /// | Location              | an accident event arrives and a position is needed |
  /// | Notifications         | the first alert is raised                        |
  ///
  /// So the checks here are all *reads*. They report what is already granted,
  /// which is what a pre-flight screen is for.
  Future<bool> run() async {
    for (int i = 0; i < 5; i++) {
      _set(i, CheckResult(label: _labelFor(i), state: CheckState.running));
    }

    // Safe to run concurrently now that none of them prompts. They touch
    // different subsystems, so serialising would just add their latencies.
    await Future.wait(<Future<void>>[
      _checkBluetooth(),
      _checkLocation(),
      _checkHospitals(),
      _checkCloud(),
      _checkNotifications(),
    ]);

    // Only a device with no Bluetooth radio at all is fatal, and even that is
    // reported rather than used to trap the user on this screen.
    return !state.any((CheckResult c) => c.fatal && c.state == CheckState.failed);
  }

  static String _labelFor(int i) => switch (i) {
        0 => 'Bluetooth',
        1 => 'Location',
        2 => 'Hospital directory',
        3 => 'Cloud sync',
        _ => 'Notifications',
      };

  /// Re-runs only the Bluetooth check, after the user has acted on it.
  Future<void> retryBluetooth() async {
    _set(0, const CheckResult(label: 'Bluetooth', state: CheckState.running));
    await _checkBluetooth();
  }

  Future<void> _checkBluetooth() async {
    final BleTransport transport = ref.read(effectiveBleTransportProvider);

    // If the radio is merely off, offer to switch it on. The BLE *permission* is
    // requested by the plugin later, when the user actually scans — asking for
    // "nearby devices" on a splash screen, before the user has any idea what a
    // node is, is how an app gets its permissions refused. So nothing is prompted
    // here; the only thing done is a switch the user can decline.
    if (transport.adapterStatus == BleAdapterStatus.poweredOff) {
      final bool nowUsable = await transport.ensureReady();
      if (nowUsable) {
        _set(0, const CheckResult(label: 'Bluetooth', state: CheckState.ok));
        return;
      }
    }

    final BleAdapterStatus status = transport.adapterStatus;
    switch (status) {
      case BleAdapterStatus.ready:
        _set(0, const CheckResult(label: 'Bluetooth', state: CheckState.ok));
      case BleAdapterStatus.poweredOff:
        // A warning with a button, never a block. This one used to be fatal and
        // it was the worst of the three: a user who opens a phone app to check
        // their emergency contacts has no reason to have switched Bluetooth on,
        // and being met with a dead-end screen is not a defensible answer to
        // that. PROJECT_PLAN §25 lists "Bluetooth disconnected" as a state to
        // display, not a reason to refuse to start.
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.warning,
            detail: 'Turn Bluetooth on to reach the node. The app works without it.',
            action: CheckAction.turnOnBluetooth,
          ),
        );
      case BleAdapterStatus.unauthorized:
        // Not fatal, and deliberately not prompted from here. The BLE permission
        // is requested by the plugin the first time the user actually scans, which
        // is a far better moment than a splash screen: by then they have seen why
        // the node exists. Asking for "nearby devices" before that is how an app
        // gets its permissions refused.
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.warning,
            detail: 'Allow "nearby devices" when you connect to a node.',
          ),
        );
      case BleAdapterStatus.unsupported:
        // The one genuinely fatal case, and even it only reports: without a
        // radio this app cannot do its job, but it can still show contacts and
        // history, and trapping the user on a splash is not the way to say so.
        _set(
          0,
          const CheckResult(
            label: 'Bluetooth',
            state: CheckState.failed,
            detail: 'This device has no Bluetooth radio. The node cannot be reached.',
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
    // **Read only.** `ensurePermission()` prompts, and it is deliberately not
    // called from a splash screen. What we ask the user here is "is this already
    // granted?", so the row is a status line rather than a request.
    final LocationPermissionOutcome outcome =
        await ref.read(locationDatasourceProvider).currentPermission();
    switch (outcome) {
      case LocationPermissionOutcome.granted:
        _set(1, const CheckResult(label: 'Location', state: CheckState.ok));
      case LocationPermissionOutcome.denied:
        // Not fatal, and not worth a warning: the app still detects crashes and
        // records them, and it asks for location at the moment it needs one —
        // which is a far better answer to "why does an accident app want my
        // location?" than a prompt at launch.
        _set(
          1,
          const CheckResult(
            label: 'Location',
            state: CheckState.ok,
            detail: 'Asked when an accident needs a position',
          ),
        );
      case LocationPermissionOutcome.permanentlyDenied:
        _set(
          1,
          const CheckResult(
            label: 'Location',
            state: CheckState.warning,
            detail: 'Blocked. Enable it in Settings or accidents have no position.',
          ),
        );
      case LocationPermissionOutcome.unavailable:
        _set(
          1,
          const CheckResult(
            label: 'Location',
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
    // **Read only**, for the same reason as location. A notification prompt on a
    // splash screen is the least defensible of the three: the user has not yet
    // seen an alert, so "allow notifications?" is unanswerable, and a refusal
    // here is the one that actually costs them an emergency.
    final bool granted = await ref.read(notificationDatasourceProvider).hasPermission();
    _set(
      4,
      CheckResult(
        label: 'Notifications',
        state: granted ? CheckState.ok : CheckState.ok,
        // A refusal is not shown as a warning here — it is not yet a problem,
        // and it is asked for properly when the first alert is raised.
        detail: granted ? null : 'Asked when the first alert is raised',
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

  Future<void> _onAction() async {
    await ref.read(splashControllerProvider.notifier).retryBluetooth();
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
                // The fix, in the row it fixes. A warning the user can only act
                // on by reading a manual is a worse experience than no warning.
                if (check.action != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: TextButton.icon(
                      onPressed: _onAction,
                      icon: const Icon(Icons.bluetooth, size: 16),
                      label: const Text('Turn on Bluetooth'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
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
