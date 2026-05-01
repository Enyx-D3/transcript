// // lib/auth/login_page.dart
// import 'dart:convert';
// import 'dart:math';
// import 'dart:io' show Platform;

// import 'package:crypto/crypto.dart';
// import 'package:flutter/gestures.dart';
// import 'package:flutter/material.dart';
// import 'package:google_sign_in/google_sign_in.dart';
// import 'package:sign_in_with_apple/sign_in_with_apple.dart';
// import 'package:supabase_flutter/supabase_flutter.dart';
// import 'package:url_launcher/url_launcher.dart';

// // ✅ Reuse shared glass widgets
// import '../widgets/brand_logo.dart';
// import '../widgets/status_pill.dart';

// // ✅ Glass primitives
// import '../ui/glass/glass_background.dart';
// import '../ui/glass/glass_card.dart';
// import '../ui/glass/glass_tokens.dart';

// class LoginPage extends StatefulWidget {
//   const LoginPage({super.key, this.onLoggedIn});

//   final VoidCallback? onLoggedIn;

//   @override
//   State<LoginPage> createState() => _LoginPageState();
// }

// class _LoginPageState extends State<LoginPage> {
//   bool _busy = false;
//   String? _error;

//   // Email/password controllers (kept for later)
//   final _emailCtrl = TextEditingController();
//   final _passwordCtrl = TextEditingController();
//   bool _pwObscured = true;

//   SupabaseClient get _sb => Supabase.instance.client;

//   /// IMPORTANT:
//   /// This must be the **Web application** OAuth client ID (server client ID).
//   static const String _serverClientId =
//       '909295591544-bd2add2ghl48rcdpr789rhkc6h2d5j33.apps.googleusercontent.com';

//   @override
//   void dispose() {
//     _emailCtrl.dispose();
//     _passwordCtrl.dispose();
//     super.dispose();
//   }

//   /// Generate a random string for nonce
//   String _generateRandomString([int length = 32]) {
//     const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
//     final random = Random.secure();
//     return List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
//   }

//   Future<void> _ensureProfile(User user) async {
//     final now = DateTime.now().toUtc();

//     final existing = await _sb
//         .from('profiles')
//         .select('id,email,date_joined,is_upgraded,trial_expires_at')
//         .eq('id', user.id)
//         .maybeSingle();

//     if (existing == null) {
//       await _sb.from('profiles').insert({
//         'id': user.id,
//         'email': user.email,
//         'date_joined': now.toIso8601String(),
//         'is_upgraded': false,
//       });
//       return;
//     }

//     final updates = <String, dynamic>{};

//     final existingEmail = existing['email'] as String?;
//     if (user.email != null && user.email != existingEmail) {
//       updates['email'] = user.email;
//     }
//     if (existing['date_joined'] == null) {
//       updates['date_joined'] = now.toIso8601String();
//     }
//     if (existing['is_upgraded'] == null) {
//       updates['is_upgraded'] = false;
//     }

//     if (updates.isNotEmpty) {
//       await _sb.from('profiles').update(updates).eq('id', user.id);
//     }
//   }

//   // ────────── Apple Sign In ──────────

//   Future<void> _signInWithApple() async {
//     if (_busy) return;

//     FocusScope.of(context).unfocus();

//     setState(() {
//       _busy = true;
//       _error = null;
//     });

//     try {
//       // 1. Generate a crypto-random nonce
//       final rawNonce = _generateRandomString();
//       final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

//       // 2. Show native Apple Sign In sheet
//       final credential = await SignInWithApple.getAppleIDCredential(
//         scopes: [
//           AppleIDAuthorizationScopes.email,
//           AppleIDAuthorizationScopes.fullName,
//         ],
//         nonce: hashedNonce,
//       );

//       final idToken = credential.identityToken;
//       if (idToken == null) {
//         throw Exception('No identity token returned from Apple.');
//       }

//       // 3. Sign in to Supabase with the Apple ID token
//       final res = await _sb.auth.signInWithIdToken(
//         provider: OAuthProvider.apple,
//         idToken: idToken,
//         nonce: rawNonce,
//       );

