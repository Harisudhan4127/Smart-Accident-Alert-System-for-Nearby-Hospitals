/// Mapping between the wire/JSON shapes and the domain entities.
///
/// Kept in one place because the shapes come from three different sources that
/// must not be allowed to drift:
///
/// * `backend/seed/hospitals.json` — the bundled offline dataset;
/// * the Firestore `hospitals` collection (§17);
/// * the Cloud Function's `nearbyHospitals` response.
///
/// All three are read by the same [Hospital] entity, so all three go through
/// here. Every mapper is total: a malformed record becomes `null` or a
/// documented default rather than an exception, because one bad document in a
/// 30 000-row dataset must not take down the emergency screen.
library;

import '../../core/logger.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';
import '../../domain/entities/user_profile.dart';

/// Reads loosely-typed JSON without throwing.
///
/// Local, rather than a dependency: the shapes are small and the tolerance
/// rules (a missing `accuracy`, a `beds` that arrived as a string) are specific
/// to this project.
extension JsonMap on Map<String, Object?> {
  /// String at [key], or `null`.
  String? stringOrNull(String key) {
    final Object? v = this[key];
    if (v == null) return null;
    return v is String ? v : v.toString();
  }

  /// Non-empty trimmed string at [key], or `null`.
  String? textOrNull(String key) {
    final String? s = stringOrNull(key)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Double at [key], tolerating a numeric string. `null` if unparseable.
  double? doubleOrNull(String key) {
    final Object? v = this[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// int at [key], tolerating a double or a numeric string.
  int? intOrNull(String key) {
    final Object? v = this[key];
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// bool at [key], tolerating `"true"`/`"false"` and 0/1.
  bool? boolOrNull(String key) {
    final Object? v = this[key];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return null;
  }

  /// Nested object at [key], or an empty map.
  Map<String, Object?> objectOrEmpty(String key) {
    final Object? v = this[key];
    return v is Map<String, Object?> ? v : const <String, Object?>{};
  }

  /// List of objects at [key].
  List<Map<String, Object?>> objectList(String key) {
    final Object? v = this[key];
    if (v is! List) return const <Map<String, Object?>>[];
    return v
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> e) => e.cast<String, Object?>())
        .toList(growable: false);
  }

  /// List of strings at [key].
  List<String> stringList(String key) {
    final Object? v = this[key];
    if (v is! List) return const <String>[];
    return v.map((Object? e) => e?.toString() ?? '').where((String s) => s.isNotEmpty).toList(growable: false);
  }
}

/// Mappers for [GeoPoint].
extension GeoPointMapper on GeoPoint {
  /// From a Firestore/JSON document.
  ///
  /// Coordinates arrive as separate `latitude`/`longitude` scalars in Firestore
  /// (§17) rather than as a `GeoPoint` value, because Firestore's native
  /// GeoPoint type is awkward to use from the web/mobile SDKs uniformly.
  static GeoPoint? fromJson(
    Map<String, Object?> json, {
    required DateTime timestamp,
    double defaultAccuracyM = 50,
  }) {
    // `latitude`/`longitude` is the §17 spelling; `lat`/`lng` is what geocoding
    // datasets and seed files use. Accepting both costs one `??` and avoids a
    // silently empty hospital list.
    final double? lat = json.doubleOrNull('latitude') ?? json.doubleOrNull('lat');
    final double? lon =
        json.doubleOrNull('longitude') ?? json.doubleOrNull('lng') ?? json.doubleOrNull('lon');
    if (lat == null || lon == null) return null;
    if (lat < GeoPoint.minLatitude ||
        lat > GeoPoint.maxLatitude ||
        lon < GeoPoint.minLongitude ||
        lon > GeoPoint.maxLongitude) {
      return null;
    }
    return GeoPoint(
      latitude: lat,
      longitude: lon,
      accuracyM: json.doubleOrNull('accuracy') ??
          json.doubleOrNull('accuracyM') ??
          defaultAccuracyM,
      timestamp: timestamp,
    );
  }

  /// To the Firestore scalar shape (§17).
  Map<String, Object?> toFirestore() => <String, Object?>{
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracyM,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };
}

/// Mappers for [Hospital].
extension HospitalMapper on Hospital {
  /// From a `hospitals` document or a seed record.
  ///
  /// Tolerates the shapes that actually exist in this project:
  ///
  /// * a Firestore document, where the id is the document name and arrives
  ///   separately — the caller passes it via `fallbackId`;
  /// * a seed record from `backend/seed/hospitals.json`, which has **no `id`
  ///   field at all** because Firestore would assign it;
  /// * a geocoding dataset, which uses `lat`/`lng` and has a `place_id`.
  ///
  /// When no id can be found, one is derived from the name and coordinates
  /// rather than dropping the record: a hospital missing from an emergency list
  /// is a worse outcome than one with a synthesised, stable identifier.
  static Hospital? fromJson(
    Map<String, Object?> json, {
    DateTime? now,
    String? fallbackId,
  }) {
    final String? name = json.textOrNull('name');
    if (name == null) return null;

    final Map<String, Object?> loc = json['location'] is Map<String, Object?>
        ? json.objectOrEmpty('location')
        : json;
    final GeoPoint? point = GeoPointMapper.fromJson(
      loc,
      timestamp: now ?? DateTime.now().toUtc(),
      // A hospital's position is a pin, not a live fix, so a nominal accuracy
      // is honest: there is no GPS error to report for a database coordinate.
      defaultAccuracyM: 100,
    );
    if (point == null) return null;

    final String id = json.textOrNull('id') ??
        fallbackId ??
        json.textOrNull('hospitalId') ??
        json.textOrNull('place_id') ??
        _synthesiseId(name, point);

    return Hospital(
      id: id,
      name: name,
      address: json.textOrNull('address') ?? '',
      location: point,
      phone: json.textOrNull('phone') ?? '',
      type: HospitalType.fromName(json.textOrNull('type')),
      beds: json.intOrNull('beds'),
      hasEmergency: json.boolOrNull('hasEmergency') ??
          json.boolOrNull('emergency') ??
          true,
      rating: json.doubleOrNull('rating'),
    );
  }

  /// A stable id for a record that has none.
  ///
  /// Name plus coordinates to four decimals (~11 m), which is stable across
  /// reloads and dataset regenerations, and does not depend on a hash
  /// implementation that could change between SDK versions.
  static String _synthesiseId(String name, GeoPoint point) {
    final String slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '$slug@${point.latitude.toStringAsFixed(4)},'
        '${point.longitude.toStringAsFixed(4)}';
  }

  /// To the `hospitals` document shape (§17), plus the extras the ranking uses.
  Map<String, Object?> toFirestore() => <String, Object?>{
        'name': name,
        'address': address,
        'latitude': location.latitude,
        'longitude': location.longitude,
        'phone': phone,
        if (type != null) 'type': type!.wireName,
        if (beds != null) 'beds': beds,
        'emergency': hasEmergency,
        if (rating != null) 'rating': rating,
      };
}

/// Mappers for [EmergencyContact].
extension EmergencyContactMapper on EmergencyContact {
  /// From a `users/{userId}.emergencyContacts` entry or an `accidents` sub-list.
  static EmergencyContact? fromJson(Map<String, Object?> json, {String? fallbackId}) {
    final String? id = json.textOrNull('id') ?? fallbackId;
    final String name = json.textOrNull('name') ?? 'Contact';
    final String phone = json.textOrNull('phone') ?? '';
    if (id == null || phone.isEmpty) return null;
    return EmergencyContact(
      id: id,
      name: name,
      phone: phone,
      relationship: json.textOrNull('relationship') ?? '',
    );
  }

  /// To the Firestore sub-document shape.
  Map<String, Object?> toFirestore() => <String, Object?>{
        'id': id,
        'name': name,
        'phone': phone,
        if (relationship != null) 'relationship': relationship,
      };
}

/// Mappers for [UserProfile].
extension UserProfileMapper on UserProfile {
  /// From a `users/{userId}` document.
  static UserProfile fromJson(
    Map<String, Object?> json, {
    required String id,
    bool notificationPermissionGranted = false,
  }) {
    return UserProfile(
      id: id,
      name: json.textOrNull('name') ?? '',
      phone: json.textOrNull('phone') ?? '',
      vehicleNumber: json.textOrNull('vehicleNumber') ?? '',
      emergencyContacts: json
          .objectList('emergencyContacts')
          .map((Map<String, Object?> e) =>
              EmergencyContactMapper.fromJson(e, fallbackId: e.textOrNull('id')))
          .whereType<EmergencyContact>()
          .toList(growable: false),
      notificationPermissionGranted: notificationPermissionGranted,
    );
  }

  /// To the `users/{userId}` document shape (§17).
  Map<String, Object?> toFirestore() => <String, Object?>{
        'name': name,
        'phone': phone,
        'vehicleNumber': vehicleNumber,
        'emergencyContacts':
            emergencyContacts.map((EmergencyContact c) => c.toFirestore()).toList(),
      };
}

/// Decodes the seed dataset's wrapper, tolerating a bare array too.
///
/// `backend/seed/hospitals.json` is an object with a `hospitals` key, but a
/// hand-trimmed fixture is often a bare list. Accepting both costs one `is List`
/// check and saves a confusing failure.
List<Map<String, Object?>> decodeHospitalRecords(Object? decoded, AppLogger? log) {
  if (decoded is List) {
    return decoded
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> e) => e.cast<String, Object?>())
        .toList(growable: false);
  }
  if (decoded is Map<String, Object?> && decoded['hospitals'] is List) {
    return decoded.objectList('hospitals');
  }
  log?.log(
    LogLevel.warning,
    'HospitalMapper',
    'unrecognised hospital dataset shape: ${decoded.runtimeType}',
  );
  return const <Map<String, Object?>>[];
}
