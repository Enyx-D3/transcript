// lib/billing/subscription_products.dart

/// Your single Pro subscription product ID from Play Console.
/// This product contains two base plans (monthly + yearly) configured in Play.
const String kProSubscriptionId = 'transcript_pro';

/// The IAP plugin still needs a Set of product IDs to query.
const Set<String> kProProductIds = {kProSubscriptionId};
