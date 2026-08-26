class DevFlags {
  DevFlags._();

  /// Set to false during local development to open the app without login.
  /// Set to true to require the normal Supabase login flow.
  static const bool enableLoginSystem = false;
}
