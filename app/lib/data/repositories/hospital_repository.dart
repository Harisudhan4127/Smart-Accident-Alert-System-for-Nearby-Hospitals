/// Hospital search, contact management and settings.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/accident.dart';
import '../../domain/entities/geo_point.dart';
import '../../domain/entities/hospital.dart';
import '../../domain/entities/user_profile.dart';
import '../datasources/firestore_datasource.dart';
import '../datasources/local_datasource.dart';
import '../hospital/hospital_index.dart';
import '../hospital/hospital_search_worker.dart';
import '../mappers/json_mappers.dart';
import '../protocol/messages.dart';

/// Where the hospital dataset came from, for the UI's freshness label.
enum HospitalSource {
  /// Bundled with the app, so it works on first launch with no network.
  bundled,

  /// Read from the local SQLite cache.
  cache,

  /// Fetched from Firestore.
  cloud,

  /// Nothing available.
  none,
}

/// A search result plus provenance.
@immutable
class HospitalSearchResult {
  const HospitalSearchResult({
    required this.hospitals,
    required this.source,
    required this.queriedAt,
  });

  final List<Hospital> hospitals;
  final HospitalSource source;
  final DateTime queriedAt;

  bool get isEmpty => hospitals.isEmpty;
}

/// What a [HospitalRepository.load] actually achieved, for reporting.
@immutable
class HospitalLoadSummary {
  const HospitalLoadSummary({required this.count, required this.source});

  /// Hospitals in the loaded index.
  final int count;

  /// Which tier the data came from.
  final HospitalSource source;

  @override
  String toString() => 'HospitalLoadSummary($count from ${source.name})';
}

/// Owns the hospital dataset, its index, and the search path.
class HospitalRepository {
  HospitalRepository({
    required LocalDatasource local,
    required FirestoreDatasource firestore,
    AppLogger? log,
    DateTime Function()? clock,
    String? bundledJson,
  })  : _local = local,
        _firestore = firestore,
        _log = log ?? AppLogger(),
        _clock = clock ?? DateTime.now,
        _bundledJson = bundledJson;

  final LocalDatasource _local;
  final FirestoreDatasource _firestore;
  final AppLogger _log;
  final DateTime Function() _clock;
  final String? _bundledJson;

  HospitalIndex? _index;
  HospitalSource _source = HospitalSource.none;
  HospitalSearchWorker? _worker;
  DateTime? _loadedAt;

  /// The loaded index, or `null` before [load].
  HospitalIndex? get index => _index;

  /// Where the current dataset came from.
  HospitalSource get source => _source;

  /// When the dataset was loaded.
  DateTime? get loadedAt => _loadedAt;

  /// Load the dataset, preferring the freshest available source.
  ///
  /// Order is deliberate: cloud (freshest) → local cache (survives a restart) →
  /// bundled asset (always available). A failure at any level falls through to
  /// the next, because an empty hospital list is the worst possible outcome
  /// during an emergency, and the bundled set is better than nothing.
  Future<Result<HospitalIndex>> load({bool preferCloud = true}) async {
    if (preferCloud) {
      final Result<List<Hospital>> cloud = await _firestore.loadHospitals();
      if (cloud case final Ok<List<Hospital>> ok) {
        if (ok.value.isNotEmpty) {
          return _install(ok.value, HospitalSource.cloud);
        }
      }
      if (cloud case final FailureResult<List<Hospital>> failure) {
        _log.log(
          LogLevel.info,
          'hospitals',
          'cloud unavailable, falling back: ${failure.failure}',
        );
      }
    }

    final Result<String?> cached = await _local.cachedHospitals();
    final String? cachedJson = cached.valueOrNull;
    if (cachedJson != null && cachedJson.isNotEmpty) {
      final Result<HospitalIndex> fromCache = _decode(cachedJson, HospitalSource.cache);
      if (fromCache is Ok<HospitalIndex>) return fromCache;
    }

    final String? bundled = _bundledJson;
    if (bundled != null && bundled.isNotEmpty) {
      return _decode(bundled, HospitalSource.bundled);
    }

    return FailureResult<HospitalIndex>(
      failureOf(
        FailureKind.storage,
        'No hospital data is available on this device',
        detail: 'The bundled dataset is missing from the app package.',
      ),
    );
  }

