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

/// The panel link the pairing screen turns into a QR code: [panelUrl] carrying
/// the device's [code] as a `code=` query parameter, which the panel reads to
/// prefill its Pair form (`panel/src/validate.js` `pairingCodeFromUrl`).
///
/// The primary device here is a TV: entering eight characters into a phone by
/// reading them off the screen across the room is the slowest step in pairing,
/// and it is the one step the app can hand over to a camera. Scanning lands the
/// user on the panel *and* fills the field.
///
/// Pure so it can be tested, and deliberately conservative:
///
/// - An unparseable [panelUrl] (a bad `PANEL_URL` define) returns it unchanged
///   rather than throwing — the QR is a convenience, and the printed link and
///   the code beside it are the real instructions.
/// - A blank [code] returns the plain panel URL, so a QR rendered while the
///   code is still being requested points somewhere useful instead of
///   advertising an empty parameter.
/// - Any existing query is preserved; only `code` is replaced.
String pairingPanelLink(String panelUrl, String code) {
  final trimmed = code.trim();
  final uri = Uri.tryParse(panelUrl);
  if (uri == null || !uri.hasScheme) return panelUrl;
  if (trimmed.isEmpty) return panelUrl;
  return uri.replace(
    queryParameters: {...uri.queryParameters, 'code': trimmed},
  ).toString();
}
