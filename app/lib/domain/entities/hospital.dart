/// The hospital entity — one document in the `hospitals` collection (§17).
///
/// §16 allows a predefined hospital list for the prototype, so this is a plain
/// read-only entity with no writes anywhere in the app. The extra fields beyond
/// §17's five (`beds`, `hasEmergency`, `type`, `rating`) are all nullable: a
/// document that only carries the five still parses, and the search results
/// degrade to a name and a distance rather than erroring. The prototype
/// hospital list in `assets/` is not required to grow a column every time a
/// screen wants a subtitle.
library;

import 'geo_point.dart';

/// What kind of care a hospital provides, used to rank search results.
///
/// `null` in the document means unknown, which ranks *below* a known general
/// hospital but stays ahead of nothing at all — see [Hospital.searchScore].
enum HospitalType {
  /// Emergency department, 24×7. The only kind this app will auto-suggest.
  emergency('EMERGENCY'),

  /// Multi-specialty hospital with an emergency department.
  multiSpecialty('MULTI_SPECIALTY'),

  /// A clinic or polyclinic, usually without an emergency department.
  clinic('CLINIC'),

  /// A diagnostic or pharmacy-type listing.
  other('OTHER');

  const HospitalType(this.wireName);

  /// The exact string stored in Firestore.
  final String wireName;

  /// Parses [name] case-insensitively, or `null` when unknown or absent.
  static HospitalType? fromName(String? name) {
    if (name == null) {
      return null;
    }
    final String upper = name.trim().toUpperCase().replaceAll(' ', '_');
    for (final HospitalType type in HospitalType.values) {
      if (type.wireName == upper) {
        return type;
      }
    }
    return null;
  }
}

/// A hospital, as stored and as searched.
final class Hospital {
  /// Creates a hospital.
  const Hospital({
    required this.id,
    required this.name,
    required this.address,
    required this.location,
    required this.phone,
    this.type,
    this.beds,
    this.hasEmergency = true,
    this.rating,
  });

  /// The Firestore document id.
  final String id;

  /// Display name, e.g. `Government General Hospital`.
  final String name;

  /// Human-readable address, as typed into the database.
  final String address;

  /// Where it is. Carries an accuracy too, so a bad pin is visible.
  final GeoPoint location;

  /// Primary phone number.
  final String phone;

  /// What kind of facility, when the document says.
  final HospitalType? type;

  /// Bed count, when known.
  final int? beds;

  /// Whether it has an emergency department.
  ///
  /// Defaults to `true` because §17 has no such field and the plan's flow is
  /// built around emergency care: a document that says nothing should still be
  /// a valid destination. Set it `false` explicitly for a listing that is known
  /// not to take emergencies.
  final bool hasEmergency;

  /// A 0–5 rating, when known.
  final double? rating;

  /// Whether this listing can take an accident case right now.
  ///
  /// Deliberately not a stored field, and deliberately not just [hasEmergency].
  /// §17 has no `hasEmergency` field, so [hasEmergency] defaults to `true` for
  /// every document that omits it — including a clinic. Trusting that default
  /// blindly would route someone past a real emergency department to a listing
  /// that has never had an ambulance queue, so an explicit
  /// [HospitalType.clinic] is treated as the more specific statement and wins.
  ///
  /// The asymmetry is the point: a *missing* type is unknown and stays
  /// optimistically usable (the plan's whole flow is built around emergency
  /// care), while a *stated* clinic type is a deliberate claim that there is no
  /// emergency department there. `hasEmergency: false` still wins outright.
  bool get takesEmergencies => hasEmergency && type != HospitalType.clinic;

  /// A copy with the given fields replaced.
  Hospital copyWith({
    String? id,
    String? name,
    String? address,
    GeoPoint? location,
    String? phone,
    HospitalType? type,
    int? beds,
    bool? hasEmergency,
    double? rating,
  }) =>
      Hospital(
        id: id ?? this.id,
        name: name ?? this.name,
        address: address ?? this.address,
        location: location ?? this.location,
        phone: phone ?? this.phone,
        type: type ?? this.type,
        beds: beds ?? this.beds,
        hasEmergency: hasEmergency ?? this.hasEmergency,
        rating: rating ?? this.rating,
      );

  /// Distance in metres from [from].
  double distanceFrom(GeoPoint from) => from.distanceTo(location);

  /// A score for ranking: higher is better.
  ///
  /// Deliberately not a distance, because "closest" is the wrong single answer
  /// for this app. A hospital 1.2 km away with no emergency department is a
  /// worse destination than one 3 km away that has one, and a plan that sorts
  /// purely on distance will happily route someone past an ambulance queue.
  ///
  /// So: emergencies are worth a fixed bonus, unknown-type listings are not
  /// penalised against known ones, and distance decays within a useful window.
  /// The 5 km normalisation means two hospitals are equal in distance beyond
  /// that, which is the honest statement that "further than 5 km" stops being a
  /// meaningful tiebreaker for a road journey anyway.
  double searchScore(GeoPoint from) {
    const double emergencyBonus = 4000;
    const double normalisationM = 5000;
    final double metres = distanceFrom(from);
    final double proximity = 1 - (metres / normalisationM);
    final double proximityTerm = proximity <= 0 ? 0 : proximity;
    final double typeBonus = takesEmergencies ? emergencyBonus : 0;
    final double ratingBonus = (rating ?? 0) * 100;
    return proximityTerm * 1000 + typeBonus + ratingBonus;
  }

  /// The `hospitals/{id}` document shape from §17.
  ///
  /// Uses the exact field names Firestore uses — `latitude`/`longitude`, not a
  /// nested `GeoPoint` — so the repository can hand this straight to `set`
  /// without a translation layer that has to be kept in step by hand.
  Map<String, Object?> toMap() => <String, Object?>{
        'name': name,
        'address': address,
        'latitude': location.latitude,
        'longitude': location.longitude,
        'phone': phone,
        if (type != null) 'type': type!.wireName,
        if (beds != null) 'beds': beds,
        'hasEmergency': hasEmergency,
        if (rating != null) 'rating': rating,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Hospital &&
          other.id == id &&
          other.name == name &&
          other.address == address &&
          other.location == location &&
          other.phone == phone &&
          other.type == type &&
          other.beds == beds &&
          other.hasEmergency == hasEmergency &&
          other.rating == rating;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        address,
        location,
        phone,
        type,
        beds,
        hasEmergency,
        rating,
      );

  @override
  String toString() => 'Hospital($id, $name)';
}
