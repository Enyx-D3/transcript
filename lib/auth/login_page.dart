// lib/auth/login_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/glass/glass_background.dart';
import '../ui/glass/glass_button.dart';
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';
import '../widgets/brand_logo.dart';
import '../widgets/status_pill.dart';

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

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _pwObscured = true;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  String _generateRandomString([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
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

  Future<void> _finishAuth(AuthResponse res) async {
    final user = res.user;
    if (user == null) {
      throw Exception('Supabase sign-in failed (no user returned).');
    }

    await _ensureProfile(user).timeout(
      const Duration(seconds: 15),
      onTimeout: () =>
          throw TimeoutException('Profile setup timed out. Please try again.'),
    );

    if (!mounted) return;
    setState(() => _busy = false);
    widget.onLoggedIn?.call();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _signInWithApple() async {
    if (_busy) return;

    if (!Platform.isIOS && !Platform.isMacOS) {
      setState(() => _error = 'Apple Sign In is available on Apple devices.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final rawNonce = _generateRandomString();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final idToken = credential.identityToken;
      if (idToken == null) {
        throw Exception('No identity token returned from Apple.');
      }

      final res = await _sb.auth
          .signInWithIdToken(
            provider: OAuthProvider.apple,
            idToken: idToken,
            nonce: rawNonce,
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
              'Supabase Apple sign-in timed out. Please try again.',
            ),
          );

      await _finishAuth(res);
    } on SignInWithAppleAuthorizationException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == AuthorizationErrorCode.canceled
            ? null
            : 'Apple Sign In failed';
      });
      debugPrint('Apple sign-in error: $e');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on TimeoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Apple login timed out. Please try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Apple Sign In failed';
      });
      debugPrint('Apple sign-in error: $e');
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_busy) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final GoogleSignIn signIn = GoogleSignIn.instance;
      String? rawNonce;

      if (Platform.isIOS || Platform.isMacOS) {
        rawNonce = _generateRandomString();
        final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
        await signIn.initialize(nonce: hashedNonce);
      } else {
        await signIn.initialize();
      }

      final googleAccount = await signIn.authenticate();
      final googleAuthentication = googleAccount.authentication;
      final idToken = googleAuthentication.idToken;

      if (idToken == null) {
        throw Exception(
          'No ID Token found. Check the Google client configuration.',
        );
      }

      final res = await _sb.auth
          .signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
            nonce: rawNonce,
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
              'Supabase Google sign-in timed out. Please try again.',
            ),
          );

      await _finishAuth(res);
    } on GoogleSignInException catch (e) {
      debugPrint('Google Sign-In failed [${e.code}]: ${e.description}');
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e.code == GoogleSignInExceptionCode.canceled) {
          _error = null;
        } else if (e.code ==
            GoogleSignInExceptionCode.clientConfigurationError) {
          _error =
              'Google Sign-In configuration error. Please check SHA-1, bundle ID, and client IDs.';
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
    } on TimeoutException catch (e) {
      debugPrint('Google login timed out: ${e.message}');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Google login timed out. Please try again.';
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
      final res = await _sb.auth
          .signInWithPassword(email: email, password: password)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
              'Email login timed out. Please try again.',
            ),
          );

      await _finishAuth(res);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on TimeoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Login timed out. Please try again.';
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
      backgroundColor: GlassTokens.backgroundColor(context),
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
                                    if (Platform.isIOS || Platform.isMacOS) ...[
                                      GlassButton(
                                        kind: GlassButtonKind.primary,
                                        onPressed: _busy
                                            ? null
                                            : _signInWithApple,
                                        label: _busy
                                            ? 'Signing in...'
                                            : 'Continue with Apple',
                                        icon: Icons.apple,
                                        loading: _busy,
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    GlassButton(
                                      kind: GlassButtonKind.primary,
                                      onPressed: _busy
                                          ? null
                                          : _signInWithGoogle,
                                      label: _busy
                                          ? 'Signing in...'
                                          : 'Continue with Google',
                                      icon: Icons.g_mobiledata,
                                      loading: _busy,
                                    ),
                                    if (widget.onBypass != null && kDebugMode == false) ...[
                                      const SizedBox(height: 12),
                                      GlassButton(
                                        kind: GlassButtonKind.secondary,
                                        onPressed: _busy
                                            ? null
                                            : () => widget.onBypass?.call(),
                                        label: 'Developer Bypass (Premium)',
                                        icon: Icons.developer_mode,
                                      ),
                                    ],
                                    const SizedBox(height: 12),
                                    const GlassDivider(
                                      height: 1,
                                      thickness: 0.8,
                                    ),
                                    const SizedBox(height: 12),
                                    // TextField(
                                    //   controller: _emailCtrl,
                                    //   keyboardType: TextInputType.emailAddress,
                                    //   textInputAction: TextInputAction.next,
                                    //   autofillHints: const [
                                    //     AutofillHints.username,
                                    //     AutofillHints.email,
                                    //   ],
                                    //   decoration: const InputDecoration(
                                    //     labelText: 'Email',
                                    //     border: OutlineInputBorder(),
                                    //   ),
                                    // ),
                                    // const SizedBox(height: 10),
                                    // TextField(
                                    //   controller: _passwordCtrl,
                                    //   obscureText: _pwObscured,
                                    //   textInputAction: TextInputAction.done,
                                    //   onSubmitted: (_) => _busy
                                    //       ? null
                                    //       : _signInWithEmailPassword(),
                                    //   autofillHints: const [
                                    //     AutofillHints.password,
                                    //   ],
                                    //   decoration: InputDecoration(
                                    //     labelText: 'Password',
                                    //     border: const OutlineInputBorder(),
                                    //     suffixIcon: IconButton(
                                    //       onPressed: _busy
                                    //           ? null
                                    //           : () => setState(
                                    //               () => _pwObscured =
                                    //                   !_pwObscured,
                                    //             ),
                                    //       icon: Icon(
                                    //         _pwObscured
                                    //             ? Icons.visibility
                                    //             : Icons.visibility_off,
                                    //       ),
                                    //     ),
                                    //   ),
                                    // ),
                                    // const SizedBox(height: 10),
                                    // GlassButton(
                                    //   kind: GlassButtonKind.secondary,
                                    //   onPressed: _busy
                                    //       ? null
                                    //       : _signInWithEmailPassword,
                                    //   label: _busy
                                    //       ? 'Signing in...'
                                    //       : 'Continue with Email',
                                    //   icon: Icons.email_outlined,
                                    // ),
                                    const SizedBox(height: 10),
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
