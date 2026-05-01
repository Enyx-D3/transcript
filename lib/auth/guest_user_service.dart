import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class GuestUserService {
  GuestUserService._();

  static final GuestUserService I = GuestUserService._();
  static const String _kGuestId = 'guest_user_id';
  static const Uuid _uuid = Uuid();

  Future<String> ensureGuestId() async {
    final sp = await SharedPreferences.getInstance();
    final existing = sp.getString(_kGuestId);
    if (existing != null && existing.trim().isNotEmpty) return existing;

    final id = _uuid.v4();
    await sp.setString(_kGuestId, id);
    return id;
  }

  Future<String?> currentGuestId() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_kGuestId);
  }
}
