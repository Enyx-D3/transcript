import 'package:supabase_flutter/supabase_flutter.dart';

class UserIdentity {
  final String? username; // display_name
  final String? email;

  const UserIdentity({this.username, this.email});
}

class UserIdentityHelper {
  UserIdentityHelper._();

  /// Auth-only identity.
  /// Username source: userMetadata['display_name'] (preferred)
  /// Fallback: email local-part (before @)
  static UserIdentity getCurrent({SupabaseClient? client}) {
    final sb = client ?? Supabase.instance.client;
    final user = sb.auth.currentUser;
    if (user == null) return const UserIdentity();

    final email = _clean(user.email);

    final meta = user.userMetadata ?? {};
    final displayName = _clean(
      meta['display_name'] is String ? meta['display_name'] as String : null,
    );

    final username = displayName ?? _emailLocalPart(email);

    return UserIdentity(username: username, email: email);
  }

  static String? _emailLocalPart(String? email) {
    final e = _clean(email);
    if (e == null) return null;
    final at = e.indexOf('@');
    if (at <= 0) return null;
    final local = e.substring(0, at).trim();
    return local.isEmpty ? null : local;
  }

  static String? _clean(String? s) {
    if (s == null) return null;
    final t = s.trim();
    return t.isEmpty ? null : t;
  }
}
