class AppProfile {
  final String id;
  final String? email;
  final DateTime? dateJoined;
  final bool isUpgraded;
  final DateTime? trialExpiresAt;
  final DateTime? proExpiresAt;
  final String? avatarUrl;

  AppProfile({
    required this.id,
    required this.email,
    required this.dateJoined,
    required this.isUpgraded,
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
      trialExpiresAt: dt('trial_expires_at'),
      proExpiresAt: dt('pro_expires_at'),
      avatarUrl: m['avatar_url'] as String?,
    );
  }
}
