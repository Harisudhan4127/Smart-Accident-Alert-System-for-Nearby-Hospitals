/// Spacing scale: a strict 4 pt grid with named tokens.
///
/// **Why named tokens instead of raw numbers:** `EdgeInsets.all(16)` is a
/// magic number that means "medium" to nobody reading the widget six months
/// later. `Spacing.medium` says it. Combined with the 4 pt grid it makes
/// vertical rhythm mechanically consistent: every gap in the app is a multiple
/// of 4, so cards line up across screens without anyone having to check.
library;

import 'package:flutter/material.dart'
    show BorderRadius, BorderSide, Color, Radius;

/// Named spacing tokens, in logical pixels.
///
/// The scale is 4-based with two half-steps (2 and 6) for optical adjustments
/// inside dense components, where a strict 4 pt grid looks too airy — a 2 pt
/// gap between a label and its value, for example.
abstract final class Spacing {
  /// 0 — no space.
  static const double none = 0;

  /// 2 — hairline, optical only. Never between groups.
  static const double hairline = 2;

  /// 4 — between an icon and its label.
  static const double xxs = 4;

  /// 8 — inside a chip, between related lines of text.
  static const double xs = 8;

  /// 12 — between a label and its value in a dense list row.
  static const double sm = 12;

  /// 16 — the workhorse. Card padding, gap between cards.
  static const double medium = 16;

  /// 20 — card padding on large surfaces (the 16 dp "dense" case).
  static const double ml = 20;

  /// 24 — between sections.
  static const double large = 24;

  /// 32 — between major sections.
  static const double xl = 32;

  /// 40 — above a page title.
  static const double xxl = 40;

  /// 48 — hero spacing (splash, empty states).
  static const double huge = 48;

  /// 64 — only on splash / onboarding.
  static const double giant = 64;

  /// Screen inset used by every scrollable page. One value so pages align.
  static const double screenPadding = medium;

  /// Horizontal inset for a card's content.
  static const double cardPadding = medium;

  /// Vertical inset for a card's content.
  static const double cardPaddingVertical = ml;

  /// Minimum touch target. Material's 48 dp, restated here so we do not have to
  /// remember it — this is a night-time app used by someone who may be shaken.
  static const double minTouchTarget = 48;

  /// The SOS button is bigger than the minimum on purpose.
  static const double emergencyButton = 96;
}

/// Named corner radii.
abstract final class Radii {
  /// 8 dp — between related controls.
  static const double sm = 8;

  /// 12 dp — inside a control.
  static const double md = 12;

  /// 16 dp — the default page gutter.
  static const double lg = 16;

  /// 24 dp — between sections.
  static const double xl = 24;

  /// Large enough to round any box to a capsule.
  static const double pill = 999;

  /// Cards and list tiles.
  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(lg));

  /// Bottom sheets: rounded at the top, flush at the bottom.
  static const BorderRadius sheetRadius =
      BorderRadius.vertical(top: Radius.circular(xl));

  /// Buttons, chips and status pills.
  static const BorderRadius pillRadius =
      BorderRadius.all(Radius.circular(pill));
}

/// Named border widths. Mostly 1 dp hairlines on glass surfaces.
abstract final class Borders {
  /// 1 dp — dividers and focus rings.
  static const double hairline = 1;

  /// 2 dp — selection and active indicators.
  static const double thick = 2;

  /// A hairline that must stay visible on a dark background, where a 1 dp
  /// `white12` border disappears on OLED.
  static const BorderSide subtleDark =
      BorderSide(color: Color(0x1FFFFFFF), width: hairline);
}
