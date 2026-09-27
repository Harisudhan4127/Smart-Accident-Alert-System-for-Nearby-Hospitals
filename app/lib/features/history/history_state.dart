/// The history screen's state, including day grouping.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../../core/di/providers.dart';
import '../../data/repositories/accident_repository.dart';
import '../../core/formatters.dart';
import '../../domain/entities/accident.dart';

/// Load state for the history list.
enum HistoryStatus { loading, ready, error }

/// A day's worth of accidents.
@immutable
class HistoryGroup {
  const HistoryGroup({required this.label, required this.records, required this.day});

  /// The heading, e.g. "Today", "Yesterday" or a date.
  final String label;

  /// Records within the day, newest first.
  final List<AccidentRecord> records;

  /// Midnight of the day, used for the relative label.
  final DateTime day;
}

/// The history screen's state.
@immutable
class HistoryViewState {
  const HistoryViewState({
    this.records = const <AccidentRecord>[],
    this.status = HistoryStatus.loading,
    this.error,
  });

  final List<AccidentRecord> records;
  final HistoryStatus status;
  final String? error;

  /// Records grouped by local day, newest day first.
  ///
  /// Grouped by *local* midnight rather than by a 24-hour window, because the
  /// only meaningful boundary for "when did this happen" is the one the user's
  /// own clock draws.
  List<HistoryGroup> get groups {
    final Map<DateTime, List<AccidentRecord>> byDay = <DateTime, List<AccidentRecord>>{};
    for (final AccidentRecord record in records) {
      final DateTime local = record.occurredAt.toLocal();
      final DateTime day = DateTime(local.year, local.month, local.day);
      (byDay[day] ??= <AccidentRecord>[]).add(record);
    }

    final List<DateTime> days = byDay.keys.toList()
      ..sort((DateTime a, DateTime b) => b.compareTo(a));

    return <HistoryGroup>[
      for (final DateTime day in days)
        HistoryGroup(
          label: _dayLabel(day),
          day: day,
          records: List<AccidentRecord>.unmodifiable(byDay[day]!),
        ),
    ];
  }

  static String _dayLabel(DateTime day) {
    final DateTime today = DateTime.now();
    final DateTime midnight = DateTime(today.year, today.month, today.day);
    final int diff = midnight.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    // Within the last week, name the weekday; older than that, an absolute
    // date is clearer than "3 weeks ago" on a screen someone scrolled.
    if (diff < 7) {
      return const <String>[
        'Monday', 'Tuesday', 'Wednesday', 'Thursday',
        'Friday', 'Saturday', 'Sunday',
      ][day.weekday - 1];
    }
    return Fmt.date(day);
  }
}

/// Drives the history screen.
class HistoryViewController extends Notifier<HistoryViewState> {
  StreamSubscription<List<AccidentRecord>>? _sub;

  @override
  HistoryViewState build() {
    ref.onDispose(() => unawaited(_sub?.cancel()));

    final AccidentRepository repo = ref.read(accidentRepositoryProvider);
    // Firestore's own stream already handles offline caching and reconnect, so
    // the history screen needs no separate sync logic.
    _sub = repo.watchHistory().listen(
      (List<AccidentRecord> records) {
        state = HistoryViewState(
          records: records,
          status: HistoryStatus.ready,
        );
      },
      onError: (Object error) {
        state = HistoryViewState(
          status: HistoryStatus.error,
          error: 'The accident history could not be loaded.',
        );
      },
    );

    return const HistoryViewState();
  }

  Future<void> reload() => ref.read(accidentRepositoryProvider).syncOutbox();
}

/// The history screen's state.
final NotifierProvider<HistoryViewController, HistoryViewState>
    historyViewProvider =
    NotifierProvider<HistoryViewController, HistoryViewState>(
  HistoryViewController.new,
);
