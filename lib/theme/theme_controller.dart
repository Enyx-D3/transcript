import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode {
  system,
  dark,
  crimson,
  light,
}

class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const String _kPrefThemeMode = 'pref_theme_mode';

  AppThemeMode _appThemeMode = AppThemeMode.system;
  AppThemeMode get appThemeMode => _appThemeMode;

  ThemeMode get themeMode {
    switch (_appThemeMode) {
      case AppThemeMode.crimson:
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }

  bool get isCrimson => _appThemeMode == AppThemeMode.crimson;

  Future<void> init() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString(_kPrefThemeMode);
      if (saved == 'crimson') {
        _appThemeMode = AppThemeMode.crimson;
      } else if (saved == 'dark') {
        _appThemeMode = AppThemeMode.dark;
      } else if (saved == 'light') {
        _appThemeMode = AppThemeMode.light;
      } else {
        _appThemeMode = AppThemeMode.system;
      }
    } catch (_) {
      _appThemeMode = AppThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setAppThemeMode(AppThemeMode mode) async {
    if (_appThemeMode == mode) return;
    _appThemeMode = mode;
    notifyListeners();

    try {
      final sp = await SharedPreferences.getInstance();
      String val = 'system';
      if (mode == AppThemeMode.crimson) val = 'crimson';
      if (mode == AppThemeMode.dark) val = 'dark';
      if (mode == AppThemeMode.light) val = 'light';
      await sp.setString(_kPrefThemeMode, val);
    } catch (_) {}
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    switch (mode) {
      case ThemeMode.dark:
        await setAppThemeMode(AppThemeMode.dark);
        break;
      case ThemeMode.light:
        await setAppThemeMode(AppThemeMode.light);
        break;
      case ThemeMode.system:
        await setAppThemeMode(AppThemeMode.system);
        break;
    }
  }
}
