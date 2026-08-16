import 'package:flutter/material.dart';
import '../ui/glass/glass_tokens.dart';

class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 86,
    this.borderRadius = 24,
    this.innerRadius = 18,
    this.assetPath,
  });

  final double size;
  final double borderRadius;
  final double innerRadius;
  final String? assetPath;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final radius = BorderRadius.circular(borderRadius);
    final selectedAsset = assetPath ??
        (isDark
            ? 'assets/logo/transcript-black.png'
            : 'assets/logo/transcript-black.png');

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF121217),
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.14),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.black.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset(
          selectedAsset,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}
