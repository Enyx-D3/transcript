import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';

class IconPillButton extends StatelessWidget {
  const IconPillButton({
    super.key,
    required this.tooltip,
    required this.icon,
    this.size = 20,
    this.padding,
    this.iconColor,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final EdgeInsetsGeometry? padding;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final fg = GlassTokens.fg(context);
    final effectiveIconColor = iconColor ??
        (disabled
            ? fg.withValues(alpha: 0.35)
            : fg.withValues(alpha: 0.92));

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: LiquidGlass(
          borderRadius: BorderRadius.circular(999),
          padding: padding ?? const EdgeInsets.all(8),
          shadow: false,
          child: Icon(icon, size: size, color: effectiveIconColor),
        ),
      ),
    );
  }
}