  Result<HospitalIndex> _decode(String json, HospitalSource source) {
    return guardSync<HospitalIndex>(
      () {
        final List<Map<String, Object?>> records =
            decodeHospitalRecords(jsonDecode(json), _log);
        return HospitalIndex.fromRaw(records, log: _log);
      },
      kind: FailureKind.storage,
      message: 'The hospital dataset could not be read',
      log: _log,
      logTag: 'Hospitals',
    ).map((HospitalIndex built) {
      _install(built, source);
      return built;
    });
  }

  Result<HospitalIndex> _install(Object dataset, HospitalSource source) {
    final HospitalIndex built = switch (dataset) {
      final List<Hospital> list => HospitalIndex.fromIterable(list, log: _log),
      final HospitalIndex index => index,
      _ => HospitalIndex.fromIterable(const <Hospital>[], log: _log),
    };
    _index = built;
    _source = source;
    _loadedAt = _clock().toUtc();
    _worker = HospitalRepository._makeWorker(built);
    _log.log(
      LogLevel.info,
      'hospitals',
      'loaded ${built.length} from $source '
      '(${built.occupiedCells} cells, avg ${built.averageBucketSize.toStringAsFixed(1)}/cell)',
    );
    return Ok<HospitalIndex>(built);
  }

  /// Exposed for tests, which need to force the isolate path regardless of size.
  static bool forceIsolate = false;

  static HospitalSearchWorker _makeWorker(HospitalIndex index) =>
      HospitalSearchWorker(
        index: index,
        forceIsolate: forceIsolate ? true : null,
      );

  /// Load and report a one-line summary.
  ///
  /// Separate from [load] so a caller that only wants to *report* status (the
  /// splash screen) does not have to reach into the index.
  Future<Result<HospitalLoadSummary>> loadSummary({bool preferCloud = true}) async {
    final Result<HospitalIndex> loaded = await load(preferCloud: preferCloud);
    return loaded.map(
      (HospitalIndex index) =>
          HospitalLoadSummary(count: index.length, source: _source),
    );
  }

  /// Find hospitals near [origin].
  ///
  /// Runs on a worker isolate when the dataset is large enough to be worth it
  /// (see `HospitalSearchWorker.shouldIsolate`), and inline otherwise.
  Future<Result<HospitalSearchResult>> nearby({
    required GeoPoint origin,
    double radiusM = 25000,
    int limit = 20,
  }) async {
    final HospitalIndex? index = _index;
    if (index == null) {
      return FailureResult<HospitalSearchResult>(
        failureOf(FailureKind.validation, 'The hospital list has not been loaded yet'),
      );
    }
    final List<Hospital> found = await (_worker ?? HospitalSearchWorker(index: index))
        .nearby(origin, radiusM: radiusM, limit: limit);
    return Ok<HospitalSearchResult>(
      HospitalSearchResult(
        hospitals: found,
        source: _source,
        queriedAt: _clock().toUtc(),
      ),
    );
  }

  /// Refresh the local cache from a Firestore-provided list.
  Future<Result<void>> cacheFromCloud(List<Hospital> hospitals) {
    return guard<void>(
      () async {
        final String json = jsonEncode(
          hospitals.map((Hospital h) => h.toFirestore()).toList(),
        );
        final Result<void> cached =
            await _local.cacheHospitals(json, now: _clock().toUtc());
        cached.onFailure((Failure f) => throw f);
      },
      kind: FailureKind.storage,
      message: 'Could not cache the hospital directory',
      log: _log,
      logTag: 'Hospitals',
    );
  }
}

/// Emergency contacts and the signed-in profile.
class ContactRepository {
  ContactRepository({
    required FirestoreDatasource firestore,
    AppLogger? log,
  })  : _firestore = firestore,
        _log = log ?? AppLogger();

  final FirestoreDatasource _firestore;
  final AppLogger _log;

  UserProfile? _profile;
  final StreamController<UserProfile?> _profileController =
      StreamController<UserProfile?>.broadcast();

  /// The loaded profile.
  UserProfile? get profile => _profile;

  /// Profile changes.
  Stream<UserProfile?> get profileStream => _profileController.stream;

  /// Load `users/{uid}` (§17).
  Future<Result<UserProfile?>> load() async {
    final Result<UserProfile?> loaded = await _firestore.loadProfile();
    if (loaded case final Ok<UserProfile?> ok) {
      _profile = ok.value;
      // Worth tracing: "no contacts" is the single most common reason a user's
      // alert cannot reach anyone, so the count is logged at startup.
      _log.log(
        LogLevel.info,
        AppLogger.tagCloud,
        'profile loaded: ${_profile?.emergencyContacts.length ?? 0} contacts',
      );
      if (_profileController.hasListener) _profileController.add(_profile);
    } else {
      _log.log(
        LogLevel.warning,
        AppLogger.tagCloud,
        'profile unavailable: ${loaded.failureOrNull}',
      );
    }
    return loaded;
  }

