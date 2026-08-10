import 'source.dart';

/// Parses both dated and explicitly non-expiring provider values. Empty/null
/// metadata remains unknown; common lifetime labels are explicit unlimited
/// values. A numeric zero stays unknown because panels also use it as a
/// missing-value placeholder (and a saved playlist hint may still have a date).
SubscriptionExpiry parseSubscriptionExpiryValue(Object? value) {
  if (value == null) return const SubscriptionExpiry.unknown();
  final raw = value.toString().trim();
  if (raw.isEmpty || raw.toLowerCase() == 'null') {
    return const SubscriptionExpiry.unknown();
  }
  final normalised = raw.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), ' ');
  if (normalised == 'unlimited' ||
      normalised == 'never' ||
      normalised == 'lifetime' ||
      normalised == 'no expiry' ||
      normalised == 'never expires') {
    return const SubscriptionExpiry.unlimited();
  }
  final date = _parseAnyDate(raw);
  if (date == null) return const SubscriptionExpiry.unknown();
  if (date.year > _maxSaneYear) {
    // A far-future sentinel is a panel spelling "unlimited" as a date —
    // `9999-12-31` and `2999-01-01` are both in the wild. Collapsing those
    // into *unknown* is exactly the loss the SubscriptionExpiry type exists
    // to prevent: the user has a perfectly good answer and the badge says
    // nothing.
    //
    // **Only for a written date, never a bare number.** These fields are also
    // where panels stuff the customer's phone number, and a phone number is a
    // large integer: read as Unix seconds, `40712345678` lands in the year
    // 3260, which this rule would happily report as a lifetime subscription.
    // An out-of-range *timestamp* is garbage and stays unknown, exactly as it
    // was before the sentinel rule existed.
    return int.tryParse(raw) == null
        ? const SubscriptionExpiry.unlimited()
        : const SubscriptionExpiry.unknown();
  }
  if (date.year < _minSaneYear) return const SubscriptionExpiry.unknown();
  return SubscriptionExpiry.dated(date);
}

/// Parses a subscription-expiry value as emitted by IPTV panels: Xtream sends a
/// Unix `exp_date` (seconds, possibly null/empty/"0"/"null" for an unlimited
/// account), Stalker sends ISO-style date strings. Handles Unix timestamps
/// (seconds or milliseconds) and ISO-8601 / `YYYY-MM-DD[ HH:MM:SS]`.
/// Returns null when the value is empty, zero, or unparseable.
DateTime? parseExpiryValue(Object? value) {
  if (value == null) return null;
  final dt = _parseAnyDate(value.toString().trim());
  return dt == null ? null : _sane(dt);
}

/// The parse half of [parseExpiryValue], **without** the sanity clamp, so a
/// caller that cares about the difference between "garbage" and "a sentinel
/// year meaning never" can tell them apart (see
/// [parseSubscriptionExpiryValue]).
DateTime? _parseAnyDate(String raw) {
  if (raw.isEmpty || raw == '0' || raw.toLowerCase() == 'null') return null;

  // Unix timestamp (seconds, or milliseconds when large enough).
  final ts = int.tryParse(raw);
  if (ts != null && ts > 0) {
    return ts > 1000000000000
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  }

  // ISO-8601, or `YYYY-MM-DD HH:MM:SS` (normalise the space to `T`).
  final normalised = raw.contains(' ') && !raw.contains('T')
      ? raw.replaceFirst(' ', 'T')
      : raw;
  return DateTime.tryParse(normalised);
}

/// Finds the subscription expiry in a Stalker portal payload (`get_main_info`'s
/// or `get_profile`'s `js` map). Checks the known field names first, then the
/// tariff, then falls back to a date embedded in `phone` — a common MAG-panel
/// quirk where the end date is stuffed into the phone field.
DateTime? expiryFromStalkerFields(Map<dynamic, dynamic> js) {
  return subscriptionExpiryFromStalkerFields(js).date;
}

