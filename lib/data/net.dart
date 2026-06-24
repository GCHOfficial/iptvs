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
