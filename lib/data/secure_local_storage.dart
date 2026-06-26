import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persists the Supabase auth session in the OS keychain (via
/// flutter_secure_storage) instead of plaintext shared-preferences — the device
/// session is a long-lived credential, so it gets the same treatment as the
/// provider credentials the app already stores there.
class SecureLocalStorage extends LocalStorage {
  final FlutterSecureStorage _storage;
  static const _key = 'supabase_session';

  SecureLocalStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
