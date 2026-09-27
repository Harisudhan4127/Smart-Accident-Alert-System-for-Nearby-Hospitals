/// Error handling across layer boundaries — no exceptions.
///
/// **Why:** PROJECT_PLAN §25 lists five failure modes that must be *rendered*
/// (BLE disconnected, GPS unavailable, internet unavailable, low battery, false
/// alarm). An exception is a control-flow mechanism that gets swallowed by the
/// nearest `catch`, ends up as a red screen, and cannot be inspected by a widget
/// without the widget knowing which layer threw. A [Result] makes the failure
/// part of the signature: `Future<Result<GeoPoint?>>` tells the caller, at the
/// call site, that this can fail and that `null` here means "no fix", not "bug".
///
/// The one rule: **throwing is still allowed inside a datasource**, where we
/// convert a plugin's exception into a [Failure]. Above that line every function
/// returns [Result].
library;

import 'dart:async';

import 'logger.dart';

/// Coarse classification of a failure.
///
/// [kind] is what the UI branches on; [message] is what it shows. Adding a new
/// failure mode means adding a case here, which is the point: the set is
/// closed, and the UI agent can exhaustively switch over it.
enum FailureKind {
  /// BLE: adapter missing/disabled, device out of range, GATT error, MTU refused.
  bluetooth,

  /// GPS: permission denied, location services off, no fix, fix too old.
  location,

  /// Location permission was denied, or permanently denied.
  permission,

  /// No usable network, request timeout, Firestore unavailable.
  network,

  /// sqflite / shared_preferences failed. Rare, but §25's "store locally" promise
  /// is exactly this kind of failure, so it is modelled explicitly.
  storage,

  /// A layer rejected the request (bad state, impossible transition, bad args).
  validation,

  /// The device sent something that does not match the frozen protocol: a bad
  /// CRC, an unknown type, or a JSON payload that does not match the schema.
  ///
  /// Distinct from [validation] on purpose. `validation` means *we* built
  /// something wrong, and a "Retry" button would be a lie. This means the
  /// firmware and the app disagree, which is a firmware-version problem the
  /// user can act on ("update the node") — and the one case where counting
  /// occurrences matters, because §8's stop-and-wait retries on top of a
  /// schema mismatch is how an alert gets silently lost.
  protocol,

  /// The operation exceeded its deadline. The BLE scan and the GPS fix both use
  /// this, and both are *expected* outcomes in a moving vehicle.
  timeout,

  /// The user declined, or an OS-level gate (SMS composer, activity result) was
  /// not satisfied. Not an error — the UI says nothing, it just does not act.
  cancelled,

  /// Anything we could not classify. Always carries a cause for diagnosis.
  unknown,
}

/// A typed, renderable failure.
///
/// Immutable, `==`-comparable, and safe to put in a widget tree. Never carries a
/// raw [Object] as its only information: [message] is already user-presentable.
final class Failure {
  /// A typed, non-fatal error. Carries enough context for a UI to
  /// explain itself and for a retry loop to decide whether to try again.
  const Failure({
    required this.kind,
    required this.message,
    this.detail,
    this.cause,
    this.retryable = false,
  });

  /// Build a failure from a caught object, keeping the object as [cause].
  factory Failure.from(
    Object error, {
    required FailureKind kind,
    required String message,
    bool? retryable,
  }) =>
      Failure(
        kind: kind,
        message: message,
        cause: error,
        retryable: retryable ?? defaultRetryable(kind),
      );

  /// The category, used to map to a user-facing message.
  final FailureKind kind;

  /// Short, user-presentable sentence. No exception class names, no stack traces.
  final String message;

  /// Extra context for the debug log / diagnostics screen. May be `null`.
  final String? detail;

  /// The underlying object, kept for logs only. Never render this.
  final Object? cause;

  /// Whether *retrying the same operation later* could plausibly succeed.
  /// Drives whether the UI shows a "Retry" button. `bluetooth` and `network`
  /// failures are retryable (the car comes back into range, the tunnel ends);
  /// `validation` and `cancelled` are not.
  final bool retryable;

  /// Sensible default for [retryable] per kind.
  static bool defaultRetryable(FailureKind kind) => switch (kind) {
        FailureKind.bluetooth => true,
        FailureKind.location => true,
        FailureKind.network => true,
        FailureKind.timeout => true,
        FailureKind.permission => true,
        FailureKind.storage => false,
        FailureKind.validation => false,
        FailureKind.protocol => false,
        FailureKind.cancelled => false,
        FailureKind.unknown => false,
      };

  @override
  String toString() =>
      'Failure(${kind.name}${retryable ? ', retryable' : ''}): $message'
      '${detail == null ? '' : ' — $detail'}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Failure &&
          other.kind == kind &&
          other.message == message &&
          other.detail == detail &&
          other.retryable == retryable;

  @override
  int get hashCode => Object.hash(kind, message, detail, retryable);
}

/// Success or [Failure], with no exceptions at the boundary.
///
/// Sealed so `switch` over a `Result` is exhaustive: forgetting the failure arm
/// is a compile error, not a production incident.
sealed class Result<T> {
  const Result();

  /// The value, or `null` when this is a [FailureResult]. Use [valueOrNull] if
  /// you want the nullable form without a type test.
  T? get valueOrNull => switch (this) {
        final Ok<T> ok => ok.value,
        final FailureResult<T> _ => null,
      };

  /// The failure, or `null` when this is an [Ok].
  Failure? get failureOrNull => switch (this) {
        final Ok<T> _ => null,
        final FailureResult<T> failure => failure.failure,
      };

  /// Whether this is a success.
  bool get isOk => this is Ok<T>;

  /// Whether this is a failure.
  bool get isFailure => this is FailureResult<T>;

