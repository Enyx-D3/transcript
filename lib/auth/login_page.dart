// lib/auth/login_page.dart
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

// ✅ Reuse shared glass widgets
import '../widgets/brand_logo.dart';
import '../widgets/status_pill.dart';

// ✅ Glass primitives
import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.onLoggedIn, this.onBypass});

  final VoidCallback? onLoggedIn;
  final VoidCallback? onBypass;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;

  // Email/password controllers (kept for later)
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _pwObscured = true;

  SupabaseClient get _sb => Supabase.instance.client;

  /// IMPORTANT:
  /// This must be the **Web application** OAuth client ID (server client ID).
  static const String _serverClientId =
      '909295591544-bd2add2ghl48rcdpr789rhkc6h2d5j33.apps.googleusercontent.com';

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureProfile(User user) async {
    final now = DateTime.now().toUtc();
    final trial = now.add(const Duration(days: 1));

    final existing = await _sb
        .from('profiles')
        .select('id,email,date_joined,is_upgraded,trial_expires_at')
        .eq('id', user.id)
        .maybeSingle();

    if (existing == null) {
      await _sb.from('profiles').insert({
        'id': user.id,
        'email': user.email,
        'date_joined': now.toIso8601String(),
        'is_upgraded': false,
        'trial_expires_at': trial.toIso8601String(),
      });
      return;
    }

    final updates = <String, dynamic>{};

    final existingEmail = existing['email'] as String?;
    if (user.email != null && user.email != existingEmail) {
      updates['email'] = user.email;
    }
    if (existing['date_joined'] == null) {
      updates['date_joined'] = now.toIso8601String();
    }
    if (existing['trial_expires_at'] == null) {
      updates['trial_expires_at'] = trial.toIso8601String();
    }
    if (existing['is_upgraded'] == null) {
      updates['is_upgraded'] = false;
    }

    if (updates.isNotEmpty) {
      await _sb.from('profiles').update(updates).eq('id', user.id);
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_busy) return;

    if (!Platform.isAndroid) {
      setState(
        () => _error = 'This login flow is configured for Android only.',
      );
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final GoogleSignIn signIn = GoogleSignIn.instance;

      await signIn.initialize(serverClientId: _serverClientId);

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

      await _ensureProfile(user);

      if (!mounted) return;
      setState(() => _busy = false);
      widget.onLoggedIn?.call();
    } on GoogleSignInException catch (e) {
      debugPrint('Google Sign-In failed [${e.code}]: ${e.description}');
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e.code == GoogleSignInExceptionCode.canceled) {
          // User dismissed or tapped outside; cleanly reset state
          _error = null;
        } else if (e.code == GoogleSignInExceptionCode.clientConfigurationError) {
          _error = 'Google Sign-In configuration error. Please check SHA-1 & Client ID.';
        } else {
          _error = e.description ?? 'Google Sign-In failed (${e.code.name}).';
        }
      });
    } on AuthException catch (e) {
      debugPrint('Google -> Supabase auth failed: ${e.message}');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on PostgrestException catch (e) {
      debugPrint('Profile sync failed after Google sign-in: ${e.message}');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message.isEmpty ? 'Profile setup failed.' : e.message;
      });
    } catch (e) {
      debugPrint('Google login failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _signInWithEmailPassword() async {
    if (_busy) return;

    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter email and password.');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await _sb.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = res.user;
      if (user == null) {
        throw Exception('Login failed (no user returned).');
      }

      await _ensureProfile(user);

      if (!mounted) return;
      setState(() => _busy = false);
      widget.onLoggedIn?.call();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Login Failed, Provide valid credentials';
      });
    }
  }

  Future<void> _openTerms() async {
    final uri = Uri.parse(
      'https://enyx.app/privacy/meeting-transcript-unlimited',
    );

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      debugPrint('Could not launch: $uri');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = GlassTokens.fg(context, alpha: 0.92);
    final muted = GlassTokens.muted(context, alpha: 0.72);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: GlassBackground(
        child: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => FocusScope.of(context).unfocus(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Align(
                                alignment: Alignment.center,
                                child: BrandLogo(),
                              ),
                              const SizedBox(height: 22),

                              Text(
                                'Welcome back',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: fg,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Sign in to sync your transcripts and unlock AI features.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: muted,
                                  fontWeight: FontWeight.w600,
                                  height: 1.25,
                                ),
                              ),
                              const SizedBox(height: 24),

                              GlassCard(
                                variant: GlassCardVariant.panel,
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // ✅ Google (glass button)
                                    GlassButton(
                                       kind: GlassButtonKind.primary,
                                       onPressed: _busy
                                           ? null
                                           : _signInWithGoogle,
                                       label: _busy
                                           ? 'Signing in…'
                                           : 'Continue with Google',
                                       icon: Icons.g_mobiledata,
                                       loading: _busy,
                                    ),

                                    const SizedBox(height: 12),

                                    // 🛠️ Developer Bypass (Skip Login)
                                    GlassButton(
                                      kind: GlassButtonKind.secondary,
                                      onPressed: _busy
                                          ? null
                                          : () {
                                              if (widget.onBypass != null) {
                                                widget.onBypass!();
                                              } else {
                                                widget.onLoggedIn?.call();
                                              }
                                            },
                                      label: 'Developer Bypass (Skip Login)',
                                      icon: Icons.developer_mode,
                                    ),

                                    const SizedBox(height: 12),
                                    const GlassDivider(
                                      height: 1,
                                      thickness: 0.8,
                                    ),
                                    const SizedBox(height: 12),

                                    // ✅ Keep the email/password section commented for now (unchanged)
                                    // If you later enable it, wrap fields in GlassCard tile
                                    // and use GlassButton for submit.
                                    RichText(
                                      textAlign: TextAlign.center,
                                      text: TextSpan(
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: muted.withValues(alpha: 0.9),
                                          fontWeight: FontWeight.w600,
                                        ),
                                        children: [
                                          const TextSpan(
                                            text:
                                                'By continuing you agree to our ',
                                          ),
                                          TextSpan(
                                            text: 'Terms and Privacy Policy',
                                            style: TextStyle(
                                              color: fg,
                                              decoration:
                                                  TextDecoration.underline,
                                              fontWeight: FontWeight.w800,
                                            ),
                                            recognizer: TapGestureRecognizer()
                                              ..onTap = _openTerms,
                                          ),
                                          const TextSpan(text: '.'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              if (_error != null) ...[
                                const SizedBox(height: 14),
                                Align(
                                  alignment: Alignment.center,
                                  child: StatusPill(
                                    text: _error!,
                                    isError: true,
                                  ),
                                ),
                              ],

                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
