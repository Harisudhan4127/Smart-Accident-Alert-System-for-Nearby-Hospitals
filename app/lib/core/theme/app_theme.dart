/// The app's design system.
///
/// **Dark-first, and that is a functional decision, not a preference.** This is a
/// night-driving safety app. The screen is mounted in a car at 2am behind a
/// steering wheel; a bright surface is a windshield glare source and destroys
/// the driver's dark adaptation, which takes 20+ minutes to recover. The dark
/// theme is therefore the *default* and the light theme is the accessible
/// alternative, not the other way round.
///
/// The palette is built with [ColorScheme.fromSeed] for correct Material 3 tonal
/// palettes (and correct `onX` contrasts, which are contrast-checked by the
/// framework), then hand-tuned:
///
/// * deep navy/slate surfaces (`#0A0F1A` → `#161E2E`) rather than pure black,
///   so OLED pixels are not fully off and elevation still reads as elevation;
/// * an electric cyan-blue primary for *interactive* affordances only;
/// * `#FF3B47` emergency red used for **critical states only** — a red button
///   that is not an emergency trains the driver to ignore red;
/// * amber for warnings, emerald for safe/ok. Traffic-light semantics, because
///   they are the semantics drivers already have.
/// ```
library;

import 'package:flutter/material.dart';

import 'motion.dart';
import 'spacing.dart';
import 'typography.dart';

/// Brand + semantic colours that are not part of Material's role system.
///
/// These are the *raw* values. The role-based tokens the widgets should use live
/// in [TelemetryPalette], [StatusPalette], [GlassSurfaces] and
/// [ElevationScale] as [ThemeExtension]s, so a widget reads
/// `Theme.of(context).extension<TelemetryPalette>()!.accel` rather than a hex
/// literal.
abstract final class AppColors {
  // --- surfaces ---------------------------------------------------------------
  /// Page background, dark.
  static const Color surfaceDark = Color(0xFF0A0F1A);

  /// Raised surface, dark.
  static const Color surfaceDarkRaised = Color(0xFF121A28);

  /// Card surface, dark.
  static const Color surfaceDarkCard = Color(0xFF161E2E);

  /// Hairline that stays visible on OLED.
  static const Color borderDark = Color(0x1FFFFFFF);

  /// Page background, light.
  static const Color surfaceLight = Color(0xFFF6F8FC);

  /// Pure white card fill. Only correct on the light scheme: on a dark
  /// surface, elevation has to come from a lighter fill, not from white.
  static const Color surfaceLightCard = Color(0xFFFFFFFF);

  /// Hairline border for the light scheme.
  static const Color borderLight = Color(0x1F0A0F1A);

  // --- semantic ---------------------------------------------------------------
  /// The signature emergency red. Critical states only.
  static const Color emergency = Color(0xFFFF3B47);

  /// Deeper red for text on a light emergency surface, where `#FF3B47` does not
  /// reach 4.5:1 against white.
  static const Color emergencyInk = Color(0xFFC1121F);

  /// Warning.
  static const Color amber = Color(0xFFFFB020);

  /// Warning ink for light surfaces.
  static const Color amberInk = Color(0xFF8A5A00);

  /// Safe / ok.
  static const Color emerald = Color(0xFF22C55E);

  /// Safe ink for light surfaces.
  static const Color emeraldInk = Color(0xFF0F7A3D);

  /// Interactive primary — electric cyan-blue.
  static const Color electric = Color(0xFF2DD4FF);

  /// Primary ink on dark.
  static const Color electricInk = Color(0xFF0A0F1A);

  /// Primary for light surfaces, darkened until it passes contrast on white.
  static const Color electricLight = Color(0xFF0077B6);

  /// Informational / neutral accent (used for the "monitoring" state).
  static const Color slate = Color(0xFF8CA0B8);

  // --- telemetry series -------------------------------------------------------
  /// Accelerometer series. Cyan reads as "the primary signal".
  static const Color accel = Color(0xFF2DD4FF);

  /// SW-420 vibration channel. Violet separates it from cyan for colour-blind
  /// readers (cyan/violet remain distinguishable in all three common CVD types).
  ///
  /// This slot used to be the gyroscope series, and the ADXL345 has no
  /// gyroscope. Violet was kept rather than freed: the SW-420 is the node's one
  /// other independent evidence channel, and it is what a second trace on this
  /// chart should show.
  static const Color vibration = Color(0xFFA78BFA);

  /// Magnitude envelope.
  static const Color magnitude = Color(0xFF38BDF8);

  /// Session peak marker.
  static const Color peak = Color(0xFFFFB020);

  /// The detection threshold line.
  static const Color threshold = Color(0xFFFF3B47);
}

