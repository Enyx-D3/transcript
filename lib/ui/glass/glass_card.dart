import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

enum GlassCardVariant {
  panel, // primary card / container
  tile,  // nested / secondary tile
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.borderRadius,
    this.blur,
    this.variant = GlassCardVariant.panel,
    this.tintOpacityLight,
    this.tintOpacityDark,
    this.borderOpacityLight,
    this.borderOpacityDark,
    this.shadow,
    this.shadowBlur,
    this.shadowOffset,
    this.shadowOpacityLight,
    this.shadowOpacityDark,
    this.onTap,
    this.grain,
    this.backgroundColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final double? blur;
  final GlassCardVariant variant;
  final double? tintOpacityLight;
  final double? tintOpacityDark;
  final double? borderOpacityLight;
  final double? borderOpacityDark;
  final bool? shadow;
  final double? shadowBlur;
  final Offset? shadowOffset;
  final double? shadowOpacityLight;
  final double? shadowOpacityDark;
  final VoidCallback? onTap;
  final bool? grain;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final isPanel = variant == GlassCardVariant.panel;

    final solidBg = backgroundColor ??
        (isPanel
            ? (isDark ? GlassTokens.cardDark : GlassTokens.cardLight)
            : (isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight));

    return LiquidGlass(
      margin: margin,
      padding: padding,
      borderRadius: borderRadius ?? GlassTokens.radiusCard,
      backgroundColor: solidBg,
      borderColor: isDark ? GlassTokens.borderDark : GlassTokens.borderLight,
      shadow: shadow ?? isPanel,
      shadowBlur: shadowBlur ?? (isPanel ? 12 : 6),
      shadowOffset: shadowOffset ?? (isPanel ? const Offset(0, 4) : const Offset(0, 2)),
      shadowOpacityDark: shadowOpacityDark ?? (isPanel ? 0.35 : 0.20),
      shadowOpacityLight: shadowOpacityLight ?? 0.05,
      onTap: onTap,
      child: child,
    );
  }
}
