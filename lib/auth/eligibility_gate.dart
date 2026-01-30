import 'package:supabase_flutter/supabase_flutter.dart';

class EligibilityGateResult {
  final bool eligible;
  final String? error;

  const EligibilityGateResult({required this.eligible, this.error});
}

Future<EligibilityGateResult> checkEligibilityOnce(SupabaseClient sb) async {
  try {
    final user = sb.auth.currentUser;
    if (user == null) {
      return const EligibilityGateResult(eligible: false);
    }

    final row = await sb
        .from('profiles')
        .select('is_upgraded, is_lifetime, trial_expires_at, pro_expires_at')
        .eq('id', user.id)
        .maybeSingle();

    if (row == null) {
      return const EligibilityGateResult(eligible: false);
    }

    final map = Map<String, dynamic>.from(row);

    final bool isUpgraded = (map['is_upgraded'] as bool?) ?? false;
    final DateTime? trialExpires = _parseDate(map['trial_expires_at']);
    final DateTime? proExpires = _parseDate(map['pro_expires_at']);

    final now = DateTime.now().toUtc();

    final bool trialActive = trialExpires != null && trialExpires.isAfter(now);
    final bool isLifetime = (map['is_lifetime'] as bool?) ?? false;

    final bool proActive =
        isUpgraded &&
        (isLifetime || (proExpires != null && proExpires.isAfter(now)));

    return EligibilityGateResult(eligible: trialActive || proActive);
  } catch (e) {
    return EligibilityGateResult(eligible: false, error: e.toString());
  }
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v.toUtc();
  if (v is String) return DateTime.tryParse(v)?.toUtc();
  return null;
}