/// Telemetry sparkline colours.
///
/// A [ThemeExtension] rather than constants because a sparkline on a dark card
/// and a sparkline on a light card need *different* alphas and grid colours, and
/// a hard-coded constant cannot adapt to [ThemeData.colorScheme.brightness].
///
/// Read with:
///
/// ```dart
/// final telemetry = Theme.of(context).extension<TelemetryPalette>()!;
/// ```
@immutable
class TelemetryPalette extends ThemeExtension<TelemetryPalette> {
  /// Colours for live telemetry readouts and threshold bands.
  const TelemetryPalette({
    required this.accel,
    required this.accelFill,
    required this.vibration,
    required this.vibrationFill,
    required this.magnitude,
    required this.peak,
    required this.threshold,
    required this.grid,
    required this.axisLabel,
    required this.idleBand,
    required this.safeBand,
    required this.criticalBand,
    required this.staleTrace,
  });

  /// Dark palette.
  factory TelemetryPalette.dark() => const TelemetryPalette(
        accel: AppColors.accel,
        accelFill: Color(0x332DD4FF),
        vibration: AppColors.vibration,
        vibrationFill: Color(0x33A78BFA),
        magnitude: AppColors.magnitude,
        peak: AppColors.peak,
        threshold: AppColors.threshold,
        grid: Color(0x14FFFFFF),
        axisLabel: Color(0x99FFFFFF),
        idleBand: Color(0x0D22C55E),
        safeBand: Color(0x0DFFB020),
        criticalBand: Color(0x1AFF3B47),
        // A gap in the trace (packet loss) must be visible as a gap, not bridged
        // by a straight line that implies data we did not receive.
        staleTrace: Color(0x40FFFFFF),
      );

  /// Light palette.
  factory TelemetryPalette.light() => const TelemetryPalette(
        accel: Color(0xFF0077B6),
        accelFill: Color(0x1F0077B6),
        vibration: Color(0xFF6D3BE0),
        vibrationFill: Color(0x1F6D3BE0),
        magnitude: Color(0xFF0369A1),
        peak: Color(0xFF8A5A00),
        threshold: Color(0xFFC1121F),
        grid: Color(0x14000B18),
        axisLabel: Color(0x8A000B18),
        idleBand: Color(0x140F7A3D),
        safeBand: Color(0x148A5A00),
        criticalBand: Color(0x14C1121F),
        staleTrace: Color(0x40000B18),
      );

  /// Accelerometer trace.
  final Color accel;

  /// Gradient fill under the accelerometer trace.
  final Color accelFill;

  /// SW-420 vibration trace.
  final Color vibration;

  /// Gradient fill under the vibration trace.
  final Color vibrationFill;

  /// Magnitude envelope (the signal the detector actually fuses on).
  final Color magnitude;

  /// Session-peak marker line.
  final Color peak;

  /// Detector threshold line.
  final Color threshold;

  /// Sparkline grid lines.
  final Color grid;

  /// Axis tick labels.
  final Color axisLabel;

  /// The band around 1 g that counts as "no event".
  final Color idleBand;

  /// The band between "unusual" and "suspicious".
  final Color safeBand;

  /// The band at/over the threshold.
  final Color criticalBand;

  /// Colour of a broken line across a telemetry gap.
  final Color staleTrace;

  @override
  TelemetryPalette copyWith({
    Color? accel,
    Color? accelFill,
    Color? vibration,
    Color? vibrationFill,
    Color? magnitude,
    Color? peak,
    Color? threshold,
    Color? grid,
    Color? axisLabel,
    Color? idleBand,
    Color? safeBand,
    Color? criticalBand,
    Color? staleTrace,
  }) =>
      TelemetryPalette(
        accel: accel ?? this.accel,
        accelFill: accelFill ?? this.accelFill,
        vibration: vibration ?? this.vibration,
        vibrationFill: vibrationFill ?? this.vibrationFill,
        magnitude: magnitude ?? this.magnitude,
        peak: peak ?? this.peak,
        threshold: threshold ?? this.threshold,
        grid: grid ?? this.grid,
        axisLabel: axisLabel ?? this.axisLabel,
        idleBand: idleBand ?? this.idleBand,
        safeBand: safeBand ?? this.safeBand,
        criticalBand: criticalBand ?? this.criticalBand,
        staleTrace: staleTrace ?? this.staleTrace,
      );

  @override
  TelemetryPalette lerp(covariant TelemetryPalette? other, double t) {
    if (other == null) {
      return this;
    }
    return TelemetryPalette(
      accel: Color.lerp(accel, other.accel, t)!,
      accelFill: Color.lerp(accelFill, other.accelFill, t)!,
      vibration: Color.lerp(vibration, other.vibration, t)!,
      vibrationFill: Color.lerp(vibrationFill, other.vibrationFill, t)!,
      magnitude: Color.lerp(magnitude, other.magnitude, t)!,
      peak: Color.lerp(peak, other.peak, t)!,
      threshold: Color.lerp(threshold, other.threshold, t)!,
      grid: Color.lerp(grid, other.grid, t)!,
      axisLabel: Color.lerp(axisLabel, other.axisLabel, t)!,
      idleBand: Color.lerp(idleBand, other.idleBand, t)!,
      safeBand: Color.lerp(safeBand, other.safeBand, t)!,
      criticalBand: Color.lerp(criticalBand, other.criticalBand, t)!,
      staleTrace: Color.lerp(staleTrace, other.staleTrace, t)!,
    );
  }
}

