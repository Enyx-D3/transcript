import 'package:shared_preferences/shared_preferences.dart';

class ModelDownloadConsent {
  static const _kKey = 'qwen_model_download_decision';
  static const accepted = 'accepted';
  static const declined = 'declined';

  static Future<String?> getDecision() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kKey);
  }

  static Future<bool> hasAccepted() async => (await getDecision()) == accepted;
  static Future<bool> hasDeclined() async => (await getDecision()) == declined;
  static Future<bool> hasDecided() async => (await getDecision()) != null;

  static Future<void> setAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, accepted);
  }

  static Future<void> setDeclined() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, declined);
  }

  /// Debug / dev tool: makes the prompt appear again next launch.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }
}
