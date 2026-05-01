import 'dart:io';

import 'package:flutter/material.dart';

import '../billing/subscription_service.dart';
import 'paywall_page.dart';

Future<bool> ensureIosPremiumForTranscription(
  BuildContext context, {
  VoidCallback? onUpgradeSuccess,
}) async {
  if (!Platform.isIOS) return true;

  await SubscriptionService.I.initializePurchase();
  if (SubscriptionService.I.premiumActive) return true;
  if (!context.mounted) return false;

  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PaywallPage(
        onPremiumUnlocked: () async {
          onUpgradeSuccess?.call();
        },
      ),
    ),
  );

  return SubscriptionService.I.premiumActive;
}
