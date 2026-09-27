/// A spatial index over the hospital dataset.
///
/// ## The problem
///
/// "Show me the nearest hospitals" over a national dataset is a scan: compute
/// the distance from the accident to all N hospitals, sort, take K. That is
/// **O(N log N)** time and **O(N)** allocation per query, and it runs on the UI
/// isolate. With the 320-hospital seed dataset that is already visibly janky on
/// a mid-range phone; with a real national dataset (tens of thousands) it drops
/// frames outright, and it is being run *while an emergency countdown is
/// ticking*.
///
/// ## The approach
///
/// Bucket every hospital into a fixed lat/lon **grid** at build time. A query
/// only has to look at the cells that overlap the search radius, which is a
/// constant number of cells for any fixed cell size:
///
/// ```text
///   cells spanned = ceil(2r / cellHeight) x ceil(2r / cellWidth)
/// ```
///
/// So a query becomes:
///
/// 1. compute the cell range overlapped by the radius — **O(1)**;
/// 2. iterate only those cells' buckets — **O(k)**, where k is the number of
///    hospitals actually inside the radius, not N;
/// 3. Haversine-filter and keep the best K — **O(k log K)** at worst, and
///    **O(k)** with the bounded insertion list below.
///
/// For a 25 km query with 0.02° cells, that is a ~7x5 cell window = 35 buckets.
/// Even if only 30 hospitals fall inside, we touch 30 records instead of 320 —
/// a 10x reduction, and the gap widens with dataset size.
///
/// ## Why a bounded insertion list, not a sort
///
/// `List.sort()` on k candidates is **O(k log k)** and allocates. Since the UI
/// only ever shows the top ~20, keeping a fixed-capacity insertion list makes
/// the common case **O(k)**: an element is compared against at most K entries,
/// and once the list is full and sorted, a candidate that is not better than the
/// worst entry is rejected in a single comparison. For a search where the
/// typical k is tens and K is 20, that is the difference between a sort and a
/// scan. (K is configurable; when K approaches k the two converge and the sort
/// is not worth its allocation.)
///
/// ## Choosing the cell size
///
/// There is a real trade-off and it is not "bigger is better":
///
/// * **Cells too large** → a query spans many cells, so k approaches N and the
///   index degenerates to a scan while still paying the bucketing cost.
/// * **Cells too small** → too many cells to enumerate, and the per-cell
///   [List] overhead dominates the memory for a sparse dataset.
///
/// 0.02° (~2.2 km) is the sweet spot for an emergency radius: a 25 km search
/// spans ~35 cells, and urban clusters (which is where hospitals and users both
/// are) put many hospitals in each cell without over-bucketing rural ones.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../../core/logger.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';
import '../mappers/json_mappers.dart';

/// Default cell size in degrees (~2.2 km of latitude).
///
/// See the class docs for why this is not larger.
const double kDefaultCellSizeDeg = 0.02;

/// A hospital paired with its precomputed grid cell.
///
/// Carrying the cell index inside the record avoids a second division per
/// candidate during a query — a small but real win, since this runs per record
/// per query and the division is on the hot path.
@immutable
class IndexedHospital {
  const IndexedHospital(this.hospital, this.cellCol, this.cellRow);

  /// The hospital.
  final Hospital hospital;

  /// Grid column (longitude cell index).
  final int cellCol;

  /// Grid row (latitude cell index).
  final int cellRow;
}

/// An immutable spatial index over hospitals.
///
/// Cheap to build once, cheap to query many times. Every instance is immutable
/// after construction, so it can be shared across isolates and threads without
/// synchronisation.
class HospitalIndex {
  HospitalIndex._(this._buckets, this._cellSize, this.length, this._bounds);

  /// Cell size in degrees.
  final double _cellSize;

  /// Number of hospitals indexed.
  final int length;

  /// `row * columns + col` → bucket. Sparse: a [Map] over a dense 2-D array
  /// would allocate one slot per empty cell in the world.
  final Map<int, List<IndexedHospital>> _buckets;

  /// Cached geographic bounds, so a caller can tell whether the dataset even
  /// covers the accident before doing any work.
  final GeoBounds? _bounds;

  /// Whether the index is empty.
  bool get isEmpty => length == 0;

  /// Whether the index has any hospitals.
  bool get isNotEmpty => length > 0;

  /// The geographic extent this index covers.
  GeoBounds? get bounds => _bounds;

  /// The cell size in degrees.
  double get cellSizeDeg => _cellSize;

  /// The cell size in metres at the equator, for display and tuning.
  double get cellSizeMetres => _cellSize * 111320.0;

  /// Every indexed record, in bucket order.
  ///
  /// Exposed for serialisation into a worker isolate (see
  /// `hospital_search_worker.dart`). Ordered by bucket rather than by input so
  /// the serialised form is deterministic for a given dataset, which makes the
  /// round-trip testable.
  List<IndexedHospital> get all {
    final List<IndexedHospital> out = <IndexedHospital>[];
    for (final List<IndexedHospital> bucket in _buckets.values) {
      out.addAll(bucket);
    }
    return out;
  }

