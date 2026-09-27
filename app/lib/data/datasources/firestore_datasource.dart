/// Cloud persistence: Cloud Firestore, per PROJECT_PLAN §17.
///
/// The schema implemented here is exactly the one in §17 and mirrored by
/// `backend/firestore.rules`:
///
/// ```text
/// users/{userId}        name, phone, vehicleNumber, emergencyContacts[]
/// accidents/{accidentId} userId, latitude, longitude, accuracy, timestamp,
///                       impactValue, status, deviceId
/// hospitals/{hospitalId}  name, address, latitude, longitude, phone
/// ```
///
/// Note that coordinates are stored as **separate scalars**, not a Firestore
/// `GeoPoint`. That is deliberate and matches §17: a native GeoPoint does not
/// participate in composite indexes, so a `GeoPoint` field would make
/// "hospitals near this accident" an unindexable collection scan. Scalars plus a
/// composite index are the only way to make it a bounded query — see
/// `backend/firestore.indexes.json`.
library;

import 'dart:async';

// Aliased, not merely imported: `cloud_firestore` exports its own `GeoPoint`
// (a Firestore value type), which would otherwise be ambiguous with the
// domain entity of the same name. The domain type is what this app means by
// a location, so it is imported unprefixed and the plugin is prefixed.
import 'package:cloud_firestore/cloud_firestore.dart' as cfs;
import 'package:firebase_auth/firebase_auth.dart' as fa;

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';
import '../../domain/entities/user_profile.dart';
import '../mappers/json_mappers.dart';

/// Firestore collection names, as one place so a typo cannot silently create a
/// second, orphaned collection.
abstract final class FirestorePaths {
  static const String users = 'users';
  static const String accidents = 'accidents';
  static const String hospitals = 'hospitals';
}

/// Cloud reads and writes.
abstract class FirestoreDatasource {
  /// The signed-in user id, or `null` when signed out.
  String? get currentUserId;

  /// Sign in anonymously.
  ///
  /// Anonymous auth rather than no auth: §26 requires an authenticated boundary
  /// before any personal location data is readable, and an anonymous credential
  /// is a real, rules-enforceable identity that collects no PII. Upgrading to a
  /// real account later is a one-line change that keeps the same uid.
  Future<Result<String>> signInAnonymously();

  /// Sign out.
  Future<void> signOut();

  /// Read `users/{userId}`.
  Future<Result<UserProfile?>> loadProfile();

  /// Write `users/{userId}`.
  Future<Result<void>> saveProfile(UserProfile profile);

  /// Write one accident document.
  ///
  /// Uses [set] with the explicit id, never `add`, so a retried delivery of the
  /// same accident overwrites itself instead of creating a second document.
  Future<Result<void>> writeAccident(AccidentRecord record);

  /// Accidents for the current user, newest first.
  ///
  /// Paginated. A driver's whole history is unbounded, and the history screen
  /// uses a lazy list — so the query is paged rather than fetched whole.
  Stream<List<AccidentRecord>> watchAccidents({int limit = 50});

  /// Page forward from [startAfter].
  Future<Result<List<AccidentRecord>>> nextAccidentPage({
    required cfs.DocumentSnapshot<Map<String, Object?>>? startAfter,
    int limit = 50,
  });

  /// All hospitals, for local indexing.
  Future<Result<List<Hospital>>> loadHospitals();

  /// Whether the cloud is reachable, for the offline banner.
  Stream<bool> watchConnectivity();
}

/// The production implementation.
class FirestoreDatasourceImpl implements FirestoreDatasource {
  FirestoreDatasourceImpl({
    cfs.FirebaseFirestore? firestore,
    fa.FirebaseAuth? auth,
    AppLogger? log,
  })  : _log = log ?? AppLogger(),
        _injectedFirestore = firestore,
        _injectedAuth = auth;

  final AppLogger _log;
  final cfs.FirebaseFirestore? _injectedFirestore;
  final fa.FirebaseAuth? _injectedAuth;

  /// Resolved lazily, on first use.
  ///
  /// `FirebaseFirestore.instance` throws if `Firebase.initializeApp()` never
  /// ran. Touching it in the constructor would mean merely *constructing* this
  /// datasource requires Firebase — which defeats the whole design, where the
  /// app must start and work with no cloud configuration at all (see the
  /// offline-first outbox in `AccidentRepository`). Deferring the lookup means
  /// the absence of Firebase is a `Failure` on the call that needed it, not a
  /// crash while wiring the dependency graph.
  late final cfs.FirebaseFirestore _firestore =
      _injectedFirestore ?? cfs.FirebaseFirestore.instance;