/// Keys that are *meant* to hold the expiry, in preference order.
///
/// `expire_date` appears at the top level on some panels and only under
/// `tariff` on others, so it is listed here and reached through
/// [_expiryContainers] rather than special-cased in one place.
const _expiryFieldKeys = [
  'end_date',
  'expire_billing_date',
  'subscription_expire',
  'exp_date',
  'expire_date',
  'tariff_expired_date',
  'end_date_timestamp',
];

/// Free-form fields panels are known to *stuff* the date into. `phone` is the
/// classic, but resold Ministra skins use the other identity fields the same
/// way — the expiry is shown to the customer through whichever box the panel's
/// STB screen happens to render.
///
/// Deliberately limited to the **identity** fields. Genuinely free-form ones
/// (`comment`, `description`) were tried and dropped: a date in a note is far
/// more likely to be about something else, and a *wrong* expiry is worse than
/// no expiry — the badge is only useful if it can be believed.
const _stuffedFieldKeys = ['phone', 'fname', 'ls'];

/// Sub-maps worth searching with the same rules as the root. Panels differ on
/// whether `get_main_info` returns a flat `js` or wraps it.
const _nestedContainerKeys = ['tariff', 'account_info', 'info', 'data'];

SubscriptionExpiry subscriptionExpiryFromStalkerFields(
  Map<dynamic, dynamic> js,
) {
  for (final container in _expiryContainers(js)) {
    for (final key in _expiryFieldKeys) {
      final value = container[key];
      final parsed = parseSubscriptionExpiryValue(value);
      if (parsed.kind != SubscriptionExpiryKind.unknown) return parsed;
      // The same leniency `phone` always had, applied to the fields that are
      // *supposed* to carry the date. Panels return `end_date` as
      // "October 20, 2026", "20.10.2026", or "expires 2026-10-20" at least as
      // often as they return something DateTime.parse accepts — and until this
      // existed, every one of those read as "Expiry unknown" while a date sat
      // in plain sight in the payload.
      final embedded = extractExpiryFromText(value);
      if (embedded != null) return SubscriptionExpiry.dated(embedded);
    }
  }
  for (final container in _expiryContainers(js)) {
    for (final key in _stuffedFieldKeys) {
      final value = container[key];
      final embedded = extractExpiryFromText(value);
      if (embedded != null) return SubscriptionExpiry.dated(embedded);
      final parsed = parseSubscriptionExpiryValue(value);
      if (parsed.kind != SubscriptionExpiryKind.unknown) return parsed;
    }
  }
  return const SubscriptionExpiry.unknown();
}

/// The root map followed by the nested maps worth searching, root first so a
/// top-level answer always beats a nested one.
Iterable<Map<dynamic, dynamic>> _expiryContainers(Map<dynamic, dynamic> js) {
  return [
    js,
    for (final key in _nestedContainerKeys)
      if (js[key] is Map) js[key] as Map<dynamic, dynamic>,
  ];
}

/// A character-class **shape** of a portal value, for diagnostics: digits
/// become `d`, letters `a`, recognised separators stay, anything else `?`.
/// `"2026-06-19"` → `dddd-dd-dd`; `"October 20, 2026"` → `aaaaaaa dd, dddd`.
///
/// Exists because the fix for "expiry unknown on this portal" is always the
/// same two questions — which key, and in what format — and neither can be
/// answered from an exported log without shipping the payload. The values
/// themselves can't go in one: `phone`, `fname` and `ls` are customer PII, and
/// a panel that stuffs the expiry into them is stuffing it *next to* the
/// account identity. A shape answers the format question and carries no
/// content, so it is safe to export verbatim.
String expiryValueShape(Object? value, {int maxLength = 32}) {
  if (value == null) return 'null';
  final raw = value.toString().trim();
  if (raw.isEmpty) return 'empty';
  final buffer = StringBuffer();
  for (final rune in raw.runes.take(maxLength)) {
    final ch = String.fromCharCode(rune);
    if (RegExp(r'\d').hasMatch(ch)) {
      buffer.write('d');
    } else if (RegExp(r'[A-Za-z]').hasMatch(ch)) {
      buffer.write('a');
    } else if (r'-./:, '.contains(ch)) {
      buffer.write(ch);
    } else {
      buffer.write('?');
    }
  }
  if (raw.runes.length > maxLength) buffer.write('…');
  return buffer.toString();
}