/// Severity of a status token. The UI maps this to a colour *and* to an icon and
/// a label, so "critical" can never be communicated by colour alone — a
/// requirement for colour-blind users that is easy to forget.
enum StatusSeverity {
  /// No semantic judgement: a plain value, an ID, a timestamp.
  neutral,

  /// FYI: connected, synced, charging.
  info,

  /// Desired state: armed, linked, delivered.
  good,

  /// Degraded but usable: weak signal, stale GPS fix, queued uploads.
  warning,

  /// Needs a human now: accident detected, GPS denied, link lost.
  critical,
}

/// One status colour triple: fill, ink (text/icon on the fill) and outline.
@immutable
class StatusToken {
  /// The four colours one status (good/warn/bad/…) is drawn with.
  const StatusToken({
    required this.severity,
    required this.fill,
    required this.ink,
    required this.outline,
  });

  /// Which semantic slot this token fills.
  final StatusSeverity severity;

  /// Pill background.
  final Color fill;

  /// Text/icon colour on [fill].
  final Color ink;

  /// Pill border.
  final Color outline;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatusToken &&
          other.severity == severity &&
          other.fill == fill &&
          other.ink == ink &&
          other.outline == outline;

  @override
  int get hashCode => Object.hash(severity, fill, ink, outline);
}

/// Colours for every status pill in the app.
///
/// Keyed by the *domain* enums rather than by widget, so a status pill and a
/// status banner cannot drift apart: both read the same token.
@immutable
class StatusPalette extends ThemeExtension<StatusPalette> {
  /// The full set of semantic status tokens for one colour scheme.
  const StatusPalette({
    required this.ok,
    required this.info,
    required this.warning,
    required this.critical,
    required this.neutral,
    required this.pending,
    required this.synced,
    required this.queued,
    required this.failed,
    required this.offline,
    required this.scrim,
  });

  /// Status tokens tuned for the dark scheme.
  factory StatusPalette.dark() => const StatusPalette(
        ok: StatusToken(
          severity: StatusSeverity.good,
          fill: Color(0x1A22C55E),
          ink: AppColors.emerald,
          outline: Color(0x4D22C55E),
        ),
        info: StatusToken(
          severity: StatusSeverity.info,
          fill: Color(0x1A2DD4FF),
          ink: AppColors.electric,
          outline: Color(0x4D2DD4FF),
        ),
        warning: StatusToken(
          severity: StatusSeverity.warning,
          fill: Color(0x1AFFB020),
          ink: AppColors.amber,
          outline: Color(0x4DFFB020),
        ),
        critical: StatusToken(
          severity: StatusSeverity.critical,
          fill: Color(0x1AFF3B47),
          ink: AppColors.emergency,
          outline: Color(0x4DFF3B47),
        ),
        neutral: StatusToken(
          severity: StatusSeverity.neutral,
          fill: Color(0x14FFFFFF),
          ink: AppColors.slate,
          outline: Color(0x26FFFFFF),
        ),
        pending: StatusToken(
          severity: StatusSeverity.warning,
          fill: Color(0x26FFB020),
          ink: AppColors.amber,
          outline: Color(0x66FFB020),
        ),
        synced: StatusToken(
          severity: StatusSeverity.good,
          fill: Color(0x1A22C55E),
          ink: AppColors.emerald,
          outline: Color(0x4D22C55E),
        ),
        queued: StatusToken(
          severity: StatusSeverity.info,
          fill: Color(0x1A2DD4FF),
          ink: AppColors.electric,
          outline: Color(0x4D2DD4FF),
        ),
        failed: StatusToken(
          severity: StatusSeverity.critical,
          fill: Color(0x1AFF3B47),
          ink: AppColors.emergency,
          outline: Color(0x4DFF3B47),
        ),
        offline: StatusToken(
          severity: StatusSeverity.warning,
          fill: Color(0x1AFFB020),
          ink: AppColors.amber,
          outline: Color(0x4DFFB020),
        ),
        scrim: Color(0xB3000000),
      );

