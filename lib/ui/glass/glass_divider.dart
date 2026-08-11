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
    this.alphaLight = 1.0,
    this.alphaDark = 1.0,
    this.color,
  });

  final double height;
  final double thickness;
  final double indent;
  final double endIndent;
  final double alphaLight;
  final double alphaDark;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final c = color ??
        (isDark ? const Color(0xFF262632) : const Color(0xFFE5E5ED));

    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, end: endIndent),
      child: SizedBox(
        height: height,
        child: Center(
          child: Container(
            height: thickness,
            color: c,
          ),
        ),
      ),
    );
  }
}