/// One-line, credential-free description of what a portal payload actually
/// contained, for the diagnostics log when the expiry came back unknown.
///
/// Key **names** are safe in full (they're schema, not data) and are the thing
/// most likely to explain a miss — a panel using a field nobody here has heard
/// of. Values appear only as [expiryValueShape], and only for the keys already
/// being inspected.
String describeStalkerExpiryPayload(Map<dynamic, dynamic> js) {
  final keys = js.keys.map((k) => '$k').toList()..sort();
  final shapes = <String>[];
  for (final container in _expiryContainers(js)) {
    for (final key in [..._expiryFieldKeys, ..._stuffedFieldKeys]) {
      if (!container.containsKey(key)) continue;
      shapes.add('$key=${expiryValueShape(container[key])}');
    }
  }
  return 'keys=[${keys.join(',')}] '
      'candidates={${shapes.join(', ')}}';
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

  // Month-name forms: `October 20, 2026`, `Oct 20 2026`, `20 October 2026`.
  // PHP's default date formatting produces these, so they are what a stock
  // Ministra/stalker_portal skin returns in `end_date` — the single most
  // common shape this parser used to reject outright.
  final mdy = RegExp(
    r'([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})',
  ).firstMatch(raw);
  if (mdy != null) {
    final month = _monthFromName(mdy[1]!);
    if (month != null) {
      final day = int.parse(mdy[2]!);
      if (day >= 1 && day <= 31) {
        return _sane(DateTime(int.parse(mdy[3]!), month, day));
      }
    }
  }
  final dmy = RegExp(
    r'(\d{1,2})(?:st|nd|rd|th)?\.?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})',
  ).firstMatch(raw);
  if (dmy != null) {
    final month = _monthFromName(dmy[2]!);
    if (month != null) {
      final day = int.parse(dmy[1]!);
      if (day >= 1 && day <= 31) {
        return _sane(DateTime(int.parse(dmy[3]!), month, day));
      }
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
  return subscriptionExpiryFromPlaylistUrl(url).date;
}

SubscriptionExpiry subscriptionExpiryFromPlaylistUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.queryParameters.isEmpty) {
    return const SubscriptionExpiry.unknown();
  }
  // Xtream playlist links are commonly labelled `exp`, while some panels
  // copy the player API field name verbatim as `exp_date`.
  const keys = {'exp', 'exp_date', 'expiry', 'expire', 'expires'};
  for (final entry in uri.queryParameters.entries) {
    if (!keys.contains(entry.key.toLowerCase())) continue;
    final parsed = parseSubscriptionExpiryValue(entry.value);
    if (parsed.kind != SubscriptionExpiryKind.unknown) return parsed;
  }
  return const SubscriptionExpiry.unknown();
}

const _englishMonths = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];

/// 1-based month for an English month name or its abbreviation, or null when
/// the token isn't one. English only, deliberately: panels serve this field
/// through PHP's default (English) formatting, and accepting arbitrary locales
/// would mean matching short words against twelve names in a dozen languages —
/// far more ways to read a date out of something that isn't one.
int? _monthFromName(String token) {
  final name = token.toLowerCase();
  if (name.length < 3) return null;
  for (var i = 0; i < _englishMonths.length; i++) {
    if (_englishMonths[i].startsWith(name)) return i + 1;
  }
  return null;
}

const int _minSaneYear = 2000;
const int _maxSaneYear = 2100;

/// Guards against epoch/garbage values producing absurd years.
DateTime? _sane(DateTime dt) =>
    (dt.year >= _minSaneYear && dt.year <= _maxSaneYear) ? dt : null;
