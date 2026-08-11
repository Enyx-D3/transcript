import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';

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
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);
    final isDark = GlassTokens.isDark(context);

    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LiquidGlass(
              borderRadius: BorderRadius.circular(18),
              padding: const EdgeInsets.all(14),
              backgroundColor:
                  isDark ? GlassTokens.surfaceDark : GlassTokens.surfaceLight,
              shadow: false,
              child: Icon(
                icon,
                size: iconSize,
                color: fg.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
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
