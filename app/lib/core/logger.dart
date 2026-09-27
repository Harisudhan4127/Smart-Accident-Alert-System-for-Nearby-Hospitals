/// Structured logging for the app.
///
/// **Why this exists:** the project bans `print` (`avoid_print` is on and
/// `print` in release is stripped anyway). More importantly, an emergency app
/// needs *one* place that decides what a log line looks like, because when you
/// are debugging "the alert did not fire" at 2am the log is the only evidence you
/// will have. Every line carries a subsystem tag and, in debug, a wall-clock
/// timestamp with millisecond resolution — BLE frames arrive at 50 Hz, so
/// ordering and timing are the whole story.
///
/// Production behaviour is deliberately conservative: below [LogLevel.warning]
/// nothing is emitted at all, and nothing is ever written to disk (accident
/// records contain location data; §26 says do not store unnecessary personal
/// information, and a log file is personal information).
library;

import 'dart:developer' as developer;

/// Severity of a log record.
enum LogLevel {
  /// Fine-grained tracing, e.g. per-frame BLE telemetry. Off by default: 50 Hz
  /// telemetry would be 180 000 lines per hour.
  trace,

  /// Milestones: link up/down, event received, accident persisted.
  debug,

  /// Recoverable problems: GPS unavailable, outbox retrying, hospital search
  /// fell back to the main isolate.
  info,

  /// Something the user should probably know about but that is not fatal.
  warning,

  /// A layer boundary failed. The message is written so that a `Failure` in
  /// core/result.dart could be rendered from it, which is what the UI needs.
  error,

  /// Unrecoverable. The app is about to show an error screen.
  fatal,
}

/// A single log sink. Implementations must be cheap and must never throw —
/// logging must not be able to break an emergency dispatch.
abstract interface class LogSink {
  /// Emit one already-formatted record.
  void write(LogRecord record);
}

/// One log line.
final class LogRecord {
  /// One log line, as handed to a [LogSink].
  const LogRecord({
    required this.level,
    required this.tag,
    required this.message,
    required this.timestamp,
    this.error,
    this.stackTrace,
  });

  /// Severity of this record.
  final LogLevel level;

  /// Subsystem tag, e.g. `BLE`, `Outbox`, `Hospitals`.
  final String tag;

  /// The message, already interpolated.
  final String message;

  /// When the line was created. Carried on the record (not read by the sink) so
  /// tests can assert ordering and so every sink renders the same instant.
  final DateTime timestamp;

  /// The error, if any. `Object`, not `Exception`: a plugin
  /// can throw anything and the sink must not care.
  final Object? error;

  /// Where [error] was thrown, when the caller captured it.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..write('[')
      ..write(_hms(timestamp))
      ..write('] ')
      ..write(level.name.toUpperCase().padRight(7))
      ..write('] ')
      ..write('<')
      ..write(tag)
      ..write('> ')
      ..write(message);
    if (error != null) {
      buffer.write(' | error: $error');
    }
    if (stackTrace != null) {
      buffer.write('\n$stackTrace');
    }
    return buffer.toString();
  }
}

/// The logger. Obtain the instance from `loggerProvider`
/// (`lib/core/di/providers.dart`) — do not construct one ad hoc, or the level
/// configured by the user will not apply.
final class AppLogger {
  /// Creates a logger. [sink] defaults to [DeveloperConsoleSink] and
  /// [clock] is injectable so tests can pin timestamps.
  AppLogger({
    this.level = LogLevel.debug,
    LogSink? sink,
    this.clock = DateTime.now,
    this.tagPrefix = '',
  }) : _sink = sink ?? const DeveloperConsoleSink();

  final LogSink _sink;

  /// Time source, injectable so tests get deterministic output.
  final DateTime Function() clock;

  /// Prepended to every tag written by this logger, separated by `.`.
  ///
  /// This is what [child] manipulates. It lives here rather than in a wrapper
  /// subclass so that a child *is* an [AppLogger] and shares this instance's
  /// sink and clock: there is exactly one code path that formats a line, which
  /// is the whole point of a logger.
  final String tagPrefix;

