/// The dashboard (PROJECT_PLAN §12, Screen 2).
///
/// The screen a driver glances at. Three things matter at a glance: is the node
/// connected, do I have a location, is anything queued. Everything else is
/// secondary, and the emergency actions are pinned to the bottom where a thumb
/// reaches them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/telemetry.dart';
import '../../widgets/ui_kit.dart';
import '../alerts/alert_controller.dart';
import 'home_state.dart';

/// The dashboard.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final HomeState home = ref.watch(homeStateProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'SMART ACCIDENT ALERT',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
            Text(
              home.deviceLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            onPressed: () => context.pushNamed(AppRoutes.history),
            icon: const Icon(Icons.history),
            tooltip: 'Accident history',
          ),
          IconButton(
            onPressed: () => context.pushNamed(AppRoutes.settings),
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (home.banner != null) NoticeBanner(message: home.banner!, severity: home.bannerSeverity),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(homeStateProvider.notifier).refresh(),
              child: ListView(
                padding: const EdgeInsets.all(Spacing.medium),
                children: <Widget>[
                  _statusCard(context, home),
                  const SizedBox(height: Spacing.medium),
                  _metrics(context, home),
                  const SizedBox(height: Spacing.medium),
                  if (home.device != null) _telemetryCard(context, home),
                  const SizedBox(height: Spacing.medium),
                  _quickActions(context, home),
                ],
              ),
            ),
          ),
          _emergencyActions(context, home),
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context, HomeState home) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: home.linkSeverity == StatusSeverity.good
                      ? AppColors.emerald.withValues(alpha: 0.15)
                      : AppColors.amber.withValues(alpha: 0.15),
                ),
                child: Icon(
                  home.linkIcon,
                  color: home.linkSeverity == StatusSeverity.good
                      ? AppColors.emerald
                      : AppColors.amber,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      home.linkLabel,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      home.linkDetail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              StatusPill(
                label: home.linkShortLabel,
                severity: home.linkSeverity,
                dense: true,
              ),
            ],
          ),
          if (home.linkSeverity != StatusSeverity.good &&
              home.linkHint != null) ...<Widget>[
            const SizedBox(height: Spacing.sm),
            TextButton.icon(
              onPressed: home.linkAction(
                ref.read(homeStateProvider.notifier),
                context,
              ),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(home.linkHint!),
            ),
          ],
        ],
      ),
    );
  }

  Widget _metrics(BuildContext context, HomeState home) {
    return Row(
      children: <Widget>[
        Expanded(
          child: MetricTile(
            label: 'GPS',
            value: home.gpsValue,
            icon: Icons.gps_fixed,
            severity: home.gpsSeverity,
            caption: home.gpsCaption,
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: MetricTile(
            label: 'Network',
            value: home.networkValue,
            icon: Icons.cloud_outlined,
            severity: home.networkSeverity,
            caption: home.pendingUploads > 0
                ? '${home.pendingUploads} queued'
                : null,
          ),
        ),
      ],
    );
  }

  /// Live telemetry, throttled.
  ///
  /// Deliberately *not* rebuilding at 50 Hz. The dashboard shows rounded values
  /// that a driver reads at a glance, so it samples at 4 Hz via
  /// [HomeState.telemetry]. Rebuilding a dashboard 50 times a second
  /// would burn battery for no visible gain, and would fight the alert screen's
  /// animations for the main thread.
  Widget _telemetryCard(BuildContext context, HomeState home) {
    final TelemetryRecord? t = home.telemetry;
    if (t == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader('Live sensors'),
          Row(
            children: <Widget>[
              Expanded(
                child: MetricTile(
                  label: 'Impact',
                  value: (t.magMg / 1000).toStringAsFixed(2),
                  unit: 'g',
                  icon: Icons.speed,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: MetricTile(
                  label: 'Rotation',
                  value: home.gyrationDps.toStringAsFixed(0),
                  unit: '°/s',
                  icon: Icons.rotate_right,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: MetricTile(
                  label: 'Peak',
                  value: (t.peakMg / 1000).toStringAsFixed(1),
                  unit: 'g',
                  icon: Icons.trending_up,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: <Widget>[
              StatusPill(
                label: t.flags.sw420 ? 'Vibration' : 'No vibration',
                severity: t.flags.sw420 ? StatusSeverity.warning : StatusSeverity.neutral,
                icon: Icons.vibration,
                dense: true,
              ),
              const SizedBox(width: Spacing.xs),
              StatusPill(
                label: t.state.name,
                severity: home.stateSeverity,
                dense: true,
              ),
              const Spacer(),
              Text(
                '${home.telemetryHz.round()} Hz',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickActions(BuildContext context, HomeState home) {
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            onPressed: home.busy ? null : () => _testAlert(context),
            icon: const Icon(Icons.science_outlined, size: 18),
            label: const Text('Test alert'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: Spacing.medium),
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => context.pushNamed(AppRoutes.contacts),
            icon: const Icon(Icons.groups_outlined, size: 18),
            label: const Text('Contacts'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: Spacing.medium),
            ),
          ),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => context.pushNamed(AppRoutes.hospitals,
                extra: const HospitalsArgs(accidentId: '')),
            icon: const Icon(Icons.local_hospital_outlined, size: 18),
            label: const Text('Hospitals'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: Spacing.medium),
            ),
          ),
        ),
      ],
    );
  }

  /// Test alert.
  ///
  /// Runs the node's detector against synthetic data, so the whole alert flow
  /// can be rehearsed without a crash. Deliberately labelled "test" rather than
  /// hidden in settings: a prototype needs a way to demonstrate itself, and a
  /// button that is easy to find is less likely to be pressed by accident than
  /// one buried three menus deep.
  Future<void> _testAlert(BuildContext context) async {
    final AlertController controller = ref.read(alertControllerProvider.notifier);
    await controller.begin(eventId: 'test-${DateTime.now().millisecondsSinceEpoch}');
    if (!context.mounted) return;
    context.pushNamed(AppRoutes.alert, extra: const AlertArgs(fromSos: false));
  }

  Widget _emergencyActions(BuildContext context, HomeState home) {
    return Container(
      padding: const EdgeInsets.all(Spacing.medium),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: context.glass.border)),
      ),
      child: PrimaryAction(
        label: 'SOS — EMERGENCY',
        icon: Icons.sos,
        critical: true,
        onPressed: home.busy
            ? null
            : () async {
                final AlertController controller =
                    ref.read(alertControllerProvider.notifier);
                await controller.begin(
                  eventId: 'sos-${DateTime.now().millisecondsSinceEpoch}',
                  manualSos: true,
                  // No countdown: the user pressed the button, so asking them to
                  // confirm their own SOS wastes the ten seconds that matter.
                  confirmWindowSec: 0,
                );
                if (!context.mounted) return;
                context.pushNamed(
                  AppRoutes.alert,
                  extra: AlertArgs(fromSos: true),
                );
              },
      ),
    );
  }
}
