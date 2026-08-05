import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';

class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 86,
    this.borderRadius = 26,
    this.innerRadius = 18,
    this.assetPath = 'assets/logo/transcript-transparent.png',
  });

  final double size;
  final double borderRadius;
  final double innerRadius;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);

    return ClipRRect(
      borderRadius: radius,
      child: LiquidGlass(
        borderRadius: radius,
        padding: const EdgeInsets.all(10),
        blurX: 0,
        blurY: 0,
        shadow: false,
        grain: false,
        tintOpacityDark: 0.045,
        tintOpacityLight: 0.040,
        borderOpacityDark: 0.22,
        borderOpacityLight: 0.26,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(innerRadius),
              child: Image.asset(assetPath, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
}
