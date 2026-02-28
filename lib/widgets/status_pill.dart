import 'package:flutter/material.dart';
import '../ui/glass/liquid_glass.dart';
import '../ui/glass/glass_tokens.dart';

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.text,
    this.isError = false,
    this.icon,
  });

  final String text;
  final bool isError;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = isError ? Colors.redAccent : null;
    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.78);

    final radius = BorderRadius.circular(999);

    final tl = accent != null ? 0.060 : 0.050;
    final td = accent != null ? 0.085 : 0.070;
    final bl = accent != null ? 0.26 : 0.20;
    final bd = accent != null ? 0.22 : 0.16;

    final resolvedIcon = icon ??
        (isError
            ? Icons.warning_amber_rounded
            : Icons.hourglass_bottom_rounded);

    return ClipRRect(
      borderRadius: radius,
      child: LiquidGlass(
        borderRadius: radius,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shadow: false,
        blurX: 0,
        blurY: 0,
        grain: false,
        tintOpacityLight: tl,
        tintOpacityDark: td,
        borderOpacityLight: bl,
        borderOpacityDark: bd,
        child: SizedBox(
          height: 32, // keeps perfect capsule
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                resolvedIcon,
                size: 16,
                color: accent ?? fg,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: accent ?? muted,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}