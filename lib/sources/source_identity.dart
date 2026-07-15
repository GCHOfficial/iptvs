import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

const _m3uChannelPrefix = 'm3u-channel:';

/// Canonical form used only to derive an M3U channel's opaque identity.
///
/// HTTP locator scheme/host casing, default ports, path dot-segments, and URL
/// fragments do not change the resource requested from the provider, so they
/// must not create a different channel. Query order and user-info are retained:
/// providers can assign meaning to either, and changing them blindly could
/// merge distinct streams.
@visibleForTesting
String normalizeM3uLocator(String locator) {
  final trimmed = locator.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.hasScheme) return trimmed;

  final scheme = parsed.scheme.toLowerCase();
  final host = parsed.host.toLowerCase();
  final defaultPort =
      (scheme == 'http' && parsed.port == 80) ||
      (scheme == 'https' && parsed.port == 443);
  final normalized = Uri(
    scheme: scheme,
    userInfo: parsed.userInfo,
    host: host,
    port: parsed.hasPort && !defaultPort ? parsed.port : null,
    path: parsed.path,
    query: parsed.hasQuery ? parsed.query : null,
  ).normalizePath();
  return normalized.toString();
}

/// Stable, credential-opaque M3U channel identifier.
///
/// Equal normalized locators intentionally share an identity. Different
/// locators use the full SHA-256 digest; a cryptographic collision is treated
/// as the same identity rather than leaking either locator into persisted keys.
String stableM3uChannelId(String locator) =>
    '$_m3uChannelPrefix${sha256.convert(utf8.encode(normalizeM3uLocator(locator)))}';

bool isStableM3uChannelId(String value) => value.startsWith(_m3uChannelPrefix);
