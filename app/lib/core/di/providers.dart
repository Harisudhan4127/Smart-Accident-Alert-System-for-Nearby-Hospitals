/// Dependency wiring.
///
/// Everything the app needs is constructed here, once, and overridable. That
/// overridability is not decoration: it is what lets the entire application run
/// against [FakeBleTransport], a scripted [FakeLocationDatasource] and an
/// in-memory outbox, so widget tests and the hardware-free demo exercise the
/// real code paths rather than a parallel test-only implementation.
///
/// The layering is strict and one-directional:
///
/// ```text
///   providers ──▶ repositories ──▶ datasources ──▶ plugins
///                     │
///                     └──▶ domain entities (no Flutter, no plugins)
/// ```
///
/// No repository imports another repository, and nothing below the repository
/// layer knows a widget exists.
library;

import 'package:connectivity_plus/connectivity_plus.dart' as connectivity;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/ble/ble_service.dart';
import '../../data/ble/ble_transport.dart';
import '../../data/ble/fake_ble_transport.dart';
import '../../data/datasources/firestore_datasource.dart';
import '../../data/datasources/local_datasource.dart';
import '../../data/datasources/location_datasource.dart';
import '../../data/datasources/maps_datasource.dart';
import '../../data/datasources/notification_datasource.dart';
import '../../data/repositories/accident_repository.dart';
import '../../data/repositories/device_repository.dart';
import '../../data/repositories/hospital_repository.dart';

/// Bundled hospital dataset, loaded once and shared.
///
/// A `FutureProvider` over the asset rather than an eagerly-read string, so a
/// 300 KB JSON file does not sit in memory during the splash screen and does not
/// block the first frame.
final FutureProvider<String> bundledHospitalsProvider =
    FutureProvider<String>((Ref ref) async {
  // A FutureProvider over the asset rather than an eagerly-read string: a
  // ~300 KB JSON file should not sit in memory during the splash screen, and
  // reading it lazily keeps the first frame cheap.
  final HospitalAssetLoader loader = ref.watch(hospitalAssetLoaderProvider);
  return loader();
});

/// Reads the hospital seed asset. Overridden in tests with a small fixture.
typedef HospitalAssetLoader = Future<String> Function();

/// Loads the bundled dataset via [rootBundle].
final Provider<HospitalAssetLoader> hospitalAssetLoaderProvider =
    Provider<HospitalAssetLoader>((Ref ref) {
  return () => rootBundle.loadString(kHospitalAssetPath);
});

/// Asset path of the bundled hospital dataset.
const String kHospitalAssetPath = 'assets/data/hospitals.json';

// ------------------------------------------------------------------ datasources

/// The BLE transport. Override in tests and in demo mode.
final Provider<BleTransport> bleTransportProvider = Provider<BleTransport>((Ref ref) {
  final BleService service = BleService();
  service.start();
  ref.onDispose(service.dispose);
  return service;
});

/// GPS.
final Provider<LocationDatasource> locationDatasourceProvider =
    Provider<LocationDatasource>((Ref ref) {
  final GeolocatorDatasource ds = GeolocatorDatasource();
  ref.onDispose(ds.dispose);
  return ds;
});

/// Local SQLite, including the offline outbox.
final Provider<LocalDatasource> localDatasourceProvider =
    Provider<LocalDatasource>((Ref ref) {
  return SqfliteDatasource();
});

/// Cloud.
final Provider<FirestoreDatasource> firestoreDatasourceProvider =
    Provider<FirestoreDatasource>((Ref ref) {
  return FirestoreDatasourceImpl();
});

/// Maps / dialer / SMS intents.
final Provider<MapsDatasource> mapsDatasourceProvider =
    Provider<MapsDatasource>((Ref ref) {
  return UrlLauncherMapsDatasource();
});

/// Notifications.
final Provider<NotificationDatasource> notificationDatasourceProvider =
    Provider<NotificationDatasource>((Ref ref) {
  return LocalNotificationDatasource();
});

/// `SharedPreferences`.
final FutureProvider<SharedPreferences> sharedPreferencesProvider =
    FutureProvider<SharedPreferences>((Ref ref) => SharedPreferences.getInstance());

/// Network reachability, as a *hint*.
///
/// The outbox retry scheduler uses it to know when to try sooner. It is not the
/// source of truth — the result of the write attempt is, because a phone can
/// report "connected" to a captive portal that cannot reach Firestore at all.
final StreamProvider<bool> isOnlineProvider = StreamProvider<bool>((Ref ref) {
  return connectivity.Connectivity().onConnectivityChanged.map(
        (List<connectivity.ConnectivityResult> results) =>
            results.any((connectivity.ConnectivityResult r) => r != connectivity.ConnectivityResult.none),
      );
});

// ----------------------------------------------------------------- repositories

/// The device link.
final Provider<DeviceRepository> deviceRepositoryProvider =
    Provider<DeviceRepository>((Ref ref) {
  final DeviceRepository repo = DeviceRepository(
    // `effectiveBleTransportProvider`, not the raw one: this is the single
    // substitution point, so demo mode reaches the whole stack.
    transport: ref.watch(effectiveBleTransportProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// Accidents and the outbox.
final Provider<AccidentRepository> accidentRepositoryProvider =
    Provider<AccidentRepository>((Ref ref) {
  final AccidentRepository repo = AccidentRepository(
    local: ref.watch(localDatasourceProvider),
    firestore: ref.watch(firestoreDatasourceProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// Hospitals and their index.
final Provider<HospitalRepository> hospitalRepositoryProvider =
    Provider<HospitalRepository>((Ref ref) {
  return HospitalRepository(
    local: ref.watch(localDatasourceProvider),
    firestore: ref.watch(firestoreDatasourceProvider),
    bundledJson: ref.watch(bundledHospitalsProvider).value,
  );
});

/// Contacts and the profile.
final Provider<ContactRepository> contactRepositoryProvider =
    Provider<ContactRepository>((Ref ref) {
  final ContactRepository repo = ContactRepository(
    firestore: ref.watch(firestoreDatasourceProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// Settings.
final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider<SettingsRepository>((Ref ref) {
  return SettingsRepository(prefs: ref.watch(sharedPreferencesProvider).value);
});

// ------------------------------------------------------------------ app state

/// Whether the app is in hardware-free demo mode.
///
/// When true, the app runs entirely against [FakeBleTransport] and a scripted
/// location, so it can be demonstrated or reviewed with no hardware attached.
/// Set by `--dart-define=DEMO=true`.
final Provider<bool> demoModeProvider = Provider<bool>((Ref ref) {
  return const bool.fromEnvironment('DEMO', defaultValue: false);
});

/// The transport actually in use, honouring [demoModeProvider].
///
/// This is the single place the substitution happens, so no other file needs to
/// know whether it is talking to hardware or a simulator.
final Provider<BleTransport> effectiveBleTransportProvider =
    Provider<BleTransport>((Ref ref) {
  if (ref.watch(demoModeProvider)) {
    final FakeBleTransport fake = FakeBleTransport();
    ref.onDispose(fake.dispose);
    return fake;
  }
  return ref.watch(bleTransportProvider);
});

/// The location datasource actually in use.
final Provider<LocationDatasource> effectiveLocationProvider =
    Provider<LocationDatasource>((Ref ref) {
  if (ref.watch(demoModeProvider)) {
    final FakeLocationDatasource fake = FakeLocationDatasource();
    ref.onDispose(fake.dispose);
    return fake;
  }
  return ref.watch(locationDatasourceProvider);
});
