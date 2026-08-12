import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Dark Theme
  static final ThemeData dark = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFF0E0E12),
    canvasColor: const Color(0xFF0E0E12),
    cardColor: const Color(0xFF17171D),
    dividerColor: const Color(0xFF282832),

    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF007AFF),
      secondary: Color(0xFF007AFF),
      surface: Color(0xFF17171D),
      onSurface: Colors.white,
      onPrimary: Colors.white,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0E0E12),
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),

    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,

    textTheme: ThemeData.dark().textTheme.apply(
      bodyColor: Colors.white.withValues(alpha: 0.95),
      displayColor: Colors.white.withValues(alpha: 0.95),
    ),
  );

  // Light Theme
  static final ThemeData light = ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFFF5F5F8),
    canvasColor: const Color(0xFFF5F5F8),
    cardColor: const Color(0xFFFFFFFF),
    dividerColor: const Color(0xFFE2E2E8),

    colorScheme: const ColorScheme.light(
      primary: Color(0xFF007AFF),
      secondary: Color(0xFF007AFF),
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF141418),
      onPrimary: Colors.white,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF5F5F8),
      foregroundColor: Color(0xFF141418),
      elevation: 0,
      scrolledUnderElevation: 0,
    ),

    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,

    textTheme: ThemeData.light().textTheme.apply(
      bodyColor: const Color(0xFF18181C),
      displayColor: const Color(0xFF18181C),
    ),
  );
}
