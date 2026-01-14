/// Subscription product (with base plans: monthly + yearly)
const String kProSubscriptionId = 'transcript_pro';

/// Lifetime one-time product (managed / non-consumable)
const String kProLifetimeId = 'transcript_pro_lifetime';

/// Query both
const Set<String> kProProductIds = {kProSubscriptionId, kProLifetimeId};

bool isLifetimeProduct(String productId) => productId == kProLifetimeId;
bool isSubscriptionProduct(String productId) => productId == kProSubscriptionId;
