import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';

class LeadingPillIcon extends StatelessWidget {
  const LeadingPillIcon({
    super.key,
    required this.icon,
    this.size = 20,
    this.boxSize = 42,
    this.alpha = 0.85,
    this.borderRadius = 14,
    this.blurX = 12,
    this.blurY = 12,
    this.shadow = false,
    this.padding = EdgeInsets.zero,
    this.tintOpacityDark = 0.05,
    this.tintOpacityLight = 0.04,
    this.borderOpacityDark = 0.14,
    this.borderOpacityLight = 0.18,
  });

  final IconData icon;

  // customization knobs (optional)
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

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      borderRadius: BorderRadius.circular(borderRadius),
      padding: padding,
      shadow: shadow,
      blurX: blurX,
      blurY: blurY,
      tintOpacityDark: tintOpacityDark,
      tintOpacityLight: tintOpacityLight,
      borderOpacityDark: borderOpacityDark,
      borderOpacityLight: borderOpacityLight,
      child: SizedBox(
        width: boxSize,
        height: boxSize,
        child: Icon(
          icon,
          size: size,
          color: Colors.white.withValues(alpha: alpha),
        ),
      ),
    );
  }
}
