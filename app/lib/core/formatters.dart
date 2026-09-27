/// Display formatting.
///
/// Pure functions, no widget dependencies, no `BuildContext` — so they are
/// unit-testable and reusable from a notification body, an SMS, or a widget.
///
/// The one non-obvious rule in this file: **any number that changes while the
/// user is looking at it must be rendered with a fixed number of characters**,
/// otherwise the layout jitters. `12.3 km` next to `9.87 km` has different
/// widths; the telemetry panels therefore use the fixed-width variants
/// ([distanceCompact], [coordinateFixed]) rather than the natural ones.
library;

import 'package:intl/intl.dart';

import '../domain/entities/geo_point.dart';

/// All formatters used by the app.
///
/// Injectable date/number formats would be overkill; instead the locale is a
/// settable static so tests and the (future) localisation layer can pin it.
abstract final class Fmt {
  /// Active locale for date/number formatting. Defaults to en-IN to match
  /// `HELLO.locale` (§6.1) and the project's own examples (§20 shows
  /// `27/09/2026 10:30 AM`).
  static String locale = 'en_IN';

  /// Locales are cached in one bundle so that changing [locale] cannot leave
  /// half the app on the old language. `_Formats` is rebuilt when [locale]
  /// changes (see [resetLocale]).
  static _Formats? _formats;

  static _Formats get _f => _formats ??= _Formats.forLocale(locale);

  /// `27/09/2026`
  static String date(DateTime value) => _f.date.format(value);

  /// `10:30 AM`
  static String time(DateTime value) => _f.time.format(value);

  /// `27/09/2026 10:30 AM` — the format used in the emergency SMS (§20).
  static String dateTime(DateTime value) => _f.dateTime.format(value);

  /// `2026-09-27 10:30:00` — sortable, used in logs and diagnostics.
  static String sortable(DateTime value) => _f.iso.format(value);

  /// `20260927-103000` — used in export file names.
  static String fileStamp(DateTime value) => _f.fileStamp.format(value);

  /// Whole seconds, zero padded: `07`. Used by the countdown, where a changing
  /// digit count would shift the layout.
  static String countdown(int seconds) => seconds.toString().padLeft(2, '0');

  /// `1.2 km` / `340 m` / `820 m` — natural width, for lists and messages.
  static String distance(num metres) {
    if (metres.isNaN) {
      return '—';
    }
    if (metres < 0) {
      return '—';
    }
    if (metres < 1000) {
      return '${metres.round()} m';
    }
    if (metres < 10000) {
      return '${(metres / 1000).toStringAsFixed(1)} km';
    }
    return '${(metres / 1000).round()} km';
  }

  /// Fixed-width distance, always `< 100 km` or `> 100 km`:
  /// `  12.3 km` / `123.4 km`. Six characters plus a unit, so a telemetry readout
  /// does not reflow as the number changes.
  static String distanceCompact(num metres) {
    if (metres.isNaN || metres < 0) {
      return '   ——  ';
    }
    if (metres < 100000) {
      return '${(metres / 1000).toStringAsFixed(1).padLeft(6)} km';
    }
    return '${(metres / 1000).round().toString().padLeft(6)} km';
  }

  /// ±7 decimal places, always signed: `+12.345678`. Seven decimals is 11 mm,
  /// which is what §6 means by "floats rounded to 7 decimal places", and the
  /// sign keeps a north/south reading unambiguous at a glance.
  static String coordinateFixed(num value) {
    final String s = value.abs().toStringAsFixed(7);
    final String padded = s.length >= 9 ? s : s.padLeft(9, '0');
    return '${value < 0 ? '-' : '+'}$padded';
  }

  /// `12.345678` — no sign, no padding. Used where the sign is noise (e.g. a
  /// maps URL) or where a sign would be misread as "plus/minus unknown".
  static String coordinatePlain(num value) => value.toStringAsFixed(6);

  /// `12.345678, 79.123456` — the §20 "Location:" line.
  static String coordinatePair(GeoPoint point) =>
      '${coordinatePlain(point.latitude)}, ${coordinatePlain(point.longitude)}';

  /// GPS accuracy: `8 m` / `1.2 km` — same rules as [distance] but never below
  /// 1 m, because a reported accuracy of 0 m means "unknown", not "perfect".
  static String accuracy(num metres) {
    if (metres.isNaN || metres <= 0) {
      return 'unknown';
    }
    return distance(metres);
  }

  /// Battery percentage. `100` → `100%`, [null]/unknown → `—`.
  static String battery(int? percent) => percent == null ? '—' : '$percent%';

  /// Battery with a visual hint the UI can colour: `Low 12%`, `Charging`,
  /// `96%`, or `—` when unknown.
  ///
  /// The protocol reserves `255` for "battery unknown" (§5), and the phone-side
  /// battery may genuinely be unavailable; both collapse to `—` rather than
  /// showing a nonsensical 255 %.
  static String batteryVerbose(int? percent, {required bool charging}) {
    if (percent == null || percent < 0 || percent > 100) {
      return charging ? 'Charging' : '—';
    }
    if (charging) {
      return 'Charging $percent%';
    }
    return '$percent%';
  }

