// lib/ui/glass/glass_dock.dart
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

class GlassDock extends StatelessWidget {
  const GlassDock({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 10),
    this.innerPadding = EdgeInsets.zero,
    this.radius,
    this.blur,
    this.tintLight,
    this.tintDark,
    this.shadow = true,
    this.backgroundColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry innerPadding;
  final BorderRadius? radius;
  final double? blur;
  final double? tintLight;
  final double? tintDark;
  final bool shadow;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    final bg = backgroundColor ??
        (isDark ? const Color(0xFF14141A) : const Color(0xFFFFFFFF));
    final border = isDark ? const Color(0xFF282832) : const Color(0xFFE2E2E9);

    return SafeArea(
      top: false,
      child: Padding(
        padding: padding,
        child: LiquidGlass(
          padding: innerPadding,
          borderRadius: radius ?? GlassTokens.radiusDock,
          backgroundColor: bg,
          borderColor: border,
          shadow: shadow,
          shadowBlur: 20,
          shadowOffset: const Offset(0, 4),
          shadowOpacityDark: 0.45,
          shadowOpacityLight: 0.08,
          onTap: null,
          child: child,
        ),
      ),
    );
  }
}
