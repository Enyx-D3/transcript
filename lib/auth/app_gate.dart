// lib/auth/app_gate.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home_shell.dart';
import '../billing/subscription_service.dart'; // ✅ ADD
import 'login_page.dart';
import 'eligibility_gate.dart';

class AppGate extends StatefulWidget {
  const AppGate({super.key, required this.initialEligibility});

  final EligibilityGateResult initialEligibility;

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  late final SupabaseClient _sb;
  StreamSubscription<AuthState>? _sub;

  Session? _session;
  bool _ready = false;

  late EligibilityGateResult _eligibility;

  // When true -> show splash screen (eligibility checking)
  bool _checkingEligibility = false;

  @override
  void initState() {
    super.initState();
    _sb = Supabase.instance.client;

    _eligibility = widget.initialEligibility;

    _session = _sb.auth.currentSession;
    _ready = true;

    // ✅ If already logged in at app start, show splash then check eligibility
    if (_session != null) {
      _checkingEligibility = true;
      _runEligibilityCheck();
    }

    // ✅ React to login/logout
    _sub = _sb.auth.onAuthStateChange.listen((state) {
      if (!mounted) return;

      final newSession = state.session;

      setState(() {
        _session = newSession;
        _ready = true;

        // ✅ If logged in -> show splash until eligibility check finishes
        _checkingEligibility = newSession != null;
      });

      if (newSession != null) {
        _runEligibilityCheck();
      } else {
        // logged out
        setState(() {
          // iOS review requirement: keep non-account features available in guest mode.
          _eligibility = EligibilityGateResult(eligible: Platform.isIOS);
          _checkingEligibility = false;
        });
      }
    });
  }

  // ✅ One place that does "reconcile + check" with timeouts
  Future<EligibilityGateResult> _reconcileAndCheck() async {
    // Step A: try to reconcile purchases (important after purchase/restart)
    try {
      await SubscriptionService.I
          .reconcileNow(timeout: const Duration(seconds: 18))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Step B: read eligibility (timed)
    try {
      return await checkEligibilityOnce(_sb).timeout(
        const Duration(seconds: 5),
        onTimeout: () => const EligibilityGateResult(eligible: false),
      );
    } catch (e) {
      return EligibilityGateResult(eligible: false, error: e.toString());
    }
  }

  Future<void> _runEligibilityCheck() async {
    try {
      final res = await _reconcileAndCheck();

      if (!mounted) return;
      setState(() {
        _eligibility = res;
        _checkingEligibility = false; // ✅ splash -> homeshell
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eligibility = EligibilityGateResult(
          eligible: false,
          error: e.toString(),
        );
        _checkingEligibility = false;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ✅ Used by HomeShell Retry button
  Future<EligibilityGateResult> _retryEligibility() async {
    if (!mounted) return const EligibilityGateResult(eligible: false);

    setState(() => _checkingEligibility = true); // show splash-like loader

    final res = await _reconcileAndCheck();

    if (!mounted) return res;
    setState(() {
      _eligibility = res;
      _checkingEligibility = false;
    });
    return res;
  }

  Future<EligibilityGateResult> _retryGuestEligibility() async {
    return EligibilityGateResult(eligible: Platform.isIOS);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const _GateSplash(status: 'Preparing…');
    }

    // ✅ iOS only: guest mode for non-account features (Guideline 5.1.1(v)).
    if (_session == null) {
      if (Platform.isIOS) {
        return HomeShell(
          initialEligible: true,
          eligibilityError: null,
          onRetryEligibility: _retryGuestEligibility,
        );
      }
      return const LoginPage();
    }

    // ✅ Logged in -> Splash until eligibility done
    if (_checkingEligibility) {
      return const _GateSplash(status: 'Initializing…');
    }

    // ✅ Logged in + eligibility ready -> Home
    return HomeShell(
      initialEligible: _eligibility.eligible,
      eligibilityError: _eligibility.error,
      onRetryEligibility: _retryEligibility,
    );
  }
}

/// A lightweight splash UI used by AppGate (NOT your main SplashGate boot screen)
class _GateSplash extends StatelessWidget {
  const _GateSplash({required this.status, this.failed = false, this.onRetry});

  final String status;

  // ✅ Optional: if you ever want to reuse it for an error state like SplashGate
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ---- Brand header ----
                  Container(
                    width: 86,
                    height: 86,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF12131A),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.35),
                      ),
                      // boxShadow: [
                      //   BoxShadow(
                      //     blurRadius: 26,
                      //     offset: const Offset(0, 14),
                      //     color: const Color(0xFF8E7CFF).withOpacity(0.18),
                      //   ),
                      // ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.asset(
                        'assets/logo/transcript-transparent.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  Text(
                    'Starting up',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ---- Status pill ----
                  _StatusPill(
                    text: status,
                    isError: failed,
                  ),

                  const SizedBox(height: 14),

                  // ---- Progress / error card ----
                  Card(
                    elevation: 0.6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          if (!failed) ...[
                            const LinearProgressIndicator(minHeight: 3,color: Colors.white,backgroundColor: Colors.black),
                            const SizedBox(height: 12),
                          ] else ...[
                            const Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.error_outline,
                                    color: Colors.redAccent),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'We couldn’t finish setup. Please try again.',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: onRetry,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.isError});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.redAccent : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isError
                ? Icons.warning_amber_rounded
                : Icons.hourglass_bottom_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, height: 1.15),
            ),
          ),
        ],
      ),
    );
  }
}
