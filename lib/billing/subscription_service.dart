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
  Future<bool> buy(ProductDetails product) async {
    await initialize();

    final c = Completer<bool>();
    _pending[product.id] = c;

    final param = PurchaseParam(productDetails: product);

    // For subscriptions, use buyNonConsumable in this plugin.
    final started = await _iap.buyNonConsumable(purchaseParam: param);

    if (!started) {
      _pending.remove(product.id);
      return false;
    }

    return c.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        _pending.remove(product.id);
        return false;
      },
    );
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
  /// - We TRY that server path if your function exists.
  /// - Otherwise we fall back to a simple MVP update that does not guess duration.
  Future<bool> _applyEntitlementFromPurchase(PurchaseDetails p) async {
    final user = _sb.auth.currentUser;
    if (user == null) return false;

    final token = p.verificationData.serverVerificationData;

    // ---- 1) Try server verification (if you add it later) ----
    if (token.isNotEmpty) {
      try {
        final res = await _sb.functions.invoke(
          'verify-play-subscription',
          body: {
            'product_id': p.productID,
            'purchase_token': token,
          },
        );

        // Treat it as success if function returns a success flag
        final data = res.data;
        if (data is Map &&
            (data['ok'] == true || data['success'] == true)) {
          return true; // server should have updated profiles
        }
      } catch (_) {
        // ignore -> fallback
      }
    }

    // ---- 2) MVP fallback (no duration guessing) ----
    final now = DateTime.now().toUtc();

    await _sb.from('profiles').update({
      'is_upgraded': true,
      // We don't know monthly vs yearly here — don't guess.
      // Keep null so your _proActive logic stays true for upgraded users.
      'pro_expires_at': null,
      // End trial immediately
      'trial_expires_at': now.toIso8601String(),
    }).eq('id', user.id);

    return true;
  }
}
