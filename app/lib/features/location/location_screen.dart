/// Accident location (PROJECT_PLAN §12, Screen 4).
///
/// The coordinates, the accuracy, and a map. Deliberately shows the raw numbers
/// as well as the map: a responder reading them over the phone needs the actual
/// figures, and a user debugging a bad fix needs to see that the accuracy is
/// poor rather than being told "something went wrong".
library;


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/geo_point.dart';
import '../../widgets/ui_kit.dart';
import 'location_state.dart';

/// The location screen.
class LocationScreen extends ConsumerStatefulWidget {
  const LocationScreen({super.key});

  @override
  ConsumerState<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends ConsumerState<LocationScreen> {
  @override
  Widget build(BuildContext context) {
    final LocationViewState state = ref.watch(locationViewProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Accident location'),
        actions: <Widget>[
          if (state.point != null)
            IconButton(
              onPressed: () => ref.read(locationViewProvider.notifier).refresh(),
              icon: const Icon(Icons.my_location),
              tooltip: 'Get a fresh fix',
            ),
        ],
      ),
      body: state.point == null
          ? _waiting(context, state)
          : ListView(
              padding: const EdgeInsets.all(Spacing.medium),
              children: <Widget>[
                _coordinates(context, state),
                const SizedBox(height: Spacing.medium),
                _mapPlaceholder(context, state),
                const SizedBox(height: Spacing.medium),
                _accuracyCard(context, state),
                const SizedBox(height: Spacing.medium),
                PrimaryAction(
                  label: 'Open in Maps',
                  icon: Icons.map_outlined,
                  onPressed: () => ref.read(locationViewProvider.notifier).openInMaps(),
                ),
                const SizedBox(height: Spacing.sm),
                PrimaryAction(
                  label: 'Find nearby hospitals',
                  icon: Icons.local_hospital_outlined,
                  critical: false,
                  onPressed: () => context.pushNamed(
                    AppRoutes.hospitals,
                    extra: HospitalsArgs(accidentId: state.accidentId),
                  ),
                ),
                if (state.error != null) ...<Widget>[
                  const SizedBox(height: Spacing.medium),
                  Text(
                    state.error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.amber),
                  ),
                ],
              ],
            ),
      bottomNavigationBar: state.point == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.sm),
                child: Text(
                  'Location is ${state.isStale ? 'stale' : 'current'}. '
                  'It is only as good as the phone\'s GPS.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
    );
  }

  Widget _waiting(BuildContext context, LocationViewState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          const SizedBox(height: Spacing.medium),
          Text('Getting your location…', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Spacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
            child: Text(
              state.error ?? 'This can take a few seconds, especially indoors.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coordinates(BuildContext context, LocationViewState state) {
    final GeoPoint p = state.point!;
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader('Coordinates (WGS-84)'),
          _coordinateRow(context, 'Latitude', '${p.latitude.toStringAsFixed(6)}°'),
          const SizedBox(height: Spacing.xs),
          _coordinateRow(context, 'Longitude', '${p.longitude.toStringAsFixed(6)}°'),
          const SizedBox(height: Spacing.sm),
          // The shareable form. One tap to copy, because reading six digits aloud
          // over a phone to a dispatcher is exactly the situation where a
          // transcription error causes real harm.
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  p.latLngLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: p.latLngLabel));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Coordinates copied')),
                  );
                },
                icon: const Icon(Icons.copy, size: 17),
                tooltip: 'Copy',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _coordinateRow(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// A map placeholder.
  ///
  /// `google_maps_flutter` needs an API key and a network. When either is
  /// missing — which is the *normal* case for an offline demo, and the case in
  /// a tunnel — a broken grey box is worse than an honest schematic. So this
  /// shows a readable coordinate card instead, and the external Maps button
  /// below always works.
  Widget _mapPlaceholder(BuildContext context, LocationViewState state) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      child: SizedBox(
        height: 180,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.map_outlined, size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: Spacing.sm),
              Text(
                'In-app map needs network',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.large),
                child: Text(
                  'Use "Open in Maps" below for a street-level view.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accuracyCard(BuildContext context, LocationViewState state) {
    final ThemeData theme = Theme.of(context);
    final int metres = state.point!.accuracyM.round();
    final StatusSeverity severity = metres <= 20
        ? StatusSeverity.good
        : metres <= 100
            ? StatusSeverity.warning
            : StatusSeverity.critical;

    return GlassCard(
      child: Row(
        children: <Widget>[
          Icon(
            severity == StatusSeverity.good ? Icons.gps_fixed : Icons.gps_not_fixed,
            color: severity == StatusSeverity.good ? AppColors.emerald : AppColors.amber,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Accuracy', style: theme.textTheme.titleSmall),
                Text(
                  switch (severity) {
                    StatusSeverity.good => 'Good enough for a responder to find you.',
                    StatusSeverity.warning => 'Roughly a block out. Move to open sky.',
                    _ => 'Too coarse to be useful. Wait for a better fix.',
                  },
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '±$metres m',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
