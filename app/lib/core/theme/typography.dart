/// Typography with a hard requirement: **tabular figures for every number**.
///
/// Why this is not cosmetic: telemetry values change 10 times a second. With
/// proportional figures, `1.2` is narrower than `9.87`, so a live readout
/// *jitters horizontally* — digits shuffle sideways at a rate the eye tracks as
/// noise, and it is genuinely harder to read a value that is moving. With
/// [FontFeature.tabularFigures] every digit occupies the same advance width, so
/// a changing number stays rock-still and only the glyphs change.
///
/// [FontFeature] reaches us through the `material.dart` export chain (it lives
/// in `dart:ui`, which is not meant to be imported directly).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Font families. One sans (UI + numbers) and one mono (telemetry/logs).
///
/// Inter is the UI face: it has a true tabular-figure cut, which is the whole
/// reason we do not fall back to the platform font, and it is delivered by
/// `google_fonts` so the app does not depend on the device having a decent
/// default. JetBrains Mono is used only where character alignment is load-
/// bearing (raw frames in the diagnostics screen).
abstract final class AppFonts {
  /// The feature set applied to every numeric style.
  ///
  /// `tnum` is the OpenType name for tabular figures. `ss01`… are deliberately
  /// NOT enabled: stylistic sets in Inter change glyph widths, which is exactly
  /// what we are trying to avoid.
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// Tabular figures + slashed zero, for values where 0/O ambiguity matters
  /// (device ids, hex chip ids in the diagnostics view).
  static const List<FontFeature> technical = <FontFeature>[
    FontFeature.tabularFigures(),
    FontFeature.slashedZero(),
  ];

  /// Resolve the UI face. `google_fonts` handles asset bundling and falls back
  /// to the platform font offline, so this never throws.
  static TextStyle sans({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    double? height,
    double? letterSpacing,
    Color? color,
    List<FontFeature>? features,
  }) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
        color: color,
        fontFeatures: features ?? tabular,
      );

  /// Monospace face for raw protocol bytes, device ids and logs.
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    double? height,
    Color? color,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: weight,
        height: height,
        color: color,
        fontFeatures: technical,
      );
}

/// The app's [TextTheme], built once per colour scheme.
///
/// Roles are named after *use*, not size, so a widget never has to know that
/// "headlineSmall" happens to be 24 sp:
///
/// * `displayNumeric` / `titleNumeric` — large tabular readouts (impact value,
///   countdown).
/// * `bodyData` — the default for any value that changes at runtime.
/// * `labelCaps` — the small uppercase section headers.
abstract final class AppTypography {
  /// Build the text theme.
  ///
  /// [onSurface] is the colour of body text and [muted] the colour of secondary
  /// text; both are passed in (rather than read from a [ColorScheme]) so this
  /// function is a pure function of its arguments and can be unit tested
  /// without a [ThemeData].
  ///
  /// Note that no `.apply(primary: ...)` happens here: [TextTheme.apply] has no
  /// such parameter, and re-colouring a themed text theme is how a widget ends
  /// up with onSurface text on a surface it does not contrast with. Colours are
  /// assigned per role, once, above.
  static TextTheme textTheme(Color onSurface, Color muted) {
    return TextTheme(
      // --- display: hero numbers only ---------------------------------------
      displayLarge: AppFonts.sans(
        size: 44,
        weight: FontWeight.w700,
        height: 1.05,
        letterSpacing: -1.2,
        color: onSurface,
      ),
      displayMedium: AppFonts.sans(
        size: 34,
        weight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.8,
        color: onSurface,
      ),
      displaySmall: AppFonts.sans(
        size: 28,
        weight: FontWeight.w700,
        height: 1.15,
        letterSpacing: -0.5,
        color: onSurface,
      ),

      // --- headlines: screen titles ----------------------------------------
      headlineLarge: AppFonts.sans(
        size: 26,
        weight: FontWeight.w700,
        height: 1.2,
        letterSpacing: -0.4,
        color: onSurface,
      ),
      headlineMedium: AppFonts.sans(
        size: 22,
        weight: FontWeight.w700,
        height: 1.25,
        letterSpacing: -0.3,
        color: onSurface,
      ),
      headlineSmall: AppFonts.sans(
        size: 20,
        weight: FontWeight.w600,
        height: 1.3,
        letterSpacing: -0.2,
        color: onSurface,
      ),

      // --- titles: card and list headers ------------------------------------
      titleLarge: AppFonts.sans(
        size: 18,
        weight: FontWeight.w600,
        height: 1.35,
        color: onSurface,
      ),
      titleMedium: AppFonts.sans(
        size: 16,
        weight: FontWeight.w600,
        height: 1.4,
        color: onSurface,
      ),
      titleSmall: AppFonts.sans(
        size: 14,
        weight: FontWeight.w600,
        height: 1.4,
        color: onSurface,
      ),

      // --- body ---------------------------------------------------------------
      bodyLarge: AppFonts.sans(
        size: 16,
        weight: FontWeight.w400,
        height: 1.5,
        color: onSurface,
      ),
      bodyMedium: AppFonts.sans(
        size: 14,
        weight: FontWeight.w400,
        height: 1.5,
        color: onSurface,
      ),
      bodySmall: AppFonts.sans(
        size: 12,
        weight: FontWeight.w400,
        height: 1.45,
        color: muted,
      ),

      // --- labels ---------------------------------------------------------------
      labelLarge: AppFonts.sans(
        size: 14,
        weight: FontWeight.w600,
        height: 1.2,
        color: onSurface,
      ),
      labelMedium: AppFonts.sans(
        size: 12,
        weight: FontWeight.w600,
        height: 1.2,
        letterSpacing: 0.2,
        color: muted,
      ),
      labelSmall: AppFonts.sans(
        size: 11,
        weight: FontWeight.w500,
        height: 1.2,
        letterSpacing: 0.4,
        color: muted,
      ),
    ).apply(
      bodyColor: onSurface,
      displayColor: onSurface,
    );
  }

  /// Large live readout, e.g. the impact magnitude on the alert screen.
  static TextStyle numericDisplay(Color color) => AppFonts.sans(
        size: 56,
        weight: FontWeight.w700,
        height: 1,
        letterSpacing: -2,
        color: color,
        features: AppFonts.tabular,
      );

  /// Default style for any runtime-changing value.
  static TextStyle numericBody(Color color, {double size = 15}) =>
      AppFonts.sans(
        size: size,
        weight: FontWeight.w600,
        height: 1.2,
        color: color,
        features: AppFonts.tabular,
      );

  /// Monospace for raw protocol bytes / diagnostics.
  static TextStyle code(Color color) => AppFonts.mono(size: 12, color: color);
}
