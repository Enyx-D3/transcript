// lib/ui/glass/glass_modal.dart
import 'package:flutter/material.dart';
import 'liquid_glass.dart';
import 'glass_tokens.dart';

/// ----------------------------
/// Modal Barrier (background)
/// ----------------------------
class GlassModalBarrier extends StatelessWidget {
  const GlassModalBarrier({
    super.key,
    this.onTap,
    this.blur = 0,
    this.dimAlphaLight = 0.40,
    this.dimAlphaDark = 0.65,
  });

  final VoidCallback? onTap;
  final double blur;
  final double dimAlphaLight;
  final double dimAlphaDark;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final dim = Colors.black.withValues(
      alpha: isDark ? dimAlphaDark : dimAlphaLight,
    );

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(color: dim),
      ),
    );
  }
}

/// ----------------------------
/// Modal Solid Panel
/// ----------------------------
class GlassModal extends StatelessWidget {
  const GlassModal({
    super.key,
    required this.child,
    this.maxWidth = 520,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 16),
    this.radius,
    this.blur,
    this.tintLight,
    this.tintDark,
    this.backgroundColor,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final BorderRadius? radius;
  final double? blur;
  final double? tintLight;
  final double? tintDark;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    final bg = backgroundColor ??
        (isDark ? const Color(0xFF191921) : const Color(0xFFFFFFFF));
    final border = isDark ? const Color(0xFF2C2C38) : const Color(0xFFDFDFE6);

    return Center(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: LiquidGlass(
              padding: padding,
              borderRadius: radius ?? GlassTokens.radiusModal,
              backgroundColor: bg,
              borderColor: border,
              shadow: true,
              shadowBlur: 28,
              shadowOffset: const Offset(0, 10),
              shadowOpacityDark: 0.50,
              shadowOpacityLight: 0.12,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