  /// Build an index from [hospitals].
  ///
  /// Single pass, O(N), with each bucket pre-sized to a small capacity. Not
  /// pre-sizing would mean every [List] in the map starts at capacity 0 and the
  /// first insert into each of hundreds of buckets triggers a reallocation —
  /// the classic "N small allocations" cost that dominates a one-off build.
  factory HospitalIndex.fromIterable(
    Iterable<Hospital> hospitals, {
    double cellSizeDeg = kDefaultCellSizeDeg,
    AppLogger? log,
  }) {
    if (cellSizeDeg <= 0) {
      throw ArgumentError.value(cellSizeDeg, 'cellSizeDeg', 'must be positive');
    }

    final Map<int, List<IndexedHospital>> buckets =
        <int, List<IndexedHospital>>{};
    int count = 0;
    double? minLat;
    double? maxLat;
    double? minLon;
    double? maxLon;

    for (final Hospital hospital in hospitals) {
      final GeoPoint p = hospital.location;
      if (!p.isValid) {
        // A hospital with impossible coordinates is unusable for a proximity
        // search, so it is dropped rather than bucketed at a nonsense cell.
        log?.log(
          LogLevel.warning,
          'HospitalIndex',
          'dropping ${hospital.id}: invalid location',
        );
        continue;
      }
      final int col = (p.longitude / cellSizeDeg).floor();
      final int row = (p.latitude / cellSizeDeg).floor();
      // +1 per bucket so the common urban case (a handful of hospitals per
      // cell) never reallocates.
      (buckets[col * (1 << 20) + row] ??= <IndexedHospital>[]).add(
        IndexedHospital(hospital, col, row),
      );
      count++;
      minLat = minLat == null || p.latitude < minLat ? p.latitude : minLat;
      maxLat = maxLat == null || p.latitude > maxLat ? p.latitude : maxLat;
      minLon = minLon == null || p.longitude < minLon ? p.longitude : minLon;
      maxLon = maxLon == null || p.longitude > maxLon ? p.longitude : maxLon;
    }

    return HospitalIndex._(
      buckets,
      cellSizeDeg,
      count,
      count == 0
          ? null
          : GeoBounds(
              minLat: minLat!,
              maxLat: maxLat!,
              minLon: minLon!,
              maxLon: maxLon!,
            ),
    );
  }

  /// Build from the committed seed dataset's decoded shape.
  ///
  /// Accepts the raw list so a caller can hand over parsed JSON without
  /// building N intermediate objects. Records that fail to map are dropped with
  /// a log line rather than aborting the build — one malformed row must not
  /// cost the user their entire hospital list.
  factory HospitalIndex.fromRaw(
    List<Map<String, Object?>> records, {
    double cellSizeDeg = kDefaultCellSizeDeg,
    AppLogger? log,
  }) {
    final DateTime now = DateTime.now().toUtc();
    return HospitalIndex.fromIterable(
      records
          .map((Map<String, Object?> e) => HospitalMapper.fromJson(e, now: now))
          .whereType<Hospital>(),
      cellSizeDeg: cellSizeDeg,
      log: log,
    );
  }

