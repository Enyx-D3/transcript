import 'package:shared_preferences/shared_preferences.dart';

class AppPrefs {
  static const String kAllowLongRecording = 'allow_long_recording';

  static Future<bool> getAllowLongRecording() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kAllowLongRecording) ?? false;
  }

  static Future<void> setAllowLongRecording(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAllowLongRecording, value);
  }
}
