/// The emergency alert screen — the single most important surface in the app.
///
/// ## What this screen has to get right
///
/// Someone has just had a crash, or thinks they have. They are possibly
/// injured, possibly panicking, and possibly holding the phone one-handed. The
/// screen therefore:
///
/// * **cannot be dismissed by reflex.** The back gesture and the system back
///   button are both blocked while the countdown runs. A driver reaching for
///   the hazard light must not be able to swipe away the only thing that will
///   call for help.
/// * **offers exactly two decisions**, both large, both unambiguous, and both
///   non-trapping: "I'm safe" and "Send help". No third option, no settings, no
///   navigation.
/// * **states the consequence of inaction in words.** "Help is sent in 10
///   seconds" is a fact; a silent countdown is just pressure.
/// * **degrades honestly.** No GPS fix, no contacts, no network — each is named
///   on the screen rather than hidden, because a user who is told "location
///   unavailable" can act on it, while one silently given a blank map cannot.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/formatters.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../widgets/ui_kit.dart';
import '../alerts/alert_controller.dart';

/// The countdown screen.
class AccidentAlertScreen extends ConsumerStatefulWidget {
  const AccidentAlertScreen({required this.args, super.key});

  /// Passed in when the alert was launched by a route, so CONFIRM/CANCEL can
  /// target the right device-side event.
  final AlertArgs args;

  @override
  ConsumerState<AccidentAlertScreen> createState() => _AccidentAlertScreenState();
}

class _AccidentAlertScreenState extends ConsumerState<AccidentAlertScreen> {
  final GlobalKey _confirmKey = GlobalKey();
  final GlobalKey _cancelKey = GlobalKey();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AlertState state = ref.watch(alertControllerProvider);
    final int window = state.confirmWindowSec <= 0 ? 10 : state.confirmWindowSec;
    final int remaining = state.remainingSec(window);
    final MotionResolver motion = context.motion;

