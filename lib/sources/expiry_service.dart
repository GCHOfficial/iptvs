import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'stalker_source.dart';
import 'source_config.dart';

DateTime? parseExpiryValue(Object? value) {
  if (value == null) return null;

  final raw = value.toString().trim();
  if (raw.isEmpty || raw == '0' || raw.toLowerCase() == 'null') {
    return null;
  }

  final decoded = Uri.decodeFull(raw);
  if (decoded != raw) {
    final parsed = parseExpiryValue(decoded);
    if (parsed != null) return parsed;
  }

  final ts = int.tryParse(raw);
  if (ts != null && ts > 0) {
    final dt = ts > 1_000_000_000_000
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    if (dt.year >= 2000 && dt.year <= 2100) return dt;
  }

  final dt = DateTime.tryParse(raw);
  if (dt != null && dt.year >= 2000 && dt.year <= 2100) return dt;

  if (raw.contains('?') || raw.contains('&') || raw.contains('=')) {
    final uri = Uri.tryParse(raw);
    if (uri != null) {
      for (final entry in uri.queryParameters.entries) {
        if (_isExpiryParam(entry.key)) {
          final parsed = parseExpiryValue(entry.value);
          if (parsed != null) return parsed;
        }
      }
    }
  }

  return _findExpirySubstring(raw);
}

bool _isExpiryParam(String key) {
  final lower = key.toLowerCase();
  return lower == 'exp' || lower == 'expiry' || lower == 'expire' || lower == 'expires' || lower == 'exp_date';
}

DateTime? _findExpirySubstring(String raw) {
  final decoded = Uri.decodeFull(raw);
  final candidateSources = <String>{raw, decoded};

  for (final candidate in candidateSources) {
    for (final pattern in [
      RegExp(r'\b\d{4}-\d{2}-\d{2}\b'),
      RegExp(r'\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b'),
      RegExp(r'\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}(?:,?\s*\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?)?\b', caseSensitive: false),
    ]) {
      for (final match in pattern.allMatches(candidate)) {
        final dateStr = match.group(0)!;
        // Try direct date parsing to avoid infinite recursion
        final parsed = DateTime.tryParse(dateStr) ?? _parseNonIsoDate(dateStr) ?? _parseNamedMonthDate(dateStr);
        if (parsed != null && parsed.year >= 2000 && parsed.year <= 2100) return parsed;
      }
    }
  }
  return null;
}

