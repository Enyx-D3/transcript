class AppProfile {
  final String id;
  final String? email;
  final DateTime? dateJoined;
  final bool isUpgraded;

  // ✅ NEW: lifetime flag (maps to Supabase `is_lifetime`)
  final bool isLifetime;

  final DateTime? trialExpiresAt;
  final DateTime? proExpiresAt;
  final String? avatarUrl;

  AppProfile({
    required this.id,
    required this.email,
    required this.dateJoined,
    required this.isUpgraded,

    // ✅ NEW
    required this.isLifetime,

    required this.trialExpiresAt,
    required this.proExpiresAt,
    required this.avatarUrl,
  });

  factory AppProfile.fromMap(Map<String, dynamic> m) {
    DateTime? dt(String k) =>
        m[k] == null ? null : DateTime.tryParse(m[k].toString());

    return AppProfile(
      id: m['id'] as String,
      email: m['email'] as String?,
      dateJoined: dt('date_joined'),
      isUpgraded: (m['is_upgraded'] as bool?) ?? false,

      // ✅ NEW (backward compatible if column isn't present yet)
      isLifetime: (m['is_lifetime'] as bool?) ?? false,

      trialExpiresAt: dt('trial_expires_at'),
      proExpiresAt: dt('pro_expires_at'),
      avatarUrl: m['avatar_url'] as String?,
    );
  }
}
