// lib/billing/subscription_service.dart
import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'subscription_products.dart';

class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService I = SubscriptionService._();

  final InAppPurchase _iap = InAppPurchase.instance;

  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  bool _initialized = false;

  /// Completers to allow UI to await a specific purchase outcome.
  final Map<String, Completer<bool>> _pending = {};

  /// Fires when any entitlement was successfully applied (purchase OR restore).
  final StreamController<void> _entitlementAppliedCtrl =
      StreamController<void>.broadcast();

  SupabaseClient get _sb => Supabase.instance.client;

  Future<void> initialize() async {
    if (_initialized) return;

    final available = await _iap.isAvailable();
    if (!available) {
      _initialized = true;
      return;
    }

    _purchaseSub = _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (_) {},
    );

    _initialized = true;
  }

  void dispose() {
    _purchaseSub?.cancel();
    _purchaseSub = null;
    _initialized = false;
  }

  Future<List<ProductDetails>> fetchProducts() async {
    await initialize();

    final resp = await _iap.queryProductDetails(kProProductIds);
    if (resp.error != null) {
      throw Exception(resp.error!.message);
    }

    final list = resp.productDetails.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return list;
  }

  /// Starts a purchase and returns true when the entitlement is applied.
  ///
  /// IMPORTANT: Billing cancellation / "already owned" sometimes does not emit
  /// a purchaseStream update on some devices/Play versions.
  /// So we use a shorter timeout to avoid "infinite loading" UX.
  Future<bool> buy(ProductDetails product) async {
    await initialize();

    // If another pending exists for same product, complete it false.
    final old = _pending.remove(product.id);
    if (old != null && !old.isCompleted) old.complete(false);

    final c = Completer<bool>();
    _pending[product.id] = c;

    final param = PurchaseParam(productDetails: product);

    // For subscriptions, use buyNonConsumable in this plugin.
    final started = await _iap.buyNonConsumable(purchaseParam: param);

    if (!started) {
      _pending.remove(product.id);
      return false;
    }

    // Shorter timeout prevents spinner hanging forever on cancel / already-owned.
    return c.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _pending.remove(product.id);
        return false;
      },
    );
  }

  /// Restore purchases and return true if an entitlement gets applied.
  /// This is useful for:
  /// - already-owned subscription
  /// - users who purchased before your server/profile updates worked
  Future<bool> restore({Duration timeout = const Duration(seconds: 30)}) async {
    await initialize();

    // Listen for the next successful entitlement application.
    final completer = Completer<bool>();
    late StreamSubscription sub;
    sub = _entitlementAppliedCtrl.stream.listen((_) {
      if (!completer.isCompleted) completer.complete(true);
    });

    try {
      await _iap.restorePurchases();

      // Wait for entitlementApplied or timeout
      final ok = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      return ok;
    } finally {
      await sub.cancel();
    }
  }

  // ---------------- Purchase handler ----------------

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      try {
        if (p.status == PurchaseStatus.pending) {
          continue;
        }

        if (p.status == PurchaseStatus.error) {
          _completePending(p.productID, false);
          continue;
        }

        if (p.status == PurchaseStatus.canceled) {
          _completePending(p.productID, false);
          continue;
        }

        if (p.status == PurchaseStatus.purchased ||
            p.status == PurchaseStatus.restored) {
          final ok = await _applyEntitlementFromPurchase(p);

          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }

          _completePending(p.productID, ok);

          if (ok) {
            // Signal restore/purchase success
            if (!_entitlementAppliedCtrl.isClosed) {
              _entitlementAppliedCtrl.add(null);
            }
          }
        }
      } catch (_) {
        _completePending(p.productID, false);
      }
    }
  }

  void _completePending(String productId, bool ok) {
    final c = _pending.remove(productId);
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  // ---------------- Entitlement logic ----------------

  /// Best practice:
  /// 1) Send purchaseToken to a Supabase Edge Function.
  /// 2) Server verifies with Google Play.
  /// 3) Server writes is_upgraded + real pro_expires_at.
  ///
  /// For now:
  /// - We TRY that server path.
  /// - Otherwise fall back to MVP update (requires UPDATE RLS policy).
Future<bool> _applyEntitlementFromPurchase(PurchaseDetails p) async {
  final user = _sb.auth.currentUser;
  if (user == null) return false;

  final token = p.verificationData.serverVerificationData;
  if (token.isEmpty) return false;

  try {
    final res = await _sb.functions.invoke(
      'verify-play-subscription', 
      body: {
        'product_id': p.productID,
        'purchase_token': token,
      },
    );

    final data = res.data;
    final ok = data is Map && (data['ok'] == true || data['success'] == true);
    if (!ok) {
      // ignore: avoid_print
      print('verify-play-entitlement failed: $data');
    }
    return ok;
  } catch (e) {
    // ignore: avoid_print
    print('verify-play-entitlement exception: $e');
    return false;
  }
}
}
