// lib/ui/glass/glass_modal.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

/// ----------------------------
/// Modal Barrier (background)
/// ----------------------------
class GlassModalBarrier extends StatelessWidget {
  const GlassModalBarrier({
    super.key,
    this.onTap,
    this.blur = 14, // stronger blur behind modal
    this.dimAlphaLight = 0.20,
    this.dimAlphaDark = 0.48,
  });

  final VoidCallback? onTap;
  final double blur;
  final double dimAlphaLight;
  final double dimAlphaDark;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    final dim = Colors.black.withValues(
      alpha: isDark ? dimAlphaDark : dimAlphaLight,
    );

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          children: [
            // dim layer

            // background blur
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned.fill(child: Container(color: dim)),
          ],
        ),
      ),
    );
  }
}

/// ----------------------------
/// Modal Glass Panel
/// ----------------------------
class GlassModal extends StatelessWidget {
  const GlassModal({
    super.key,
    required this.child,
    this.maxWidth = 520,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 16),
    this.radius,
    this.blur,
    this.tintLight,
    this.tintDark,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  final BorderRadius? radius;
  final double? blur;

  final double? tintLight;
  final double? tintDark;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    // Modal should be slightly stronger than panel
    const defaultTintDark = 0.045;
    const defaultTintLight = 0.035;

    const defaultBorderDark = 0.16;
    const defaultBorderLight = 0.22;

    final blurValue = blur ?? (isDark ? 18 : 14); // perf

    return Center(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: LiquidGlass(
              padding: padding,
              borderRadius: radius ?? GlassTokens.radiusModal,

              blurX: blurValue,
              blurY: blurValue,
              grain: false,

              // extremely transparent, true glass
              tintOpacityDark: tintDark ?? defaultTintDark,
              tintOpacityLight: tintLight ?? defaultTintLight,

              borderOpacityDark: defaultBorderDark,
              borderOpacityLight: defaultBorderLight,

              shadow: true,
              shadowBlur: 36,
              shadowOffset: const Offset(0, 20),
              shadowOpacityDark: 0.22,
              shadowOpacityLight: 0.08,

              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
