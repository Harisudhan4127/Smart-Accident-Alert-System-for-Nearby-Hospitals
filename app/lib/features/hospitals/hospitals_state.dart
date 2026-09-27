/// The nearby-hospital screen's state.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../core/result.dart';
import '../../data/datasources/maps_datasource.dart';
import '../../data/repositories/hospital_repository.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';

/// What the hospital list shows.
@immutable
class HospitalsViewState {
  const HospitalsViewState({
    this.hospitals = const <Hospital>[],
    this.origin,
    this.loading = true,
    this.radiusM = 25000,
    this.source = HospitalSource.none,
    this.error,
  });

  final List<Hospital> hospitals;
  final GeoPoint? origin;
  final bool loading;
  final double radiusM;
  final HospitalSource source;
  final String? error;

  HospitalsViewState copyWith({
    List<Hospital>? hospitals,
    GeoPoint? origin,
    bool? loading,
    double? radiusM,
    HospitalSource? source,
    String? error,
  }) =>
      HospitalsViewState(
        hospitals: hospitals ?? this.hospitals,
        origin: origin ?? this.origin,
        loading: loading ?? this.loading,
        radiusM: radiusM ?? this.radiusM,
        source: source ?? this.source,
        error: error,
      );
}

/// Drives the hospital list.
class HospitalsViewController extends Notifier<HospitalsViewState> {
  @override
  HospitalsViewState build() {
    // Fire-and-forget: the screen renders its own loading state, and awaiting
    // here would block `build` on a permission dialog.
    unawaited(_search());
    return const HospitalsViewState();
  }

  Future<void> _search() async {
    state = state.copyWith(loading: true);

    // Load the dataset if the splash has not already done so. Cheap when it
    // has: the repository memoises the index.
    final HospitalRepository repo = ref.read(hospitalRepositoryProvider);
    if (repo.index == null) {
      await repo.load();
    }

    final Result<GeoPoint?> position =
        await ref.read(locationDatasourceProvider).currentPosition();
    final GeoPoint? origin = position.valueOrNull;
    if (origin == null) {
      state = state.copyWith(
        loading: false,
        error: position.failureOrNull?.message ?? 'No GPS fix is available.',
      );
      return;
    }

    state = state.copyWith(origin: origin);

    final Result<HospitalSearchResult> found = await repo.nearby(
      origin: origin,
      radiusM: state.radiusM,
      limit: 20,
    );
    final HospitalSearchResult? search = found.valueOrNull;
    if (search == null) {
      state = state.copyWith(
        loading: false,
        error: found.failureOrNull?.message ?? 'The search failed.',
      );
      return;
    }
    state = state.copyWith(
      hospitals: search.hospitals,
      source: search.source,
      loading: false,
    );
  }

  /// Widen the radius after an empty result.
  Future<void> widen() async {
    state = state.copyWith(radiusM: 50000);
    await _search();
  }

  Future<void> refresh() => _search();

  /// Call a hospital.
  Future<void> call(Hospital hospital) =>
      ref.read(mapsDatasourceProvider).call(hospital.phone);

  /// Show a hospital on a map.
  Future<void> showOnMap(Hospital hospital, GeoPoint? from) {
    final MapsDatasource maps = ref.read(mapsDatasourceProvider);
    return maps.searchInMaps(
      from == null
          ? hospital.name
          : '${from.latitude},${from.longitude} to '
              '${hospital.location.latitude},${hospital.location.longitude}',
    );
  }
}

/// The hospital list's state.
final NotifierProvider<HospitalsViewController, HospitalsViewState>
    hospitalsViewProvider =
    NotifierProvider<HospitalsViewController, HospitalsViewState>(
  HospitalsViewController.new,
);
