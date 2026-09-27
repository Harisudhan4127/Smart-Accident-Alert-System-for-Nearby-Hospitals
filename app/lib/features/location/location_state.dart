/// The location screen's state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../core/result.dart';
import '../../domain/entities/geo_point.dart';

/// A fix is "stale" past this age.
///
/// 30 s is not arbitrary: a car at 60 km/h covers 500 m in that time, so a fix
/// older than this is likely describing a different piece of road entirely.
const Duration kFixStaleAfter = Duration(seconds: 30);

/// What the location screen shows.
@immutable
class LocationViewState {
  const LocationViewState({
    this.point,
    this.loading = true,
    this.error,
    this.accidentId = '',
  });

  final GeoPoint? point;
  final bool loading;
  final String? error;

  /// The accident this location belongs to, when opened from one.
  final String accidentId;

  /// Whether the fix is too old to trust.
  bool get isStale =>
      point != null && point!.timestamp.add(kFixStaleAfter).isBefore(DateTime.now());

  LocationViewState copyWith({
    GeoPoint? point,
    bool? loading,
    String? error,
    String? accidentId,
  }) =>
      LocationViewState(
        point: point ?? this.point,
        loading: loading ?? this.loading,
        error: error,
        accidentId: accidentId ?? this.accidentId,
      );
}

/// Drives the location screen.
class LocationViewController extends Notifier<LocationViewState> {
  StreamSubscription<GeoPoint>? _watch;

  @override
  LocationViewState build() {
    ref.onDispose(() => unawaited(_watch?.cancel()));
    unawaited(_acquire());
    return const LocationViewState();
  }

  Future<void> _acquire() async {
    state = state.copyWith(loading: true, error: null);
    final Result<GeoPoint?> result =
        await ref.read(locationDatasourceProvider).currentPosition();

    if (result case final FailureResult<GeoPoint?> failure) {
      state = state.copyWith(loading: false, error: failure.failure.message);
      return;
    }

    final GeoPoint? point = result.valueOrNull;
    if (point == null) {
      state = state.copyWith(loading: false, error: 'No GPS fix is available yet.');
      return;
    }
    state = state.copyWith(loading: false, point: point, error: null);

    // Keep watching so a coarse first fix refines in place, rather than the
    // user having to pull to refresh. A screen showing "±500 m" that silently
    // becomes "±8 m" is exactly the right behaviour.
    _watch ??= ref.read(locationDatasourceProvider).watch().listen((GeoPoint p) {
      state = state.copyWith(point: p, error: null);
    });
  }

  /// Get a fresh fix.
  Future<void> refresh() => _acquire();

  /// Open the location in a map application (§15).
  Future<void> openInMaps() async {
    final GeoPoint? point = state.point;
    if (point == null) return;
    await ref.read(mapsDatasourceProvider).openInMaps(point, label: 'Accident');
  }
}

/// The location screen's state.
final NotifierProvider<LocationViewController, LocationViewState>
    locationViewProvider =
    NotifierProvider<LocationViewController, LocationViewState>(
  LocationViewController.new,
);
