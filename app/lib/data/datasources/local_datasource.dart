/// Local persistence: the offline outbox, cached history, and the hospital
/// cache.
///
/// ## Why SQLite and not SharedPreferences
///
/// SharedPreferences is a single key-value blob with no queries, no indexes and
/// no atomic multi-row write. The outbox needs *"the 20 oldest rows that are due
/// for a retry, ordered by `nextAttemptAt`"* — a query with an ORDER BY and a
/// LIMIT over an index, run on every reconnect. In SharedPreferences that means
/// deserialising the entire queue, sorting it in Dart, and writing the whole
/// thing back, every time. SQLite does it in the database engine in O(log n + k).
///
/// It is also crash-safe: a write is a transaction, so a process death
/// mid-write cannot leave a half-written queue row that would then be retried
/// forever.
library;

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/logger.dart';
import '../../core/result.dart';

/// A queued cloud write.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.accidentId,
    required this.payload,
    required this.createdAt,
    required this.attempts,
    required this.nextAttemptAt,
    this.lastError,
  });

  /// Local row id.
  final int id;

  /// The accident this entry publishes.
  final String accidentId;

  /// The Firestore document, pre-encoded as JSON.
  final String payload;

  /// When it was queued. This is the *accident* time, not the queue time.
  final DateTime createdAt;

  /// How many delivery attempts have been made.
  final int attempts;

  /// Earliest time the next attempt may run. Drives the backoff.
  final DateTime nextAttemptAt;

  /// The last failure message, for the diagnostics screen.
  final String? lastError;

  /// Whether an attempt is due now.
  bool isDue(DateTime now) => !now.isBefore(nextAttemptAt);

  /// Backoff for the next attempt.
  ///
  /// Exponential with a hard ceiling: attempt 1 → 5 s, 2 → 10 s, 3 → 20 s …
  /// capped at 5 minutes. The ceiling matters — an unbounded backoff on a long
  /// outage means the app reconnects to the network and then sits silent for an
  /// hour, which for an emergency log is unacceptable. The floor keeps a
  /// transient blip from becoming a permanent loss.
  static Duration backoffFor(int attempts) {
    const Duration floor = Duration(seconds: 5);
    const Duration ceiling = Duration(minutes: 5);
    final int seconds = 5 * (1 << (attempts.clamp(0, 10) - 1));
    final Duration d = Duration(seconds: seconds);
    return d < floor ? floor : (d > ceiling ? ceiling : d);
  }

  @override
  String toString() => 'OutboxEntry($id, accident=$accidentId, attempts=$attempts)';
}

/// Local storage.
abstract class LocalDatasource {
  /// Open the database, creating and migrating as needed.
  Future<Result<void>> open();

  /// Enqueue a document for later delivery. Idempotent per [accidentId].
  Future<Result<int>> enqueue({
    required String accidentId,
    required Map<String, Object?> payload,
    required DateTime now,
  });

  /// Entries whose backoff has elapsed, oldest first.
  Future<Result<List<OutboxEntry>>> dueEntries({
    required DateTime now,
    int limit = 20,
  });

  /// Mark [id] delivered.
  Future<Result<void>> markDelivered(int id);

  /// Mark [id] failed, scheduling the next attempt with backoff.
  Future<Result<void>> markFailed(int id, {required String error, required DateTime now});

  /// Number of entries still pending.
  Future<Result<int>> pendingCount();

  /// Cache a serialised hospital dataset.
  Future<Result<void>> cacheHospitals(String json, {required DateTime now});

  /// Read the cached hospital dataset, or `null`.
  Future<Result<String?>> cachedHospitals();

  /// Release resources.
  Future<void> close();
}

/// `sqflite` implementation.
class SqfliteDatasource implements LocalDatasource {
  SqfliteDatasource({AppLogger? log, this.databaseName = 'saas_outbox.db'})
      : _log = log ?? AppLogger();

  final AppLogger _log;
  final String databaseName;
  Database? _db;

