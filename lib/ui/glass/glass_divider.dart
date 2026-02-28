// lib/ui/glass/glass_divider.dart
import 'package:flutter/material.dart';
import 'glass_tokens.dart';

class GlassDivider extends StatelessWidget {
  const GlassDivider({
    super.key,
    this.height = 1,
    this.thickness = 1,
    this.indent = 0,
    this.endIndent = 0,
    this.alphaLight = 0.14,
    this.alphaDark = 0.12,
  });

  final double height;
  final double thickness;
  final double indent;
  final double endIndent;

  final double alphaLight;
  final double alphaDark;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    final c = Colors.white.withValues(
      alpha: isDark ? alphaDark : alphaLight,
    );

    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: indent,
        end: endIndent,
      ),
      child: SizedBox(
        height: height,
        child: Center(
          child: Container(
            height: thickness,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }
}