//       final user = res.user;
//       if (user == null) {
//         throw Exception('Supabase sign-in failed (no user returned).');
//       }

//       await _ensureProfile(user);

//       if (!mounted) return;
//       setState(() => _busy = false);
//       widget.onLoggedIn?.call();
//       if (Navigator.of(context).canPop()) {
//         Navigator.of(context).pop(true);
//       }
//     } on SignInWithAppleAuthorizationException catch (e) {
//       if (!mounted) return;
//       // User cancelled — don't show error
//       if (e.code == AuthorizationErrorCode.canceled) {
//         setState(() => _busy = false);
//         return;
//       }
//       setState(() {
//         _busy = false;
//         _error = 'Apple Sign In failed';
//         debugPrint('Apple sign-in error: $e');
//       });
//     } catch (e) {
//       if (!mounted) return;
//       setState(() {
//         _busy = false;
//         _error = 'Apple Sign In failed';
//         debugPrint('Apple sign-in error: $e');
//       });
//     }
//   }

//   Future<void> _signInWithGoogle() async {
//     if (_busy) return;

//     FocusScope.of(context).unfocus();

//     setState(() {
//       _busy = true;
//       _error = null;
//     });

//     try {
//       final GoogleSignIn signIn = GoogleSignIn.instance;

//       String? rawNonce;

//       if (Platform.isIOS) {
//         // iOS requires nonce for token validation
//         rawNonce = _generateRandomString();
//         final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

//         await signIn.initialize(
//           serverClientId: _serverClientId,
//           nonce: hashedNonce,
//         );
//       } else {
//         // Android doesn't need nonce
//         await signIn.initialize(
//           serverClientId: _serverClientId,
//         );
//       }

//       final googleAccount = await signIn.authenticate();
//       final googleAuthentication = googleAccount.authentication;
//       final idToken = googleAuthentication.idToken;

//       if (idToken == null) {
//         throw Exception('No ID Token found. Check your serverClientId.');
//       }

//       final res = await _sb.auth.signInWithIdToken(
//         provider: OAuthProvider.google,
//         idToken: idToken,
//         nonce: rawNonce, // null for Android, set for iOS
//       );

//       final user = res.user;
//       if (user == null) {
//         throw Exception('Supabase sign-in failed (no user returned).');
//       }

//       await _ensureProfile(user);

//       if (!mounted) return;
//       setState(() => _busy = false);
//       widget.onLoggedIn?.call();
//       if (Navigator.of(context).canPop()) {
//         Navigator.of(context).pop(true);
//       }
//     } catch (e) {
//       if (!mounted) return;
//       setState(() {
//         _busy = false;
//         _error = 'Login Failed';
//         debugPrint('Google sign-in error: $e');
//       });
//     }
//   }

//   Future<void> _signInWithEmailPassword() async {
//     if (_busy) return;

//     final email = _emailCtrl.text.trim();
//     final password = _passwordCtrl.text;

//     if (email.isEmpty || password.isEmpty) {
//       setState(() => _error = 'Enter email and password.');
//       return;
//     }

//     FocusScope.of(context).unfocus();

//     setState(() {
//       _busy = true;
//       _error = null;
//     });

//     try {
//       final res = await _sb.auth.signInWithPassword(
//         email: email,
//         password: password,
//       );

//       final user = res.user;
//       if (user == null) {
//         throw Exception('Login failed (no user returned).');
//       }

//       await _ensureProfile(user);

//       if (!mounted) return;
//       setState(() => _busy = false);
//       widget.onLoggedIn?.call();
//       if (Navigator.of(context).canPop()) {
//         Navigator.of(context).pop(true);
//       }
//     } on AuthException catch (e) {
//       if (!mounted) return;
//       setState(() {
//         _busy = false;
//         _error = e.message;
//       });
//     } catch (_) {
//       if (!mounted) return;
//       setState(() {
//         _busy = false;
//         _error = 'Login Failed, Provide valid credentials';
//       });
//     }
//   }

//   Future<void> _openTerms() async {
//     final uri = Uri.parse(
//       'https://enyx.app/privacy/meeting-transcript-unlimited',
//     );

