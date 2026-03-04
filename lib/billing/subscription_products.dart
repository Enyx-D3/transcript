// lib/billing/subscription_products.dart
import 'dart:io';

/// Separate subscription IDs (NO base plans needed in Flutter)
const String kProMonthlyAndroidId = 'transcript_pro_monthly';
const String kProMonthlyAppleId = 'transcript_pro_monthly_apple';
const String kProYearlyId = 'transcript_pro_yearly';

String get kProMonthlyId =>
    Platform.isIOS ? kProMonthlyAppleId : kProMonthlyAndroidId;

/// Lifetime one-time product (managed / non-consumable)
const String kProLifetimeId = 'transcript_pro_lifetime';

/// Query all 3
Set<String> get kProProductIds => {
  kProMonthlyId,
  kProYearlyId,
  kProLifetimeId,
};

bool isLifetimeProduct(String productId) => productId == kProLifetimeId;

bool isSubscriptionProduct(String productId) =>
    productId == kProMonthlyId || productId == kProYearlyId;

bool isMonthly(String productId) => productId == kProMonthlyId;
bool isYearly(String productId) => productId == kProYearlyId;
