// lib/ui/glass/glass_tokens.dart
import 'package:flutter/material.dart';

class GlassTokens {
  GlassTokens._();

  // -----------------
  // Radii
  // -----------------
  static const BorderRadius radiusCard = BorderRadius.all(Radius.circular(18));
  static const BorderRadius radiusModal = BorderRadius.all(Radius.circular(22));
  static const BorderRadius radiusDock = BorderRadius.all(Radius.circular(24));

  // -----------------
  // Blur
  // -----------------
  // Panels should blur more than controls
  static const double blurSm = 10; // controls
  static const double blurMd = 28; // panels
  static const double blurLg = 34; // sheets / large surfaces

  // -----------------
  // Border
  // -----------------
  static const double borderWidth = 1;

  // Thin subtle white edge
  static const double borderOpacityLight = 0.18;
  static const double borderOpacityDark = 0.14;

  // -----------------
  // Tint (TRUE Apple Glass)
  // -----------------
  // Panels = almost zero tint (blur does the work)
  static const double tintPanelLight = 0.02;
  static const double tintPanelDark = 0.02;

  // Controls = slightly visible
  static const double tintControlLight = 0.06;
  static const double tintControlDark = 0.08;

  // Strong (rare)
  static const double tintStrongLight = 0.10;
  static const double tintStrongDark = 0.12;

  // -----------------
  // Highlight (top specular line)
  // -----------------
  static const double highlightOpacityLight = 0.18;
  static const double highlightOpacityDark = 0.14;

  // -----------------
  // Shadow
  // -----------------
  static const double shadowOpacityLight = 0.08;
  static const double shadowOpacityDark = 0.18;

  static const double shadowBlur = 24;
  static const Offset shadowOffset = Offset(0, 14);

  // -----------------
  // Helpers
  // -----------------
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color fg(BuildContext context, {double alpha = 0.92}) {
    final dark = isDark(context);
    return (dark ? Colors.white : Colors.black).withValues(alpha: alpha);
  }

  static Color muted(BuildContext context, {double alpha = 0.62}) {
    final dark = isDark(context);
    return (dark ? Colors.white : Colors.black).withValues(alpha: alpha);
  }

  static Color borderColor(BuildContext context) {
    final dark = isDark(context);
    return Colors.white.withValues(
      alpha: dark ? borderOpacityDark : borderOpacityLight,
    );
  }

  /// IMPORTANT:
  /// Apple glass uses WHITE tint even in dark mode.
  /// Not black.
  static Color tintColor(BuildContext context, {double? light, double? dark}) {
    final isD = isDark(context);
    final a = isD ? (dark ?? tintPanelDark) : (light ?? tintPanelLight);

    return Colors.white.withValues(alpha: a);
  }
}