  /// Transform the success value, keeping the failure.
  ///
  /// Synchronous on purpose. An `async` transform cannot return a [Result] of
  /// its own type, so a single method that accepted `FutureOr` would have to
  /// return `Future<Result<R>>` and infect every synchronous call site. Use
  /// [mapAsync] when the transform is genuinely async.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        final Ok<T> ok => Ok<R>(transform(ok.value)),
        final FailureResult<T> failure => FailureResult<R>(failure.failure),
      };

  /// Transform the success value with an async function, keeping the failure.
  ///
  /// The failure is propagated *without* awaiting, so a failure short-circuits.
  Future<Result<R>> mapAsync<R>(Future<R> Function(T value) transform) =>
      switch (this) {
        final Ok<T> ok => guard<R>(
            () => transform(ok.value),
            kind: FailureKind.unknown,
            message: 'mapAsync transform failed',
          ),
        final FailureResult<T> failure => Future<Result<R>>.value(
            FailureResult<R>(failure.failure),
          ),
      };

  /// Alias for [map], for call sites where the sync/async distinction should be
  /// obvious at a glance in a long chain.
  Result<R> mapSync<R>(R Function(T value) transform) => map(transform);

  /// Chain another fallible operation.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
        final Ok<T> ok => transform(ok.value),
        final FailureResult<T> failure => FailureResult<R>(failure.failure),
      };

  /// Run [action] only on success. Handy for logging.
  ///
  /// Uses a type test rather than a null test so that `Ok(null)` — a genuinely
  /// successful "no fix yet" — still runs the action.
  Result<T> onOk(void Function(T value) action) {
    if (this case final Ok<T> ok) {
      action(ok.value);
    }
    // Returning `this` is deliberate: `result.onOk(log).map(parse)` reads as one
    // pipeline. The lint's suggestion (void) would force a temp variable at every
    // call site for no gain.
    // ignore: avoid_returning_this
    return this;
  }

  /// Run [action] only on failure. Handy for logging at a layer boundary.
  Result<T> onFailure(void Function(Failure failure) action) {
    final Failure? f = failureOrNull;
    if (f != null) {
      action(f);
    }
    // ignore: avoid_returning_this — see [onOk].
    return this;
  }
}

/// The success arm.
final class Ok<T> extends Result<T> {
  /// Wraps a successful [value].
  const Ok(this.value);

  /// The success value.
  final T value;

  @override
  String toString() => 'Ok($value)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash('Ok', value);
}

/// The failure arm.
final class FailureResult<T> extends Result<T> {
  /// Wraps a [Failure].
  const FailureResult(this.failure);

  /// The failure. Always present.
  final Failure failure;

  @override
  String toString() => 'FailureResult($failure)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FailureResult<T> && other.failure == failure;

  @override
  int get hashCode => Object.hash('FailureResult', failure);
}

/// Constructors that read well at a call site.
///
/// [ok] and [fail] are top-level functions rather than factory constructors so
/// the type argument is inferred from the assignment target:
/// `return ok(snapshot);` / `return fail<AccidentEvent>(f);`
Result<T> ok<T>(T value) => Ok<T>(value);

/// A [FailureResult] for any `T`; the type is usually fixed by the return type.
Result<T> fail<T>(Failure failure) => FailureResult<T>(failure);

/// Build a [Failure] without a `const` where the message is interpolated.
Failure failureOf(
  FailureKind kind,
  String message, {
  String? detail,
  Object? cause,
  bool? retryable,
}) =>
    Failure(
      kind: kind,
      message: message,
      detail: detail,
      cause: cause,
      retryable: retryable ?? Failure.defaultRetryable(kind),
    );

/// Await [body] and convert any thrown object into a [FailureResult].
///
/// This is the *only* place exceptions are allowed to be caught, and it lives in
/// core so that every datasource funnels through the same classification.
Future<Result<T>> guard<T>(
  Future<T> Function() body, {
  required FailureKind kind,
  required String message,
  bool Function(Object error)? isRetryable,
  AppLogger? log,
  String? logTag,
}) async {
  try {
    return Ok<T>(await body());
  } on Object catch (error, stackTrace) {
    final Failure failure = Failure(
      kind: kind,
      message: message,
      cause: error,
      retryable: isRetryable?.call(error) ?? Failure.defaultRetryable(kind),
    );
    log?.log(
      LogLevel.warning,
      logTag ?? 'Result',
      'guard: $failure',
      error,
      stackTrace,
    );
    return FailureResult<T>(failure);
  }
}

/// Synchronous sibling of [guard].
Result<T> guardSync<T>(
  T Function() body, {
  required FailureKind kind,
  required String message,
  AppLogger? log,
  String? logTag,
}) {
  try {
    return Ok<T>(body());
  } on Object catch (error, stackTrace) {
    final Failure failure = Failure(
      kind: kind,
      message: message,
      cause: error,
    );
    log?.log(
      LogLevel.warning,
      logTag ?? 'Result',
      'guardSync: $failure',
      error,
      stackTrace,
    );
    return FailureResult<T>(failure);
  }
}

/// Convenience: run [body], and if it throws, turn it into a failure tagged with
/// the layer name. Used by repositories around Firestore/sqflite calls.
///
/// Deliberately *not* used to hide programming errors: pass
/// [FailureKind.unknown] for those so they still surface as failures rather than
/// vanishing into a `catch` that swallows everything.
Future<Result<T>> layer<T>(
  String layerName,
  Future<T> Function() body, {
  required FailureKind kind,
  required String message,
  AppLogger? log,
}) =>
    guard<T>(
      body,
      kind: kind,
      message: message,
      log: log,
      logTag: layerName,
    );