  /// Add a contact and persist.
  Future<Result<UserProfile>> addContact(EmergencyContact contact) async {
    final UserProfile? current = _profile;
    if (current == null) {
      return FailureResult<UserProfile>(
        failureOf(FailureKind.validation, 'Load your profile before adding contacts'),
      );
    }
    // Replace rather than append when the id already exists, so re-adding an
    // edited contact updates it instead of creating a duplicate row.
    final List<EmergencyContact> next = <EmergencyContact>[
      for (final EmergencyContact c in current.emergencyContacts)
        if (c.id != contact.id) c,
      contact,
    ];
    return save(current.copyWith(emergencyContacts: next));
  }

  /// Remove a contact.
  Future<Result<UserProfile>> removeContact(String contactId) async {
    final UserProfile? current = _profile;
    if (current == null) {
      return FailureResult<UserProfile>(
        failureOf(FailureKind.validation, 'Load your profile first'),
      );
    }
    return save(
      current.copyWith(
        emergencyContacts: current.emergencyContacts
            .where((EmergencyContact c) => c.id != contactId)
            .toList(growable: false),
      ),
    );
  }

  /// Persist [profile] to the cloud and publish the result.
  Future<Result<UserProfile>> save(UserProfile profile) async {
    final Result<void> written = await _firestore.saveProfile(profile);
    if (written is FailureResult<void>) {
      return FailureResult<UserProfile>(written.failure);
    }
    _profile = profile;
    if (_profileController.hasListener) _profileController.add(profile);
    return Ok<UserProfile>(profile);
  }

  /// Contacts who can actually be dialled.
  List<EmergencyContact> get callableContacts =>
      (_profile?.emergencyContacts ?? const <EmergencyContact>[])
          .where((EmergencyContact c) => c.isCallable)
          .toList(growable: false);

  Future<void> dispose() => _profileController.close();
}

/// Small local settings, via `SharedPreferences`.
class SettingsRepository {
  SettingsRepository({SharedPreferences? prefs, AppLogger? log})
      : _prefs = prefs,
        _log = log ?? AppLogger();

  SharedPreferences? _prefs;
  final AppLogger _log;

  static const String _kOnboarded = 'onboarded';
  static const String _kThemeMode = 'theme_mode';
  static const String _kDeviceId = 'device_id';
  static const String _kDeviceLabel = 'device_label';
  static const String _kConfirmWindow = 'confirm_window_sec';

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Whether the user has been through onboarding.
  Future<bool> isOnboarded() async => (await _p).getBool(_kOnboarded) ?? false;

  Future<void> setOnboarded(bool value) async =>
      (await _p).setBool(_kOnboarded, value);

  /// `system`, `light` or `dark`.
  Future<String> themeMode() async => (await _p).getString(_kThemeMode) ?? 'system';

  Future<void> setThemeMode(String mode) async =>
      (await _p).setString(_kThemeMode, mode);

  /// The paired node's id, so the app reconnects on launch.
  Future<String?> deviceId() async => (await _p).getString(_kDeviceId);

  Future<void> setDeviceId(String? id) async {
    final SharedPreferences p = await _p;
    if (id == null) {
      await p.remove(_kDeviceId);
      _log.log(LogLevel.info, AppLogger.tagSettings, 'forgot the paired node');
    } else {
      await p.setString(_kDeviceId, id);
      _log.log(LogLevel.info, AppLogger.tagSettings, 'remembered node $id');
    }
  }

  /// The user's own name for the node.
  Future<String> deviceLabel() async => (await _p).getString(_kDeviceLabel) ?? '';

  Future<void> setDeviceLabel(String label) async =>
      (await _p).setString(_kDeviceLabel, label);

  /// The user's preferred cancel window, in seconds.
  ///
  /// Local-only: the authoritative value is the device's CONFIG, and the two
  /// are reconciled when the app connects. Keeping a local copy means the
  /// settings screen can render before a connection exists.
  Future<int> confirmWindowSec() async =>
      (await _p).getInt(_kConfirmWindow) ?? DeviceConfig.defaults().confirmWindowSec;

  Future<void> setConfirmWindowSec(int seconds) async =>
      (await _p).setInt(_kConfirmWindow, seconds);
}
