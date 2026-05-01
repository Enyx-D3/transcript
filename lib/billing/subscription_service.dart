// lib/billing/subscription_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'subscription_products.dart';

class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService I = SubscriptionService._();

  final InAppPurchase _iap = InAppPurchase.instance;

  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  bool _initialized = false;
  bool _storeAvailable = false;
  bool _premiumActive = false;
  String? _activeProductId;

  /// Completers to allow UI to await a specific purchase outcome.
  final Map<String, Completer<bool>> _pending = {};

  /// Fires when any entitlement was successfully applied (purchase OR restore).
  final StreamController<void> _entitlementAppliedCtrl =
      StreamController<void>.broadcast();
  final StreamController<bool> _premiumStateCtrl =
      StreamController<bool>.broadcast();

  SupabaseClient get _sb => Supabase.instance.client;

  // ✅ NEW: expose last server result for UI
  String? lastVerifyCode;   // e.g. TOKEN_ALREADY_CLAIMED
  String? lastVerifyError;  // human readable
  String? lastStoreError;

  // ✅ IMPORTANT: must match your deployed edge function names
  static const String _fnVerifyAndroid = 'verify-play-subscription';
  static const String _fnVerifyApple = 'verify-apple-subscription';
  static const String _kPremiumActive = 'premium_active_local';
  static const String _kActiveProductId = 'premium_active_product_id';

  bool get premiumActive => _premiumActive;
  String? get activeProductId => _activeProductId;
  Stream<bool> get premiumState => _premiumStateCtrl.stream;

  Future<void> initializePurchase() => initialize();

  Future<bool> purchaseSubscription(ProductDetails product) => buy(product);

  Future<bool> restorePurchases({
    Duration timeout = const Duration(seconds: 30),
  }) => restore(timeout: timeout);

  Future<void> listenToPurchaseUpdates() => initialize();

  Future<void> initialize() async {
    if (_initialized) return;

    await _loadLocalPremiumState();

    final available = await _iap.isAvailable();
    _storeAvailable = available;
    if (!available) {
      if (Platform.isIOS) {
        lastStoreError = 'STORE_UNAVAILABLE';
      }
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

  Future<void> _loadLocalPremiumState() async {
    final sp = await SharedPreferences.getInstance();
    _premiumActive = sp.getBool(_kPremiumActive) ?? false;
    _activeProductId = sp.getString(_kActiveProductId);
  }

  Future<void> _setPremiumActive(bool value, {String? productId}) async {
    _premiumActive = value;
    _activeProductId = value ? productId : null;

    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPremiumActive, value);
    if (value && productId != null) {
      await sp.setString(_kActiveProductId, productId);
    } else {
      await sp.remove(_kActiveProductId);
    }

    if (!_premiumStateCtrl.isClosed) {
      _premiumStateCtrl.add(_premiumActive);
    }
  }

  Future<List<ProductDetails>> fetchProducts() async {
    await initialize();

    final resp = await _iap.queryProductDetails(kProProductIds);
    if (resp.error != null) {
      if (Platform.isIOS) {
        lastStoreError = 'STORE_QUERY_ERROR: ${resp.error!.message}';
      }
      throw Exception(resp.error!.message);
    }

    if (Platform.isIOS && resp.productDetails.isEmpty) {
      final missing = resp.notFoundIDs.join(', ');
      lastStoreError = 'STORE_PRODUCTS_UNAVAILABLE: $missing';
      throw Exception(
        'STORE_PRODUCTS_UNAVAILABLE: No products returned from App Store. '
        'Missing: $missing',
      );
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
    debugPrint('[IAP] buy start: ${product.id} (${product.price})');
    if (Platform.isIOS && !_storeAvailable) {
      lastStoreError = 'STORE_UNAVAILABLE';
      debugPrint('[IAP] store unavailable on iOS');
      return false;
    }

    // reset last verify info
    lastVerifyCode = null;
    lastVerifyError = null;
    lastStoreError = null;

    // If another pending exists for same product, complete it false.
    final old = _pending.remove(product.id);
    if (old != null && !old.isCompleted) old.complete(false);

    final c = Completer<bool>();
    _pending[product.id] = c;

    final param = PurchaseParam(productDetails: product);

    // For subscriptions + non-consumables, use buyNonConsumable in this plugin.
    final started = await _iap.buyNonConsumable(purchaseParam: param);
    debugPrint('[IAP] buyNonConsumable started=$started product=${product.id}');

    if (!started) {
      lastStoreError = 'BUY_NOT_STARTED';
      _pending.remove(product.id);
      return false;
    }

    // Shorter timeout prevents spinner hanging forever on cancel / already-owned.
    return c.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        lastStoreError = 'PURCHASE_TIMEOUT_NO_UPDATE';
        debugPrint('[IAP] timeout waiting purchaseStream update for ${product.id}');
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
    lastStoreError = null;

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
    lastStoreError = null;

    // We consider success if any entitlement gets applied.
    final completer = Completer<bool>();
    late StreamSubscription sub;
    sub = _entitlementAppliedCtrl.stream.listen((_) {
      if (!completer.isCompleted) completer.complete(true);
    });

    try {
      if (Platform.isAndroid) {
        // Android: query past purchases + verify them
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
      } else if (Platform.isIOS) {
        // iOS: restore purchases triggers purchaseStream updates
        await _iap.restorePurchases();
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
        debugPrint(
          '[IAP] update product=${p.productID} status=${p.status} pendingComplete=${p.pendingCompletePurchase}',
        );
        if (p.status == PurchaseStatus.pending) continue;

        if (p.status == PurchaseStatus.error ||
            p.status == PurchaseStatus.canceled) {
          if (p.status == PurchaseStatus.error) {
            final msg = p.error?.message ?? 'unknown';
            final code = p.error?.code ?? 'unknown';
            lastStoreError = 'PURCHASE_ERROR:$code:$msg';
            debugPrint('[IAP] purchase error code=$code message=$msg');
          } else {
            lastStoreError = 'PURCHASE_CANCELED';
            debugPrint('[IAP] purchase canceled by user');
          }
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
        lastStoreError = 'PURCHASE_HANDLER_EXCEPTION';
        _completePending(p.productID, false);
      }
    }
  }

  void _completePending(String productId, bool ok) {
    final c = _pending.remove(productId);
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  // ---------------- Entitlement logic ----------------

  /// Prefer BillingClient token for Android, App Store receipt for iOS.
  String? extractPurchaseToken(PurchaseDetails p) {
    // ---- iOS: use serverVerificationData (App Store receipt or JWS transaction) ----
    if (Platform.isIOS) {
      final sv = p.verificationData.serverVerificationData;
      if (sv.isNotEmpty) return sv;
      final lv = p.verificationData.localVerificationData;
      if (lv.isNotEmpty) return lv;
      return null;
    }

    // ---- Android: prefer billingClient purchaseToken ----
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
    // Only verify known products
    if (!kProProductIds.contains(p.productID)) return false;

    // Local entitlement is enough to unlock premium on device.
    await _setPremiumActive(true, productId: p.productID);

    final user = _sb.auth.currentUser;
    if (user == null) return true;

    final token = extractPurchaseToken(p);
    if (token == null || token.isEmpty) return true;

    try {
      // Pick the right edge function based on platform
      final fnName = Platform.isIOS ? _fnVerifyApple : _fnVerifyAndroid;

      // ✅ Supabase client automatically includes Authorization for the signed-in user.
      final res = await _sb.functions.invoke(
        fnName,
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
        debugPrint('$fnName failed: $data');
      }
      return true;
    } catch (e) {
      debugPrint('verify exception: $e');
      lastVerifyCode = null;
      lastVerifyError = e.toString();
      return true;
    }
  }
}
