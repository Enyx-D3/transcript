import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

enum GlassCardVariant {
  panel, // big shared surfaces
  tile, // small components
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

    // ✅ pass-through (optional)
    this.grain,
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

  /// If null, uses smart default (panel=true, tile=false).
  final bool? grain;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final isPanel = variant == GlassCardVariant.panel;

    // Panels = almost transparent (structure only)
    const panelTintDark = 0.020;
    const panelTintLight = 0.025;
    const panelBorderDark = 0.12;
    const panelBorderLight = 0.16;

    // ✅ Reduce blur a bit (huge perf gain, minimal visual change)
    const panelBlurDark = 14.0; // perf
    const panelBlurLight = 10.0; // perf

    // Tiles = slightly more visible
    const tileTintDark = 0.065;
    const tileTintLight = 0.060;
    const tileBorderDark = 0.16;
    const tileBorderLight = 0.20;
    const tileBlurDark = 0.0;
    const tileBlurLight = 0.0; // perf: no per-tile blur (use screen blur)

    final presetBlur =
        blur ??
        (isDark
            ? (isPanel ? panelBlurDark : tileBlurDark)
            : (isPanel ? panelBlurLight : tileBlurLight));

    // Panels should not float
    final defaultShadow = isPanel ? false : true;

    return LiquidGlass(
      margin: margin,
      padding: padding,
      borderRadius: borderRadius ?? GlassTokens.radiusCard,

      blurX: presetBlur,
      blurY: presetBlur,

      tintOpacityDark:
          tintOpacityDark ?? (isPanel ? panelTintDark : tileTintDark),
      tintOpacityLight:
          tintOpacityLight ?? (isPanel ? panelTintLight : tileTintLight),

      borderOpacityDark:
          borderOpacityDark ?? (isPanel ? panelBorderDark : tileBorderDark),
      borderOpacityLight:
          borderOpacityLight ?? (isPanel ? panelBorderLight : tileBorderLight),

      shadow: shadow ?? defaultShadow,
      shadowBlur: shadowBlur ?? 24,
      shadowOffset: shadowOffset ?? const Offset(0, 12),
      shadowOpacityDark: shadowOpacityDark ?? 0.18,
      shadowOpacityLight: shadowOpacityLight ?? 0.06,

      // ✅ Smart default: grain on panels, off on tiles (massive perf win)
      grain: grain ?? false,

      onTap: onTap,
      child: child,
    );
  }
}
