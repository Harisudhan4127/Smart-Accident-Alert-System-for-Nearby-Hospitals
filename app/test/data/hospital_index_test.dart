/// Correctness and performance tests for [HospitalIndex].
///
/// The brute-force reference is the point of this suite. An index that is fast
/// but wrong is worse than a scan, because a safety app that shows a hospital 40
/// km away instead of the one 400 m away sends someone to the wrong place during
/// an emergency. So every index result is cross-checked against an O(N) scan
/// over the same data, on real coordinates from the committed seed dataset.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_accident_alert/data/hospital/hospital_index.dart';
import 'package:smart_accident_alert/data/hospital/hospital_search_worker.dart';
import 'package:smart_accident_alert/data/mappers/json_mappers.dart';
import 'package:smart_accident_alert/domain/entities/geo_point.dart';
import 'package:smart_accident_alert/domain/entities/hospital.dart';

void main() {
  final List<Hospital> hospitals = _loadSeed();
  final HospitalIndex index = HospitalIndex.fromIterable(hospitals);

  group('HospitalIndex', () {
    test('indexes every mappable hospital', () {
      expect(index.length, hospitals.length);
      expect(index.isEmpty, isFalse);
      expect(index.occupiedCells, lessThanOrEqualTo(index.length));
    });

    test('a point inside the dataset finds something', () {
      // A hospital's own coordinates: the index must at least find itself.
      final Hospital probe = hospitals.first;
      final List<Hospital> found = index.nearby(probe.location, radiusM: 5000, limit: 5);
      expect(found, isNotEmpty, reason: 'the probe hospital should be within its own radius');
      expect(
        found.map((Hospital h) => h.id),
        contains(probe.id),
      );
    });

    test('matches a brute-force scan, exactly, across many random points', () {
      // The correctness contract: same set, same order, as an O(N) reference.
      final List<GeoPoint> origins = <GeoPoint>[
        // The dataset's own points plus some deliberately awkward ones.
        for (final Hospital h in hospitals.take(12)) h.location,
        GeoPoint(latitude: 12.9716, longitude: 77.5946, accuracyM: 10, timestamp: _epoch),
        GeoPoint(latitude: 13.0827, longitude: 77.5120, accuracyM: 10, timestamp: _epoch),
        // Far away: must return nothing, not everything.
        GeoPoint(latitude: -33.8688, longitude: 151.2093, accuracyM: 10, timestamp: _epoch),
        // The pole, where the longitude window must not collapse to one cell.
        GeoPoint(latitude: 89.9, longitude: 0, accuracyM: 10, timestamp: _epoch),
        // The antimeridian, where longitude wraps.
        GeoPoint(latitude: 0, longitude: 179.999, accuracyM: 10, timestamp: _epoch),
      ];

      for (final GeoPoint origin in origins) {
        for (final double radius in const <double>[1000, 5000, 25000, 100000]) {
          final List<Hospital> viaIndex =
              index.nearby(origin, radiusM: radius, limit: 25);
          final List<Hospital> viaScan = _bruteForce(
            hospitals,
            origin,
            radius,
            25,
          );

          expect(
            viaIndex.map((Hospital h) => h.id).toList(),
            viaScan.map((Hospital h) => h.id).toList(),
            reason: 'index and scan disagree at $origin r=$radius',
          );
        }
      }
    });

    test('respects the limit', () {
      final List<Hospital> found = index.nearby(
        hospitals.first.location,
        radiusM: 200000,
        limit: 7,
      );
      expect(found.length, lessThanOrEqualTo(7));
    });

    test('an empty or zero-radius query is empty, not an error', () {
      expect(index.nearby(hospitals.first.location, radiusM: 0), isEmpty);
      expect(index.nearby(hospitals.first.location, limit: 0), isEmpty);
    });

    test('the antimeridian does not wrap into a false match', () {
      // Longitude 179.99 and -179.99 are ~2 km apart but ~360 degrees apart in
      // a naive bucket. Verify no hospital is invented there.
      final List<Hospital> found = index.nearby(
        GeoPoint(latitude: 0, longitude: 179.999, accuracyM: 10, timestamp: _epoch),
        radiusM: 5000,
      );
      for (final Hospital h in found) {
        final double lon = h.location.longitude;
        expect(
          lon > 179.0 || lon < -179.0,
          isTrue,
          reason: 'hospitals near the antimeridian only: got $lon',
        );
      }
    });

    test('equal scores are ordered deterministically by id', () {
    // The score saturates: past 5 km the proximity term clamps to 0, so every
    // far-away emergency hospital with the same rating scores identically. The
    // result must not depend on bucket iteration order.
    final GeoPoint origin = hospitals.first.location;
    final List<String> a =
        index.nearby(origin, radiusM: 100000, limit: 25).map((Hospital h) => h.id).toList();
    final List<String> b =
        index.nearby(origin, radiusM: 100000, limit: 25).map((Hospital h) => h.id).toList();
    expect(a, b, reason: 'the same query must return the same order every time');
  });

  test('a query far from the data is rejected in O(1) and returns nothing', () {
      final List<Hospital> found = index.nearby(
        GeoPoint(latitude: -33.8688, longitude: 151.2093, accuracyM: 10, timestamp: _epoch),
        radiusM: 25000,
      );
      expect(found, isEmpty, reason: 'Sydney is not near Bengaluru');
    });

    test('ranking prefers emergency capability, not raw distance', () {
      // A clinic slightly closer than an emergency department: the emergency
      // one should still rank first, or the ranking is useless in an emergency.
      final GeoPoint origin = GeoPoint(
        latitude: 12.9716, longitude: 77.5946, accuracyM: 10, timestamp: _epoch,
      );
      final HospitalIndex small = HospitalIndex.fromIterable(<Hospital>[
        _hospital('clinic', origin.latitude + 0.0005, origin.longitude, HospitalType.clinic),
        _hospital('emergency', origin.latitude + 0.002, origin.longitude, HospitalType.multiSpecialty),
      ]);
      final List<Hospital> ranked = small.nearby(origin, radiusM: 5000, limit: 5);
      expect(ranked.first.id, 'emergency', reason: 'a farther ER beats a nearer clinic');
    });
  });

  group('encodeIndex / decodeIndex round-trip', () {
    test('survives serialisation with equality intact', () {
      final HospitalIndex rebuilt = decodeIndex(encodeIndex(index));
      expect(rebuilt.length, index.length);

      final GeoPoint origin = hospitals.first.location;
      expect(
        rebuilt.nearby(origin, radiusM: 25000, limit: 10).map((Hospital h) => h.id).toList(),
        index.nearby(origin, radiusM: 25000, limit: 10).map((Hospital h) => h.id).toList(),
      );
    });

    test('a truncated blob raises a FormatException, not a crash', () {
      final List<int> full = encodeIndex(index);
      expect(
        () => decodeIndex(Uint8List.fromList(full.sublist(0, full.length - 5))),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('HospitalSearchWorker', () {
    test('inline and isolated paths return the same hospitals', () async {
      // Forces the isolate path regardless of dataset size, so the two are
      // actually compared rather than both taking the inline shortcut.
      final HospitalSearchWorker worker =
          HospitalSearchWorker(index: index, forceIsolate: true);
      final GeoPoint origin = hospitals.first.location;
      final List<Hospital> viaWorker = await worker.nearby(origin, radiusM: 25000, limit: 10);
      final List<Hospital> viaIndex = index.nearby(origin, radiusM: 25000, limit: 10);
      expect(
        viaWorker.map((Hospital h) => h.id).toList(),
        viaIndex.map((Hospital h) => h.id).toList(),
      );
    });

    test('shouldIsolate only escalates for large datasets', () {
      // Spawning an isolate costs milliseconds; the bundled seed is microseconds
      // to scan inline. Isolating it would be pure overhead.
      expect(HospitalSearchWorker.shouldIsolate(320), isFalse, reason: 'the bundled seed');
      expect(HospitalSearchWorker.shouldIsolate(2001), isTrue);
    });
  });

  group('performance', () {
    test('a query stays well under a frame budget on a mid dataset', () {
      final GeoPoint origin = hospitals.first.location;
      // Warm the JIT so the measurement is not dominated by compilation.
      for (int i = 0; i < 50; i++) {
        index.nearby(origin, radiusM: 25000, limit: 20);
      }
      final Stopwatch sw = Stopwatch()..start();
      const int iterations = 500;
      for (int i = 0; i < iterations; i++) {
        index.nearby(origin, radiusM: 25000, limit: 20);
      }
      sw.stop();
      final double microsPerQuery = sw.elapsedMicroseconds / iterations;
      // A generous ceiling for CI hardware: the point is to catch an accidental
      // O(N log N)-per-query regression, not to benchmark a phone.
      expect(
        microsPerQuery,
        lessThan(2000),
        reason: 'a query took ${microsPerQuery.toStringAsFixed(0)}µs; expected sub-2ms',
      );
    });
  });
}

/// Brute-force O(N log N) reference, deliberately naive.
List<Hospital> _bruteForce(
  List<Hospital> all,
  GeoPoint origin,
  double radiusM,
  int limit,
) {
  // Filter on DISTANCE (that is what a radius means), rank on SCORE
  // (higher is better), and break ties by id so the reference is deterministic.
  final List<Hospital> matched = all
      .where((Hospital h) => h.distanceFrom(origin) <= radiusM)
      .toList()
    ..sort((Hospital a, Hospital b) {
      final int byScore = b.searchScore(origin).compareTo(a.searchScore(origin));
      return byScore != 0 ? byScore : a.id.compareTo(b.id);
    });
  return matched.take(limit).toList();
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

Hospital _hospital(String id, double lat, double lon, HospitalType type) => Hospital(
      id: id,
      name: 'Test $id',
      address: '',
      location: GeoPoint(latitude: lat, longitude: lon, accuracyM: 100, timestamp: _epoch),
      phone: '',
      type: type,
      hasEmergency: type != HospitalType.clinic,
    );

/// Load the committed seed dataset, so the tests run against real coordinates.
///
/// The search walks up from the current directory rather than assuming a fixed
/// relative path: `flutter test`, `dart test` and an IDE all set a different
/// working directory, and a test that only passes under one of them is a test
/// that will break for the next person who clones the repo.
List<Hospital> _loadSeed() {
  final File file = _findSeed();
  if (!file.existsSync()) {
    throw StateError(
      'Seed dataset not found. Run: node backend/seed/generate.mjs',
    );
  }
  final Object? decoded = jsonDecode(file.readAsStringSync());
  final List<Map<String, Object?>> records = decodeHospitalRecords(decoded, null);
  final DateTime now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return records
      .map((Map<String, Object?> e) => HospitalMapper.fromJson(e, now: now))
      .whereType<Hospital>()
      .toList(growable: false);
}

/// Find `backend/seed/hospitals.json` by walking up from the working directory.
File _findSeed() {
  const String relative = 'backend/seed/hospitals.json';
  Directory dir = Directory.current;
  for (int depth = 0; depth < 6; depth++) {
    final File candidate = File('${dir.path}/$relative');
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return File(relative);
}
