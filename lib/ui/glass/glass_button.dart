// lib/ui/glass/glass_button.dart
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

enum GlassButtonKind { primary, secondary }

class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = GlassButtonKind.primary,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.padding = const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
    this.borderRadius,
    this.innerChrome = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final GlassButtonKind kind;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final bool innerChrome;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final isDark = GlassTokens.isDark(context);
    final isPrimary = kind == GlassButtonKind.primary;

    // Solid High-Contrast Colors
    final Color btnBg = isPrimary
        ? GlassTokens.primary(context)
        : (isDark ? const Color(0xFF22222A) : const Color(0xFFE8E8EE));

    final Color btnFg = isPrimary
        ? Colors.white
        : (isDark ? Colors.white : const Color(0xFF111114));

    final Color btnBorder = isPrimary
        ? Colors.transparent
        : (isDark ? const Color(0xFF33333F) : const Color(0xFFD6D6DE));

    final br = borderRadius ?? BorderRadius.circular(14);

    Widget content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation<Color>(btnFg),
            ),
          )
        else ...[
          if (icon != null) ...[
            Icon(icon, size: 18, color: btnFg),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 0.1,
              color: btnFg,
            ),
          ),
        ],
      ],
    );

    Widget button = LiquidGlass(
      borderRadius: br,
      padding: padding,
      backgroundColor: btnBg,
      borderColor: btnBorder,
      borderWidth: isPrimary ? 0 : 1,
      shadow: isPrimary,
      shadowBlur: 8,
      shadowOffset: const Offset(0, 2),
      shadowOpacityDark: 0.25,
      shadowOpacityLight: 0.08,
      onTap: enabled ? onPressed : null,
      child: content,
    );

    if (expand) {
      button = SizedBox(width: double.infinity, child: button);
    }

    if (!enabled) {
      button = Opacity(opacity: 0.45, child: button);
    }

    return button;
  }
}
