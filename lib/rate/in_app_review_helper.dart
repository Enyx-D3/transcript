import 'package:in_app_review/in_app_review.dart';

class InAppReviewHelper {
  static final InAppReview _inAppReview = InAppReview.instance;

  /// Best-effort: system may or may not show the dialog.
  static Future<void> requestReviewOrStoreFallback() async {
    try {
      final available = await _inAppReview.isAvailable();
      if (available) {
        await _inAppReview.requestReview();
      } else {
        await _inAppReview.openStoreListing();
      }
    } catch (_) {
      // If anything fails, do nothing (never crash UX)
    }
  }
}
