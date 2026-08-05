import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';

class IconPillButton extends StatelessWidget {
  const IconPillButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final iconColor = disabled
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.white.withValues(alpha: 0.92);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: LiquidGlass(
          borderRadius: BorderRadius.circular(999),
          padding: const EdgeInsets.all(8),
          shadow: false,
          blurX: 12,
          blurY: 12,
          tintOpacityDark: 0.040,
          tintOpacityLight: 0.032,
          borderOpacityDark: 0.14,
          borderOpacityLight: 0.18,
          child: Icon(icon, size: 20, color: iconColor),
        ),
      ),
    );
  }
}
