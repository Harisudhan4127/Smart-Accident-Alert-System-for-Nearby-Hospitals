/// The shared UI kit.
///
/// Every screen builds from these, so a "card" or a "status pill" looks and
/// behaves identically everywhere. The two rules the kit exists to enforce:
///
/// * **Colour carries meaning, not decoration.** [AppColors.emergency] is used
///   for nothing except "a human is needed now". A screen that wants red for
///   emphasis is doing something wrong, because then red stops meaning
///   "danger" and the one screen that needs it loses its authority.
/// * **Numbers do not move.** Every numeric readout uses tabular figures
///   (see `core/theme/typography.dart`), so a live telemetry value does not
///   shift its own digits sideways 50 times a second.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/motion.dart';
import '../core/theme/spacing.dart';

/// A rounded surface card with a top highlight and a soft shadow.
///
/// Wraps in [RepaintBoundary] by default: most of these sit inside scrolling
/// lists, and without an explicit boundary a repaint anywhere in the list
/// repaints every card in it.
class GlassCard extends StatelessWidget {
  const GlassCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Spacing.medium),
    this.critical = false,
    this.elevated = false,
    this.margin,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// Draw the critical variant. Reserve it for live emergencies.
  final bool critical;

  /// Use the more opaque, shadowed surface.
  final bool elevated;

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final GlassSurfaces glass = context.glass;

    final Color fill = critical
        ? glass.cardCritical
        : (elevated ? glass.cardElevated : glass.card);
    final BorderRadius radius = BorderRadius.circular(20);

    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: Border.all(
          color: critical ? AppColors.emergency.withValues(alpha: 0.5) : glass.border,
          width: critical ? 1.5 : 1,
        ),
        boxShadow: critical
            ? context.elevations.critical
            : (elevated ? context.elevations.medium : const <BoxShadow>[]),
      ),
      // The 1 dp top highlight: what makes a dark card read as a physical
      // surface catching light rather than a hole in the background.
      child: Stack(
        children: <Widget>[
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: radius,
                child: Container(
                  height: 1,
                  color: critical
                      ? AppColors.emergency.withValues(alpha: 0.35)
                      : glass.highlight,
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    return RepaintBoundary(
      child: Padding(
        padding: margin ?? EdgeInsets.zero,
        child: onTap == null
            ? surface
            : Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: radius,
                  splashColor: glass.pressOverlay,
                  child: surface,
                ),
              ),
      ),
    );
  }
}

/// Maps a [StatusSeverity] onto the theme's [StatusPalette] token.
///
/// The palette is keyed by domain slot (`ok`, `warning`, `critical`, …) rather
/// than by severity, because several slots share a severity — `pending`,
/// `queued` and `warning` are all [StatusSeverity.warning]. This mapping is the
/// one place that collapse happens, so a pill asking for "warning" always gets
/// the same colours as every other warning pill.
extension StatusSeverityToken on StatusSeverity {
  StatusToken tokenOf(StatusPalette palette) => switch (this) {
        StatusSeverity.good => palette.ok,
        StatusSeverity.info => palette.info,
        StatusSeverity.warning => palette.warning,
        StatusSeverity.critical => palette.critical,
        StatusSeverity.neutral => palette.neutral,
      };
}

