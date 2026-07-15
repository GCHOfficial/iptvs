/// Parses a subscription-expiry value as emitted by IPTV panels: Xtream sends a
/// Unix `exp_date` (seconds, possibly null/empty/"0"/"null" for an unlimited
/// account), Stalker sends ISO-style date strings. Handles Unix timestamps
/// (seconds or milliseconds) and ISO-8601 / `YYYY-MM-DD[ HH:MM:SS]`.
/// Returns null when the value is empty, zero, or unparseable.
DateTime? parseExpiryValue(Object? value) {
  if (value == null) return null;
  final raw = value.toString().trim();
  if (raw.isEmpty || raw == '0' || raw.toLowerCase() == 'null') return null;

  // Unix timestamp (seconds, or milliseconds when large enough).
  final ts = int.tryParse(raw);
  if (ts != null && ts > 0) {
    final dt = ts > 1000000000000
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return _sane(dt);
  }

  // ISO-8601, or `YYYY-MM-DD HH:MM:SS` (normalise the space to `T`).
  final normalised =
      raw.contains(' ') && !raw.contains('T') ? raw.replaceFirst(' ', 'T') : raw;
  final dt = DateTime.tryParse(normalised);
  if (dt != null) return _sane(dt);

  return null;
}

/// Finds the subscription expiry in a Stalker portal payload (`get_main_info`'s
/// or `get_profile`'s `js` map). Checks the known field names first, then the
/// tariff, then falls back to a date embedded in `phone` — a common MAG-panel
/// quirk where the end date is stuffed into the phone field.
DateTime? expiryFromStalkerFields(Map<dynamic, dynamic> js) {
  for (final key in const [
    'end_date',
    'expire_billing_date',
    'subscription_expire',
    'exp_date',
  ]) {
    final parsed = parseExpiryValue(js[key]);
    if (parsed != null) return parsed;
  }
  final tariff = js['tariff'];
  if (tariff is Map) {
    final parsed = parseExpiryValue(tariff['expire_date']);
    if (parsed != null) return parsed;
  }
  return extractExpiryFromText(js['phone']);
}

/// Extracts a date embedded in free-form text — some MAG portals stuff the
/// subscription end date into unrelated `get_main_info` fields (classically
/// `phone`), often with surrounding text ("exp: 2026-09-01 00:00:00") or in
/// `DD.MM.YYYY` form. Deliberately does *not* treat bare numbers as Unix
/// timestamps (a phone field may hold an actual phone number). Returns null
/// when no date-shaped substring parses.
DateTime? extractExpiryFromText(Object? value) {
  if (value == null) return null;
  final raw = value.toString();

  // ISO-ish: YYYY-MM-DD, optionally followed by HH:MM[:SS].
  final iso = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(raw);
  if (iso != null) {
    final dt = DateTime.tryParse(
      '${iso[1]}-${iso[2]}-${iso[3]}T'
      '${iso[4] ?? '00'}:${iso[5] ?? '00'}:${iso[6] ?? '00'}',
    );
    if (dt != null) {
      final sane = _sane(dt);
      if (sane != null) return sane;
    }
  }

  // European: DD.MM.YYYY or DD/MM/YYYY.
  final eu = RegExp(r'(\d{1,2})[./](\d{1,2})[./](\d{4})').firstMatch(raw);
  if (eu != null) {
    final day = int.parse(eu[1]!);
    final month = int.parse(eu[2]!);
    final year = int.parse(eu[3]!);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      return _sane(DateTime(year, month, day));
    }
  }

  return null;
}

/// Finds the subscription expiry embedded in an M3U provider's playlist URL.
/// Plain M3U playlists carry no expiry metadata, but some providers stuff it
/// into a query param (`exp`, `expiry`, `expire`, `expires`) as a Unix
/// timestamp or a date string — matched case-insensitively since providers
/// aren't consistent. Returns null when the URL is unparseable or no
/// recognised param carries a usable value.
DateTime? expiryFromPlaylistUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.queryParameters.isEmpty) return null;
  // Xtream playlist links are commonly labelled `exp`, while some panels
  // copy the player API field name verbatim as `exp_date`.
  const keys = {'exp', 'exp_date', 'expiry', 'expire', 'expires'};
  for (final entry in uri.queryParameters.entries) {
    if (!keys.contains(entry.key.toLowerCase())) continue;
    final parsed = parseExpiryValue(entry.value);
    if (parsed != null) return parsed;
  }
  return null;
}

/// Guards against epoch/garbage values producing absurd years.
DateTime? _sane(DateTime dt) =>
    (dt.year >= 2000 && dt.year <= 2100) ? dt : null;
