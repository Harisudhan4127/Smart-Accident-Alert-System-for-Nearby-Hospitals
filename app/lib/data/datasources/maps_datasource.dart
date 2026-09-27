/// Building and opening platform intents: maps, `tel:` and `sms:`.
///
/// **Everything here is a pure function.** The URI is built by this library and
/// only then handed to `url_launcher`, so the whole §15 / §20 message format is
/// unit-testable on a machine with no phone, no platform channel and no
/// network. That matters more than it sounds: the emergency message is the
/// single most important string the app produces, and it must be verifiable in
/// CI rather than by squinting at a phone.
library;

import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../core/logger.dart';
import '../../core/result.dart';
import '../../domain/entities/geo_point.dart';

/// A `sms:` intent: body, optional recipient.
class SmsIntent {
  const SmsIntent({required this.body, this.recipients = const <String>[]});

  /// The pre-filled message body.
  final String body;

  /// Recipients, in order. Empty opens the composer with no recipient, letting
  /// the user pick — the right default when the profile has no contacts.
  final List<String> recipients;
}

/// Builds and opens maps, dialer and SMS intents.
abstract class MapsDatasource {
  /// Open [point] in a map application (§15).
  Future<Result<void>> openInMaps(GeoPoint point, {String? label});

  /// Open a search for [query] in a map application.
  Future<Result<void>> searchInMaps(String query);

  /// Dial [phoneNumber].
  Future<Result<void>> call(String phoneNumber);

  /// Open the SMS composer pre-filled per §20.
  ///
  /// Does **not** send silently: `sms:` opens the user's composer, so they see
  /// and send the message. Silently dispatching an SMS would need a paid SMS
  /// gateway and would be a decision the user must make, not us.
  Future<Result<void>> openSms(SmsIntent intent);

  /// The §15 maps URL for [point].
  String mapsUrl(GeoPoint point);

  /// The §20 emergency message for a crash at [point] at [occurredAt].
  String emergencyMessageBody({
    required GeoPoint point,
    required DateTime occurredAt,
    String? deviceName,
  });
}

/// `url_launcher` implementation.
class UrlLauncherMapsDatasource implements MapsDatasource {
  UrlLauncherMapsDatasource({AppLogger? log})
      : _log = log ?? AppLogger();

  final AppLogger _log;

  /// The §15 URL format, verbatim.
  ///
  /// `api=1` + `query=` is Google's documented "open this point" form. The
  /// coordinates are interpolated from [point] — §15 explicitly forbids
  /// hard-coding them, and this is the only place they are formatted.
  @override
  String mapsUrl(GeoPoint point) {
    return 'https://www.google.com/maps/search/?api=1&query='
        '${_coord(point.latitude)},${_coord(point.longitude)}';
  }

  /// 6 decimal places ≈ 0.11 m of precision.
  ///
  /// More digits would imply accuracy the GPS does not have; fewer would make
  /// two nearby crashes indistinguishable. `GeoPoint` is already clamped to a
  /// sane range, so this cannot emit `NaN` or an out-of-range coordinate.
  static String _coord(double v) => v.toStringAsFixed(6);

  @override
  String emergencyMessageBody({
    required GeoPoint point,
    required DateTime occurredAt,
    String? deviceName,
  }) {
    // Renders in the device's local zone: the recipient is a person, and "10:30"
    // is only meaningful if they are in the same place as the accident.
    final String stamp = _formatLocal(occurredAt);
    final String accuracy =
        '±${point.accuracyM.round()} m' + (point.accuracyM > 50 ? ' (low)' : '');

    return <String>[
      'EMERGENCY ALERT',
      '',
      deviceName == null || deviceName.trim().isEmpty
          ? 'A possible accident has been detected.'
          : 'A possible accident has been detected for $deviceName.',
      '',
      'Time: $stamp',
      'Location: ${_coord(point.latitude)}, ${_coord(point.longitude)}',
      'Accuracy: $accuracy',
      '',
      'Open location:',
      mapsUrl(point),
      '',
      'Please check the person\'s condition.',
    ].join('\n');
  }