/// A compact status pill, e.g. `CONNECTED` / `OFFLINE` / `LOW BATTERY`.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.severity,
    this.icon,
    this.dense = false,
    super.key,
  });

  final String label;
  final StatusSeverity severity;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final StatusToken token = severity.tokenOf(context.statusPalette);
    final TextStyle style = (dense
            ? Theme.of(context).textTheme.labelSmall
            : Theme.of(context).textTheme.labelMedium) ??
        const TextStyle();

    return Semantics(
      label: '$label: ${severity.name}',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? Spacing.xs : Spacing.sm,
          vertical: dense ? 3 : 5,
        ),
        decoration: BoxDecoration(
          color: token.fill,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: token.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: dense ? 11 : 13, color: token.ink),
              SizedBox(width: dense ? 3 : 5),
            ],
            // `tabularFigures` comes from the app's TextTheme, so the label
            // does not jitter as text changes ("LINKING" -> "LINKED").
            Text(
              label.toUpperCase(),
              style: style.copyWith(
                color: token.ink,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled readout. The workhorse of the dashboard.
class MetricTile extends StatelessWidget {
  const MetricTile({
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.severity = StatusSeverity.neutral,
    this.caption,
    super.key,
  });

  final String label;

  /// Already formatted. Kept as a `String` so the caller owns the formatting
  /// policy and this widget never rounds behind its back.
  final String value;
  final String? unit;
  final IconData? icon;
  final StatusSeverity severity;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StatusToken token = severity.tokenOf(context.statusPalette);

    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          // `FittedBox` + tabular figures: the value never reflows its own
          // layout as digits change, which is what stops a live readout from
          // twitching.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: severity == StatusSeverity.neutral
                        ? theme.colorScheme.onSurface
                        : token.ink,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                if (unit != null) ...<Widget>[
                  const SizedBox(width: 3),
                  Text(
                    unit!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (caption != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              caption!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// The countdown ring for the emergency alert.
///
/// Animated with a single [AnimationController] driven by a periodic ticker
/// rather than a rebuild per second, so the ring is smooth and the rest of the
/// screen is not rebuilt 50 times while it sweeps.
class CountdownRing extends StatefulWidget {
  const CountdownRing({
    required this.remaining,
    required this.total,
    this.diameter = 220,
    super.key,
  });

  final int remaining;
  final int total;
  final double diameter;

  @override
  State<CountdownRing> createState() => _CountdownRingState();
}

class _CountdownRingState extends State<CountdownRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MotionResolver motion = context.motion;
    final ThemeData theme = Theme.of(context);
    final int total = widget.total <= 0 ? 1 : widget.total;
    final double progress = (1 - widget.remaining / total).clamp(0.0, 1.0);
    final bool urgent = widget.remaining <= 3;

    final Color ring = urgent ? AppColors.emergency : AppColors.amber;

    return SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // A pulse while the countdown runs: the one animation in the app that
          // is *not* decorative. It is the signal that says "you have N seconds".
          if (!motion.reduceMotion)
            AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                // Sine so the pulse eases rather than snapping.
                final double t =
                    0.5 + 0.5 * math.sin(_controller.value * 2 * math.pi);
                return Opacity(
                  opacity: 0.10 + 0.16 * t,
                  child: Container(
                    width: widget.diameter,
                    height: widget.diameter,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ring,
                    ),
                  ),
                );
              },
            ),
          CustomPaint(
            size: Size.square(widget.diameter),
            painter: _RingPainter(
              progress: motion.reduceMotion ? progress : _eased(progress, _controller.value),
              track: theme.colorScheme.surfaceContainerHighest,
              color: ring,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${widget.remaining}',
                style: theme.textTheme.displayLarge?.copyWith(
                  color: ring,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'SECONDS',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Smooth the discrete 1 Hz progress value so the ring does not step.
  double _eased(double target, double phase) {
    // Exponential approach toward the target, driven by the 1 Hz ticker.
    final double t = Curves.easeOut.transform(phase);
    return _lastTarget + (target - _lastTarget) * t;
  }

  double _lastTarget = 0;

  @override
  void didUpdateWidget(CountdownRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.total != oldWidget.total) _lastTarget = 0;
  }
}

/// Paints the countdown ring.
class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.track,
    required this.color,
  });

  final double progress;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 12;
    final Rect rect = Offset.zero & size;
    final Rect arcRect = rect.deflate(stroke / 2);

    final Paint trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, 0, 2 * math.pi, false, trackPaint);

    if (progress <= 0) return;

    final Paint progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    // Start at 12 o'clock and sweep clockwise.
    canvas.drawArc(
      arcRect,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

/// A full-bleed banner for a non-fatal but important condition
/// (offline with queued uploads, GPS denied, battery low).
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    required this.message,
    this.severity = StatusSeverity.warning,
    this.icon = Icons.info_outline,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final StatusSeverity severity;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StatusToken token = severity.tokenOf(context.statusPalette);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.medium,
          vertical: Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: token.fill,
          border: Border(
            bottom: BorderSide(color: token.outline),
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 17, color: token.ink),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: token.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: token.ink,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

/// A section heading.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: <Widget>[
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// An empty state.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: Spacing.medium),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: Spacing.xs),
              Text(
                message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: Spacing.large),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A big, unmistakable call-to-action.
///
/// Sized for a thumb and used for the two decisions on the alert screen, where
/// the difference between "I'm safe" and "send help" is the whole outcome.
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.critical = false,
    this.busy = false,
    this.expand = true,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool critical;
  final bool busy;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final Color background =
        critical ? AppColors.emergency : Theme.of(context).colorScheme.primary;
    final Color foreground =
        critical ? Colors.white : Theme.of(context).colorScheme.onPrimary;

    return SizedBox(
      width: expand ? double.infinity : null,
      height: 56,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        child: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(foreground),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 20),
                    const SizedBox(width: Spacing.xs),
                  ],
                  Text(label),
                ],
              ),
      ),
    );
  }
}