DateTime? _parseNonIsoDate(String raw) {
  final normalized = raw.replaceAll('/', '.').replaceAll('-', '.').trim();
  final regex = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{2,4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$');
  final match = regex.firstMatch(normalized);
  if (match != null) {
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    if (year < 2000 || year > 2100) return null;
    final hour = int.parse(match.group(4) ?? '0');
    final minute = int.parse(match.group(5) ?? '0');
    final second = int.parse(match.group(6) ?? '0');
    return DateTime(year, month, day, hour, minute, second);
  }
  return null;
}

DateTime? _parseNamedMonthDate(String raw) {
  final normalized = raw.trim();
  final regex = RegExp(
    r'^(?:([A-Za-z]+)\s+(\d{1,2}),?\s+(\d{4})(?:,?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?)?|\d{1,2}\s+([A-Za-z]+)\s+(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?)?)$',
    caseSensitive: false,
  );
  final match = regex.firstMatch(normalized);
  if (match == null) return null;

  String monthName;
  String dayStr;
  String yearStr;
  String? hourStr;
  String? minuteStr;
  String? secondStr;
  String? ampm;

  if (match.group(1) != null) {
    monthName = match.group(1)!;
    dayStr = match.group(2)!;
    yearStr = match.group(3)!;
    hourStr = match.group(4);
    minuteStr = match.group(5);
    secondStr = match.group(6);
    ampm = match.group(7);
  } else {
    monthName = match.group(8)!;
    dayStr = match.group(7)!;
    yearStr = match.group(9)!;
    hourStr = match.group(10);
    minuteStr = match.group(11);
    secondStr = match.group(12);
    ampm = match.group(13);
  }

  final month = _monthFromName(monthName);
  if (month == null) return null;

  final day = int.parse(dayStr);
  final year = int.parse(yearStr);
  if (year < 2000 || year > 2100) return null;

  var hour = int.parse(hourStr ?? '0');
  final minute = int.parse(minuteStr ?? '0');
  final second = int.parse(secondStr ?? '0');
  if (ampm != null) {
    final mg = ampm.toLowerCase();
    if (mg == 'pm' && hour < 12) hour += 12;
    if (mg == 'am' && hour == 12) hour = 0;
  }

  return DateTime(year, month, day, hour, minute, second);
}

int? _monthFromName(String raw) {
  switch (raw.toLowerCase()) {
    case 'jan':
    case 'january':
      return 1;
    case 'feb':
    case 'february':
      return 2;
    case 'mar':
    case 'march':
      return 3;
    case 'apr':
    case 'april':
      return 4;
    case 'may':
      return 5;
    case 'jun':
    case 'june':
      return 6;
    case 'jul':
    case 'july':
      return 7;
    case 'aug':
    case 'august':
      return 8;
    case 'sep':
    case 'september':
      return 9;
    case 'oct':
    case 'october':
      return 10;
    case 'nov':
    case 'november':
      return 11;
    case 'dec':
    case 'december':
      return 12;
  }
  return null;
}

/// Holds the result of an expiry look-up for a single source.
class ExpiryResult {
  /// null  → could not determine (M3U with no URL param, Stalker with blank date, etc.)
  final DateTime? expiresAt;
  final String? error;

  const ExpiryResult({this.expiresAt, this.error});

  bool get isExpired {
    if (expiresAt == null) return false;
    return expiresAt!.isBefore(DateTime.now());
  }

  bool get isUnknown => expiresAt == null && error == null;
  bool get hasFailed => error != null;
}

/// Fetches the subscription expiry date for a [SourceConfig].
///
/// Xtream  → GET /player_api.php?username=X&password=Y  → user_info.exp_date (Unix ts)
/// Stalker → handshake + GET portal.php?type=account_info&action=get_main_info
///            → js.end_date  OR  js.expire_billing_date  OR  js.tariff.expire_date
/// M3U     → parse URL query params for exp / expiry / expire / token (some providers)
///
/// All network failures are caught and returned as [ExpiryResult.error].
class ExpiryService {
  static final ExpiryService instance = ExpiryService._();
  ExpiryService._();

  static const _timeout = Duration(seconds: 12);

  /// Fetch the expiry for [config]. Never throws — failures are captured in
  /// [ExpiryResult.error].
  Future<ExpiryResult> fetchExpiry(SourceConfig config) async {
    try {
      switch (config.kind) {
        case SourceKind.xtream:
          return await _xtream(config.fields);
        case SourceKind.stalker:
          return await _stalker(config.fields);
        case SourceKind.m3u:
          return _m3u(config.fields);
        case SourceKind.demo:
          return const ExpiryResult(); // always unknown
      }
    } catch (e) {
      return ExpiryResult(error: e.toString());
    }
  }

  // ── Xtream ─────────────────────────────────────────────────────────────────

  Future<ExpiryResult> _xtream(Map<String, String> fields) async {
    var host = (fields['host'] ?? '').trim();
    if (host.isEmpty) return ExpiryResult(error: 'Missing host');
    if (!host.startsWith('http')) host = 'http://$host';
    if (host.endsWith('/')) host = host.substring(0, host.length - 1);

    final username = fields['username'] ?? '';
    final password = fields['password'] ?? '';

    final uri = Uri.parse('$host/player_api.php').replace(
      queryParameters: {'username': username, 'password': password},
    );

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(_timeout);
      if (resp.statusCode != 200) {
        return ExpiryResult(error: 'HTTP ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
      final json = jsonDecode(body);
      if (json is! Map) return ExpiryResult(error: 'Unexpected response');

      final userInfo = json['user_info'];
      if (userInfo is! Map) return ExpiryResult(error: 'No user_info in response');

      // exp_date can be a Unix timestamp (int/string) or a plain date string.
      final raw = userInfo['exp_date'];
      if (raw == null) return const ExpiryResult(); // unlimited account

      final parsed = parseExpiryValue(raw);
      if (parsed == null) return const ExpiryResult();
      return ExpiryResult(expiresAt: parsed);
    } finally {
      client.close(force: true);
    }
  }

  // ── Stalker ────────────────────────────────────────────────────────────────

  Future<ExpiryResult> _stalker(Map<String, String> fields) async {
    var portal = (fields['portal'] ?? '').trim();
    if (portal.isEmpty) return ExpiryResult(error: 'Missing portal URL');
    if (!portal.startsWith('http')) portal = 'http://$portal';
    if (!portal.endsWith('/')) portal = '$portal/';

    final mac = (fields['mac'] ?? '').trim();
    final client = HttpClient()..connectionTimeout = _timeout;

    try {
      // Step 1: handshake to get token
      final endpoint = await _stalkerResolveEndpoint(client, portal, mac);
      if (endpoint == null) {
        return ExpiryResult(error: 'Could not reach portal');
      }

      final token = endpoint.$2;

      // Step 2: account_info
      final uri = Uri.parse(endpoint.$1).replace(queryParameters: {
        'type': 'account_info',
        'action': 'get_main_info',
        'JsHttpRequest': '1-xml',
      });

      final req = await client.getUrl(uri);
      req.headers
        ..set('Cookie', 'mac=$mac; stb_lang=en; timezone=UTC')
        ..set('X-User-Agent', 'Model: MAG250; Link: WiFi')
        ..set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3');
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }

      final resp = await req.close().timeout(_timeout);
      if (resp.statusCode != 200) {
        return ExpiryResult(error: 'account_info HTTP ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join().timeout(_timeout);

      dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        return ExpiryResult(error: 'Non-JSON account_info response');
      }

      if (decoded is! Map) return ExpiryResult(error: 'Unexpected account_info shape');

      dynamic jsValue = decoded['js'];
      Map<dynamic, dynamic>? js;
      if (jsValue is Map) {
        js = jsValue;
      } else if (jsValue is String) {
        try {
          final parsedJs = jsonDecode(jsValue);
          if (parsedJs is Map) js = parsedJs;
        } catch (_) {
          // fall through and treat as no js map
        }
      }
      if (js is! Map) return const ExpiryResult(); // portal doesn't expose it

      // Portals expose expiry under a variety of field names.
      final knownKeys = const [
        'end_date',
        'expire_billing_date',
        'subscription_expire',
        'subscription_end',
        'subscription_expire_date',
        'expiry_date',
        'expire_date',
        'expires_on',
        'exp_date',
        'active_until',
        'date_end',
        'date_expire',
        'expire_timestamp',
      ];
      for (final key in knownKeys) {
        final value = js[key]?.toString().trim();
        if (value == null || value.isEmpty || value == '0000-00-00 00:00:00') continue;

        final parsed = parseExpiryValue(value);
        if (parsed != null) return ExpiryResult(expiresAt: parsed);
      }

      // Some portals nest it under js.tariff
      final tariff = js['tariff'];
      if (tariff is Map) {
        final raw = tariff['expire_date']?.toString().trim();
        if (raw != null && raw.isNotEmpty) {
          final parsed = parseExpiryValue(raw);
          if (parsed != null) return ExpiryResult(expiresAt: parsed);
        }
      }

      // Try a broader scan across js fields for any expiry-like value.
      final scanned = _scanExpiryFields(js);
      if (scanned != null) {
        debugPrint('[expiry_service] found expiry via scan: $scanned');
        return ExpiryResult(expiresAt: scanned);
      }

      // As a last resort, scan the whole response for an expiry-like field.
      final scannedRoot = _scanExpiryFields(decoded);
      if (scannedRoot != null) {
        debugPrint('[expiry_service] found expiry via scan on root: $scannedRoot');
        return ExpiryResult(expiresAt: scannedRoot);
      }

      debugPrint('[expiry_service] no expiry found in js fields: ${js.keys}');
      final profileResult = await _stalkerProfile(client, endpoint.$1, portal, mac, token);
      if (!profileResult.isUnknown || profileResult.hasFailed) {
        return profileResult;
      }
      return const ExpiryResult(); // portal found but no expiry field
    } finally {
      client.close(force: true);
    }
  }

  DateTime? _stalkerKnownExpiryKey(String key, Map<dynamic, dynamic> js) {
    final value = js[key]?.toString().trim();
    if (value == null || value.isEmpty || value == '0000-00-00 00:00:00') return null;
    return parseExpiryValue(value);
  }

  Future<ExpiryResult> _stalkerProfile(
    HttpClient client,
    String endpoint,
    String portal,
    String mac,
    String? token,
  ) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final identity = MagIdentity.fromMac(mac);
    final params = {
      'type': 'stb',
      'action': 'get_profile',
      'ver':
          'ImageDescription: 0.2.18-r14-250; ImageDate: Fri Jan 15 15:20:44 EET 2016; '
          'PORTAL version: 5.1.0; API Version: JS API version: 343; '
          'STB API version: 146; Player Engine version: 0x566',
      'hd': '1',
      'num_banks': '2',
      'image_version': '218',
      'video_out': 'hdmi',
      'hw_version': '1.7-BD-00',
      'not_valid': '0',
      'timestamp': '$timestamp',
      'api_signature': '262',
      'prehash': '',
      ...identity.profileParams(profile: MagProfile.mag250, timestamp: timestamp),
      'JsHttpRequest': '1-xml',
    };

    final uri = Uri.parse(endpoint).replace(queryParameters: params);
    final req = await client.getUrl(uri);
    req.headers
      ..set(HttpHeaders.userAgentHeader, MagProfile.mag250.userAgent)
      ..set('X-User-Agent', 'Model: ${MagProfile.mag250.model}; Link: WiFi')
      ..set(HttpHeaders.acceptHeader, '*/*')
      ..set(HttpHeaders.cookieHeader, 'mac=$mac; stb_lang=en; timezone=UTC')
      ..set(HttpHeaders.refererHeader, portal);
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }

    final resp = await req.close().timeout(_timeout);
    if (resp.statusCode != 200) {
      return ExpiryResult(error: 'profile HTTP ${resp.statusCode}');
    }

    final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return ExpiryResult(error: 'Non-JSON profile response');
    }
    if (decoded is! Map) return ExpiryResult(error: 'Unexpected profile shape');

    dynamic jsValue = decoded['js'];
    Map<dynamic, dynamic>? js;
    if (jsValue is Map) {
      js = jsValue;
    } else if (jsValue is String) {
      try {
        final parsedJs = jsonDecode(jsValue);
        if (parsedJs is Map) js = parsedJs;
      } catch (_) {
        // ignore
      }
    }
    if (js is! Map) return const ExpiryResult();

    final knownKeys = const [
      'end_date',
      'expire_date',
      'expiry_date',
      'subscription_expire',
      'subscription_end',
      'expire_billing_date',
      'active_until',
      'date_end',
      'date_expire',
      'expires_on',
      'exp_date',
      'expire_timestamp',
    ];
    for (final key in knownKeys) {
      final parsed = _stalkerKnownExpiryKey(key, js);
      if (parsed != null) {
        debugPrint('[expiry_service] Stalker profile expiry from $key: $parsed');
        return ExpiryResult(expiresAt: parsed);
      }
    }

    final scanned = _scanExpiryFields(js);
    if (scanned != null) {
      debugPrint('[expiry_service] found expiry via profile scan: $scanned');
      return ExpiryResult(expiresAt: scanned);
    }

    final scannedRoot = _scanExpiryFields(decoded);
    if (scannedRoot != null) {
      debugPrint('[expiry_service] found expiry via profile scan on root: $scannedRoot');
      return ExpiryResult(expiresAt: scannedRoot);
    }

    debugPrint('[expiry_service] no expiry found in Stalker profile fields: ${js.keys}');
    return const ExpiryResult();
  }

  DateTime? _scanExpiryFields(Map<dynamic, dynamic> fields) {
    for (final entry in fields.entries) {
      final key = entry.key.toString().toLowerCase();
      final value = entry.value;
      if (value == null) continue;

      if (value is Map<dynamic, dynamic>) {
        final nested = _scanExpiryFields(value);
        if (nested != null) return nested;
        continue;
      }

      if (value is List) {
        for (final item in value) {
          final parsed = parseExpiryValue(item);
          if (parsed != null) return parsed;
        }
        continue;
      }

      final parsed = parseExpiryValue(value);
      if (parsed != null) return parsed;

      if (key.contains('exp') || key.contains('expiry') || key.contains('date')) {
        final parsedHint = parseExpiryValue(value);
        if (parsedHint != null) return parsedHint;
      }
    }
    return null;
  }

  /// Tries known endpoint paths and returns the first working (endpointUrl, token) pair.
  Future<(String, String?)?> _stalkerResolveEndpoint(
    HttpClient client,
    String portal,
    String mac,
  ) async {
    final base = Uri.parse(portal);
    final root = '${base.scheme}://${base.host}${base.hasPort ? ':${base.port}' : ''}/';
    final candidates = <String>{};
    for (final prefix in [portal, root, '${root}stalker_portal/server/', '${root}server/']) {
      candidates.add('${prefix}portal.php');
      candidates.add('${prefix}load.php');
    }

    for (final url in candidates) {
      try {
        final uri = Uri.parse(url).replace(queryParameters: {
          'type': 'stb',
          'action': 'handshake',
          'token': '',
          'prehash': '',
          'JsHttpRequest': '1-xml',
        });
        final req = await client.getUrl(uri);
        req.headers
          ..set('Cookie', 'mac=$mac; stb_lang=en; timezone=UTC')
          ..set(HttpHeaders.userAgentHeader,
              'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3');
        final resp = await req.close().timeout(_timeout);
        if (resp.statusCode != 200) continue;
        final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
        final decoded = jsonDecode(body);
        if (decoded is! Map) continue;
        final js = decoded['js'];
        final token = js is Map ? js['token']?.toString() : null;
        if (token != null && token.isNotEmpty) {
          debugPrint('[expiry_service] Stalker endpoint: $url');
          return (url, token);
        }
        // Some portals don't require a token but still respond
        if (decoded['js'] != null) return (url, null);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  // ── M3U ───────────────────────────────────────────────────────────────────

  Future<ExpiryResult> _m3u(Map<String, String> fields) async {
    final url = (fields['playlistUrl'] ?? '').trim();
    if (url.isEmpty) return const ExpiryResult();

    final uri = Uri.tryParse(url);
    if (uri == null) return const ExpiryResult();

    // Common expiry param names used by providers
    for (final key in const ['exp', 'expiry', 'expire', 'token', 'expires']) {
      final raw = uri.queryParameters[key];
      if (raw == null || raw.isEmpty) continue;
      final parsed = parseExpiryValue(raw);
      if (parsed != null) return ExpiryResult(expiresAt: parsed);
    }

    // If a query param contains an embedded URL, parse that URL only for
    // expiry-specific parameters.
    for (final part in uri.queryParameters.values) {
      final embedded = Uri.tryParse(part);
      if (embedded == null) continue;
      final parsed = _parseExpiryFromUri(embedded);
      if (parsed != null) return ExpiryResult(expiresAt: parsed);
    }

    final xtream = extractXtreamCredentials(uri);
    if (xtream != null) {
      final fields = {
        'host': xtream.host,
        'username': xtream.username,
        'password': xtream.password,
      };
      final xtreamResult = await _xtream(fields);
      if (!xtreamResult.isUnknown || xtreamResult.hasFailed) {
        return xtreamResult;
      }
    }

    debugPrint('[expiry_service] m3u url scan no expiry: $url');
    return const ExpiryResult(); // no expiry param found — unknown
  }
}

DateTime? _parseExpiryFromUri(Uri uri) {
  for (final key in const ['exp', 'expiry', 'expire', 'token', 'expires']) {
    final raw = uri.queryParameters[key];
    if (raw == null || raw.isEmpty) continue;
    final parsed = parseExpiryValue(raw);
    if (parsed != null) return parsed;
  }
  return null;
}

class XtreamCredentials {
  final String host;
  final String username;
  final String password;

  const XtreamCredentials({
    required this.host,
    required this.username,
    required this.password,
  });
}

@visibleForTesting
XtreamCredentials? extractXtreamCredentials(Uri uri) {
  String? username;
  String? password;

  if (uri.userInfo.isNotEmpty) {
    final parts = uri.userInfo.split(':');
    if (parts.length >= 2) {
      username = parts[0];
      password = parts.sublist(1).join(':');
    }
  }

  username ??= uri.queryParameters['username'];
  password ??= uri.queryParameters['password'];

  if (username == null || username.isEmpty || password == null || password.isEmpty) {
    return null;
  }

  final hostName = uri.host;
  if (hostName.isEmpty) return null;
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
  final host = '$scheme://$hostName${uri.hasPort ? ':${uri.port}' : ''}';

  return XtreamCredentials(host: host, username: username, password: password);
}
