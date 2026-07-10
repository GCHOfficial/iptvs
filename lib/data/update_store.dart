import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the updater's small preferences — the version the user chose to
/// skip, and when we last checked GitHub — in the OS keychain. Mirrors
/// [LocalProfileStore]'s single-preference idiom (the app has no
/// SharedPreferences); the constructor takes an injectable storage for tests.
class UpdateStore {
  static const _kSkipped = 'update_skipped_version';
  static const _kLastCheck = 'update_last_check';

  final FlutterSecureStorage _storage;

  const UpdateStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// The version string the user pressed "Skip this version" on, if any.
  Future<String?> skippedVersion() => _storage.read(key: _kSkipped);

  Future<void> setSkippedVersion(String? version) async {
    if (version == null || version.isEmpty) {
      await _storage.delete(key: _kSkipped);
    } else {
      await _storage.write(key: _kSkipped, value: version);
    }
  }

  /// When the startup auto-check last ran (used to throttle it).
  Future<DateTime?> lastCheck() async {
    final raw = await _storage.read(key: _kLastCheck);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastCheck(DateTime time) =>
      _storage.write(key: _kLastCheck, value: time.toIso8601String());
}
