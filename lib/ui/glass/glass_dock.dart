// lib/ui/glass/glass_dock.dart
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

class GlassDock extends StatelessWidget {
  const GlassDock({
    super.key,
    required this.child,
    this.padding =
        const EdgeInsets.fromLTRB(12, 10, 12, 12),
    this.innerPadding = EdgeInsets.zero,
    this.radius,
    this.blur,
    this.tintLight,
    this.tintDark,
    this.shadow = true,
  });

  final Widget child;

  /// outer spacing
  final EdgeInsetsGeometry padding;

  /// inner padding inside glass
  final EdgeInsetsGeometry innerPadding;

  final BorderRadius? radius;
  final double? blur;

  final double? tintLight;
  final double? tintDark;

  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    // Dock should be slightly stronger than panels
    const defaultTintDark = 0.065;
    const defaultTintLight = 0.050;

    const defaultBorderDark = 0.16;
    const defaultBorderLight = 0.22;

    final blurValue = blur ?? (isDark ? 16 : 12); // perf

    return SafeArea(
      top: false,
      child: Padding(
        padding: padding,
        child: LiquidGlass(
          padding: innerPadding,
          borderRadius: radius ?? GlassTokens.radiusDock,

          blurX: blurValue,
          blurY: blurValue,

          tintOpacityDark: tintDark ?? defaultTintDark,
          tintOpacityLight: tintLight ?? defaultTintLight,

          borderOpacityDark: defaultBorderDark,
          borderOpacityLight: defaultBorderLight,

          shadow: shadow,
          grain: false,
          shadowBlur: 30,
          shadowOffset: const Offset(0, 18),
          shadowOpacityDark: 0.20,
          shadowOpacityLight: 0.08,

          onTap: null, // dock is not tappable itself
          child: child,
        ),
      ),
    );
  }
}
