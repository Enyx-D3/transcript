// lib/ui/glass/glass_tokens.dart
import 'package:flutter/material.dart';

class GlassTokens {
  GlassTokens._();

  // -----------------
  // Colors (Solid Modern Palette)
  // -----------------
  static const Color backgroundDark = Color(0xFF0E0E12);
  static const Color backgroundLight = Color(0xFFF6F6F9);

  static const Color cardDark = Color(0xFF17171D);
  static const Color cardLight = Color(0xFFFFFFFF);

  static const Color surfaceDark = Color(0xFF1F1F27);
  static const Color surfaceLight = Color(0xFFEEEEF3);

  static const Color borderDark = Color(0xFF282832);
  static const Color borderLight = Color(0xFFE2E2E9);

  // -----------------
  // Radii
  // -----------------
  static const BorderRadius radiusCard = BorderRadius.all(Radius.circular(16));
  static const BorderRadius radiusModal = BorderRadius.all(Radius.circular(20));
  static const BorderRadius radiusDock = BorderRadius.all(Radius.circular(22));

  // -----------------
  // Blur (Disabled for Solid Theme)
  // -----------------
  static const double blurSm = 0;
  static const double blurMd = 0;
  static const double blurLg = 0;

  // -----------------
  // Border
  // -----------------
  static const double borderWidth = 1;
  static const double borderOpacityLight = 1.0;
  static const double borderOpacityDark = 1.0;

  // -----------------
  // Tint / Surface
  // -----------------
  static const double tintPanelLight = 1.0;
  static const double tintPanelDark = 1.0;
  static const double tintControlLight = 1.0;
  static const double tintControlDark = 1.0;
  static const double tintStrongLight = 1.0;
  static const double tintStrongDark = 1.0;

  // -----------------
  // Highlight
  // -----------------
  static const double highlightOpacityLight = 0.0;
  static const double highlightOpacityDark = 0.0;

  // -----------------
  // Shadow
  // -----------------
  static const double shadowOpacityLight = 0.05;
  static const double shadowOpacityDark = 0.35;
  static const double shadowBlur = 16;
  static const Offset shadowOffset = Offset(0, 4);

  // -----------------
  // Helpers
  // -----------------
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color primary(BuildContext context) {
    return Theme.of(context).colorScheme.primary;
  }

  static Color fg(BuildContext context, {double alpha = 0.95}) {
    final dark = isDark(context);
    return (dark ? Colors.white : const Color(0xFF1A1A1E))
        .withValues(alpha: alpha);
  }

  static Color muted(BuildContext context, {double alpha = 0.65}) {
    final dark = isDark(context);
    return (dark ? const Color(0xFFA0A0AB) : const Color(0xFF6B6B78))
        .withValues(alpha: alpha);
  }

  static Color borderColor(BuildContext context) {
    return isDark(context) ? borderDark : borderLight;
  }

  static Color surfaceColor(BuildContext context) {
    return isDark(context) ? surfaceDark : surfaceLight;
  }

  static Color backgroundColor(BuildContext context) {
    return isDark(context) ? backgroundDark : backgroundLight;
  }

  static Color cardColor(BuildContext context) {
    return isDark(context) ? cardDark : cardLight;
  }

  static Color tintColor(BuildContext context, {double? light, double? dark}) {
    return cardColor(context);
  }
}
