import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'source_config.dart';

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

      // exp_date can be a Unix timestamp (int or string) or null / "0"
      final raw = userInfo['exp_date'];
      if (raw == null) return const ExpiryResult(); // unlimited account
      final ts = raw is int ? raw : int.tryParse(raw.toString().trim());
      if (ts == null || ts == 0) return const ExpiryResult();

      return ExpiryResult(expiresAt: DateTime.fromMillisecondsSinceEpoch(ts * 1000));
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

      final js = decoded['js'];
      if (js is! Map) return const ExpiryResult(); // portal doesn't expose it

      // Portals expose expiry under a variety of field names
      for (final key in const [
        'end_date',
        'expire_billing_date',
        'subscription_expire',
        'subscription_end',
        'expiry_date',
        'expire_date',
      ]) {
        final value = js[key]?.toString().trim();
        if (value == null || value.isEmpty || value == '0000-00-00 00:00:00') continue;

        // Try Unix timestamp first
        final ts = int.tryParse(value);
        if (ts != null && ts > 0) {
          return ExpiryResult(
            expiresAt: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
          );
        }

        // Try date string (most portals: "2025-12-31 00:00:00" or "2025-12-31")
        final dt = DateTime.tryParse(value);
        if (dt != null && dt.year > 2000) {
          return ExpiryResult(expiresAt: dt);
        }
      }

      // Some portals nest it under js.tariff
      final tariff = js['tariff'];
      if (tariff is Map) {
        final raw = tariff['expire_date']?.toString().trim();
        if (raw != null && raw.isNotEmpty) {
          final dt = DateTime.tryParse(raw);
          if (dt != null) return ExpiryResult(expiresAt: dt);
        }
      }

      return const ExpiryResult(); // portal found but no expiry field
    } finally {
      client.close(force: true);
    }
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

  ExpiryResult _m3u(Map<String, String> fields) {
    final url = (fields['playlistUrl'] ?? '').trim();
    if (url.isEmpty) return const ExpiryResult();

    final uri = Uri.tryParse(url);
    if (uri == null) return const ExpiryResult();

    // Common expiry param names used by providers
    for (final key in const ['exp', 'expiry', 'expire', 'token', 'expires']) {
      final raw = uri.queryParameters[key];
      if (raw == null || raw.isEmpty) continue;
      final ts = int.tryParse(raw);
      if (ts != null && ts > 0) {
        // Unix seconds vs milliseconds heuristic
        final dt = ts > 1_000_000_000_000
            ? DateTime.fromMillisecondsSinceEpoch(ts)
            : DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        if (dt.year >= 2020 && dt.year <= 2100) {
          return ExpiryResult(expiresAt: dt);
        }
      }
      // ISO date string
      final dt = DateTime.tryParse(raw);
      if (dt != null && dt.year > 2020) return ExpiryResult(expiresAt: dt);
    }

    return const ExpiryResult(); // no expiry param found — unknown
  }
}
