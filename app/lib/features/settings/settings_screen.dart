/// Settings and diagnostics (PROJECT_PLAN §21's tool surface, §6.4's CONFIG).
///
/// Two halves. The top is what a user changes: the detection thresholds, the
/// cancel window, the buzzer, the theme. The bottom is what they read when
/// something is wrong: live firmware counters from the node's `DIAG` message
/// (§6.9), which is the only way to tell "the sensor is not reporting" from
/// "the link is congested" from "the detector is set impossibly high".
library;


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../data/protocol/ble_frame.dart' as wire;
import '../../data/protocol/messages.dart';
import '../../widgets/ui_kit.dart';
import 'settings_state.dart';

/// The settings screen.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SettingsViewState state = ref.watch(settingsViewProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Spacing.medium),
              children: <Widget>[
                if (state.banner != null) ...<Widget>[
                  NoticeBanner(
                    message: state.banner!,
                    severity: state.bannerSeverity,
                  ),
                  const SizedBox(height: Spacing.medium),
                ],

                const SectionHeader('Detection'),
                GlassCard(
                  child: Column(
                    children: <Widget>[
                      _slider(
                        context,
                        label: 'Impact threshold',
                        help: 'How hard a jolt must be before the detector considers '
                            'a crash. Raise it if you get false alarms on rough roads.',
                        value: state.config.accelThresholdMg.toDouble(),
                        min: 1500,
                        max: 8000,
                        divisions: 65,
                        unit: 'mg',
                        display: '${state.config.accelThresholdMg} mg '
                            '(${(state.config.accelThresholdMg / 1000).toStringAsFixed(1)} g)',
                        onChanged: (double v) => ref
                            .read(settingsViewProvider.notifier)
                            .setAccelThreshold(v.round()),
                      ),
                      const Divider(height: Spacing.large),
                      _slider(
                        context,
                        label: 'Rotation threshold',
                        help: 'How much spin counts as a rollover.',
                        value: state.config.gyroThresholdDps,
                        min: 80,
                        max: 800,
                        divisions: 36,
                        display: '${state.config.gyroThresholdDps.round()} °/s',
                        onChanged: (double v) => ref
                            .read(settingsViewProvider.notifier)
                            .setGyroThreshold(v),
                      ),
                      const Divider(height: Spacing.large),
                      _slider(
                        context,
                        label: 'Cancel window',
                        help: 'How long you have to call a false alarm before help '
                            'is sent. Shorter means less delay for a real crash.',
                        value: state.config.confirmWindowSec.toDouble(),
                        min: 5,
                        max: 60,
                        divisions: 11,
                        display: '${state.config.confirmWindowSec} s',
                        onChanged: (double v) => ref
                            .read(settingsViewProvider.notifier)
                            .setConfirmWindow(v.round()),
                      ),
                      const Divider(height: Spacing.large),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: state.config.vibrationRequired,
                        onChanged: (bool v) =>
                            ref.read(settingsViewProvider.notifier).setVibrationRequired(v),
                        title: const Text('Require vibration sensor'),
                        subtitle: const Text(
                          'Ignore an impact unless the SW-420 also fires. Fewer false '
                          'alarms, but a crash with no vibration is missed.',
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: state.config.autoArm,
                        onChanged: (bool v) =>
                            ref.read(settingsViewProvider.notifier).setAutoArm(v),
                        title: const Text('Arm automatically'),
                        subtitle: const Text('Start monitoring as soon as the app connects.'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: Spacing.large),
                const SectionHeader('Alerts'),
                GlassCard(
                  child: Column(
                    children: <Widget>[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: state.config.buzzerEnabled,
                        onChanged: (bool v) =>
                            ref.read(settingsViewProvider.notifier).setBuzzerEnabled(v),
                        title: const Text('Buzzer on the node'),
                        subtitle: const Text('A local sound, in case the phone is not nearby.'),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: state.config.ledEnabled,
                        onChanged: (bool v) =>
                            ref.read(settingsViewProvider.notifier).setLedEnabled(v),
                        title: const Text('LED indicators'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: Spacing.large),
                const SectionHeader('Diagnostics'),
                if (state.diag == null)
                  GlassCard(
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.usb_off, size: 18),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            'Connect to a node to read its diagnostics.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _diagCard(context, ref, state),

                const SizedBox(height: Spacing.large),
                const SectionHeader('About'),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _aboutRow(context, 'App', '1.0.0'),
                      _aboutRow(context, 'Protocol', 'v${wire.kProtocolVersion}'),
                      _aboutRow(
                        context,
                        'Node firmware',
                        state.firmwareVersion ?? '—',
                      ),
                      const SizedBox(height: Spacing.sm),
                      Row(
                        children: <Widget>[
                          const Icon(Icons.warning_amber_rounded,
                              size: 16, color: AppColors.amber),
                          const SizedBox(width: Spacing.xs),
                          Expanded(
                            child: Text(
                              'This is a prototype. It is not a certified '
                              'emergency system, and it can produce false '
                              'alarms or miss real ones.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.amber,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required String help,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    String? unit,
    required ValueChanged<double> onChanged,
  }) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(label, style: theme.textTheme.titleSmall),
            ),
            // Tabular figures so the number does not jitter while dragging.
            Text(
              display,
              style: theme.textTheme.labelLarge?.copyWith(
                color: AppColors.electric,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
        Text(
          help,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _diagCard(BuildContext context, WidgetRef ref, SettingsViewState state) {
    final DiagMessage d = state.diag!;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('Node diagnostics', style: Theme.of(context).textTheme.titleSmall),
              ),
              TextButton.icon(
                onPressed: () => ref.read(settingsViewProvider.notifier).readDiagnostics(),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: <Widget>[
              Expanded(
                child: MetricTile(label: 'CPU', value: '${d.cpuLoadPct.round()}', unit: '%'),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: MetricTile(label: 'Rate', value: '${d.loopHz.round()}', unit: 'Hz'),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: MetricTile(
                  label: 'Free heap',
                  value: '${(d.heapFree / 1024).round()}',
                  unit: 'KB',
                  severity: d.heapFree < 40000 ? StatusSeverity.warning : StatusSeverity.neutral,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.xxs,
            runSpacing: Spacing.xxs,
            children: <Widget>[
              StatusPill(
                label: 'CRC errors ${d.crcErrors ?? 0}',
                severity: (d.crcErrors ?? 0) > 0 ? StatusSeverity.warning : StatusSeverity.good,
                dense: true,
              ),
              StatusPill(
                label: 'Dropped ${d.droppedFrames ?? 0}',
                severity: (d.droppedFrames ?? 0) > 0 ? StatusSeverity.warning : StatusSeverity.good,
                dense: true,
              ),
              StatusPill(
                label: 'Uptime ${Fmt.uptime(Duration(milliseconds: d.uptimeMs))}',
                severity: StatusSeverity.neutral,
                dense: true,
              ),
              if ((d.mpuI2cErrors ?? 0) > 0)
                StatusPill(
                  label: 'I²C errors ${d.mpuI2cErrors}',
                  severity: StatusSeverity.critical,
                  icon: Icons.error_outline,
                  dense: true,
                ),
              if ((d.watchdogResets ?? 0) > 0)
                StatusPill(
                  label: 'Watchdog resets ${d.watchdogResets}',
                  severity: StatusSeverity.warning,
                  dense: true,
                ),
              if ((d.brownoutCount ?? 0) > 0)
                StatusPill(
                  label: 'Brownouts ${d.brownoutCount}',
                  severity: StatusSeverity.critical,
                  dense: true,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
