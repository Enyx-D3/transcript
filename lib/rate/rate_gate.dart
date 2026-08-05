import 'package:shared_preferences/shared_preferences.dart';

class RateGate {
  static const _kFirstUseAtKey = 'rate_first_use_at_ms'; // ✅ NEW
  static const _kLastPromptAtKey = 'rate_last_prompt_at_ms';
  static const _kHasRatedKey = 'rate_has_rated';
  static const _kDismissKey = 'rate_dismiss_count';

  // ✅ rules
  static const int delayFirstPromptDays = 2; // ✅ don't show first 2 days
  static const int cooldownDays = 3; // ✅ then at most once every 3 days
  static const int maxDismissBeforeStop = 2;

  static Future<void> _ensureFirstUseSaved(SharedPreferences prefs) async {
    final existing = prefs.getInt(_kFirstUseAtKey);
    if (existing != null) return;
    await prefs.setInt(_kFirstUseAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  static int _daysBetween(DateTime a, DateTime b) {
    // date-only diff (prevents hour/minute edge cases)
    final da = DateTime(a.year, a.month, a.day);
    final db = DateTime(b.year, b.month, b.day);
    return da.difference(db).inDays.abs();
  }

  /// ✅ Returns true/false ONLY (doesn't write lastPromptAt).
  static Future<bool> shouldPrompt() async {
    final prefs = await SharedPreferences.getInstance();

    await _ensureFirstUseSaved(prefs);

    // never ask again if rated
    if (prefs.getBool(_kHasRatedKey) == true) return false;

    // stop after too many dismisses
    final dismissCount = prefs.getInt(_kDismissKey) ?? 0;
    if (dismissCount >= maxDismissBeforeStop) return false;

    final now = DateTime.now();

    // ✅ block first 2 days
    final firstMs = prefs.getInt(_kFirstUseAtKey);
    if (firstMs != null) {
      final first = DateTime.fromMillisecondsSinceEpoch(firstMs);
      final daysSinceFirst = _daysBetween(now, first);
      if (daysSinceFirst < delayFirstPromptDays) return false;
    }

    // ✅ cooldown every 3 days
    final lastMs = prefs.getInt(_kLastPromptAtKey);
    if (lastMs != null) {
      final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
      final daysSinceLast = _daysBetween(now, last);
      if (daysSinceLast < cooldownDays) return false;
    }

    return true;
  }

  /// ✅ Call ONLY when you actually show the dialog.
  static Future<void> recordPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastPromptAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<void> onDismiss() async {
    final prefs = await SharedPreferences.getInstance();
    final d = prefs.getInt(_kDismissKey) ?? 0;
    await prefs.setInt(_kDismissKey, d + 1);
  }

  static Future<void> markRated() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHasRatedKey, true);
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFirstUseAtKey);
    await prefs.remove(_kLastPromptAtKey);
    await prefs.remove(_kHasRatedKey);
    await prefs.remove(_kDismissKey);
  }
}
