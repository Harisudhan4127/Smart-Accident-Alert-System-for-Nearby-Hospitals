/// Motion: durations and curves as named constants, and a reduced-motion
/// escape hatch.
///
/// **Why this file exists rather than a bare `Duration(milliseconds: 300)`
/// inline:** an app that pulses a
/// red alert ring has an accessibility obligation, and the obligation is easier
/// to keep if *all* motion goes through one resolver. [MotionResolver] reads
/// `MediaQuery.disableAnimationsOf` (set by the OS "Remove animations"
/// accessibility switch and by Flutter's own test binding) and collapses every
/// duration to [MotionResolver.instant] while keeping opacity changes, which are
/// not motion and are how a user who cannot tolerate animation still perceives a
/// state change.
///
/// Usage:
///
/// ```dart
/// final motion = MotionResolver.of(context);
/// AnimatedOpacity(
///   duration: motion.duration(MotionDuration.medium), // 0 if reduced
///   opacity: active ? 1 : 0,
/// )
/// ```
library;

import 'package:flutter/widgets.dart';

/// Named durations.
///
/// The scale follows Material 3's motion scheme, with two additions this app
/// needs: [fast] for telemetry (must track a 10 Hz value without feeling laggy)
/// and [slow] for the emergency alert, where a slow build-up reads as
/// deliberate rather than glitchy.
enum MotionDuration {
  /// 80 ms — telemetry digits, hover, ripple.
  fast,

  /// 150 ms — small state changes, chips, icon swaps.
  quick,

  /// 250 ms — the default: card expand, sheet reveal, page transition.
  medium,

  /// 400 ms — large surfaces, full-screen dialogs.
  slow,

  /// 800 ms — the SOS ring's single pulse. Deliberately long: one slow pulse
  /// reads as an alarm, three fast ones read as a rendering bug.
  pulse,
}

/// Named curves.
abstract final class MotionCurves {
  /// Material 3 "standard" — the default for on-screen movement.
  static const Curve standard = Curves.easeInOutCubicEmphasized;

  /// Decelerate — anything entering the screen (it arrives and settles).
  static const Curve decelerate = Curves.easeOutCubic;

  /// Accelerate — anything leaving (it leaves, it does not linger).
  static const Curve accelerate = Curves.easeInCubic;

  /// Springy, low overshoot — the SOS button press.
  static const Curve spring = Curves.easeOutBack;

  /// Linear — progress rings and the countdown bar. A progress indicator that
  /// eases is lying about its rate.
  static const Curve linear = Curves.linear;
}

/// Resolves named durations, honouring the platform "reduce motion" setting.
class MotionResolver {
  /// Captures the ambient reduced-motion preference.
  ///
  /// Read it once at the top of a build and pass it down, so a subtree
  /// cannot disagree with itself mid-animation.
  const MotionResolver({required this.reduceMotion});

  /// Read the current setting from a [BuildContext].
  ///
  /// Safe to call in `build`; the result is a value, not a subscription, so a
  /// change rebuilds the widgets that read it, which is exactly the set that
  /// animates.
  factory MotionResolver.of(BuildContext context) => MotionResolver(
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      );

  /// True when all motion is suppressed.
  final bool reduceMotion;

  /// What every duration collapses to when motion is reduced.
  static const Duration instant = Duration.zero;

  /// Still used for opacity, so a state change remains *visible*.
  static const Duration fade = Duration(milliseconds: 100);

  /// The duration for [name], or [instant] when motion is reduced.
  ///
  /// A `switch` rather than a map lookup: it is exhaustive by construction, so
  /// there is no null to defend against, and adding a [MotionDuration] is a
  /// compile error here instead of a `!` that fires at runtime.
  Duration duration(MotionDuration name) {
    if (reduceMotion) {
      return instant;
    }
    return switch (name) {
      MotionDuration.fast => const Duration(milliseconds: 80),
      MotionDuration.quick => const Duration(milliseconds: 150),
      MotionDuration.medium => const Duration(milliseconds: 250),
      MotionDuration.slow => const Duration(milliseconds: 400),
      MotionDuration.pulse => const Duration(milliseconds: 800),
    };
  }

  /// The curve for [name]. Curves are meaningless at zero duration but are also
  /// harmless, so we do not special-case them.
  Curve curve(MotionDuration name) => switch (name) {
        MotionDuration.fast => MotionCurves.standard,
        MotionDuration.quick => MotionCurves.standard,
        MotionDuration.medium => MotionCurves.standard,
        MotionDuration.slow => MotionCurves.decelerate,
        MotionDuration.pulse => MotionCurves.linear,
      };

  /// A duration that is scaled down but not eliminated — for cases where a
  /// totally instant state change reads as a glitch rather than as
  /// accessibility. Not used by default; [MotionDuration.fast] collapses to
  /// [instant] under reduced motion, which is correct.
  Duration scaled(double factor) => reduceMotion
      ? instant
      : Duration(microseconds: (200000 * factor).round());

  /// Build an [AnimationController]-free tween for opacity, which is the one
  /// animation that must survive reduced motion.
  Duration get opacityDuration =>
      reduceMotion ? fade : duration(MotionDuration.quick);

  /// A copy with motion explicitly enabled/disabled. Tests use this to force
  /// both paths deterministically instead of faking
  /// [MediaQuery.disableAnimations].
  MotionResolver copyWith({bool? reduceMotion}) =>
      MotionResolver(reduceMotion: reduceMotion ?? this.reduceMotion);
}
