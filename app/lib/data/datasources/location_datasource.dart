/// GPS access, behind [LocationDatasource].
///
/// ## The design decision that matters
///
/// **Last-known-first.** A phone that has been sitting in a car almost always
/// has a recent cached fix, and waiting for a fresh one before rendering would
/// add seconds to the alert screen for no benefit — seconds a possibly-injured
/// person is staring at a spinner.
///
/// So [currentPosition] returns the cached position immediately and, in the
/// background, upgrades to a live fix. The alert screen therefore shows a
/// plausible pin within a frame and then silently tightens it, rather than
/// showing nothing and then something.
///
/// The distinction the API preserves:
///
/// * `Ok(null)` — "we do not know where you are yet", a *normal* state;
/// * `Failure` — the *request* failed (permission denied, services off, timeout).
///
/// Collapsing these would make "waiting for a fix in a tunnel" and "you denied
/// location access" look identical in the UI, and the user could not tell that
/// one of them is fixable by moving and the other is not.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart' as geo;

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/geo_point.dart';

/// Supplies the phone's position.
abstract class LocationDatasource {
  /// Ask for the location permission, showing a rationale if needed.
  Future<LocationPermissionOutcome> ensurePermission();

  /// The best position available right now.
  ///
  /// Returns `null` inside an [Ok] when there is genuinely no fix.
  Future<Result<GeoPoint?>> currentPosition();

  /// Positions as they arrive, for the live-location screen.
  Stream<GeoPoint> watch({int distanceFilterM});
}

/// How the permission request ended.
enum LocationPermissionOutcome {
  /// The user granted fine (or approximate) location.
  granted,

  /// The user denied, but the OS will ask again.
  denied,

  /// The user denied with "don't ask again", so only Settings can change it.
  permanentlyDenied,

  /// The device has no location hardware, or services are off device-wide.
  unavailable,
}

/// `geolocator` implementation.
class GeolocatorDatasource implements LocationDatasource {
  GeolocatorDatasource({AppLogger? log}) : _log = log ?? AppLogger();

  final AppLogger _log;

  /// Refined fixes, published while a caller is watching.
  ///
  /// A broadcast controller so [watch] has no listener-count coupling with
  /// [currentPosition]; the background refresh and the watch feed are the same
  /// stream, so a position learned by one benefits the other.
  final StreamController<GeoPoint> _refined = StreamController<GeoPoint>.broadcast();

