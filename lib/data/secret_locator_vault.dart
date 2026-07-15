import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypts provider-owned playback locators before they enter the SQLite
/// cache. The key is generated once per installation and never leaves secure
/// storage; losing it intentionally makes the regenerable cache unreadable.
class SecretLocatorVault {
  SecretLocatorVault({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const keyName = 'cache_secret_locator_key_v1';
  static final _algorithm = AesGcm.with256bits();
  static SecretKey? _fallbackKey;

  final FlutterSecureStorage _storage;
  SecretKey? _key;
  bool generatedNewKey = false;

  Future<SecretKey> _secretKey() async {
    final cached = _key;
    if (cached != null) return cached;
    String? encoded;
    try {
      encoded = await _storage.read(key: keyName);
    } catch (_) {
      // Host-side FFI tests have no secure-storage plugin. Keep those tests
      // deterministic without weakening the real platform path.
      return _key = _fallbackKey ??= await _algorithm.newSecretKey();
    }
    if (encoded == null || encoded.isEmpty) {
      generatedNewKey = true;
      final generated = await _algorithm.newSecretKey();
      encoded = base64UrlEncode(await generated.extractBytes());
      try {
        await _storage.write(key: keyName, value: encoded);
      } catch (_) {
        return _key = _fallbackKey ??= generated;
      }
    }
    final bytes = base64Url.decode(encoded);
    if (bytes.length != 32) throw const FormatException('Invalid cache key');
    return _key = SecretKey(bytes);
  }

  Future<void> ensureKey() => _secretKey().then((_) {});

  Future<String> encrypt(Map<String, String> locators) async {
    if (locators.isEmpty) return '';
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(locators)),
      secretKey: await _secretKey(),
    );
    return base64UrlEncode(box.concatenation());
  }

  Future<Map<String, String>> decrypt(String encoded) async {
    if (encoded.isEmpty) return const {};
    final box = SecretBox.fromConcatenation(
      base64Url.decode(encoded),
      nonceLength: 12,
      macLength: 16,
    );
    final clear = await _algorithm.decrypt(box, secretKey: await _secretKey());
    final value = jsonDecode(utf8.decode(Uint8List.fromList(clear)));
    if (value is! Map) throw const FormatException('Invalid secret locator');
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }
}

const secretLocatorKey = 'secretLocator';

const _secretLocatorFields = {
  'url',
  'cmd',
  'streamUrl',
  'stream_url',
  'movieUrl',
  'movie_url',
  'episodeUrl',
  'episode_url',
  'link',
};

Future<Map<String, dynamic>> protectSecretLocators(
  Map<String, dynamic> extra,
  SecretLocatorVault vault,
) async {
  final locators = <String, String>{};
  final regular = <String, dynamic>{};
  final existingEncrypted = extra[secretLocatorKey]?.toString();
  for (final entry in extra.entries) {
    if (_secretLocatorFields.contains(entry.key) && entry.value is String) {
      locators[entry.key] = entry.value as String;
    } else if (entry.key != secretLocatorKey) {
      regular[entry.key] = entry.value;
    }
  }
  final encrypted = await vault.encrypt(locators);
  if (encrypted.isNotEmpty) {
    regular[secretLocatorKey] = encrypted;
  } else if (existingEncrypted != null && existingEncrypted.isNotEmpty) {
    regular[secretLocatorKey] = existingEncrypted;
  }
  return regular;
}

Future<Map<String, dynamic>> restoreSecretLocators(
  Map<String, dynamic> extra,
  SecretLocatorVault vault,
) async {
  final encoded = extra[secretLocatorKey]?.toString();
  if (encoded == null || encoded.isEmpty) return extra;
  final restored = await vault.decrypt(encoded);
  final result = <String, dynamic>{...extra}..remove(secretLocatorKey);
  result.addAll(restored);
  return result;
}
