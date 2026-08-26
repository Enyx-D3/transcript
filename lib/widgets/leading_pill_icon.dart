import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';

class LeadingPillIcon extends StatelessWidget {
  const LeadingPillIcon({
    super.key,
    required this.icon,
    this.size = 20,
    this.boxSize = 42,
    this.alpha = 0.85,
    this.borderRadius = 14,
    this.blurX = 0,
    this.blurY = 0,
    this.shadow = false,
    this.padding = EdgeInsets.zero,
    this.tintOpacityDark = 0.05,
    this.tintOpacityLight = 0.04,
    this.borderOpacityDark = 0.14,
    this.borderOpacityLight = 0.18,
    this.backgroundColor,
    this.iconColor,
  });

  final IconData icon;
  final double size;
  final double boxSize;
  final double alpha;
  final double borderRadius;
  final double blurX;
  final double blurY;
  final bool shadow;
  final EdgeInsets padding;
  final double tintOpacityDark;
  final double tintOpacityLight;
  final double borderOpacityDark;
  final double borderOpacityLight;
  final Color? backgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final fg = iconColor ?? GlassTokens.fg(context, alpha: alpha);
    final isDark = GlassTokens.isDark(context);
    final bg = backgroundColor ??
        (isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight);

    return LiquidGlass(
      borderRadius: BorderRadius.circular(borderRadius),
      padding: padding,
      backgroundColor: bg,
      shadow: shadow,
      child: SizedBox(
        width: boxSize,
        height: boxSize,
        child: Icon(
          icon,
          size: size,
          color: fg,
        ),
      ),
    );
  }
}