  /// Threshold at runtime. Raise or lower it from the debug menu, or before
  /// attaching a crash reporter, without rebuilding anything.
  LogLevel level;

  /// Tags for the subsystems in this app. Keeping them in one enum stops
  /// `logger.d('ble', ...)` / `logger.d('BLE', ...)` drift.
  static const String tagBle = 'BLE';

  /// Tag for the BLE framing/codec layer.
  static const String tagProtocol = 'PROTO';

  /// Tag for the 50 Hz telemetry pipeline.
  static const String tagTelemetry = 'TELEM';

  /// Tag for location acquisition.
  static const String tagLocation = 'GPS';

  /// Tag for cloud reads/writes.
  static const String tagCloud = 'FIRESTORE';

  /// Tag for the offline outbox and its sync scheduler.
  static const String tagOutbox = 'OUTBOX';

  /// Tag for hospital search and caching.
  static const String tagHospitals = 'HOSP';

  /// Tag for the emergency dispatch pipeline.
  static const String tagEmergency = 'EMERG';

  /// Tag for local notifications.
  static const String tagNotifications = 'NOTIFY';

  /// Tag for navigation and route guards.
  static const String tagRouter = 'ROUTER';

  /// Tag for persisted user settings.
  static const String tagSettings = 'SETTINGS';

  /// Tag for the hardware-free simulator.
  static const String tagSimulator = 'SIM';

  /// Finest-grained severity; off in release builds.
  void trace(String tag, String message) => log(LogLevel.trace, tag, message);

  /// Developer diagnostics.
  void debug(String tag, String message) => log(LogLevel.debug, tag, message);

  /// Normal, expected progress.
  void info(String tag, String message) => log(LogLevel.info, tag, message);

  /// Something recoverable that the user may need to know about.
  void warning(String tag, String message, [Object? error]) =>
      log(LogLevel.warning, tag, message, error);

  /// A failed operation the app recovered from.
  void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) =>
      log(LogLevel.fatal, tag, message, error, stackTrace);

  /// An operation the app could not recover from.
  void fatal(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) =>
      log(LogLevel.fatal, tag, message, error, stackTrace);

  /// Single entry point so that rate limiting / redaction can be added later in
  /// exactly one place.
  void log(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (level.index < this.level.index) {
      return;
    }
    try {
      _sink.write(
        LogRecord(
          level: level,
          tag: tagPrefix.isEmpty ? tag : '$tagPrefix.$tag',
          message: message,
          timestamp: clock(),
          error: error,
          stackTrace: stackTrace,
        ),
      );
    } on Object {
      // A failing sink must never propagate into an emergency code path.
    }
  }

  /// Returns a logger that prefixes every tag with [childTag]. Used to attribute
  /// a whole layer at once, e.g. `logger.child('repo')`.
  ///
  /// The result shares this logger's [sink] and [clock], and snapshots [level]
  /// (so a subtree can be turned up to `trace` without flooding the rest of the
  /// app). Chained calls compose left to right: `logger.child('a').child('b')`
  /// writes `a.b.<tag>`.
  AppLogger child(String childTag) => AppLogger(
        level: level,
        sink: _sink,
        clock: clock,
        tagPrefix: tagPrefix.isEmpty ? childTag : '$tagPrefix.$childTag',
      );
}

/// `HH:MM:SS.mmm` — the format we use everywhere. Lexicographically sortable,
/// which matters when you are reading interleaved 50 Hz lines.
String _hms(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
}

/// Default sink: `dart:developer`'s `log()`, which goes to the IDE console and
/// `adb logcat` without needing a platform channel or a file write.
final class DeveloperConsoleSink implements LogSink {
  /// Creates a sink that writes through `dart:developer`'s `log()`.
  const DeveloperConsoleSink();

  @override
  void write(LogRecord record) {
    developer.log(
      '$record',
      name: record.tag,
      level: _developerLevel(record.level),
      time: record.timestamp,
    );
  }

  static int _developerLevel(LogLevel level) => switch (level) {
        LogLevel.trace => 500,
        LogLevel.debug => 800,
        LogLevel.info => 900,
        LogLevel.warning => 1000,
        LogLevel.error => 1200,
        LogLevel.fatal => 1300,
      };
}
