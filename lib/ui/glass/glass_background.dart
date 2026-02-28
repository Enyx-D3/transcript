import 'dart:ui';
import 'package:flutter/material.dart';

class GlassBackground extends StatelessWidget {
  const GlassBackground({
    super.key,
    this.child,
    this.assetPath = 'assets/wallpapers/glass_bg.jpeg',
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,

    // ✅ add these
    this.globalBlur = true,
    this.blurSigma = 14,
    this.dimOpacity = 0.10,
  });

  final Widget? child;

  final String assetPath;
  final BoxFit fit;
  final Alignment alignment;

  /// ✅ One blur for the whole screen (recommended)
  final bool globalBlur;

  /// Blur strength (keep ~10–18)
  final double blurSigma;

  /// Darkens the background slightly so glass reads better
  final double dimOpacity;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          assetPath,
          fit: fit,
          alignment: alignment,
          filterQuality: FilterQuality.high,
        ),

        // ✅ ONE global blur layer (cheap compared to blurring each card)
        if (globalBlur)
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: const SizedBox.expand(),
            ),
          ),

        // ✅ optional dim overlay (helps readability + “glass” look)
        if (dimOpacity > 0)
          Container(color: Colors.black.withValues(alpha: dimOpacity)),

        if (child != null) child!,
      ],
    );
  }
}