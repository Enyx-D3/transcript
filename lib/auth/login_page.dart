// lib/auth/login_page.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.onLoggedIn});

  final VoidCallback? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;

  SupabaseClient get _sb => Supabase.instance.client;

  /// IMPORTANT:
  /// This must be the **Web application** OAuth client ID
  /// (aka server client ID).
  static const String _serverClientId = '909295591544-bd2add2ghl48rcdpr789rhkc6h2d5j33.apps.googleusercontent.com';

  Future<void> _signInWithGoogle() async {
  if (_busy) return;

  if (!Platform.isAndroid) {
    setState(() => _error = 'This login flow is configured for Android only.');
    return;
  }

  setState(() {
    _busy = true;
    _error = null;
  });

  try {
    final GoogleSignIn signIn = GoogleSignIn.instance;

    await signIn.initialize(
      serverClientId: _serverClientId, // Web OAuth client ID
    );

    final googleAccount = await signIn.authenticate();

    final googleAuthentication = googleAccount.authentication;
    final idToken = googleAuthentication.idToken;

    if (idToken == null) {
      throw Exception('No ID Token found. Check your serverClientId.');
    }

    final res = await _sb.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );

    final user = res.user;
    if (user == null) {
      throw Exception('Supabase sign-in failed (no user returned).');
    }

    final now = DateTime.now().toUtc();

    await _sb.from('profiles').upsert({
      'id': user.id,
      'email': user.email,
      'date_joined': now.toIso8601String(),
      'is_upgraded': false,
      'trial_expires_at': now.add(const Duration(days: 3)).toIso8601String(),
    });

    if (!mounted) return;
    setState(() => _busy = false);
    widget.onLoggedIn?.call();
  } catch (e) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e.toString();
    });
  }
}

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.center,
                    child: Container(
                      height: 84,
                      width: 84,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A22),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: const Color(0xFF8E7CFF).withValues(alpha: 0.35),
                        ),
                      ),
                      child: const Icon(
                        Icons.mic_rounded,
                        size: 40,
                        color: Color(0xFF8E7CFF),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),

                  Text(
                    'Welcome back',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sign in to sync your transcripts and unlock AI features.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),

                  Card(
                    elevation: 0.6,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy ? null : _signInWithGoogle,
                            icon: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.g_mobiledata),
                            label: Text(_busy ? 'Signing in…' : 'Continue with Google'),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'By continuing you agree to our Terms and Privacy Policy.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],

                  const SizedBox(height: 20),
                  const Text(
                    'Android-only Google + Supabase sign-in.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
