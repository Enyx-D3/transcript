import 'package:flutter/material.dart';
import 'glass_tokens.dart';

class GlassBackground extends StatelessWidget {
  const GlassBackground({
    super.key,
    this.child,
    this.assetPath = 'assets/wallpapers/glass_bg.jpeg',
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.globalBlur = false,
    this.blurSigma = 0,
    this.dimOpacity = 0,
    this.backgroundColor,
  });

  final Widget? child;
  final String assetPath;
  final BoxFit fit;
  final Alignment alignment;
  final bool globalBlur;
  final double blurSigma;
  final double dimOpacity;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final bg = backgroundColor ??
        (isDark ? GlassTokens.backgroundDark : GlassTokens.backgroundLight);

    return Container(
      color: bg,
      width: double.infinity,
      height: double.infinity,
      child: child,
    );
  }
}