    return PopScope<Object?>(
      // `canPop: false` blocks the back gesture and the system back button.
      // The only exits are the two buttons.
      canPop: false,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.medium,
                    Spacing.large,
                    Spacing.medium,
                    Spacing.medium,
                  ),
                  children: <Widget>[
                    _header(context, state),
                    const SizedBox(height: Spacing.large),
                    Center(
                      child: CountdownRing(
                        remaining: remaining,
                        total: window,
                      ),
                    ),
                    const SizedBox(height: Spacing.large),
                    _consequence(context, remaining),
                    const SizedBox(height: Spacing.large),
                    _locationCard(context, state),
                    const SizedBox(height: Spacing.sm),
                    if (state.contacts.isNotEmpty)
                      _contactsCard(context, state)
                    else
                      _noContactsWarning(context),
                    if (state.nearestHospital != null) ...<Widget>[
                      const SizedBox(height: Spacing.sm),
                      _hospitalCard(context, state),
                    ],
                    if (state.problems.isNotEmpty) ...<Widget>[
                      const SizedBox(height: Spacing.sm),
                      _problemsCard(context, state),
                    ],
                    const SizedBox(height: Spacing.large),
                  ],
                ),
              ),
              // Pinned to the bottom: the two decisions are always reachable
              // with a thumb, whatever the scroll position.
              _actions(context, motion),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AlertState state) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            StatusPill(
              label: state.isManualSos ? 'SOS pressed' : 'Possible accident',
              severity: StatusSeverity.critical,
              icon: Icons.warning_amber_rounded,
            ),
          ],
        ),
        const SizedBox(height: Spacing.medium),
        Text(
          state.isManualSos ? 'HELP REQUESTED' : 'ACCIDENT DETECTED',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          state.isManualSos
              ? 'The SOS button on the node was pressed.'
              : 'The sensors detected a possible collision.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// The countdown's consequence, in words.
  ///
  /// A bare number is pressure; a stated consequence is information. Someone who
  /// understands that "send help" will contact their emergency contacts should
  /// make a different choice from someone who thinks it merely notifies the
  /// app.
  Widget _consequence(BuildContext context, int remaining) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.medium,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.emergency.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.emergency.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.campaign_outlined, size: 18, color: AppColors.emergency),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              remaining <= 0
                  ? 'Sending help now.'
                  : 'Help will be sent in $remaining second${remaining == 1 ? '' : 's'} — '
                      'your emergency contacts will be called and messaged with this location.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.emergency,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _locationCard(BuildContext context, AlertState state) {
    final GeoPoint? point = state.location;
    if (point == null) {
      return GlassCard(
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Getting your location…',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    'Your contacts will not be sent a location until this finishes.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final ThemeData theme = Theme.of(context);
    // §25: name the accuracy problem rather than hiding it. A 500 m fix is
    // useless for finding a hospital entrance, and the user needs to know that
    // before they rely on it.
    final bool imprecise = point.accuracyM > 50;

    return GlassCard(
      onTap: () => context.pushNamed(AppRoutes.location),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.electric.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.my_location, color: AppColors.electric, size: 22),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Accident location', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  // Tabular figures: these digits are read at a glance.
                  '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 3),
                StatusPill(
                  label: imprecise
                      ? 'Low accuracy ±${point.accuracyM.round()} m'
                      : 'Accurate ±${point.accuracyM.round()} m',
                  severity: imprecise ? StatusSeverity.warning : StatusSeverity.good,
                  icon: imprecise ? Icons.gps_not_fixed : Icons.gps_fixed,
                  dense: true,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ],
      ),
    );
  }

  Widget _contactsCard(BuildContext context, AlertState state) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      onTap: () => context.pushNamed(AppRoutes.contacts),
      child: Row(
        children: <Widget>[
          const Icon(Icons.groups_outlined, color: AppColors.electric),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Emergency contacts', style: theme.textTheme.titleSmall),
                Text(
                  state.contacts
                      .map((EmergencyContact c) => c.name)
                      .join(', '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ],
      ),
    );
  }

  /// Shown when no contact is configured.
  ///
  /// Worth a loud card: without a contact, "send help" cannot actually reach
  /// anyone, and the user should learn that *now* rather than after relying on
  /// a system that silently did nothing.
  Widget _noContactsWarning(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      critical: true,
      onTap: () => context.pushNamed(AppRoutes.contacts),
      child: Row(
        children: <Widget>[
          const Icon(Icons.person_off_outlined, color: AppColors.emergency),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('No emergency contacts', style: theme.textTheme.titleSmall),
                Text(
                  'Add a contact now, or the alert can only be recorded.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ],
      ),
    );
  }

  Widget _hospitalCard(BuildContext context, AlertState state) {
    final ThemeData theme = Theme.of(context);
    final hospital = state.nearestHospital!;
    return GlassCard(
      onTap: () => context.pushNamed(
        AppRoutes.hospitals,
        extra: HospitalsArgs(accidentId: state.accidentId),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.local_hospital_outlined, color: AppColors.emerald),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Nearest hospital', style: theme.textTheme.titleSmall),
                Text(
                  '${hospital.name} · ${Fmt.distance(state.hospitalDistanceM ?? 0)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ],
      ),
    );
  }

  /// Every condition that is degrading this alert, named.
  Widget _problemsCard(BuildContext context, AlertState state) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Attention needed',
            style: theme.textTheme.titleSmall?.copyWith(color: AppColors.amber),
          ),
          const SizedBox(height: Spacing.xs),
          ...state.problems.map(
            (String problem) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: Icon(Icons.error_outline, size: 12, color: AppColors.amber),
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      problem,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, MotionResolver motion) {
    final AlertState state = ref.watch(alertControllerProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Spacing.medium,
        Spacing.sm,
        Spacing.medium,
        Spacing.medium,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: context.glass.border),
        ),
      ),
      child: Row(
        children: <Widget>[
          // "I'm safe" is the false-alarm path, so it is the *less* prominent
          // button: a driver who is fine should dismiss quickly, but the design
          // should not invite it as the default reading of the screen.
          Expanded(
            child: PrimaryAction(
              key: _cancelKey,
              label: "I'm safe",
              icon: Icons.check_circle_outline,
              critical: false,
              busy: _busy && state.phase == AlertPhase.countingDown,
              onPressed: _busy ? null : _onCancel,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: PrimaryAction(
              key: _confirmKey,
              label: 'Send help',
              icon: Icons.emergency_share_outlined,
              critical: true,
              busy: _busy && state.phase == AlertPhase.sending,
              onPressed: _busy ? null : _onConfirm,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onConfirm() async {
    setState(() => _busy = true);
    HapticFeedback.heavyImpact();
    await ref.read(alertControllerProvider.notifier).sendHelp();
    if (mounted) {
      setState(() => _busy = false);
      context.goNamed(AppRoutes.hospitals, extra: HospitalsArgs(accidentId: ''));
    }
  }

  Future<void> _onCancel() async {
    setState(() => _busy = true);
    HapticFeedback.lightImpact();
    final bool ok = await ref.read(alertControllerProvider.notifier).dismiss();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      context.goNamed(AppRoutes.home);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not dismiss the alert. Try again.'),
        ),
      );
    }
  }
}
