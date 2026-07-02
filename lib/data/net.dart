import 'dart:io';
import 'dart:typed_data';

/// Ceiling for waiting on response headers and for the gap between body
/// chunks. [HttpClient.connectionTimeout] only covers the TCP handshake, so a
/// server that connects then stalls would otherwise hang a request forever —
/// a real risk against flaky IPTV panels and third-party metadata APIs.
const Duration kHttpReadTimeout = Duration(seconds: 20);

extension HttpResponseRead on HttpClientResponse {
  /// Drains the body to bytes, throwing [TimeoutException] if no chunk arrives
  /// within [timeout]. The timer resets on each chunk, so it caps stalls
  /// rather than total transfer time.
  Future<Uint8List> readBytes({Duration timeout = kHttpReadTimeout}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in this.timeout(timeout)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

/// Redacts secret-looking material from free-form [text] (an exception
/// message, an mpv log line) so it is safe to log or show on screen. Finds an
/// embedded http(s) URL and redacts its path segments that look like
/// credentials (long or token-shaped) — IPTV providers put username/password
/// in the *path* (`/live/user/pass/123.ts`), which [redactUrl]'s query-focused
/// redaction wouldn't touch.
String redactText(String text) {
  final urlMatch = RegExp(
    r'https?://\S+',
    caseSensitive: false,
  ).firstMatch(text);
  if (urlMatch != null) {
    final redactedUrl = _redactUrlPath(urlMatch.group(0)!);
    return text.replaceRange(urlMatch.start, urlMatch.end, redactedUrl);
  }
  return _redactUrlPath(text);
}

String _redactUrlPath(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return value;
  if (!uri.hasAuthority && !value.contains('/')) return value;
  final cleanSegments = uri.pathSegments.map((segment) {
    final looksSecret =
        segment.length > 18 || RegExp(r'^[A-Za-z0-9_-]{12,}$').hasMatch(segment);
    return looksSecret ? '<redacted>' : segment;
  }).toList();
  final path = cleanSegments.join('/');
  final authority = uri.hasAuthority ? '${uri.scheme}://${uri.authority}' : '';
  final prefix = authority.isNotEmpty
      ? authority
      : (uri.scheme.isNotEmpty ? '${uri.scheme}:' : '');
  return '$prefix/${path.replaceAll(RegExp(r'/+'), '/')}';
}

/// Removes credentials from [url] so it is safe to surface in error messages,
/// logs, and exported diagnostics. Drops any userinfo (`user:pass@`) and
/// replaces the query string — IPTV panels carry username/password as query
/// params — while keeping scheme/host/port/path for debugging.
String redactUrl(Object url) {
  final text = url.toString();
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.isEmpty) {
    return text.split('?').first;
  }
  final out = StringBuffer()
    ..write(uri.scheme)
    ..write('://')
    ..write(uri.host);
  if (uri.hasPort) out.write(':${uri.port}');
  out.write(uri.path);
  if (uri.hasQuery) out.write('?<redacted>');
  return out.toString();
}
