// lib/billing/subscription_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
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

  // ✅ NEW: expose last server result for UI
  String? lastVerifyCode;   // e.g. TOKEN_ALREADY_CLAIMED
  String? lastVerifyError;  // human readable

  // ✅ IMPORTANT: must match your deployed edge function name
  static const String _fnVerify = 'verify-play-subscription';

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

    // Keep a stable order: lifetime, monthly, yearly
    final list = resp.productDetails.toList()
      ..sort((a, b) {
        int rank(String id) {
          if (id == kProLifetimeId) return 0;
          if (id == kProMonthlyId) return 1;
          if (id == kProYearlyId) return 2;
          return 99;
        }

        final ra = rank(a.id);
        final rb = rank(b.id);
        if (ra != rb) return ra.compareTo(rb);
        return a.id.compareTo(b.id);
      });

    return list;
  }

  /// Starts a purchase and returns true when the entitlement is applied.
  ///
  /// IMPORTANT: Billing cancellation / "already owned" sometimes does not emit
  /// a purchaseStream update on some devices/Play versions.
  /// So we use a shorter timeout to avoid "infinite loading" UX.
  Future<bool> buy(ProductDetails product) async {
    await initialize();

    // reset last verify info
    lastVerifyCode = null;
    lastVerifyError = null;

    // If another pending exists for same product, complete it false.
    final old = _pending.remove(product.id);
    if (old != null && !old.isCompleted) old.complete(false);

    final c = Completer<bool>();
    _pending[product.id] = c;

    final param = PurchaseParam(productDetails: product);

    // For subscriptions + non-consumables, use buyNonConsumable in this plugin.
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
  Future<bool> restore({Duration timeout = const Duration(seconds: 30)}) async {
    await initialize();

    // reset last verify info
    lastVerifyCode = null;
    lastVerifyError = null;

    final completer = Completer<bool>();
    late StreamSubscription sub;
    sub = _entitlementAppliedCtrl.stream.listen((_) {
      if (!completer.isCompleted) completer.complete(true);
    });

    try {
      await _iap.restorePurchases();

      final ok = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      return ok;
    } finally {
      await sub.cancel();
    }
  }

  /// Immediate reconcile: query past purchases and verify tokens.
  Future<bool> reconcileNow({Duration timeout = const Duration(seconds: 25)}) async {
    await initialize();

    // reset last verify info
    lastVerifyCode = null;
    lastVerifyError = null;

    // We consider success if any entitlement gets applied.
    final completer = Completer<bool>();
    late StreamSubscription sub;
    sub = _entitlementAppliedCtrl.stream.listen((_) {
      if (!completer.isCompleted) completer.complete(true);
    });

    try {
      // Android: query past purchases + verify them
      if (Platform.isAndroid) {
        final addition =
            _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
        final resp = await addition.queryPastPurchases();

        for (final p in resp.pastPurchases) {
          if (!kProProductIds.contains(p.productID)) continue;

          final ok = await _applyEntitlementFromPurchase(p);

          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }

          if (ok && !_entitlementAppliedCtrl.isClosed) {
            _entitlementAppliedCtrl.add(null);
          }
        }
      } else {
        // fallback for other platforms
        await _iap.restorePurchases();
      }

      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }

  // ---------------- Purchase handler ----------------

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      try {
        if (p.status == PurchaseStatus.pending) continue;

        if (p.status == PurchaseStatus.error ||
            p.status == PurchaseStatus.canceled) {
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

  /// Prefer BillingClient token for Android.
  String? extractPurchaseToken(PurchaseDetails p) {
    if (Platform.isAndroid && p is GooglePlayPurchaseDetails) {
      final token = p.billingClientPurchase.purchaseToken;
      if (token.isNotEmpty) return token;
    }

    // Fallback: localVerificationData sometimes contains purchaseToken JSON
    if (Platform.isAndroid) {
      try {
        final obj = jsonDecode(p.verificationData.localVerificationData);
        final token = obj['purchaseToken'];
        if (token is String && token.isNotEmpty) return token;
      } catch (_) {}
    }

    // Last fallback: serverVerificationData sometimes holds token too
    final sv = p.verificationData.serverVerificationData;
    if (Platform.isAndroid && sv.isNotEmpty) return sv;

    return null;
  }

  Future<bool> _applyEntitlementFromPurchase(PurchaseDetails p) async {
    final user = _sb.auth.currentUser;
    if (user == null) return false;

    // Only verify known products
    if (!kProProductIds.contains(p.productID)) return false;

    final token = extractPurchaseToken(p);
    if (token == null || token.isEmpty) return false;

    try {
      // ✅ Supabase client automatically includes Authorization for the signed-in user.
      final res = await _sb.functions.invoke(
        _fnVerify,
        body: {
          'product_id': p.productID,
          'purchase_token': token,
        },
      );

      final data = res.data;

      // store last error/code for UI
      if (data is Map) {
        lastVerifyCode = data['code'] as String?;
        lastVerifyError = data['error'] as String?;
      } else {
        lastVerifyCode = null;
        lastVerifyError = null;
      }

      final ok = data is Map && (data['ok'] == true || data['success'] == true);
      if (!ok) {
        // ignore: avoid_print
        debugPrint('$_fnVerify failed: $data');
      }
      return ok;
    } catch (e) {
      // ignore: avoid_print
      debugPrint('$_fnVerify exception: $e');
      lastVerifyCode = null;
      lastVerifyError = e.toString();
      return false;
    }
  }
}
