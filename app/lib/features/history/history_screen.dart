/// Accident history (PROJECT_PLAN §12, Screen 7; §18).
///
/// Grouped by day, newest first, showing the §18 status of each record. A
/// history screen is read after the fact — often by someone anxious — so it
/// leads with the outcome (was this a real accident, was help sent) rather than
/// with sensor data.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../widgets/ui_kit.dart';
import 'history_state.dart';

/// The accident history list.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HistoryViewState state = ref.watch(historyViewProvider);
    final ThemeData theme = Theme.of(context);

    // Flatten groups into rows once. Called on every build, but the group list
    // is at most a few dozen entries, so this is a trivial allocation compared
    // with the rebuild it causes.
    final List<_HistoryRow> rows = <_HistoryRow>[
      for (final HistoryGroup group in state.groups) ...<_HistoryRow>[
        _HistoryRow.header(group.label),
        for (final AccidentRecord record in group.records)
          _HistoryRow.record(record),
      ],
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Accident history')),
      body: switch (state) {
        HistoryViewState(status: HistoryStatus.loading) =>
          const Center(child: CircularProgressIndicator()),
        HistoryViewState(status: HistoryStatus.error, :final String error) => EmptyState(
            icon: Icons.cloud_off,
            title: 'History unavailable',
            message: error,
            action: FilledButton(
              onPressed: () => ref.read(historyViewProvider.notifier).reload(),
              child: const Text('Try again'),
            ),
          ),
        HistoryViewState(records: final List<AccidentRecord> records)
            when records.isEmpty =>
          const EmptyState(
            icon: Icons.history,
            title: 'No accidents recorded',
            message: 'When the sensors detect a possible collision, or you '
                'press SOS, it will appear here.',
          ),
        HistoryViewState() =>
          RefreshIndicator(
            onRefresh: () => ref.read(historyViewProvider.notifier).reload(),
            // Flattened once per build into a typed row list, rather than
            // re-deriving "is this index a header or a record?" inside
            // `itemBuilder`. The list view is still lazy, so only visible rows
            // build; the flattening is O(n) over a page of 50, which is free.
            child: ListView.builder(
              padding: const EdgeInsets.all(Spacing.medium),
              itemCount: rows.length,
              itemBuilder: (BuildContext context, int index) {
                final _HistoryRow row = rows[index];
                if (row.header != null) {
                  return Padding(
                    padding: const EdgeInsets.only(top: Spacing.sm, bottom: Spacing.xs),
                    child: Text(
                      row.header!,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.xs),
                  child: HistoryTile(
                    record: row.record!,
                    onTap: () => context.pushNamed(AppRoutes.location),
                  ),
                );
              },
            ),
          ),
      },
    );
  }
}

/// One row of the flattened history list: either a day header or a record.
class _HistoryRow {
  const _HistoryRow.header(this.header) : record = null;
  const _HistoryRow.record(this.record) : header = null;

  final String? header;
  final AccidentRecord? record;
}
/// One history row.
class HistoryTile extends StatelessWidget {
  const HistoryTile({required this.record, this.onTap, super.key});

  final AccidentRecord record;
  final VoidCallback? onTap;

  /// §18 status → the language a person would use.
  static String statusLabel(AccidentStatus status) => switch (status) {
        AccidentStatus.detected => 'Detected',
        AccidentStatus.cancelled => 'False alarm',
        AccidentStatus.confirmed => 'Confirmed',
        AccidentStatus.alertSent => 'Help sent',
        AccidentStatus.resolved => 'Resolved',
        AccidentStatus.unknown => 'Unknown',
      };

  static StatusSeverity statusSeverity(AccidentStatus status) => switch (status) {
        AccidentStatus.alertSent || AccidentStatus.resolved => StatusSeverity.good,
        AccidentStatus.confirmed => StatusSeverity.warning,
        AccidentStatus.detected => StatusSeverity.critical,
        AccidentStatus.cancelled => StatusSeverity.neutral,
        AccidentStatus.unknown => StatusSeverity.warning,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final GeoPoint location = record.location;

    return GlassCard(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.emergency.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.car_crash_outlined, color: AppColors.emergency, size: 20),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  Fmt.dateTime(record.occurredAt),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  Fmt.coordinatePair(location),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Spacing.xs),
                Wrap(
                  spacing: Spacing.xxs,
                  runSpacing: Spacing.xxs,
                  children: <Widget>[
                    StatusPill(
                      label: statusLabel(record.status),
                      severity: statusSeverity(record.status),
                      dense: true,
                    ),
                    // A record that has not reached the cloud is a real state
                    // (§25), so it is shown rather than hidden — the user should
                    // know it is not yet backed up.
                    if (!record.isSynced)
                      StatusPill(
                        label: 'Pending sync',
                        severity: StatusSeverity.warning,
                        icon: Icons.cloud_upload_outlined,
                        dense: true,
                      ),
                    if (!record.isLocationPrecise)
                      StatusPill(
                        label: 'Low accuracy',
                        severity: StatusSeverity.warning,
                        icon: Icons.gps_not_fixed,
                        dense: true,
                      ),
                  ],
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        ],
      ),
    );
  }
}
