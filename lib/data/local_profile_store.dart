import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sources/source_config.dart'; // newSourceId

/// A locally-stored profile. No cloud account needed — just a name and a
/// display colour index. Each local profile keeps its own snapshot of the
/// source list so profiles are truly isolated from one another.
class LocalProfile {
  final String id;
  final String name;
  final int colorIndex;

  /// Snapshot of the SourceConfig list belonging to this profile (raw JSON).
  final List<Map<String, dynamic>> sourcesJson;

  /// Which source was active when this profile was last used.
  final String? activeSourceId;

  const LocalProfile({
    required this.id,
    required this.name,
    required this.colorIndex,
    this.sourcesJson = const [],
    this.activeSourceId,
  });

  factory LocalProfile.fromJson(Map<String, dynamic> j) => LocalProfile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        colorIndex: (j['colorIndex'] as int?) ?? 0,
        sourcesJson: j['sources'] == null
            ? const []
            : List<Map<String, dynamic>>.from(
                (j['sources'] as List)
                    .map((e) => Map<String, dynamic>.from(e as Map)),
              ),
        activeSourceId: j['activeSourceId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorIndex': colorIndex,
        'sources': sourcesJson,
        if (activeSourceId != null) 'activeSourceId': activeSourceId,
      };
}

/// Persists [LocalProfile]s in the OS keychain via [FlutterSecureStorage].
class LocalProfileStore {
  static const _kProfiles = 'local_profiles_v1';
  static const _kActiveId = 'active_local_profile_id';

  final FlutterSecureStorage _storage;

  const LocalProfileStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<List<LocalProfile>> loadAll() async {
    final raw = await _storage.read(key: _kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List;
      return [
        for (final e in list)
          LocalProfile.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(LocalProfile profile) async {
    final all = await loadAll();
    final idx = all.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      all[idx] = profile;
    } else {
      all.add(profile);
    }
    await _storage.write(
      key: _kProfiles,
      value: json.encode([for (final p in all) p.toJson()]),
    );
  }

  Future<void> delete(String id) async {
    final all = await loadAll();
    all.removeWhere((p) => p.id == id);
    await _storage.write(
      key: _kProfiles,
      value: json.encode([for (final p in all) p.toJson()]),
    );
    if (await activeId() == id) await setActive(null);
  }

  Future<String?> activeId() => _storage.read(key: _kActiveId);

  Future<void> setActive(String? id) async {
    if (id == null) {
      await _storage.delete(key: _kActiveId);
    } else {
      await _storage.write(key: _kActiveId, value: id);
    }
  }

  /// Creates a new local profile with a generated UUID and the next colour slot.
  /// Pass [initialSourcesJson] / [initialActiveSourceId] to seed the profile's
  /// source list (e.g. the demo source when creating a fresh local profile).
  Future<LocalProfile> createProfile(
    String name,
    int colorIndex, {
    List<Map<String, dynamic>> initialSourcesJson = const [],
    String? initialActiveSourceId,
  }) async {
    final profile = LocalProfile(
      id: newSourceId(),
      name: name,
      colorIndex: colorIndex,
      sourcesJson: initialSourcesJson,
      activeSourceId: initialActiveSourceId,
    );
    await save(profile);
    return profile;
  }
}