//     final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
//     if (!ok) {
//       debugPrint('Could not launch: $uri');
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     final theme = Theme.of(context);
//     final fg = GlassTokens.fg(context, alpha: 0.92);
//     final muted = GlassTokens.muted(context, alpha: 0.72);

//     return Scaffold(
//       resizeToAvoidBottomInset: true,
//       extendBodyBehindAppBar: true,
//       backgroundColor: Colors.transparent,
//       body: GlassBackground(
//         child: SafeArea(
//           child: GestureDetector(
//             behavior: HitTestBehavior.opaque,
//             onTap: () => FocusScope.of(context).unfocus(),
//             child: LayoutBuilder(
//               builder: (context, constraints) {
//                 return SingleChildScrollView(
//                   padding: EdgeInsets.only(
//                     bottom: MediaQuery.of(context).viewInsets.bottom,
//                   ),
//                   child: ConstrainedBox(
//                     constraints: BoxConstraints(minHeight: constraints.maxHeight),
//                     child: Center(
//                       child: ConstrainedBox(
//                         constraints: const BoxConstraints(maxWidth: 420),
//                         child: Padding(
//                           padding: const EdgeInsets.all(20),
//                           child: Column(
//                             mainAxisAlignment: MainAxisAlignment.center,
//                             crossAxisAlignment: CrossAxisAlignment.stretch,
//                             children: [
//                               const Align(
//                                 alignment: Alignment.center,
//                                 child: BrandLogo(),
//                               ),
//                               const SizedBox(height: 22),

//                               Text(
//                                 'Welcome back',
//                                 textAlign: TextAlign.center,
//                                 style: theme.textTheme.headlineSmall?.copyWith(
//                                   fontWeight: FontWeight.w700,
//                                   color: fg,
//                                 ),
//                               ),
//                               const SizedBox(height: 8),
//                               Text(
//                                 'Sign in to sync your transcripts and unlock AI features.',
//                                 textAlign: TextAlign.center,
//                                 style: TextStyle(
//                                   color: muted,
//                                   fontWeight: FontWeight.w600,
//                                   height: 1.25,
//                                 ),
//                               ),
//                               const SizedBox(height: 24),

//                               GlassCard(
//                                 variant: GlassCardVariant.panel,
//                                 padding: const EdgeInsets.all(16),
//                                 child: Column(
//                                   crossAxisAlignment: CrossAxisAlignment.stretch,
//                                   children: [
//                                     // GOOGLE
//                                     if (Platform.isAndroid) ...[
//                                     FilledButton.icon(
//                                       onPressed: _busy
//                                           ? null
//                                           : _signInWithGoogle,
//                                       icon: _busy
//                                           ? const SizedBox(
//                                               width: 18,
//                                               height: 18,
//                                               child: CircularProgressIndicator(
//                                                 strokeWidth: 2,
//                                                 color: Colors.black,
//                                               ),
//                                             )
//                                           : const Icon(Icons.g_mobiledata),
//                                       label: Text(
//                                         _busy
//                                             ? 'Signing in…'
//                                             : 'Continue with Google',
//                                         style: TextStyle(color: Colors.black),
//                                       ),
//                                       style: OutlinedButton.styleFrom(
//                                         backgroundColor: Colors.white,
//                                       ),
//                                     ),

//                                     const SizedBox(height: 16),
//                                     const Divider(),
//                                     const SizedBox(height: 12),
//                                     ],

//                                     // APPLE SIGN IN (iOS only)
//                                     if (Platform.isIOS) ...[
//                                       FilledButton.icon(
//                                       onPressed: _busy
//                                           ? null
//                                           : _signInWithApple,
//                                       icon: _busy
//                                           ? const SizedBox(
//                                               width: 18,
//                                               height: 18,
//                                               child: CircularProgressIndicator(
//                                                 strokeWidth: 2,
//                                                 color: Colors.black,
//                                               ),
//                                             )
//                                           : const Icon(Icons.apple),

