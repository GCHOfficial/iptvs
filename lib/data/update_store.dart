import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'distribution_channel.dart';
import 'update_manifest.dart';

/// A fully downloaded Android update whose manifest and bytes were verified.
///
/// This small record survives settings/OEM-installer detours and process
/// recreation. The APK itself remains in the app-owned cache; callers must
/// verify its size/hash again before each installer launch.
class PendingUpdate {
  const PendingUpdate({
    required this.version,
    required this.path,
    required this.releasePage,
    required this.artifact,
  });

  final String version;
  final String path;
  final Uri releasePage;
  final ReleaseArtifact artifact;

  Map<String, dynamic> toJson() => {
    'version': version,
    'path': path,
    'release_page': releasePage.toString(),
    'artifact': {
      'platform': artifact.platform,
      'filename': artifact.filename,
      'byte_size': artifact.byteSize,
      'sha256': artifact.sha256,
    },
  };

  static PendingUpdate fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final path = json['path'];
    final releasePage = Uri.tryParse(json['release_page']?.toString() ?? '');
    final artifactJson = json['artifact'];
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        path is! String ||
        path.isEmpty ||
        releasePage == null ||
        releasePage.scheme != 'https' ||
        releasePage.host != 'github.com' ||
        artifactJson is! Map) {
      throw const FormatException('Invalid pending update');
    }
    final artifact = ReleaseArtifact.fromJson(
      Map<String, dynamic>.from(artifactJson),
      version,
    );
    if (artifact.platform != 'android') {
      throw const FormatException('Pending update is not an Android APK');
    }
    return PendingUpdate(
      version: version,
      path: path,
      releasePage: releasePage,
      artifact: artifact,
    );
  }
}

/// Persists the updater's small preferences — the version the user chose to
/// skip, and when we last checked GitHub — in the OS keychain. Mirrors
/// [LocalProfileStore]'s single-preference idiom (the app has no
/// SharedPreferences); the constructor takes an injectable storage for tests.
class UpdateStore {
  static const _kSkipped = 'update_skipped_version';
  static const _kLastCheck = 'update_last_check';
  static const _kTrack = 'update_track';
  static const _kPending = 'update_pending_install';

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

  Future<UpdateTrack> track() async =>
      parseUpdateTrack(await _storage.read(key: _kTrack));

  Future<void> setTrack(UpdateTrack track) =>
      _storage.write(key: _kTrack, value: track.storageValue);

  Future<PendingUpdate?> pendingUpdate() async {
    final raw = await _storage.read(key: _kPending);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid pending update');
      }
      return PendingUpdate.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      await clearPendingUpdate();
      return null;
    }
  }

  Future<void> setPendingUpdate(PendingUpdate pending) =>
      _storage.write(key: _kPending, value: jsonEncode(pending.toJson()));

  Future<void> clearPendingUpdate() => _storage.delete(key: _kPending);
}