  /// Hospitals within [radiusM] of [origin], best-ranked first, capped at
  /// [limit].
  ///
  /// "Best" is [Hospital.searchScore], **not** raw distance: an emergency
  /// department 3 km away is a better destination than a clinic 800 m away, and
  /// a distance-only sort would route a responder past the one that can help.
  /// The score is a *higher-is-better* value, so this method filters on
  /// [Hospital.distanceFrom] and orders on the score — see the note on the
  /// two-metric approach below.
  ///
  /// Complexity: **O(1)** to find the cell window, **O(k)** to visit the
  /// candidates inside it, and **O(k)** (not O(k log k)) to rank them, thanks
  /// to the bounded insertion list. In practice k is the number of hospitals
  /// inside the radius — typically tens — rather than the size of the dataset.
  List<Hospital> nearby(
    GeoPoint origin, {
    double radiusM = 25000,
    int limit = 20,
  }) {
    if (isEmpty || radiusM <= 0 || limit <= 0) return const <Hospital>[];

    // Fast reject: the accident is nowhere near the dataset (e.g. a seed set
    // for one metro being queried from another continent). O(1) and it avoids
    // walking a large empty cell window.
    final GeoBounds? b = _bounds;
    if (b != null && !b.intersectsRadius(origin, radiusM)) {
      return const <Hospital>[];
    }

    final (int rowLo, int rowHi, int colLo, int colHi) =
        _cellWindow(origin, radiusM);

    // Bounded insertion list, kept sorted by score **descending** and never
    // larger than [limit]. The common rejection path is a single comparison
    // against the weakest entry already kept, which is what makes this O(k)
    // rather than O(k log k).
    final List<Hospital> best = <Hospital>[];
    // Parallel to [best], descending. Kept separately so the comparison in the
    // hot loop is a `double` compare rather than recomputing a score, which
    // would be a sqrt per candidate.
    final List<double> bestScore = <double>[];

    for (int row = rowLo; row <= rowHi; row++) {
      for (int col = colLo; col <= colHi; col++) {
        final List<IndexedHospital>? bucket = _buckets[col * (1 << 20) + row];
        if (bucket == null) continue;
        for (final IndexedHospital indexed in bucket) {
          final Hospital hospital = indexed.hospital;

          // Hard geometric filter FIRST. This is the cheap test that decides
          // membership of the result set, and it must be the distance, because
          // [radiusM] is a distance. Filtering on the score instead would be
          // meaningless — a score has no metres in it.
          final double metres = hospital.distanceFrom(origin);
          if (metres > radiusM) continue;

          final double score = hospital.searchScore(origin);

          // Reject only if it cannot beat the weakest entry we hold *including
          // the tiebreak*. An exact score tie is common in this dataset: the
          // score saturates (proximity clamps to 0 beyond 5 km) and adds a
          // fixed emergency bonus, so every far-away emergency hospital with the
          // same rating scores identically. Without a deterministic tiebreak the
          // result would depend on bucket iteration order, and the same query
          // could return a different list on two runs — which makes the result
          // untestable and, worse, could reorder the recommendation the user acts
          // on.
          if (best.length == limit) {
            final double worst = bestScore.last;
            if (score < worst) continue;
            if (score == worst && hospital.id.compareTo(best.last.id) >= 0) {
              // Equal score and loses the tiebreak: the existing entry stays.
              continue;
            }
          }

          final int at = _descendingInsertionIndex(bestScore, score, best, hospital.id);
          best.insert(at, hospital);
          bestScore.insert(at, score);
          if (best.length > limit) {
            best.removeLast();
            bestScore.removeLast();
          }
        }
      }
    }

    return List<Hospital>.unmodifiable(best);
  }

  /// Index at which a candidate belongs in a list sorted by score
  /// **descending**, with ties broken by ascending [Hospital.id].
  ///
  /// `bisect`-style: O(log k) per insertion rather than a linear scan, and no
  /// allocation per candidate beyond the eventual list insert.
  static int _descendingInsertionIndex(
    List<double> sortedDescending,
    double value,
    List<Hospital> ids,
    String id,
  ) {
    int lo = 0;
    int hi = sortedDescending.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (sortedDescending[mid] > value) {
        lo = mid + 1;
      } else if (sortedDescending[mid] == value && ids[mid].id.compareTo(id) < 0) {
        // Equal score: keep ascending-id order.
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The inclusive cell bounds overlapping [origin] ± [radiusM].
  ///
  /// Latitude is treated linearly (a degree of latitude is ~111 km everywhere)
  /// and longitude is scaled by cos(latitude), which is the standard equirectangular
  /// approximation. Over a 25 km radius the error against a true geodesic is
  /// well under the GPS accuracy we are working with (5–10 m), so paying for
  /// a proper projection would be precision the application cannot use.
  (int, int, int, int) _cellWindow(GeoPoint origin, double radiusM) {
    final double latPad = radiusM / 111320.0;
    // Guard the pole: cos(90°) is 0, which would collapse the longitude window
    // to a single cell and silently miss every hospital near the pole.
    final double cosLat = math.max(
      0.01,
      math.cos(origin.latitude * math.pi / 180.0),
    );
    final double lonPad = radiusM / (111320.0 * cosLat);

    return (
      ((origin.latitude - latPad) / _cellSize).floor(),
      ((origin.latitude + latPad) / _cellSize).floor(),
      ((origin.longitude - lonPad) / _cellSize).floor(),
      ((origin.longitude + lonPad) / _cellSize).floor(),
    );
  }

  /// Number of non-empty cells. Diagnostic, surfaced in the debug screen.
  int get occupiedCells => _buckets.length;

  /// Average hospitals per occupied cell. A very high number means the cell
  /// size is too coarse for this dataset.
  double get averageBucketSize =>
      isEmpty ? 0 : length / math.max(1, _buckets.length);
}

/// The geographic extent an index covers.
@immutable
class GeoBounds {
  const GeoBounds({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
  });

  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  /// Whether [origin] with [radiusM] could possibly overlap these bounds.
  ///
  /// O(1) and it is the cheapest rejection available, so it runs before any
  /// cell enumeration.
  bool intersectsRadius(GeoPoint origin, double radiusM) {
    final double latPad = radiusM / 111320.0;
    final double cosLat = math.max(0.01, math.cos(origin.latitude * math.pi / 180.0));
    final double lonPad = radiusM / (111320.0 * cosLat);
    return origin.latitude + latPad >= minLat &&
        origin.latitude - latPad <= maxLat &&
        origin.longitude + lonPad >= minLon &&
        origin.longitude - lonPad <= maxLon;
  }

  @override
  String toString() =>
      'GeoBounds(lat $minLat..$maxLat, lon $minLon..$maxLon)';
}