  /// Status tokens tuned for the light scheme.
  factory StatusPalette.light() => const StatusPalette(
        ok: StatusToken(
          severity: StatusSeverity.good,
          fill: Color(0x1A0F7A3D),
          ink: AppColors.emeraldInk,
          outline: Color(0x4D0F7A3D),
        ),
        info: StatusToken(
          severity: StatusSeverity.info,
          fill: Color(0x1A0077B6),
          ink: Color(0xFF00527D),
          outline: Color(0x4D0077B6),
        ),
        warning: StatusToken(
          severity: StatusSeverity.warning,
          fill: Color(0x1F8A5A00),
          ink: AppColors.amberInk,
          outline: Color(0x4D8A5A00),
        ),
        critical: StatusToken(
          severity: StatusSeverity.critical,
          fill: Color(0x1FC1121F),
          ink: AppColors.emergencyInk,
          outline: Color(0x4DC1121F),
        ),
        neutral: StatusToken(
          severity: StatusSeverity.neutral,
          fill: Color(0x14000B18),
          ink: Color(0xFF4A5568),
          outline: Color(0x26000B18),
        ),
        pending: StatusToken(
          severity: StatusSeverity.warning,
          fill: Color(0x248A5A00),
          ink: AppColors.amberInk,
          outline: Color(0x668A5A00),
        ),
        synced: StatusToken(
          severity: StatusSeverity.good,
          fill: Color(0x1A0F7A3D),
          ink: AppColors.emeraldInk,
          outline: Color(0x4D0F7A3D),
        ),
        queued: StatusToken(
          severity: StatusSeverity.info,
          fill: Color(0x1A0077B6),
          ink: Color(0xFF00527D),
          outline: Color(0x4D0077B6),
        ),
        failed: StatusToken(
          severity: StatusSeverity.critical,
          fill: Color(0x1FC1121F),
          ink: AppColors.emergencyInk,
          outline: Color(0x4DC1121F),
        ),
        offline: StatusToken(
          severity: StatusSeverity.warning,
          fill: Color(0x1F8A5A00),
          ink: AppColors.amberInk,
          outline: Color(0x4D8A5A00),
        ),
        scrim: Color(0x66000000),
      );

  /// Everything nominal: link connected, GPS fixed, online, record uploaded.
  final StatusToken ok;

  /// Informational: monitoring, connected but idle.
  final StatusToken info;

  /// Something is wrong but not urgent (low battery, poor signal).
  final StatusToken warning;

  /// Emergency. `#FF3B47`, and only for genuine emergencies.
  final StatusToken critical;

  /// Not applicable / unknown.
  final StatusToken neutral;

  /// An event is inside its cancel window.
  final StatusToken pending;

  /// A record is confirmed present in the cloud.
  final StatusToken synced;

  /// A record is durable locally and waiting for connectivity.
  final StatusToken queued;

  /// An operation exhausted its retries. The local record still exists.
  final StatusToken failed;

  /// No usable network.
  final StatusToken offline;

  /// Modal scrim.
  final Color scrim;

  /// Token for an arbitrary [severity] — lets a widget fall back to severity
  /// semantics when there is no more specific token.
  StatusToken forSeverity(StatusSeverity severity) => switch (severity) {
        StatusSeverity.good => ok,
        StatusSeverity.info => info,
        StatusSeverity.warning => warning,
        StatusSeverity.critical => critical,
        StatusSeverity.neutral => neutral,
      };

  @override
  StatusPalette copyWith({
    StatusToken? ok,
    StatusToken? info,
    StatusToken? warning,
    StatusToken? critical,
    StatusToken? neutral,
    StatusToken? pending,
    StatusToken? synced,
    StatusToken? queued,
    StatusToken? failed,
    StatusToken? offline,
    Color? scrim,
  }) =>
      StatusPalette(
        ok: ok ?? this.ok,
        info: info ?? this.info,
        warning: warning ?? this.warning,
        critical: critical ?? this.critical,
        neutral: neutral ?? this.neutral,
        pending: pending ?? this.pending,
        synced: synced ?? this.synced,
        queued: queued ?? this.queued,
        failed: failed ?? this.failed,
        offline: offline ?? this.offline,
        scrim: scrim ?? this.scrim,
      );

