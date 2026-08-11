// lib/ui/glass/liquid_glass.dart
import 'package:flutter/material.dart';
import 'glass_tokens.dart';

class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.margin,
    this.blurX,
    this.blurY,
    this.borderWidth,
    this.tintOpacityLight,
    this.tintOpacityDark,
    this.borderOpacityLight,
    this.borderOpacityDark,
    this.shadow = false,
    this.shadowBlur,
    this.shadowOffset,
    this.shadowOpacityLight,
    this.shadowOpacityDark,
    this.onTap,
    this.clipBehavior = Clip.hardEdge,
    this.highlightOpacityLight = 0,
    this.highlightOpacityDark = 0,
    this.grain = false,
    this.grainOpacityDark = 0,
    this.grainOpacityLight = 0,
    this.backgroundColor,
    this.borderColor,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? blurX;
  final double? blurY;
  final double? borderWidth;
  final double? tintOpacityLight;
  final double? tintOpacityDark;
  final double? borderOpacityLight;
  final double? borderOpacityDark;
  final bool shadow;
  final double? shadowBlur;
  final Offset? shadowOffset;
  final double? shadowOpacityLight;
  final double? shadowOpacityDark;
  final VoidCallback? onTap;
  final Clip clipBehavior;
  final double highlightOpacityLight;
  final double highlightOpacityDark;
  final bool grain;
  final double grainOpacityDark;
  final double grainOpacityLight;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? GlassTokens.radiusCard;
    final bw = borderWidth ?? GlassTokens.borderWidth;
    final isDark = GlassTokens.isDark(context);

    final bg = backgroundColor ??
        (isDark ? GlassTokens.cardDark : GlassTokens.cardLight);

    final border = borderColor ??
        (isDark ? GlassTokens.borderDark : GlassTokens.borderLight);

    final shadowColor = isDark
        ? Colors.black.withValues(alpha: shadowOpacityDark ?? 0.35)
        : Colors.black.withValues(alpha: shadowOpacityLight ?? 0.06);

    Widget box = Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: br,
        border: bw > 0 ? Border.all(color: border, width: bw) : null,
        boxShadow: shadow
            ? [
                BoxShadow(
                  blurRadius: shadowBlur ?? GlassTokens.shadowBlur,
                  offset: shadowOffset ?? GlassTokens.shadowOffset,
                  color: shadowColor,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: br,
        clipBehavior: clipBehavior,
        child: Padding(
          padding: padding ?? EdgeInsets.zero,
          child: child,
        ),
      ),
    );

    if (onTap != null) {
      box = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: box,
      );
    }

    if (margin != null) {
      box = Padding(padding: margin!, child: box);
    }

    return box;
  }
}
