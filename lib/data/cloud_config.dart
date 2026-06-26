/// Configuration for the optional Supabase-backed cloud source panel.
///
/// The URL and anon (publishable) key are safe to ship in this open-source app:
/// access is gated entirely by row-level security in `supabase/migrations`. The
/// `service_role` key must never appear here. Values come from `--dart-define`
/// at build time (see `supabase/README.md`); when unset, cloud sync is simply
/// hidden and the app behaves exactly as before.
class CloudConfig {
  CloudConfig._();

  static const String url =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');

  static const String anonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// Where users go to manage their sources and claim a device's pairing code.
  static const String panelUrl = String.fromEnvironment(
    'PANEL_URL',
    defaultValue: 'https://gchofficial.github.io/iptvs/',
  );

  /// Cloud sync is only available when both Supabase values are provided.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