  @override
  StatusPalette lerp(covariant StatusPalette? other, double t) {
    if (other == null) {
      return this;
    }
    return StatusPalette(
      ok: _lerpToken(ok, other.ok, t),
      info: _lerpToken(info, other.info, t),
      warning: _lerpToken(warning, other.warning, t),
      critical: _lerpToken(critical, other.critical, t),
      neutral: _lerpToken(neutral, other.neutral, t),
      pending: _lerpToken(pending, other.pending, t),
      synced: _lerpToken(synced, other.synced, t),
      queued: _lerpToken(queued, other.queued, t),
      failed: _lerpToken(failed, other.failed, t),
      offline: _lerpToken(offline, other.offline, t),
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }

  static StatusToken _lerpToken(StatusToken a, StatusToken b, double t) =>
      StatusToken(
        severity: t < 0.5 ? a.severity : b.severity,
        fill: Color.lerp(a.fill, b.fill, t)!,
        ink: Color.lerp(a.ink, b.ink, t)!,
        outline: Color.lerp(a.outline, b.outline, t)!,
      );
}

/// Glass card surface tokens.
///
/// "Glass" here means a translucent surface plus a 1 dp top highlight, not a
/// blur: `BackdropFilter` costs real frame time on the low-end Android hardware
/// this app will actually run on, and the visual gain is small on an opaque
/// background. [blurSigma] is provided for the two places that genuinely need
/// it (the emergency dialog and the map overlay) so the cost is paid once, in
/// one place, instead of on every card.
@immutable
class GlassSurfaces extends ThemeExtension<GlassSurfaces> {
  /// Surface fills, borders and overlays for one colour scheme.
  const GlassSurfaces({
    required this.card,
    required this.cardElevated,
    required this.cardCritical,
    required this.sunken,
    required this.border,
    required this.borderStrong,
    required this.highlight,
    required this.overlay,
    required this.blurSigma,
    required this.pressOverlay,
  });

  /// Surfaces for the dark scheme.
  factory GlassSurfaces.dark() => const GlassSurfaces(
        card: Color(0xCC161E2E),
        cardElevated: Color(0xE6161E2E),
        cardCritical: Color(0xF21A1622),
        sunken: Color(0x990A0F1A),
        border: Color(0x1FFFFFFF),
        borderStrong: Color(0x33FFFFFF),
        // A 1 dp white top border is what makes a dark card read as a physical
        // surface catching light from above. Without it, dark cards on a dark
        // background look like holes.
        highlight: Color(0x1AFFFFFF),
        overlay: Color(0xB3161E2E),
        blurSigma: 18,
        pressOverlay: Color(0x14FFFFFF),
      );

  /// Surfaces for the light scheme.
  factory GlassSurfaces.light() => const GlassSurfaces(
        card: Color(0xF2FFFFFF),
        cardElevated: Color(0xFAFFFFFF),
        cardCritical: Color(0xFFFFF5F5),
        sunken: Color(0x66000000),
        border: Color(0x1F0A0F1A),
        borderStrong: Color(0x330A0F1A),
        highlight: Color(0xFFFFFFFF),
        overlay: Color(0xCCFFFFFF),
        blurSigma: 12,
        pressOverlay: Color(0x0F0A0F1A),
      );

  /// Default card surface.
  final Color card;

  /// Card surface for content that sits on top of another card.
  final Color cardElevated;

  /// Card surface for an active emergency. Very slightly warm-shifted so the
  /// alert screen is distinguishable even before the text is read.
  final Color cardCritical;

  /// Recessed surface (chart backgrounds, code blocks).
  final Color sunken;

  /// Hairline border.
  final Color border;

  /// Border for a card that needs to read as separate (e.g. the active step).
  final Color borderStrong;

  /// Top inner highlight.
  final Color highlight;

  /// Sheet / menu surface.
  final Color overlay;

  /// Sigma for the (rare) `BackdropFilter`.
  final double blurSigma;

  /// Press/ripple overlay for a glass surface.
  final Color pressOverlay;

  @override
  GlassSurfaces copyWith({
    Color? card,
    Color? cardElevated,
    Color? cardCritical,
    Color? sunken,
    Color? border,
    Color? borderStrong,
    Color? highlight,
    Color? overlay,
    double? blurSigma,
    Color? pressOverlay,
  }) =>
      GlassSurfaces(
        card: card ?? this.card,
        cardElevated: cardElevated ?? this.cardElevated,
        cardCritical: cardCritical ?? this.cardCritical,
        sunken: sunken ?? this.sunken,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        highlight: highlight ?? this.highlight,
        overlay: overlay ?? this.overlay,
        blurSigma: blurSigma ?? this.blurSigma,
        pressOverlay: pressOverlay ?? this.pressOverlay,
      );

  @override
  GlassSurfaces lerp(covariant GlassSurfaces? other, double t) {
    if (other == null) {
      return this;
    }
    return GlassSurfaces(
      card: Color.lerp(card, other.card, t)!,
      cardElevated: Color.lerp(cardElevated, other.cardElevated, t)!,
      cardCritical: Color.lerp(cardCritical, other.cardCritical, t)!,
      sunken: Color.lerp(sunken, other.sunken, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
      // Plain linear interpolation: `t` is already 0..1, and dart:ui's
      // `lerpDouble` is not re-exported by package:flutter/foundation.
      blurSigma: blurSigma + (other.blurSigma - blurSigma) * t,
      pressOverlay: Color.lerp(pressOverlay, other.pressOverlay, t)!,
    );
  }
}

/// The app's shadow scale.
///
/// Material's `elevation` double maps to a preset shadow, which cannot express
/// "critical" — a red glow that is visible through a windscreen at night is a
/// different thing from a drop shadow. So shadows are named tokens here and
/// widgets use `BoxShadow` lists from this extension.
@immutable
class ElevationScale extends ThemeExtension<ElevationScale> {
  /// The three shadow levels, as real `BoxShadow` lists.
  const ElevationScale({
    required this.none,
    required this.low,
    required this.medium,
    required this.high,
    required this.critical,
    required this.sos,
  });

