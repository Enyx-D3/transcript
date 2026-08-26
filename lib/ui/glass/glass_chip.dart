// lib/ui/glass/glass_chip.dart
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.borderRadius,
    this.tintLight,
    this.tintDark,
    this.fgAlpha = 1.0,
    this.backgroundColor,
    this.borderColor,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final double? tintLight;
  final double? tintDark;
  final double fgAlpha;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context, alpha: fgAlpha);

    final bg = backgroundColor ??
        (isDark ? const Color(0xFF1E1E26) : const Color(0xFFE8E8EE));
    final border = borderColor ??
        (isDark ? const Color(0xFF2C2C38) : const Color(0xFFD6D6DE));

    final br = borderRadius ?? BorderRadius.circular(999);

    return LiquidGlass(
      borderRadius: br,
      padding: padding,
      backgroundColor: bg,
      borderColor: border,
      borderWidth: 1,
      shadow: false,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              fontSize: 11,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
