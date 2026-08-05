import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';

class SourceTag extends StatelessWidget {
  const SourceTag({
    super.key,
    required this.type,
    this.label,
    this.fontSize = 10,
    this.horizontalPadding = 10,
    this.verticalPadding = 6,
  });

  /// e.g. "youtube", "call", "audio", "video"
  final String type;

  /// Optional custom label (otherwise uses type.toUpperCase()).
  final String? label;

  final double fontSize;
  final double horizontalPadding;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final text = (label ?? type).toUpperCase();

    return LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      shadow: false,
      tintOpacityDark: 0.040,
      tintOpacityLight: 0.035,
      borderOpacityDark: 0.14,
      borderOpacityLight: 0.18,
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.25,
          color: Colors.white.withValues(alpha: 0.92),
          fontSize: fontSize,
        ),
      ),
    );
  }
}
