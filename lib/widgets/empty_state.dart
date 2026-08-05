import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.iconSize = 26,
    this.padding = const EdgeInsets.fromLTRB(16, 18, 16, 18),
  });

  final String title;
  final String subtitle;

  final IconData icon;
  final double iconSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LiquidGlass(
              borderRadius: BorderRadius.circular(18),
              padding: const EdgeInsets.all(14),
              shadow: false,
              blurX: 16,
              blurY: 16,
              tintOpacityDark: 0.05,
              tintOpacityLight: 0.04,
              borderOpacityDark: 0.14,
              borderOpacityLight: 0.18,
              child: Icon(
                icon,
                size: iconSize,
                color: Colors.white.withValues(alpha: 0.82),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.70),
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