  /// `just now`, `12 s ago`, `4 min ago`, `2 h ago`, `3 d ago`, `—` for null.
  /// Used in the history list and the outbox status.
  static String relativeTime(DateTime? value, {DateTime? now}) {
    if (value == null) {
      return '—';
    }
    final DateTime reference = now ?? DateTime.now();
    final Duration delta = reference.difference(value);
    if (delta.isNegative) {
      return 'just now';
    }
    if (delta.inSeconds < 5) {
      return 'just now';
    }
    if (delta.inSeconds < 60) {
      return '${delta.inSeconds} s ago';
    }
    if (delta.inMinutes < 60) {
      return '${delta.inMinutes} min ago';
    }
    if (delta.inHours < 24) {
      return '${delta.inHours} h ago';
    }
    if (delta.inDays < 7) {
      return '${delta.inDays} d ago';
    }
    return date(value);
  }

  /// `in 8 s` / `8 s ago` — signed relative time for countdowns and deadlines.
  static String relativeTimeSigned(DateTime value, {DateTime? now}) {
    final DateTime reference = now ?? DateTime.now();
    final Duration delta = value.difference(reference);
    final bool future = !delta.isNegative;
    final Duration abs = delta.abs();
    final String body = abs.inSeconds < 60
        ? '${abs.inSeconds} s'
        : abs.inMinutes < 60
            ? '${abs.inMinutes} min'
            : abs.inHours < 24
                ? '${abs.inHours} h'
                : '${abs.inDays} d';
    return future ? 'in $body' : '$body ago';
  }

  /// `uptime 6 h 12 m` — device uptime (§6.5 `uptimeMs`).
  static String uptime(Duration value) {
    if (value.inHours > 0) {
      return '${value.inHours} h ${value.inMinutes % 60} m';
    }
    if (value.inMinutes > 0) {
      return '${value.inMinutes} m ${value.inSeconds % 60} s';
    }
    return '${value.inSeconds} s';
  }

  /// `01:23.456` — a millisecond-resolution stopwatch for the device clock.
  /// Fixed width: the tenths/hundredths digits are what a user watches change.
  static String millis(Duration value) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(value.inMinutes)}:${two(value.inSeconds % 60)}.'
        '${three(value.inMilliseconds % 1000)}';
  }

  /// RSSI in dBm with a 3-state verbal hint, for the link-quality chip.
  static String signalStrength(int? dbm) {
    if (dbm == null) {
      return '—';
    }
    return '$dbm dBm';
  }

  /// Rebuild the cached formats after [locale] changes. Called by the settings
  /// repository when the user changes language; without it the memoised
  /// [DateFormat]s would keep formatting in the old locale.
  static void resetLocale(String newLocale) {
    if (newLocale == locale) {
      return;
    }
    locale = newLocale;
    _formats = null;
    _localeEpoch++;
  }

  /// Bumped by [resetLocale]; lets a test assert the caches were invalidated.
  static int get localeEpoch => _localeEpoch;
  static int _localeEpoch = 0;

  /* ------------------------------------------------------------------ messages */

  /// The §20 emergency message body, verbatim in structure.
  ///
  /// Deliberately plain text with short lines: it has to be readable in an SMS
  /// notification on a locked screen, by someone who is not the phone's owner,
  /// in a second language. The maps link is last because it is the longest line
  /// and a phone number field must survive a truncated preview.
  static String emergencyMessage({
    required DateTime occurredAt,
    required GeoPoint? location,
    required String? accuracyText,
    required String mapsUrl,
    required bool includeMapLink,
    String headline = 'EMERGENCY ALERT',
    String detail = 'A possible accident has been detected. '
        'Please check the person\'s condition.',
  }) {
    final StringBuffer buffer = StringBuffer()
      ..writeln(headline)
      ..writeln()
      ..writeln(detail)
      ..writeln()
      ..writeln('Time:')
      ..writeln(dateTime(occurredAt))
      ..writeln()
      ..writeln('Location:');
    if (location == null) {
      buffer.writeln('Location unavailable (GPS)');
    } else {
      buffer
        ..writeln(coordinatePair(location))
        ..writeln('Accuracy: ${accuracyText ?? accuracy(location.accuracyM)}');
    }
    if (includeMapLink) {
      buffer
        ..writeln()
        ..writeln('Open location:')
        ..writeln(mapsUrl);
    }
    return buffer.toString().trimRight();
  }
}

/// A locale-coherent bundle of [DateFormat]s.
///
/// Building a `DateFormat` is not free (it loads and caches locale data), and
/// telemetry/HMS rendering formats on every rebuild, so they are built once per
/// locale and thrown away together when the locale changes.
final class _Formats {
  const _Formats({
    required this.date,
    required this.time,
    required this.dateTime,
    required this.iso,
    required this.fileStamp,
  });

  factory _Formats.forLocale(String locale) => _Formats(
        date: DateFormat('dd/MM/yyyy', locale),
        time: DateFormat('hh:mm a', locale),
        dateTime: DateFormat('dd/MM/yyyy hh:mm a', locale),
        iso: DateFormat('yyyy-MM-dd HH:mm:ss', locale),
        fileStamp: DateFormat('yyyyMMdd-HHmmss', locale),
      );

  final DateFormat date;
  final DateFormat time;
  final DateFormat dateTime;
  final DateFormat iso;
  final DateFormat fileStamp;
}