  late final fa.FirebaseAuth _auth = _injectedAuth ?? fa.FirebaseAuth.instance;

  @override
  String? get currentUserId => _auth.currentUser?.uid;

  @override
  Future<Result<String>> signInAnonymously() {
    return guard<String>(
      () async {
        final fa.User? existing = _auth.currentUser;
        if (existing != null) return existing.uid;
        final fa.UserCredential cred = await _auth.signInAnonymously();
        // `signInAnonymously` is documented to produce a user, but the type is
        // nullable, and a null here would mean an anonymous uid that silently
        // fails every rules check later — so it is asserted rather than forced.
        final fa.User? user = cred.user;
        if (user == null) {
          throw StateError('anonymous sign-in returned no user');
        }
        return user.uid;
      },
      kind: FailureKind.network,
      message: 'Could not sign in',
      log: _log,
      logTag: 'Auth',
    );
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<Result<UserProfile?>> loadProfile() {
    return guard<UserProfile?>(
      () async {
        final String? uid = currentUserId;
        if (uid == null) return null;
        final cfs.DocumentSnapshot<Map<String, Object?>> doc =
            await _firestore.collection(FirestorePaths.users).doc(uid).get();
        if (!doc.exists) return null;
        final Map<String, Object?> data = doc.data() ?? const <String, Object?>{};
        return UserProfileMapper.fromJson(data, id: uid);
      },
      kind: FailureKind.network,
      message: 'Could not load your profile',
      log: _log,
      logTag: 'Firestore',
    );
  }

  @override
  Future<Result<void>> saveProfile(UserProfile profile) {
    return guard<void>(
      () async {
        await _firestore
            .collection(FirestorePaths.users)
            .doc(profile.id)
            .set(profile.toFirestore(), cfs.SetOptions(merge: true));
      },
      kind: FailureKind.network,
      message: 'Could not save your profile',
      log: _log,
      logTag: 'Firestore',
    );
  }

  @override
  Future<Result<void>> writeAccident(AccidentRecord record) {
    return guard<void>(
      () async {
        await _firestore
            .collection(FirestorePaths.accidents)
            .doc(record.id)
            .set(_accidentDocument(record), cfs.SetOptions(merge: true));
      },
      kind: FailureKind.network,
      message: 'Could not store the accident record',
      log: _log,
      logTag: 'Firestore',
    );
  }

  /// The `accidents/{id}` document (§17).
  ///
  /// `impactValue` and `status` come from the *phone*, but the server rules
  /// validate them, and `serverTimestamp` is requested for `uploadedAt` so the
  /// record's arrival time cannot be forged by a device with a wrong clock.
  static Map<String, Object?> _accidentDocument(AccidentRecord record) {
    return <String, Object?>{
      // --- the §17 fields ---
      'userId': record.userId,
      'latitude': record.location.latitude,
      'longitude': record.location.longitude,
      'accuracy': record.location.accuracyM,
      'timestamp': record.occurredAt.toUtc().toIso8601String(),
      'impactValue': record.impactValue,
      'status': record.status.wireName,
      'deviceId': record.deviceId,
      // --- enrichment; all optional, none required by §17 ---
      'impactG': record.impactG,
      'impactScore': record.impactScore,
      'detectedDeviceState': record.detectedDeviceState,
      'hospitalId': record.hospitalId,
      'hospitalName': record.hospitalName,
      // Ids, not full contact objects: §26 says do not store unnecessary
      // personal information, and the contacts already live on the profile.
      'notifiedContactIds': record.notifiedContactIds,
      if (record.confirmedAt != null)
        'confirmedAt': record.confirmedAt!.toUtc().toIso8601String(),
      if (record.alertSentAt != null)
        'alertSentAt': record.alertSentAt!.toUtc().toIso8601String(),
      if (record.resolvedAt != null)
        'resolvedAt': record.resolvedAt!.toUtc().toIso8601String(),
      if (record.cancelledAt != null)
        'cancelledAt': record.cancelledAt!.toUtc().toIso8601String(),
      // Server time, so a device with a wrong clock cannot forge arrival order.
      'uploadedAt': cfs.FieldValue.serverTimestamp(),
    };
  }

  @override
  Stream<List<AccidentRecord>> watchAccidents({int limit = 50}) {
    final String? uid = currentUserId;
    if (uid == null) return const Stream<List<AccidentRecord>>.empty();
    return _firestore
        .collection(FirestorePaths.accidents)
        .where('userId', isEqualTo: uid)
        .orderBy('timestamp', descending: true)
        // The limit is a safety net against a pathological account; the screen
        // pages for more.
        .limit(limit)
        .snapshots()
        .map(
          (cfs.QuerySnapshot<Map<String, Object?>> snap) => _toRecords(snap.docs),
        );
  }

  @override
  Future<Result<List<AccidentRecord>>> nextAccidentPage({
    required cfs.DocumentSnapshot<Map<String, Object?>>? startAfter,
    int limit = 50,
  }) {
    return guard<List<AccidentRecord>>(
      () async {
        final String? uid = currentUserId;
        if (uid == null) return const <AccidentRecord>[];
        cfs.Query<Map<String, Object?>> query = _firestore
            .collection(FirestorePaths.accidents)
            .where('userId', isEqualTo: uid)
            .orderBy('timestamp', descending: true)
            .limit(limit);
        if (startAfter != null) {
          query = query.startAfterDocument(startAfter);
        }
        final cfs.QuerySnapshot<Map<String, Object?>> snap = await query.get();
        return _toRecords(snap.docs);
      },
      kind: FailureKind.network,
      message: 'Could not load more history',
      log: _log,
      logTag: 'Firestore',
    );
  }

  /// Last document of a snapshot, for the next page's cursor.
  static cfs.DocumentSnapshot<Map<String, Object?>>? cursorOf(
    cfs.QuerySnapshot<Map<String, Object?>> snap,
  ) =>
      snap.docs.isEmpty ? null : snap.docs.last;

  /// Parse an ISO-8601 instant, or `null` when absent or malformed.
  ///
  /// A malformed timestamp must not fail the whole history query: one bad
  /// document should cost one history row, not the entire list.
  static DateTime? _dateOrNull(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toUtc();

  List<AccidentRecord> _toRecords(
    List<cfs.QueryDocumentSnapshot<Map<String, Object?>>> docs,
  ) {
    final String? uid = currentUserId;
    return docs
        .map((cfs.QueryDocumentSnapshot<Map<String, Object?>> doc) {
          final Map<String, Object?> data = doc.data();
          final GeoPoint? point = GeoPointMapper.fromJson(
            data,
            timestamp: DateTime.tryParse(
                  data.stringOrNull('timestamp') ?? '',
                )?.toUtc() ??
                DateTime.now().toUtc(),
          );
          if (point == null) return null;
          return AccidentRecord(
            id: doc.id,
            userId: data.stringOrNull('userId') ?? uid ?? '',
            deviceId: data.textOrNull('deviceId'),
            location: point,
            occurredAt: point.timestamp,
            impactValue: data.doubleOrNull('impactValue') ?? 0,
            impactG: data.doubleOrNull('impactG'),
            impactScore: data.intOrNull('impactScore'),
            detectedDeviceState: data.textOrNull('detectedDeviceState'),
            status: AccidentStatus.fromNameOrUnknown(data.textOrNull('status')),
            confirmedAt: _dateOrNull(data.stringOrNull('confirmedAt')),
            alertSentAt: _dateOrNull(data.stringOrNull('alertSentAt')),
            resolvedAt: _dateOrNull(data.stringOrNull('resolvedAt')),
            cancelledAt: _dateOrNull(data.stringOrNull('cancelledAt')),
            hospitalId: data.textOrNull('hospitalId'),
            hospitalName: data.textOrNull('hospitalName'),
            notifiedContactIds: data.stringList('notifiedContactIds'),
            // It came *from* Firestore, so it is by definition synced.
            isSynced: true,
          );
        })
        .whereType<AccidentRecord>()
        .toList(growable: false);
  }

  @override
  Future<Result<List<Hospital>>> loadHospitals() {
    return guard<List<Hospital>>(
      () async {
        final cfs.QuerySnapshot<Map<String, Object?>> snap = await _firestore
            .collection(FirestorePaths.hospitals)
            .get();
        final DateTime now = DateTime.now().toUtc();
        return snap.docs
            .map((cfs.QueryDocumentSnapshot<Map<String, Object?>> d) =>
                HospitalMapper.fromJson(
                  d.data() ?? const <String, Object?>{},
                  now: now,
                  // Firestore's document name is the id; the document body does
                  // not repeat it.
                  fallbackId: d.id,
                ))
            .whereType<Hospital>()
            .toList(growable: false);
      },
      kind: FailureKind.network,
      message: 'Could not load the hospital directory',
      log: _log,
      logTag: 'Firestore',
    );
  }

  @override
  Stream<bool> watchConnectivity() => _firestore
      .collection(FirestorePaths.hospitals)
      .limit(1)
      .snapshots()
      .map((cfs.QuerySnapshot<Map<String, Object?>> _) => true)
      .handleError((Object _) => false);
}
