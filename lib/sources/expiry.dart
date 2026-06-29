/// Parses a subscription-expiry value as emitted by IPTV panels: Xtream sends a
/// Unix `exp_date` (seconds), Stalker sends ISO-style date strings. Handles Unix
/// timestamps (seconds or milliseconds) and ISO-8601 / `YYYY-MM-DD[ HH:MM:SS]`.
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

/// Guards against epoch/garbage values producing absurd years.
DateTime? _sane(DateTime dt) =>
    (dt.year >= 2000 && dt.year <= 2100) ? dt : null;
