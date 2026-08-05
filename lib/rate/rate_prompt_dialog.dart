import 'dart:ui';
import 'package:flutter/material.dart';

import 'in_app_review_helper.dart';
import 'rate_gate.dart';

Future<void> showRatePrompt(BuildContext context) async {
  final shouldRate = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => const _RateCardDialog(),
  );

  if (shouldRate != true) {
    await RateGate.onDismiss();
    return;
  }

  await InAppReviewHelper.requestReviewOrStoreFallback();
  await RateGate.markRated();
}

class _RateCardDialog extends StatelessWidget {
  const _RateCardDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final titleColor = Colors.white.withValues(alpha: 0.92);
    final subColor = Colors.white.withValues(alpha: 0.72);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _GlassCardSurface(
            borderRadius: BorderRadius.circular(22),
            blur: isDark ? 14 : 10,
            backgroundOpacity: isDark ? 0.18 : 0.14,
            borderOpacity: isDark ? 0.26 : 0.22,
            shadowOpacity: isDark ? 0.38 : 0.20,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),

                  // stars
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      5,
                      (_) => const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          Icons.star_rounded,
                          size: 22,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  Text(
                    'Liking the experience?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                      color: titleColor,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'A quick rating helps us improve and reach more people.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: subColor,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),

                  const SizedBox(height: 14),
                  _HairlineDivider(
                    color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.20),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    children: [
                      Expanded(
                        child: _GlassActionButton(
                          kind: _GlassActionButtonKind.secondary,
                          label: 'Not now',
                          onPressed: () => Navigator.of(context).pop(false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlassActionButton(
                          kind: _GlassActionButtonKind.primary,
                          label: 'Rate now',
                          onPressed: () => Navigator.of(context).pop(true),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  Text(
                    'You can change your mind anytime.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.58),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* ---------------- Card glass surface (NOT full-screen) ---------------- */

class _GlassCardSurface extends StatelessWidget {
  const _GlassCardSurface({
    required this.child,
    required this.borderRadius,
    required this.blur,
    required this.backgroundOpacity,
    required this.borderOpacity,
    required this.shadowOpacity,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final double backgroundOpacity;
  final double borderOpacity;
  final double shadowOpacity;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          // ✅ Blur applies ONLY behind this card region
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(
                    alpha: backgroundOpacity + (isDark ? 0.04 : 0.05),
                  ),
                  Colors.white.withValues(alpha: backgroundOpacity),
                  Colors.black.withValues(alpha: isDark ? 0.08 : 0.04),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: borderOpacity),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 26,
                  offset: const Offset(0, 14),
                  color: Colors.black.withValues(alpha: shadowOpacity),
                ),
              ],
            ),
            child: Stack(
              children: [
                // top highlight line
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 1,
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.white.withValues(
                        alpha: isDark ? 0.22 : 0.30,
                      ),
                    ),
                  ),
                ),

                // subtle corner glow (nice touch)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(-0.85, -0.9),
                          radius: 1.2,
                          colors: [
                            Colors.white.withValues(
                              alpha: isDark ? 0.10 : 0.12,
                            ),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HairlineDivider extends StatelessWidget {
  const _HairlineDivider({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: color);
  }
}

enum _GlassActionButtonKind { primary, secondary }

class _GlassActionButton extends StatelessWidget {
  const _GlassActionButton({
    required this.label,
    required this.onPressed,
    this.kind = _GlassActionButtonKind.primary,
  });

  final String label;
  final VoidCallback onPressed;
  final _GlassActionButtonKind kind;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgA = kind == _GlassActionButtonKind.primary
        ? (isDark ? 0.14 : 0.12)
        : (isDark ? 0.09 : 0.08);

    final borderA = kind == _GlassActionButtonKind.primary
        ? (isDark ? 0.22 : 0.20)
        : (isDark ? 0.18 : 0.16);

    final fg = Colors.white.withValues(alpha: 0.92);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(
                      alpha: bgA + (isDark ? 0.04 : 0.05),
                    ),
                    Colors.white.withValues(alpha: bgA),
                    Colors.black.withValues(alpha: isDark ? 0.08 : 0.04),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: borderA),
                  width: 1,
                ),
              ),
              child: Stack(
                children: [
                  // inner top highlight
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 1,
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.white.withValues(
                          alpha: kind == _GlassActionButtonKind.primary
                              ? (isDark ? 0.22 : 0.28)
                              : (isDark ? 0.18 : 0.24),
                        ),
                      ),
                    ),
                  ),

                  Center(
                    // ✅ never overflow
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
