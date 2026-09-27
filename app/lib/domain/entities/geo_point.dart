/// A geographic point, as the rest of the app refers to it.
///
/// **Deliberately not `geolocator`'s [Position].** A domain object that *is* a
/// plugin object can never be constructed in a test, in the hospital search
/// isolate, or from a Firestore snapshot. `Position` comes from a platform
/// channel; `GeoPoint` comes from nothing, which means the mapping layer is the
/// only place that knows about plugins.
///
/// The coordinates are WGS-84 degrees (that is what the ESP32's GPS and
/// Firestore `GeoPoint` both use) and, per §14, the *same* class carries the
/// accuracy and the timestamp of the fix — because an accident location without
/// an accuracy is worse than no location: it looks certain when it is not.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A latitude/longitude pair with fix metadata.
@immutable
class GeoPoint {
  /// Creates a point *without* validating it.
  ///
  /// Use [GeoPoint.checked] for anything that came from GPS or the
  /// network; this constructor exists so a `const` literal is possible.
  const GeoPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.timestamp,
  });

  /// Latitude in degrees, WGS-84. Valid range: -90 … 90.
  final double latitude;

  /// Longitude in degrees, WGS-84. Valid range: -180 … 180.
  final double longitude;

  /// Horizontal accuracy radius in **metres**, as reported by the platform. A
  /// larger number means a less trustworthy point. Never negative.
  final double accuracyM;

  /// When the fix was taken, in UTC.
  final DateTime timestamp;

  /// Largest valid latitude. Constructing outside these bounds is a caller bug,
  /// so the constructor below rejects it rather than clamping silently: a
  /// silently clamped coordinate puts the accident in the wrong place.
  static const double minLatitude = -90;

  /// WGS-84 latitude limit, inclusive.
  static const double maxLatitude = 90;

  /// Largest valid longitude.
  static const double minLongitude = -180;

  /// WGS-84 longitude limit, inclusive.
  static const double maxLongitude = 180;

  /// Earth radius in metres (mean radius, WGS-84). Used by [distanceTo].
  static const double earthRadiusM = 6371008.8;

  /// Validating constructor.
  ///
  /// Throws [ArgumentError] for out-of-range coordinates, a non-finite or
  /// negative [accuracyM], or a non-finite component. There is deliberately no
  /// "empty" point: absence is modelled with `null` / a `NoPosition` state, not
  /// with a fake `0,0` that is a real place in the Gulf of Guinea.
  factory GeoPoint.checked({
    required double latitude,
    required double longitude,
    required double accuracyM,
    required DateTime timestamp,
  }) {
    if (!latitude.isFinite || !longitude.isFinite || !accuracyM.isFinite) {
      throw ArgumentError(
        'GeoPoint components must be finite, got '
        'lat=$latitude lon=$longitude accuracy=$accuracyM',
      );
    }
    if (latitude < minLatitude || latitude > maxLatitude) {
      throw ArgumentError(
        'latitude $latitude is outside $minLatitude..$maxLatitude',
      );
    }
    if (longitude < minLongitude || longitude > maxLongitude) {
      throw ArgumentError(
        'longitude $longitude is outside $minLongitude..$maxLongitude',
      );
    }
    if (accuracyM < 0) {
      throw ArgumentError('accuracyM must be >= 0, got $accuracyM');
    }
    return GeoPoint(
      latitude: latitude,
      longitude: longitude,
      accuracyM: accuracyM,
      timestamp: timestamp.toUtc(),
    );
  }

  /// True when the components are in range. Use this to *validate* untrusted
  /// input without paying for an exception.
  bool get isValid {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        !accuracyM.isFinite ||
        accuracyM < 0) {
      return false;
    }
    return latitude >= minLatitude &&
        latitude <= maxLatitude &&
        longitude >= minLongitude &&
        longitude <= maxLongitude;
  }

  /// Age of the fix at [now].
  Duration ageAt(DateTime now) => now.toUtc().difference(timestamp);

  /// Whether the fix is older than [staleAfter] at [now].
  ///
  /// Stale is *not* invalid: a fix from four minutes ago is still the best
  /// information available, and during an accident the app shows it — labelled,
  /// per [ageAt] — rather than showing nothing.
  bool isStaleAt(DateTime now, Duration staleAfter) => ageAt(now) > staleAfter;

  /// Great-circle distance to [other], in metres.
  ///
  /// Haversine, not `geolocator`'s `distanceBetween` (which is Vincenty on the
  /// sphere and is not available in the search isolate without the plugin). At
  /// the scale this app cares about — finding a hospital within 25 km — the two
  /// differ by well under a metre, and haversine needs no plugin.
  double distanceTo(GeoPoint other) {
    final double lat1 = _rad(latitude);
    final double lat2 = _rad(other.latitude);
    final double sinHalfDLat = math.sin(_rad(other.latitude - latitude) / 2);
    final double sinHalfDLon = math.sin(_rad(other.longitude - longitude) / 2);

    // h = sin²(Δφ/2) + cosφ1·cosφ2·sin²(Δλ/2)
    final double h = sinHalfDLat * sinHalfDLat +
        math.cos(lat1) * math.cos(lat2) * sinHalfDLon * sinHalfDLon;

    // 2·asin(√h) is the central angle; using asin rather than atan2 keeps the
    // argument in [0,1] and therefore the result in [0,π] without a branch.
    final double centralAngle = 2 * math.asin(math.sqrt(h));
    return earthRadiusM * centralAngle;
  }

  /// Compass / "N 12.9716, E 77.5946" style string for the diagnostics screen.
  String get latLngLabel => '${latitude.toStringAsFixed(6)}, '
      '${longitude.toStringAsFixed(6)}';

  /// A copy with individual fields replaced. Used by the "refine the fix" path
  /// in the location service.
  GeoPoint copyWith({
    double? latitude,
    double? longitude,
    double? accuracyM,
    DateTime? timestamp,
  }) =>
      GeoPoint(
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        accuracyM: accuracyM ?? this.accuracyM,
        timestamp: timestamp ?? this.timestamp,
      );

  static double _rad(double degrees) => degrees * math.pi / 180.0;

  @override
  String toString() =>
      'GeoPoint($latLngLabel, ±${accuracyM.toStringAsFixed(1)}m, '
      '${timestamp.toIso8601String()})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint &&
          other.latitude == latitude &&
          other.longitude == longitude &&
          other.accuracyM == accuracyM &&
          other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(latitude, longitude, accuracyM, timestamp);
}
