/// The signed-in user — one document in the `users` collection (§17).
///
/// The plan's `users` document is four fields: `name`, `phone`,
/// `vehicleNumber` and `emergencyContacts`. This adds a display name
/// ([displayName], falling back to the name) and a notifiable flag, because the
/// notification flow (§19) has to decide whether a user can be reached at all
/// before it builds an SMS, and reading that out of `phone` at three call sites
/// is how a "contact saved but unverified" user ends up with a dead alert path.
library;

import 'accident.dart';

/// The user's profile, as stored.
final class UserProfile {
  /// Creates a profile.
  const UserProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.vehicleNumber,
    this.emergencyContacts = const <EmergencyContact>[],
    this.notificationPermissionGranted = false,
  });

  /// The Firebase Auth uid. Also the Firestore document id.
  final String id;

  /// The user's name, as §17 spells the field.
  final String name;

  /// Primary phone number.
  final String phone;

  /// The registered vehicle's plate number, shown on the dashboard.
  final String vehicleNumber;

  /// Who to call, in the order the user arranged them.
  final List<EmergencyContact> emergencyContacts;

  /// Whether the OS notification permission is actually granted.
  ///
  /// Local state mirrored into the document, because the alert screen needs to
  /// warn the user *before* the next crash, not only at the moment one happens.
  /// Defaults to `false`: assume the alert may not get through.
  final bool notificationPermissionGranted;

  /// What to show in the app bar when [name] is blank.
  String get displayName => name.trim().isEmpty ? 'Driver' : name.trim();

  /// Whether at least one contact can actually be dialled.
  ///
  /// Guards the "notify contacts" button. A profile with three contacts whose
  /// numbers are all blank is worse than no profile: the user sees a working
  /// button and believes someone will be called.
  bool get hasCallableContact => emergencyContacts.any(
        (EmergencyContact c) => c.isCallable,
      );

  /// The contacts still to be called for [record].
  List<EmergencyContact> pendingContactsFor(AccidentRecord record) =>
      emergencyContacts
          .where((EmergencyContact c) => record.needsNotificationOf(c))
          .toList(growable: false);

  /// A copy with the given fields replaced.
  UserProfile copyWith({
    String? id,
    String? name,
    String? phone,
    String? vehicleNumber,
    List<EmergencyContact>? emergencyContacts,
    bool? notificationPermissionGranted,
  }) =>
      UserProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        vehicleNumber: vehicleNumber ?? this.vehicleNumber,
        emergencyContacts: emergencyContacts ?? this.emergencyContacts,
        notificationPermissionGranted:
            notificationPermissionGranted ?? this.notificationPermissionGranted,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          other.id == id &&
          other.name == name &&
          other.phone == phone &&
          other.vehicleNumber == vehicleNumber &&
          other.notificationPermissionGranted ==
              notificationPermissionGranted &&
          _sameContacts(other.emergencyContacts, emergencyContacts);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        phone,
        vehicleNumber,
        notificationPermissionGranted,
        Object.hashAll(emergencyContacts),
      );

  @override
  String toString() => 'UserProfile($id, $displayName)';
}

bool _sameContacts(List<EmergencyContact> a, List<EmergencyContact> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