  @override
  Future<Result<void>> open() async {
    if (_db != null) return const Ok<void>(null);
    return guard<void>(
      () async {
        final String dir = await getDatabasesPath();
        _db = await openDatabase(
          p.join(dir, databaseName),
          version: 1,
          onConfigure: (Database db) async {
            // WAL: the outbox is written on the critical path (an accident is
            // recorded while a countdown ticks) and read by a background sync.
            // WAL lets the two proceed without blocking each other.
            await db.execute('PRAGMA journal_mode=WAL');
            // Durability over speed: an accident record that is lost because
            // the process died is the one failure this app cannot tolerate.
            await db.execute('PRAGMA synchronous=FULL');
          },
          onCreate: (Database db, int version) async {
            await db.execute('''
              CREATE TABLE outbox (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                accident_id   TEXT    NOT NULL UNIQUE,
                payload       TEXT    NOT NULL,
                created_at    INTEGER NOT NULL,
                attempts      INTEGER NOT NULL DEFAULT 0,
                next_attempt_at INTEGER NOT NULL,
                last_error    TEXT
              )
            ''');
            // The outbox query is `WHERE next_attempt_at <= ? ORDER BY next_attempt_at LIMIT n`.
            // Without this index it is a full scan + sort on every reconnect.
            await db.execute(
              'CREATE INDEX idx_outbox_due ON outbox(next_attempt_at)',
            );

            await db.execute('''
              CREATE TABLE kv (
                k TEXT PRIMARY KEY,
                v TEXT NOT NULL,
                updated_at INTEGER NOT NULL
              )
            ''');
          },
        );
      },
      kind: FailureKind.storage,
      message: 'Could not open local storage',
      log: _log,
      logTag: 'Local',
    );
  }

  Database get _require => _db!;

