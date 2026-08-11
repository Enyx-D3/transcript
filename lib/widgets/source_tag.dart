import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';

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
    final fg = GlassTokens.fg(context, alpha: 0.90);
    final isDark = GlassTokens.isDark(context);

    return LiquidGlass(
      borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      backgroundColor:
          isDark ? const Color(0xFF1E1E26) : const Color(0xFFE5E5ED),
      shadow: false,
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.25,
          color: fg,
          fontSize: fontSize,
        ),
      ),
    );
  }
}