  static String _formatLocal(DateTime t) {
    final DateTime local = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final int hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final String suffix = local.hour < 12 ? 'AM' : 'PM';
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '$hour12:${two(local.minute)} $suffix';
  }

  @override
  Future<Result<void>> openInMaps(GeoPoint point, {String? label}) {
    return _open(
      mapsUrl(point),
      'map',
      FailureKind.validation,
      'Could not open the map',
    );
  }

  @override
  Future<Result<void>> searchInMaps(String query) {
    final String encoded = Uri.encodeQueryComponent(query);
    return _open(
      'https://www.google.com/maps/search/?api=1&query=$encoded',
      'map search',
      FailureKind.validation,
      'Could not search the map',
    );
  }

  @override
  Future<Result<void>> call(String phoneNumber) {
    final String digits = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.isEmpty) {
      return Future<Result<void>>.value(
        FailureResult<void>(
          failureOf(FailureKind.validation, 'That contact has no phone number'),
        ),
      );
    }
    return _open('tel:$digits', 'dialer', FailureKind.validation, 'Could not place the call');
  }

  @override
  Future<Result<void>> openSms(SmsIntent intent) {
    // Uri's query encoding handles the newlines in a multi-line body, which a
    // hand-built string would mangle into a single line.
    final Uri uri = Uri(
      scheme: 'sms',
      path: intent.recipients.isEmpty ? null : intent.recipients.first,
      queryParameters: <String, String>{'body': intent.body},
    );
    return guard<void>(
      () async {
        final bool ok = await launcher.launchUrl(
          uri,
          mode: launcher.LaunchMode.externalApplication,
        );
        if (!ok) {
          throw StateError('the platform declined to open the SMS composer');
        }
      },
      isRetryable: (Object _) => true,
      kind: FailureKind.cancelled,
      message: 'Could not open the SMS composer',
      log: _log,
      logTag: 'Maps',
    );
  }

  Future<Result<void>> _open(
    String url,
    String what,
    FailureKind kind,
    String message,
  ) {
    return guard<void>(
      () async {
        final Uri uri = Uri.parse(url);
        final bool ok = await launcher.launchUrl(
          uri,
          mode: launcher.LaunchMode.externalApplication,
        );
        if (!ok) {
          throw StateError('no application handled the $what intent');
        }
        _log.log(LogLevel.info, 'intent', 'opened $what: $url');
      },
      kind: kind,
      message: message,
      log: _log,
      logTag: 'Maps',
    );
  }
}

/// Records intents instead of opening them, for tests and the demo.
class RecordingMapsDatasource implements MapsDatasource {
  final List<String> launched = <String>[];
  final List<String> dialled = <String>[];
  final List<SmsIntent> texted = <SmsIntent>[];

  /// When set, every call fails with this, exercising §25's "no handler" path.
  bool failEverything = false;

  @override
  String mapsUrl(GeoPoint point) =>
      'https://www.google.com/maps/search/?api=1&query='
      '${point.latitude.toStringAsFixed(6)},${point.longitude.toStringAsFixed(6)}';

  @override
  String emergencyMessageBody({
    required GeoPoint point,
    required DateTime occurredAt,
    String? deviceName,
  }) =>
      'EMERGENCY ALERT\n\nTime: $occurredAt\n'
      'Location: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}\n\n'
      'Open location:\n${mapsUrl(point)}';

  @override
  Future<Result<void>> openInMaps(GeoPoint point, {String? label}) async {
    if (failEverything) {
      return FailureResult<void>(failureOf(FailureKind.validation, 'no map app'));
    }
    launched.add(mapsUrl(point));
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> searchInMaps(String query) async {
    if (failEverything) {
      return FailureResult<void>(failureOf(FailureKind.validation, 'no map app'));
    }
    launched.add('search:$query');
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> call(String phoneNumber) async {
    if (failEverything) {
      return FailureResult<void>(failureOf(FailureKind.validation, 'no dialer'));
    }
    dialled.add(phoneNumber);
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> openSms(SmsIntent intent) async {
    if (failEverything) {
      return FailureResult<void>(failureOf(FailureKind.cancelled, 'composer declined'));
    }
    texted.add(intent);
    return const Ok<void>(null);
  }
}
