// lib/ui/glass/glass_chip.dart
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.padding =
        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.borderRadius,
    this.tintLight,
    this.tintDark,
    this.fgAlpha = 0.95,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;

  final double? tintLight;
  final double? tintDark;

  final double fgAlpha;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: fgAlpha);

    // ✅ Chips should be VERY transparent
    const defaultTintDark = 0.045;
    const defaultTintLight = 0.035;

    const defaultBorderDark = 0.16;
    const defaultBorderLight = 0.20;

    final br = borderRadius ?? BorderRadius.circular(999);

    return LiquidGlass(
      borderRadius: br,
      padding: padding,

      // ✅ Lighter blur than cards
      blurX: 0, // perf
      blurY: 0, // perf
      shadow: false,
      grain: false,

      // caller override wins
      tintOpacityDark: tintDark ?? defaultTintDark,
      tintOpacityLight: tintLight ?? defaultTintLight,

      borderOpacityDark: defaultBorderDark,
      borderOpacityLight: defaultBorderLight,

      onTap: onTap,

      child: _InnerChrome(
        borderRadius: br,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 0.35,
                fontSize: 10,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Very subtle top highlight (Apple micro-detail)
class _InnerChrome extends StatelessWidget {
  const _InnerChrome({
    required this.child,
    required this.borderRadius,
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    final highlightAlpha = isDark ? 0.14 : 0.22;

    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 1,
            child: IgnorePointer(
              child: Container(
                color: Colors.white.withValues(alpha: highlightAlpha),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