  /// Shadows for the dark scheme, where depth reads as a lighter rim.
  factory ElevationScale.dark() => const ElevationScale(
        none: <BoxShadow>[],
        low: <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
        medium: <BoxShadow>[
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
        high: <BoxShadow>[
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 40,
            offset: Offset(0, 18),
          ),
        ],
        // A red glow rather than a black shadow: reads as "this is the thing that
        // matters" even at a glance through a windscreen.
        critical: <BoxShadow>[
          BoxShadow(
            color: Color(0x4DFF3B47),
            blurRadius: 32,
            offset: Offset(0, 0),
            spreadRadius: -4,
          ),
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
        // The SOS button gets a permanent red bloom so it is findable without
        // reading the screen.
        sos: <BoxShadow>[
          BoxShadow(
            color: Color(0x66FF3B47),
            blurRadius: 36,
            offset: Offset(0, 8),
            spreadRadius: 2,
          ),
        ],
      );

  /// Shadows for the light scheme.
  factory ElevationScale.light() => const ElevationScale(
        none: <BoxShadow>[],
        low: <BoxShadow>[
          BoxShadow(
            color: Color(0x14000B18),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
        medium: <BoxShadow>[
          BoxShadow(
            color: Color(0x1F000B18),
            blurRadius: 22,
            offset: Offset(0, 8),
          ),
        ],
        high: <BoxShadow>[
          BoxShadow(
            color: Color(0x2E000B18),
            blurRadius: 38,
            offset: Offset(0, 16),
          ),
        ],
        critical: <BoxShadow>[
          BoxShadow(
            color: Color(0x33C1121F),
            blurRadius: 30,
            offset: Offset(0, 0),
            spreadRadius: -6,
          ),
          BoxShadow(
            color: Color(0x1F000B18),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
        sos: <BoxShadow>[
          BoxShadow(
            color: Color(0x4DC1121F),
            blurRadius: 32,
            offset: Offset(0, 6),
            spreadRadius: 2,
          ),
        ],
      );

  /// Flat: dividers and inline elements.
  final List<BoxShadow> none;

  /// Resting cards.
  final List<BoxShadow> low;

  /// Raised surfaces: sheets, menus.
  final List<BoxShadow> medium;

  /// Overlays: the alert sheet, dialogs.
  final List<BoxShadow> high;

  /// Critical-state shadow (red glow).
  final List<BoxShadow> critical;

  /// The SOS button's permanent bloom.
  final List<BoxShadow> sos;

  /// Interpolate two shadow lists. [BoxShadow.lerpList] is null-safe here because
  /// every token in a brightness has the same length as its counterpart.
  static List<BoxShadow> _lerpShadows(
    List<BoxShadow> a,
    List<BoxShadow> b,
    double t,
  ) {
    if (a.isEmpty || b.isEmpty) {
      return t < 0.5 ? a : b;
    }
    return List<BoxShadow>.generate(
      a.length,
      (int i) => BoxShadow.lerp(a[i], b[i], t) ?? a[i],
      growable: false,
    );
  }

  @override
  ElevationScale copyWith({
    List<BoxShadow>? none,
    List<BoxShadow>? low,
    List<BoxShadow>? medium,
    List<BoxShadow>? high,
    List<BoxShadow>? critical,
    List<BoxShadow>? sos,
  }) =>
      ElevationScale(
        none: none ?? this.none,
        low: low ?? this.low,
        medium: medium ?? this.medium,
        high: high ?? this.high,
        critical: critical ?? this.critical,
        sos: sos ?? this.sos,
      );

  @override
  ElevationScale lerp(covariant ElevationScale? other, double t) {
    if (other == null) {
      return this;
    }
    return ElevationScale(
      none: _lerpShadows(none, other.none, t),
      low: _lerpShadows(low, other.low, t),
      medium: _lerpShadows(medium, other.medium, t),
      high: _lerpShadows(high, other.high, t),
      critical: _lerpShadows(critical, other.critical, t),
      sos: _lerpShadows(sos, other.sos, t),
    );
  }
}

/// Builds the app's themes.
abstract final class AppTheme {
  /// Seed for [ColorScheme.fromSeed]. A deep desaturated blue: the generated
  /// tonal palette keeps surfaces cool and slightly blue, which is what makes a
  /// dark UI read as "instrument panel" rather than "grey".
  static const Color seed = Color(0xFF2DD4FF);

  /// The dark theme. This is the default (see the file header).
  static ThemeData dark() {
    final ColorScheme scheme = _darkScheme();
    return _base(
      scheme: scheme,
      brightness: Brightness.dark,
      surfaces: GlassSurfaces.dark(),
      status: StatusPalette.dark(),
      telemetry: TelemetryPalette.dark(),
      elevation: ElevationScale.dark(),
    );
  }

  /// The light theme.
  static ThemeData light() {
    final ColorScheme scheme = _lightScheme();
    return _base(
      scheme: scheme,
      brightness: Brightness.light,
      surfaces: GlassSurfaces.light(),
      status: StatusPalette.light(),
      telemetry: TelemetryPalette.light(),
      elevation: ElevationScale.light(),
    );
  }

  /// `ColorScheme.fromSeed` gives contrast-checked role pairs; we then override
  /// only the roles where the product's semantics demand a specific colour.
  static ColorScheme _darkScheme() {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    ).copyWith(
      // Override the generated neutrals with the hand-tuned navy ramp: the
      // generated ones are a touch too blue/bright for an OLED instrument panel.
      surface: AppColors.surfaceDark,
      surfaceContainerLowest: const Color(0xFF060A12),
      surfaceContainerLow: const Color(0xFF0D1420),
      surfaceContainer: AppColors.surfaceDarkRaised,
      surfaceContainerHigh: AppColors.surfaceDarkCard,
      surfaceContainerHighest: const Color(0xFF1C2536),
      onSurface: const Color(0xFFF2F6FF),
      onSurfaceVariant: AppColors.slate,
      outline: const Color(0x4DFFFFFF),
      outlineVariant: AppColors.borderDark,
      // Interactive affordances are electric blue. Note that `primary` is *not*
      // the emergency red: a red primary would make "Save" red.
      primary: AppColors.electric,
      onPrimary: AppColors.electricInk,
      primaryContainer: const Color(0xFF00344A),
      onPrimaryContainer: const Color(0xFFBDE9FF),
      // `error` is the Material role for "something is wrong with input" and for
      // critical emphasis. It is the same red as the emergency token so the two
      // never disagree about what "critical" looks like.
      error: AppColors.emergency,
      onError: Colors.white,
      errorContainer: const Color(0xFF45060B),
      onErrorContainer: const Color(0xFFFFD9DC),
      secondary: AppColors.slate,
      onSecondary: const Color(0xFF0A0F1A),
      tertiary: AppColors.emerald,
      onTertiary: const Color(0xFF052E16),
    );
  }

  static ColorScheme _lightScheme() {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    ).copyWith(
      surface: AppColors.surfaceLight,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFBFCFE),
      surfaceContainer: Colors.white,
      surfaceContainerHigh: const Color(0xFFF2F5FA),
      surfaceContainerHighest: const Color(0xFFE9EEF6),
      onSurface: const Color(0xFF0A0F1A),
      onSurfaceVariant: const Color(0xFF4A5568),
      outline: const Color(0x66000B18),
      outlineVariant: AppColors.borderLight,
      primary: AppColors.electricLight,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFD6F1FF),
      onPrimaryContainer: const Color(0xFF00344A),
      error: AppColors.emergencyInk,
      onError: Colors.white,
      errorContainer: const Color(0xFFFFE1E3),
      onErrorContainer: const Color(0xFF45060B),
      secondary: const Color(0xFF4A5568),
      onSecondary: Colors.white,
      tertiary: AppColors.emeraldInk,
      onTertiary: Colors.white,
    );
  }

  static ThemeData _base({
    required ColorScheme scheme,
    required Brightness brightness,
    required GlassSurfaces surfaces,
    required StatusPalette status,
    required TelemetryPalette telemetry,
    required ElevationScale elevation,
  }) {
    final TextTheme textTheme = AppTypography.textTheme(
      scheme.onSurface,
      scheme.onSurfaceVariant,
    );

    // `TextTheme` members are `TextStyle?` because the type is a bag of optional
    // slots, but `ButtonStyle.textStyle` and `NavigationBarThemeData
    // .labelTextStyle` are non-nullable. `AppTypography` populates every slot,
    // so these fallbacks are unreachable in practice; they exist so that a
    // future typography change cannot turn a missing slot into a compile error.
    final TextStyle labelLarge = textTheme.labelLarge ?? const TextStyle();
    final TextStyle labelMedium = textTheme.labelMedium ?? const TextStyle();

    final bool isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      // Primary text uses tabular figures by construction (AppTypography), and
      // the display colour is forced to the scheme's onSurface so a widget that
      // uses `Theme.of(context).textTheme` does not silently lose tabular
      // alignment through `.apply()`.
      primaryTextTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,

      // --- extensions --------------------------------------------------------
      extensions: <ThemeExtension<dynamic>>[
        surfaces,
        status,
        telemetry,
        elevation,
      ],

      // --- app bar: transparent, because the page background is the surface ---
      appBarTheme: AppBarThemeData(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 56,
        titleTextStyle: textTheme.titleLarge,
      ),

      // --- cards: glass, no Material elevation (we use our own shadows) -------
      cardTheme: CardThemeData(
        color: surfaces.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardRadius),
      ),

      // --- buttons ------------------------------------------------------------
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(0, Spacing.minTouchTarget),
          ),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: Spacing.large),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(labelLarge),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: Radii.pillRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(
            Size(0, Spacing.minTouchTarget),
          ),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: surfaces.borderStrong),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(labelLarge),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: Radii.pillRadius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll<TextStyle>(labelLarge),
        ),
      ),
      // Destructive actions get the emergency red, and only destructive actions.
      // The SOS button is the one place we want a *filled* red.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: const RoundedRectangleBorder(
          borderRadius: Radii.pillRadius,
        ),
      ),

      // --- inputs -------------------------------------------------------------
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: isDark ? surfaces.sunken : scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.medium,
          vertical: Spacing.medium,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: surfaces.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: surfaces.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        helperStyle: textTheme.bodySmall,
      ),

      // --- chips / status pills ------------------------------------------------
      chipTheme: ChipThemeData(
        backgroundColor: surfaces.card,
        side: BorderSide(color: surfaces.border),
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xs,
        ),
        shape: const RoundedRectangleBorder(borderRadius: Radii.pillRadius),
      ),

      // --- lists -----------------------------------------------------------------
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.medium,
          vertical: Spacing.xs,
        ),
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardRadius),
      ),

      // --- dialogs & sheets -------------------------------------------------------
      dialogTheme: DialogThemeData(
        backgroundColor: surfaces.cardElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaces.overlay,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: status.scrim,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetRadius),
        showDragHandle: true,
        dragHandleColor: surfaces.borderStrong,
      ),

      // --- progress: linear, because a spinner cannot express "60% synced" ------
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: surfaces.sunken,
        circularTrackColor: surfaces.sunken,
        linearMinHeight: 6,
      ),

      dividerTheme: DividerThemeData(
        color: surfaces.border,
        thickness: Borders.hairline,
        space: Borders.hairline,
      ),

      // --- snackbars: the app's way of saying "queued, will retry" ---------------
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaces.cardElevated,
        contentTextStyle: textTheme.bodyMedium,
        actionTextColor: scheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
        ),
      ),

      // --- navigation ------------------------------------------------------------
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaces.card,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(labelMedium),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surfaces.card,
        indicatorColor: scheme.primaryContainer,
        labelType: NavigationRailLabelType.all,
      ),

      // --- page transitions: one shared curve, no iOS-style horizontal slide for
      //     a safety-critical flow. The emergency dialog slides up from the
      //     bottom, which reads as "something came in from outside the app".
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _AppPageTransitionsBuilder(),
          TargetPlatform.iOS: _AppPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// Convenience: the dark theme's motion defaults. Exposed so the UI agent does
  /// not have to build a [MotionResolver] just to check the reduced-motion path.
  static const MotionResolver motionEnabled =
      MotionResolver(reduceMotion: false);
}

