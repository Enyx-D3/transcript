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
    this.padding = const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    this.borderRadius,

    /// ✅ NEW: optional inner chrome (default OFF)
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

  /// ✅ NEW
  final bool innerChrome;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    final fg = GlassTokens.fg(context, alpha: enabled ? 0.94 : 0.75);
    final br = borderRadius ?? BorderRadius.circular(16);

    // ✅ Apple-ish tuning:
    // Primary is a bit more “milky”, secondary is almost-clear.
    final double tintLight = kind == GlassButtonKind.primary ? 0.055 : 0.030;
    final double tintDark = kind == GlassButtonKind.primary ? 0.070 : 0.040;

    final double borderLight = kind == GlassButtonKind.primary ? 0.22 : 0.18;
    final double borderDark = kind == GlassButtonKind.primary ? 0.18 : 0.14;

    // Buttons should feel crisp; avoid muddy blur
    final double blur = 0; // perf: rely on screen-level blur

    Widget content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(fg),
            ),
          )
        else ...[
          if (icon != null) ...[
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              color: fg,
            ),
          ),
        ],
      ],
    );

    // ✅ apply inner chrome only if enabled
    final child = innerChrome
        ? _InnerChrome(borderRadius: br, kind: kind, child: content)
        : content;

    Widget button = LiquidGlass(
      borderRadius: br,
      padding: padding,
      blurX: blur,
      blurY: blur,
      shadow: false,
      grain: false,
      tintOpacityLight: tintLight,
      tintOpacityDark: tintDark,
      borderOpacityLight: borderLight,
      borderOpacityDark: borderDark,
      onTap: enabled ? onPressed : null,
      child: child,
    );

    if (expand) {
      button = SizedBox(width: double.infinity, child: button);
    }

    if (!enabled) {
      button = Opacity(opacity: 0.55, child: button);
    }

    return button;
  }
}

/// ✅ Optional Apple trick:
/// 1) thin inner top highlight
/// 2) subtle inner bottom shadow
class _InnerChrome extends StatelessWidget {
  const _InnerChrome({
    required this.child,
    required this.borderRadius,
    required this.kind,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final GlassButtonKind kind;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);

    // top highlight stronger for primary
    final topA = kind == GlassButtonKind.primary
        ? (isDark ? 0.16 : 0.22)
        : (isDark ? 0.12 : 0.18);

    // bottom inner shade (gives depth without drop shadow)
    final bottomA = kind == GlassButtonKind.primary
        ? (isDark ? 0.22 : 0.12)
        : (isDark ? 0.18 : 0.10);

    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,

          // inner top highlight line
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 1,
            child: IgnorePointer(
              child: Container(
                color: Colors.white.withValues(alpha: topA),
              ),
            ),
          ),

          // inner bottom shadow (very subtle)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 10,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: bottomA),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}