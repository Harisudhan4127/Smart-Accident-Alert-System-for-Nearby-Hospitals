/// Nearby hospitals (PROJECT_PLAN §12, Screen 5; §16).
///
/// A proximity list over the [HospitalIndex], ranked by
/// [Hospital.searchScore] rather than raw distance — an emergency department
/// 2 km away is a better destination than a clinic 800 m away, and a
/// distance-only sort would put the wrong one first. The reason is shown on each
/// row, so the ranking is legible rather than magic.
library;


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';
import '../../widgets/ui_kit.dart';
import 'hospitals_state.dart';

/// The nearby-hospital list.
class HospitalsScreen extends ConsumerStatefulWidget {
  const HospitalsScreen({required this.accidentId, super.key});

  /// The accident the search is centred on. Empty when opened from the
  /// dashboard, in which case the phone's current position is used.
  final String accidentId;

  @override
  ConsumerState<HospitalsScreen> createState() => _HospitalsScreenState();
}

class _HospitalsScreenState extends ConsumerState<HospitalsScreen> {
  @override
  Widget build(BuildContext context) {
    final HospitalsViewState state = ref.watch(hospitalsViewProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby hospitals'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: state.origin != null && state.hospitals.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(left: Spacing.medium, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${state.hospitals.length} within ${Fmt.distance(state.radiusM)} · '
                      '${state.source.name} data',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
      body: _body(context, state),
    );
  }

  Widget _body(BuildContext context, HospitalsViewState state) {
    if (state.loading && state.hospitals.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    if (state.hospitals.isEmpty) {
      return EmptyState(
        icon: Icons.local_hospital_outlined,
        title: state.origin == null
            ? 'No location to search from'
            : 'No hospitals found',
        message: state.origin == null
            ? 'Grant location access, or open this from an accident, to search for nearby hospitals.'
            : 'Nothing was found within ${Fmt.distance(state.radiusM)}. '
                'Widen the search, or call the emergency services directly.',
        action: state.origin == null
            ? null
            : FilledButton.icon(
                onPressed: () => ref.read(hospitalsViewProvider.notifier).widen(),
                icon: const Icon(Icons.zoom_out_map),
                label: const Text('Search 50 km instead'),
              ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(Spacing.medium),
      itemCount: state.hospitals.length,
      // `ListView.separated` with a builder: only the visible rows build, so a
      // long list costs nothing until it is scrolled.
      separatorBuilder: (_, __) => const SizedBox(height: Spacing.xs),
      itemBuilder: (BuildContext context, int index) {
        final Hospital hospital = state.hospitals[index];
        final GeoPoint? origin = state.origin;
        return HospitalTile(
          hospital: hospital,
          distanceM: origin == null ? null : hospital.distanceFrom(origin),
          rank: index,
          onCall: () => ref.read(hospitalsViewProvider.notifier).call(hospital),
          onMap: () => ref.read(hospitalsViewProvider.notifier).showOnMap(hospital, origin),
        );
      },
    );
  }
}

/// One hospital row.
class HospitalTile extends StatelessWidget {
  const HospitalTile({
    required this.hospital,
    required this.rank,
    this.distanceM,
    this.onCall,
    this.onMap,
    super.key,
  });

  final Hospital hospital;
  final int rank;
  final double? distanceM;
  final VoidCallback? onCall;
  final VoidCallback? onMap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool emergency = hospital.takesEmergencies;

    return GlassCard(
      onTap: onMap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The rank is the recommendation, so it is visually primary for the
          // top entries.
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: rank == 0
                  ? AppColors.emerald.withValues(alpha: 0.18)
                  : theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Text(
              '${rank + 1}',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: rank == 0 ? AppColors.emerald : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  hospital.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (hospital.address.isNotEmpty)
                  Text(
                    hospital.address,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: Spacing.xs),
                Wrap(
                  spacing: Spacing.xxs,
                  runSpacing: Spacing.xxs,
                  children: <Widget>[
                    if (distanceM != null)
                      StatusPill(
                        label: Fmt.distance(distanceM!),
                        severity: StatusSeverity.neutral,
                        icon: Icons.near_me,
                        dense: true,
                      ),
                    StatusPill(
                      label: emergency ? 'Emergency' : (hospital.type?.wireName ?? 'Clinic'),
                      severity: emergency ? StatusSeverity.good : StatusSeverity.warning,
                      icon: Icons.local_hospital,
                      dense: true,
                    ),
                    if (hospital.beds != null)
                      StatusPill(
                        label: '${hospital.beds} beds',
                        severity: StatusSeverity.neutral,
                        dense: true,
                      ),
                  ],
                ),
                if (hospital.phone.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Spacing.xs),
                  Row(
                    children: <Widget>[
                      TextButton.icon(
                        onPressed: onCall,
                        icon: const Icon(Icons.call, size: 15),
                        label: const Text('Call'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      TextButton.icon(
                        onPressed: onMap,
                        icon: const Icon(Icons.directions, size: 15),
                        label: const Text('Directions'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