/// A single shared page transition: fade + a small rise.
///
/// Horizontal slide is Material's default on Android and iOS's default is a
/// parallax slide. Both are wrong for this app: the alert flow is not a
/// hierarchy, it is a sequence of *decisions*, and a slide reads as "you went
/// somewhere" when the user actually just answered a prompt.
class _AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const _AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<Offset> slide = Tween<Offset>(
      begin: const Offset(0, 0.02),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: animation, curve: MotionCurves.decelerate),
    );
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(position: slide, child: child),
    );
  }
}

/// Typed accessors so a widget never has to write the `!` on an extension lookup.
///
/// ```dart
/// final status = context.statusPalette;   // StatusPalette
/// final glass  = context.glass;          // GlassSurfaces
/// ```
extension ThemeContext on BuildContext {
  ThemeData get _theme => Theme.of(this);

  /// [TelemetryPalette] for the current theme.
  TelemetryPalette get telemetryPalette =>
      _theme.extension<TelemetryPalette>() ?? TelemetryPalette.dark();

  /// [StatusPalette] for the current theme.
  StatusPalette get statusPalette =>
      _theme.extension<StatusPalette>() ?? StatusPalette.dark();

  /// [GlassSurfaces] for the current theme.
  GlassSurfaces get glass =>
      _theme.extension<GlassSurfaces>() ?? GlassSurfaces.dark();

  /// [ElevationScale] for the current theme.
  ElevationScale get elevations =>
      _theme.extension<ElevationScale>() ?? ElevationScale.dark();

  /// The current [MotionResolver], including the platform reduced-motion flag.
  MotionResolver get motion => MotionResolver.of(this);
}