//                                       label: Text(
//                                         _busy
//                                             ? 'Signing in…'
//                                             : 'Continue with Apple',
//                                         style: TextStyle(color: Colors.black),
//                                       ),
//                                       style: OutlinedButton.styleFrom(
//                                         backgroundColor: Colors.white,
//                                       ),
//                                     ),
//                                       const SizedBox(height: 12),
//                                       Row(
//                                         children: [
//                                           const Expanded(child: Divider()),
//                                           Padding(
//                                             padding: const EdgeInsets.symmetric(horizontal: 12),
//                                             child: Text(
//                                               'or',
//                                               style: TextStyle(
//                                                 color: Colors.white54,
//                                                 fontSize: 13,
//                                               ),
//                                             ),
//                                           ),
//                                           const Expanded(child: Divider()),
//                                         ],
//                                       ),
//                                       const SizedBox(height: 12),
//                                     ],

//                                     // EMAIL/PASSWORD
//                                     TextField(
//                                       controller: _emailCtrl,
//                                       keyboardType: TextInputType.emailAddress,
//                                       textInputAction: TextInputAction.next,
//                                       autofillHints: const [
//                                         AutofillHints.username,
//                                         AutofillHints.email,
//                                       ],
//                                       decoration: const InputDecoration(
//                                         labelText: 'Email',
//                                         border: OutlineInputBorder(),
//                                       ),
//                                     ),
//                                     const SizedBox(height: 10),
//                                     TextField(
//                                       controller: _passwordCtrl,
//                                       obscureText: _pwObscured,
//                                       textInputAction: TextInputAction.done,
//                                       onSubmitted: (_) => _busy
//                                           ? null
//                                           : _signInWithEmailPassword(),
//                                       autofillHints: const [
//                                         AutofillHints.password,
//                                       ],
//                                       decoration: InputDecoration(
//                                         labelText: 'Password',
//                                         border: const OutlineInputBorder(),
//                                         suffixIcon: IconButton(
//                                           onPressed: _busy
//                                               ? null
//                                               : () => setState(
//                                                   () => _pwObscured =
//                                                       !_pwObscured,
//                                                 ),
//                                           icon: Icon(
//                                             _pwObscured
//                                                 ? Icons.visibility
//                                                 : Icons.visibility_off,
//                                           ),
//                                         ),
//                                       ),
//                                     ),
//                                     const SizedBox(height: 10),
//                                     FilledButton(
//                                       onPressed: _busy
//                                           ? null
//                                           : _signInWithEmailPassword,
//                                       child: Text(
//                                         _busy
//                                             ? 'Signing in…'
//                                             : 'Continue with Email',
//                                       ),
//                                     ),
//                                     const SizedBox(height: 10),
//                                     RichText(
//                                       textAlign: TextAlign.center,
//                                       text: TextSpan(
//                                         style: TextStyle(
//                                           fontSize: 11,
//                                           color: muted.withValues(alpha: 0.9),
//                                           fontWeight: FontWeight.w600,
//                                         ),
//                                         children: [
//                                           const TextSpan(
//                                             text: 'By continuing you agree to our ',
//                                           ),
//                                           TextSpan(
//                                             text: 'Terms and Privacy Policy',
//                                             style: TextStyle(
//                                               color: fg,
//                                               decoration: TextDecoration.underline,
//                                               fontWeight: FontWeight.w800,
//                                             ),
//                                             recognizer: TapGestureRecognizer()
//                                               ..onTap = _openTerms,
//                                           ),
//                                           const TextSpan(text: '.'),
//                                         ],
//                                       ),
//                                     ),
//                                   ],
//                                 ),
//                               ),

//                               if (_error != null) ...[
//                                 const SizedBox(height: 14),
//                                 Align(
//                                   alignment: Alignment.center,
//                                   child: StatusPill(
//                                     text: _error!,
//                                     isError: true,
//                                   ),
//                                 ),
//                               ],

//                               const SizedBox(height: 20),
//                             ],
//                           ),
//                         ),
//                       ),
//                     ),
//                   ),
//                 );
//               },
//             ),
//           ),
//         ),
//       ),
//     );
//   }
// }
