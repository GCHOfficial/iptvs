import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sources/source_config.dart'; // newSourceId

/// When the boot-time profile picker should appear.
enum ProfilePickerStartup {
  /// Show only when there's actually a choice to make (more than one profile).
  auto,

  /// Show on every launch.
  always,

  /// Never show at startup (profiles stay reachable from the avatar menu).
  off,
}

/// Pure decision for the boot short-circuit — unit-tested directly.
bool shouldShowPickerAtStartup(ProfilePickerStartup mode, int profileCount) {
  switch (mode) {
    case ProfilePickerStartup.auto:
      // Show on first launch (0 profiles) so the user can create one, and
      // whenever there is a real choice to make (>1 profile).  Skip when
      // exactly one profile exists — nothing to choose.
      return profileCount != 1;
    case ProfilePickerStartup.always:
      return true;
    case ProfilePickerStartup.off:
      return false;
  }
}

/// The device state a profile owns: its source list, which source was active,
/// the metadata config, and — for cloud profiles — the cloud-managed source
/// ids (`CloudSync`'s pull bookkeeping). Snapshotting/restoring all of these
/// together is what makes switching profiles side-effect-free: a local
/// profile can never inherit another profile's sources, and a cloud profile
/// keeps its device-local extras across switches.
class ProfileSnapshot {
  /// Raw [SourceConfig.toJson] maps, in list order.
  final List<Map<String, dynamic>> sourcesJson;
  final String? activeSourceId;

  /// Raw `MetadataConfig.toJson()`; null means "leave the current config".
  final Map<String, dynamic>? metadataJson;

  /// Cloud-managed source ids at snapshot time. Always empty for local
  /// profiles — restoring one clears the managed set so a later cloud pull
  /// can't merge cloud sources into a local profile.
  final List<String> managedIds;

  const ProfileSnapshot({
    this.sourcesJson = const [],
    this.activeSourceId,
    this.metadataJson,
    this.managedIds = const [],
  });

  factory ProfileSnapshot.fromJson(Map<String, dynamic> j) => ProfileSnapshot(
        sourcesJson: j['sources'] == null
            ? const []
            : [
                for (final e in j['sources'] as List)
                  Map<String, dynamic>.from(e as Map),
              ],
        activeSourceId: j['activeSourceId'] as String?,
        metadataJson: j['metadata'] == null
            ? null
            : Map<String, dynamic>.from(j['metadata'] as Map),
        managedIds: j['managedIds'] == null
            ? const []
            : [for (final e in j['managedIds'] as List) e.toString()],
      );

  Map<String, dynamic> toJson() => {
        'sources': sourcesJson,
        if (activeSourceId != null) 'activeSourceId': activeSourceId,
        if (metadataJson != null) 'metadata': metadataJson,
        if (managedIds.isNotEmpty) 'managedIds': managedIds,
      };
}

/// A locally-stored profile. No cloud account needed — just a name, a display
/// colour index, and its [ProfileSnapshot] of the device state.
class LocalProfile {
  final String id;
  final String name;
  final int colorIndex;
  final ProfileSnapshot snapshot;

  const LocalProfile({
    required this.id,
    required this.name,
    required this.colorIndex,
    this.snapshot = const ProfileSnapshot(),
  });

  LocalProfile withSnapshot(ProfileSnapshot snapshot) => LocalProfile(
        id: id,
        name: name,
        colorIndex: colorIndex,
        snapshot: snapshot,
      );

  factory LocalProfile.fromJson(Map<String, dynamic> j) => LocalProfile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        colorIndex: (j['colorIndex'] as int?) ?? 0,
        snapshot: j['snapshot'] == null
            ? const ProfileSnapshot()
            : ProfileSnapshot.fromJson(
                Map<String, dynamic>.from(j['snapshot'] as Map),
              ),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorIndex': colorIndex,
        'snapshot': snapshot.toJson(),
      };
}

/// Persists [LocalProfile]s — plus per-cloud-profile device snapshots and the
/// picker's startup mode — in the OS keychain via [FlutterSecureStorage].
class LocalProfileStore {
  static const _kProfiles = 'local_profiles_v1';
  static const _kActiveId = 'active_local_profile_id';
  static const _kCloudSnapshots = 'cloud_profile_snapshots_v1';
  static const _kPickerStartup = 'profile_picker_startup';

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

  /// The active *local* profile, or null when a cloud profile (or nothing) is
  /// active — cloud profile selection lives in `CloudSync`.
  Future<String?> activeId() => _storage.read(key: _kActiveId);

  Future<void> setActive(String? id) async {
    if (id == null) {
      await _storage.delete(key: _kActiveId);
    } else {
      await _storage.write(key: _kActiveId, value: id);
    }
  }

  /// Creates a new local profile with a generated UUID. Pass [snapshot] to
  /// seed its source list (e.g. the demo source for a fresh profile).
  Future<LocalProfile> createProfile(
    String name,
    int colorIndex, {
    ProfileSnapshot snapshot = const ProfileSnapshot(),
  }) async {
    final profile = LocalProfile(
      id: newSourceId(),
      name: name,
      colorIndex: colorIndex,
      snapshot: snapshot,
    );
    await save(profile);
    return profile;
  }

  // ── Cloud-profile device snapshots ────────────────────────────────────────
  // A cloud profile's sources come from a pull, but the device may also hold
  // local-only sources alongside them; snapshotting per cloud profile keeps
  // those (and the managed-ids set) from leaking across profile switches.

  Future<ProfileSnapshot?> cloudSnapshot(String profileId) async {
    final raw = await _storage.read(key: _kCloudSnapshots);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = Map<String, dynamic>.from(json.decode(raw) as Map);
      final entry = map[profileId];
      if (entry == null) return null;
      return ProfileSnapshot.fromJson(Map<String, dynamic>.from(entry as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCloudSnapshot(
    String profileId,
    ProfileSnapshot snapshot,
  ) async {
    Map<String, dynamic> map = {};
    final raw = await _storage.read(key: _kCloudSnapshots);
    if (raw != null && raw.isNotEmpty) {
      try {
        map = Map<String, dynamic>.from(json.decode(raw) as Map);
      } catch (_) {}
    }
    map[profileId] = snapshot.toJson();
    await _storage.write(key: _kCloudSnapshots, value: json.encode(map));
  }

  // ── Startup-picker mode ───────────────────────────────────────────────────

  Future<ProfilePickerStartup> pickerStartup() async {
    final raw = await _storage.read(key: _kPickerStartup);
    return ProfilePickerStartup.values.asNameMap()[raw] ??
        ProfilePickerStartup.auto;
  }

  Future<void> setPickerStartup(ProfilePickerStartup mode) =>
      _storage.write(key: _kPickerStartup, value: mode.name);
}
