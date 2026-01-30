// lib/billing/subscription_products.dart

/// Separate subscription IDs (NO base plans needed in Flutter)
const String kProMonthlyId = 'transcript_pro_monthly';
const String kProYearlyId = 'transcript_pro_yearly';

/// Lifetime one-time product (managed / non-consumable)
const String kProLifetimeId = 'transcript_pro_lifetime';

/// Query all 3
const Set<String> kProProductIds = {
  kProMonthlyId,
  kProYearlyId,
  kProLifetimeId,
};

bool isLifetimeProduct(String productId) => productId == kProLifetimeId;

bool isSubscriptionProduct(String productId) =>
    productId == kProMonthlyId || productId == kProYearlyId;

bool isMonthly(String productId) => productId == kProMonthlyId;
bool isYearly(String productId) => productId == kProYearlyId;