  @override
  Future<LocationPermissionOutcome> ensurePermission() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionOutcome.unavailable;
    }
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    return switch (permission) {
      geo.LocationPermission.always ||
      geo.LocationPermission.whileInUse =>
        LocationPermissionOutcome.granted,
      geo.LocationPermission.denied => LocationPermissionOutcome.denied,
      // "deniedForever" on both platforms.
      geo.LocationPermission.deniedForever =>
        LocationPermissionOutcome.permanentlyDenied,
      // The platform could not say. Treated as "not granted" rather than
      // assumed-granted: guessing "granted" would send the user down a
      // permission path that cannot work.
      geo.LocationPermission.unableToDetermine =>
        LocationPermissionOutcome.unavailable,
    };
  }

  @override
  Future<Result<GeoPoint?>> currentPosition() async {
    // The cached fix first. In a moving vehicle this is usually seconds old and
    // good enough to put a pin on the map immediately.
    final GeoPoint? cached = await _lastKnown();
    if (cached != null) {
      // Refine in the background; the caller does not wait for it. The returned
      // Future is deliberately discarded rather than awaited, so a slow fix
      // cannot delay the alert screen by even a frame.
      _refreshInBackground();
      return Ok<GeoPoint?>(cached);
    }
    return _live();
  }

  Future<GeoPoint?> _lastKnown() async {
    final Result<GeoPoint?> result = await guard<GeoPoint?>(
      () async {
        final geo.Position? p = await geo.Geolocator.getLastKnownPosition();
        return p == null ? null : _toGeoPoint(p);
      },
      kind: FailureKind.location,
      message: 'Could not read the last known position',
      log: _log,
      logTag: AppLogger.tagLocation,
    );
    return result.valueOrNull;
  }

  /// Kick off a live fix and publish it when it lands.
  ///
  /// Fire-and-forget by design: the caller already has a usable position, and
  /// blocking on a better one is the thing this whole design avoids.
  void _refreshInBackground() {
    unawaited(_live().then((Result<GeoPoint?> result) {
      final GeoPoint? point = result.valueOrNull;
      if (point != null && !_refined.isClosed) _refined.add(point);
    }));
  }

  /// A live fix, with a hard deadline.
  Future<Result<GeoPoint?>> _live() async {
    return guard<GeoPoint?>(
      () async {
        final geo.Position p = await geo.Geolocator.getCurrentPosition(
          locationSettings: _settings,
        );
        return _toGeoPoint(p);
      },
      kind: FailureKind.location,
      message: 'Could not get a GPS fix',
      isRetryable: (Object error) =>
          // A timeout is normal in a moving vehicle — a fix can take a while
      // indoors, and retrying is exactly right there. A disabled service is
      // also worth retrying, because the user can switch it back on.
          error is TimeoutException ||
          error is geo.LocationServiceDisabledException,
      log: _log,
      logTag: AppLogger.tagLocation,
    );
  }

  /// The shared location request.
  ///
  /// `timeLimit` lives on [geo.AndroidSettings] because it is an Android
  /// concept; iOS bounds the request by its own location-update budget. Setting
  /// it is what turns "hangs forever with no signal" into a prompt `Failure`
  /// the UI can render as "no fix available".
  static final geo.LocationSettings _settings = geo.LocationSettings(
    accuracy: geo.LocationAccuracy.high,
    timeLimit: const Duration(seconds: 12),
  );

  static GeoPoint _toGeoPoint(geo.Position p) => GeoPoint(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyM: p.accuracy,
        // The *phone's* clock. Deliberately: the node's own `t_ms` is uptime
        // and means nothing outside the device (§5).
        timestamp: p.timestamp.toUtc(),
      );

  @override
  Stream<GeoPoint> watch({int distanceFilterM = 10}) {
    // A distance filter, not a time filter: a stationary phone must not burn
    // power emitting the same coordinate 50 times a second.
    final Stream<geo.Position> positions = geo.Geolocator.getPositionStream(
      locationSettings: geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: distanceFilterM,
      ),
    );
    return positions.map(_toGeoPoint);
  }

  /// Release the broadcast controller. The app calls this on teardown.
  Future<void> dispose() => _refined.close();
}

/// A scripted location, for tests and the hardware-free demo.
///
/// Deterministic, so an integration test can assert "the hospital list at
/// these coordinates is exactly these three" rather than a fuzzy assertion.
class FakeLocationDatasource implements LocationDatasource {
  FakeLocationDatasource({GeoPoint? position, this.outcome = LocationPermissionOutcome.granted})
      : _position = position;

  GeoPoint? _position;

  /// What [ensurePermission] reports.
  LocationPermissionOutcome outcome;

  final StreamController<GeoPoint> _controller =
      StreamController<GeoPoint>.broadcast();

  /// Set to make [currentPosition] fail, exercising the "GPS unavailable" path
  /// of PROJECT_PLAN §25.
  Failure? nextFailure;

  /// Move the scripted position, notifying [watch] listeners.
  void moveTo(GeoPoint point) {
    _position = point;
    if (!_controller.isClosed) _controller.add(point);
  }

  @override
  Future<LocationPermissionOutcome> ensurePermission() async => outcome;

  @override
  Future<Result<GeoPoint?>> currentPosition() async {
    final Failure? failure = nextFailure;
    if (failure != null) return FailureResult<GeoPoint?>(failure);
    return Ok<GeoPoint?>(_position);
  }

  @override
  Stream<GeoPoint> watch({int distanceFilterM = 10}) => _controller.stream;

  Future<void> dispose() => _controller.close();
}