  @override
  Future<Result<int>> enqueue({
    required String accidentId,
    required Map<String, Object?> payload,
    required DateTime now,
  }) {
    return guard<int>(
      () async {
        // CONFLICT_IGNORE on the UNIQUE accident_id: re-enqueueing the same
        // accident (a retried BLE event, §8) must not create a second row, or
        // the accident would be written to Firestore twice.
        await _require.insert(
          'outbox',
          <String, Object?>{
            'accident_id': accidentId,
            'payload': jsonEncode(payload),
            'created_at': now.millisecondsSinceEpoch,
            'attempts': 0,
            // Due immediately: the first attempt should not wait.
            'next_attempt_at': now.millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final List<Map<String, Object?>> rows = await _require.query(
          'outbox',
          columns: <String>['id'],
          where: 'accident_id = ?',
          whereArgs: <Object?>[accidentId],
          limit: 1,
        );
        return rows.isEmpty ? 0 : rows.first['id']! as int;
      },
      kind: FailureKind.storage,
      message: 'Could not queue the accident for upload',
      log: _log,
      logTag: 'Local',
    );
  }

  @override
  Future<Result<List<OutboxEntry>>> dueEntries({
    required DateTime now,
    int limit = 20,
  }) {
    return guard<List<OutboxEntry>>(
      () async {
        final List<Map<String, Object?>> rows = await _require.query(
          'outbox',
          where: 'next_attempt_at <= ?',
          whereArgs: <Object?>[now.millisecondsSinceEpoch],
          orderBy: 'next_attempt_at ASC',
          limit: limit,
        );
        return rows.map(_toEntry).toList(growable: false);
      },
      kind: FailureKind.storage,
      message: 'Could not read the upload queue',
      log: _log,
      logTag: 'Local',
    );
  }

  static OutboxEntry _toEntry(Map<String, Object?> row) => OutboxEntry(
        id: row['id']! as int,
        accidentId: row['accident_id']! as String,
        payload: row['payload']! as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at']! as int,
          isUtc: true,
        ),
        attempts: row['attempts']! as int,
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(
          row['next_attempt_at']! as int,
          isUtc: true,
        ),
        lastError: row['last_error'] as String?,
      );

  @override
  Future<Result<void>> markDelivered(int id) {
    return guard<void>(
      () async {
        await _require.delete('outbox', where: 'id = ?', whereArgs: <Object?>[id]);
      },
      kind: FailureKind.storage,
      message: 'Could not clear a delivered upload',
      log: _log,
      logTag: 'Local',
    );
  }

  @override
  Future<Result<void>> markFailed(
    int id, {
    required String error,
    required DateTime now,
  }) {
    return guard<void>(
      () async {
        final List<Map<String, Object?>> rows = await _require.query(
          'outbox',
          columns: <String>['attempts'],
          where: 'id = ?',
          whereArgs: <Object?>[id],
          limit: 1,
        );
        if (rows.isEmpty) return;
        final int attempts = (rows.first['attempts']! as int) + 1;
        await _require.update(
          'outbox',
          <String, Object?>{
            'attempts': attempts,
            'next_attempt_at':
                now.add(OutboxEntry.backoffFor(attempts)).millisecondsSinceEpoch,
            'last_error': error,
          },
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      },
      kind: FailureKind.storage,
      message: 'Could not record a failed upload',
      log: _log,
      logTag: 'Local',
    );
  }

  @override
  Future<Result<int>> pendingCount() {
    return guard<int>(
      () async {
        final List<Map<String, Object?>> rows =
            await _require.rawQuery('SELECT COUNT(*) AS c FROM outbox');
        return (rows.first['c'] as int?) ?? 0;
      },
      kind: FailureKind.storage,
      message: 'Could not count pending uploads',
      log: _log,
      logTag: 'Local',
    );
  }

  static const String _hospitalKey = 'hospital_dataset';

  @override
  Future<Result<void>> cacheHospitals(String json, {required DateTime now}) {
    return guard<void>(
      () async {
        await _require.insert(
          'kv',
          <String, Object?>{
            'k': _hospitalKey,
            'v': json,
            'updated_at': now.millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      },
      kind: FailureKind.storage,
      message: 'Could not cache the hospital dataset',
      log: _log,
      logTag: 'Local',
    );
  }

  @override
  Future<Result<String?>> cachedHospitals() {
    return guard<String?>(
      () async {
        final List<Map<String, Object?>> rows = await _require.query(
          'kv',
          columns: <String>['v'],
          where: 'k = ?',
          whereArgs: <Object?>[_hospitalKey],
          limit: 1,
        );
        return rows.isEmpty ? null : rows.first['v'] as String?;
      },
      kind: FailureKind.storage,
      message: 'Could not read the cached hospital dataset',
      log: _log,
      logTag: 'Local',
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// An in-memory [LocalDatasource] for tests.
///
/// Implements the same semantics — including the UNIQUE-constraint de-dup, the
/// index-ordered due query and the backoff schedule — so a test that passes here
/// is testing the real ordering guarantees, not a mock's approximation.
class InMemoryLocalDatasource implements LocalDatasource {
  InMemoryLocalDatasource();

  final List<OutboxEntry> _entries = <OutboxEntry>[];
  int _nextId = 1;
  String? _hospitalJson;

  /// Set to make every write fail, exercising the storage-failure path.
  bool failWrites = false;

  @override
  Future<Result<void>> open() async => const Ok<void>(null);

  @override
  Future<Result<int>> enqueue({
    required String accidentId,
    required Map<String, Object?> payload,
    required DateTime now,
  }) async {
    if (failWrites) {
      return FailureResult<int>(
        failureOf(FailureKind.storage, 'Could not queue the accident for upload'),
      );
    }
    // Mirrors the UNIQUE(accident_id) constraint.
    for (final OutboxEntry existing in _entries) {
      if (existing.accidentId == accidentId) return Ok<int>(existing.id);
    }
    final OutboxEntry entry = OutboxEntry(
      id: _nextId++,
      accidentId: accidentId,
      payload: jsonEncode(payload),
      createdAt: now,
      attempts: 0,
      nextAttemptAt: now,
    );
    _entries.add(entry);
    return Ok<int>(entry.id);
  }

  @override
  Future<Result<List<OutboxEntry>>> dueEntries({
    required DateTime now,
    int limit = 20,
  }) async {
    final List<OutboxEntry> due = _entries
        .where((OutboxEntry e) => e.isDue(now))
        .toList()
      ..sort((OutboxEntry a, OutboxEntry b) =>
          a.nextAttemptAt.compareTo(b.nextAttemptAt));
    return Ok<List<OutboxEntry>>(due.take(limit).toList(growable: false));
  }

  @override
  Future<Result<void>> markDelivered(int id) async {
    _entries.removeWhere((OutboxEntry e) => e.id == id);
    return const Ok<void>(null);
  }

  @override
  Future<Result<void>> markFailed(
    int id, {
    required String error,
    required DateTime now,
  }) async {
    final int at = _entries.indexWhere((OutboxEntry e) => e.id == id);
    if (at < 0) return const Ok<void>(null);
    final OutboxEntry old = _entries[at];
    final int attempts = old.attempts + 1;
    _entries[at] = OutboxEntry(
      id: old.id,
      accidentId: old.accidentId,
      payload: old.payload,
      createdAt: old.createdAt,
      attempts: attempts,
      nextAttemptAt: now.add(OutboxEntry.backoffFor(attempts)),
      lastError: error,
    );
    return const Ok<void>(null);
  }

  @override
  Future<Result<int>> pendingCount() async => Ok<int>(_entries.length);

  @override
  Future<Result<void>> cacheHospitals(String json, {required DateTime now}) async {
    _hospitalJson = json;
    return const Ok<void>(null);
  }

  @override
  Future<Result<String?>> cachedHospitals() async => Ok<String?>(_hospitalJson);

  @override
  Future<void> close() async => _entries.clear();
}
