import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color darkBackground = Color(0xFF0E0E12);
  static const Color lightBackground = Color(0xFFF6F6F9);

  static const Color blueAccent = Color(0xFF007AFF);
  static const Color crimsonAccent = Color(0xFFE6465D);

  // Dark Theme (Blue Accent)
  static final ThemeData dark = _buildDarkTheme(primaryColor: blueAccent);

  // Crimson Theme (Dark Variant with Crimson Accent)
  static final ThemeData crimson = _buildDarkTheme(primaryColor: crimsonAccent);

  static ThemeData _buildDarkTheme({required Color primaryColor}) {
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: darkBackground,
      canvasColor: darkBackground,
      cardColor: const Color(0xFF17171D),
      dividerColor: const Color(0xFF282832),

      colorScheme: ColorScheme.dark(
        primary: primaryColor,
        secondary: primaryColor,
        surface: const Color(0xFF17171D),
        onSurface: Colors.white,
        onPrimary: Colors.white,
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        },
      ),

      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,

      textTheme: ThemeData.dark().textTheme.apply(
        bodyColor: Colors.white.withValues(alpha: 0.95),
        displayColor: Colors.white.withValues(alpha: 0.95),
      ),
    );
  }

  // Light Theme
  static final ThemeData light = ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    scaffoldBackgroundColor: lightBackground,
    canvasColor: lightBackground,
    cardColor: const Color(0xFFFFFFFF),
    dividerColor: const Color(0xFFE2E2E8),

    colorScheme: const ColorScheme.light(
      primary: blueAccent,
      secondary: blueAccent,
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF141418),
      onPrimary: Colors.white,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: lightBackground,
      foregroundColor: Color(0xFF141418),
      elevation: 0,
      scrolledUnderElevation: 0,
    ),

    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
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
