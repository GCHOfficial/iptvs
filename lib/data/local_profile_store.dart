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
///
/// [activeProfileLocked] overrides every mode: a profile with a PIN must be
/// re-opened with it on each launch, and the only place that can ask is this
/// screen. Without the override, `off` (and `auto` with a single profile) would
/// boot straight into the locked profile's library — the gate would exist only
/// for accounts that happen to have several profiles *and* have left the picker
/// on, which is not a gate at all.
///
/// [hasActiveProfile] false while profiles exist overrides every mode too, for
/// the mirror-image reason: the device state belongs to *no* profile, and the
/// picker is the only thing that can restore a snapshot. That state is reached
/// by deleting the active profile, which drops to the empty baseline and marks
/// nothing active, deliberately — so booting past the picker here means booting
/// into an empty library that no restart can fix, because with one profile left
/// `auto` never shows the picker again. The user had to find the profile
/// switcher by hand to recover.
///
/// It is the caller's [LocalProfileStore.ownerless] mark, not "is some profile
/// drawn as active": an offline device can't draw its active cloud profile and
/// still holds that profile's sources.
bool shouldShowPickerAtStartup(
  ProfilePickerStartup mode,
  int profileCount, {
  bool activeProfileLocked = false,
  bool hasActiveProfile = true,
}) {
  if (activeProfileLocked) return true;
  if (profileCount > 0 && !hasActiveProfile) return true;
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

class SnapshotRestorePreview {
  final int sourcesAdded;
  final int sourcesRemoved;
  final int sourcesRetained;
  final String? activeSourceLabel;
  final bool metadataChanges;
  final int managedSources;

  const SnapshotRestorePreview({
    required this.sourcesAdded,
    required this.sourcesRemoved,
    required this.sourcesRetained,
    required this.activeSourceLabel,
    required this.metadataChanges,
    required this.managedSources,
  });
}

/// Credential-free description of the effects of replacing [current] with
/// [target]. Only source ids/labels and aggregate counts are inspected; fields
/// containing provider URLs or credentials are never included in the result.
SnapshotRestorePreview previewSnapshotRestore(
  ProfileSnapshot current,
  ProfileSnapshot target,
) {
  String? idOf(Map<String, dynamic> source) => source['id']?.toString();
  final currentIds = {
    for (final source in current.sourcesJson)
      if (idOf(source) case final String id) id,
  };
  final targetIds = {
    for (final source in target.sourcesJson)
      if (idOf(source) case final String id) id,
  };
  String? activeLabel;
  for (final source in target.sourcesJson) {
    if (idOf(source) == target.activeSourceId) {
      final label = source['label']?.toString().trim();
      activeLabel = label == null || label.isEmpty ? 'Unnamed source' : label;
      break;
    }
  }
  return SnapshotRestorePreview(
    sourcesAdded: targetIds.difference(currentIds).length,
    sourcesRemoved: currentIds.difference(targetIds).length,
    sourcesRetained: currentIds.intersection(targetIds).length,
    activeSourceLabel: activeLabel,
    metadataChanges:
        json.encode(current.metadataJson) != json.encode(target.metadataJson),
    managedSources: target.managedIds.length,
  );
}

/// A locally-stored profile. No cloud account needed — just a name, a display
/// colour index, an optional PIN, and its [ProfileSnapshot] of the device state.
class LocalProfile {
  final String id;
  final String name;
  final int colorIndex;

  /// The profile's PIN verifier (`profile_pin.dart`), or null when the profile
  /// is open. Never the PIN itself.
  ///
  /// It rides the profile row into the keychain and **nowhere else** — a local
  /// profile has no cloud row, and this must not be confused with the cloud
  /// column of the same purpose (`CloudSync.setProfilePin`).
  final String? pin;
  final ProfileSnapshot snapshot;

  const LocalProfile({
    required this.id,
    required this.name,
    required this.colorIndex,
    this.pin,
    this.snapshot = const ProfileSnapshot(),
  });

  bool get locked => pin != null && pin!.isNotEmpty;

  LocalProfile withSnapshot(ProfileSnapshot snapshot) => LocalProfile(
    id: id,
    name: name,
    colorIndex: colorIndex,
    pin: pin,
    snapshot: snapshot,
  );

  /// [pin] of null clears the PIN — this is the one field whose "absent" and
  /// "unchanged" cases differ, so it is a separate call rather than a
  /// `copyWith` default.
  LocalProfile withPin(String? pin) => LocalProfile(
    id: id,
    name: name,
    colorIndex: colorIndex,
    pin: pin,
    snapshot: snapshot,
  );

  factory LocalProfile.fromJson(Map<String, dynamic> j) => LocalProfile(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    colorIndex: (j['colorIndex'] as int?) ?? 0,
    pin: (j['pin'] as String?)?.trim().isEmpty ?? true
        ? null
        : (j['pin'] as String).trim(),
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
    if (pin != null) 'pin': pin,
    'snapshot': snapshot.toJson(),
  };
}

/// A cloud profile's cached lock: the PIN verifier plus the name to draw it
/// with. See [LocalProfileStore.cloudPins].
class CloudProfileLock {
  final String verifier;
  final String name;

  const CloudProfileLock({required this.verifier, this.name = ''});

  static CloudProfileLock? fromJson(Map<String, dynamic> j) {
    final verifier = (j['pin'] as String?)?.trim() ?? '';
    if (verifier.isEmpty) return null;
    return CloudProfileLock(
      verifier: verifier,
      name: (j['name'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'pin': verifier, 'name': name};
}

/// Persists [LocalProfile]s — plus per-cloud-profile device snapshots and the
/// picker's startup mode — in the OS keychain via [FlutterSecureStorage].
class LocalProfileStore {
  static const _kProfiles = 'local_profiles_v1';
  static const _kActiveId = 'active_local_profile_id';
  static const _kCloudSnapshots = 'cloud_profile_snapshots_v1';
  static const _kPickerStartup = 'profile_picker_startup';
  static const _kCloudPins = 'cloud_profile_pins_v1';
  static const _kOwnerless = 'profile_state_ownerless';

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

  // ── Ownerless device state ────────────────────────────────────────────────
  // Set when the *active* profile is deleted: the live source list is reset to
  // the empty baseline and no profile owns it any more. It is an explicit fact
  // rather than something inferred from "is there an active id", because the
  // two persisted selections can't express it between them — deleting the
  // active local profile clears `activeId` but leaves the cloud
  // `active_profile_id` pointing at a profile whose sources are *not* loaded
  // (switching to a local profile never clears it, and there is no RPC to),
  // so the picker would mark that profile active, short-circuit the boot into
  // it, and answer a tap on it with the identity shortcut — landing in an
  // empty library either way.
  //
  // Cleared by every path that hands the device to a profile: selecting one,
  // creating one, and the sole-survivor adoption after a delete.

  Future<bool> ownerless() async =>
      (await _storage.read(key: _kOwnerless)) == '1';

  Future<void> setOwnerless(bool value) async {
    if (value) {
      await _storage.write(key: _kOwnerless, value: '1');
    } else {
      await _storage.delete(key: _kOwnerless);
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

  /// Set (or, with null, clear) a local profile's PIN verifier. A no-op for an
  /// id that isn't stored, so a delete racing a PIN change can't resurrect a
  /// profile row.
  Future<void> setPin(String id, String? verifier) async {
    final all = await loadAll();
    final idx = all.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    all[idx] = all[idx].withPin(verifier);
    await _storage.write(
      key: _kProfiles,
      value: json.encode([for (final p in all) p.toJson()]),
    );
  }

  // ── Cloud-profile PIN cache ───────────────────────────────────────────────
  // A cloud profile's PIN lives in its cloud row, but the gate has to hold when
  // the network doesn't: the boot check runs before any cloud call can answer,
  // and a device that is offline (or whose token has expired) must not let a
  // locked profile through just because it couldn't ask.
  //
  // So every successful profile listing mirrors the locked profiles here, and
  // the picker falls back to this cache when the listing fails. The **name** is
  // cached beside the verifier for one specific reason: an offline boot into a
  // locked cloud profile has to show that profile so its PIN can be typed. With
  // only the verifier there would be nothing to draw — the picker would present
  // a screen with no way forward at all.
  //
  // Staleness only ever fails *closed*: a PIN cleared on the panel while this
  // device was offline stays enforced until the next successful listing, which
  // is the safe direction and self-heals. The cache holds verifiers, never
  // PINs, and only for profiles that actually have one.

  Future<Map<String, CloudProfileLock>> cloudPins() async {
    final raw = await _storage.read(key: _kCloudPins);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final map = Map<String, dynamic>.from(json.decode(raw) as Map);
      final out = <String, CloudProfileLock>{};
      for (final e in map.entries) {
        if (e.value is! Map) continue;
        final lock = CloudProfileLock.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        );
        if (lock != null) out[e.key] = lock;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Replace the whole cache from a fresh listing. A *replace*, not a merge:
  /// a profile whose PIN was cleared on the panel is simply absent from
  /// [locks], and merging would keep enforcing a PIN the account no longer has.
  Future<void> saveCloudPins(Map<String, CloudProfileLock> locks) =>
      _storage.write(
        key: _kCloudPins,
        value: json.encode({
          for (final e in locks.entries) e.key: e.value.toJson(),
        }),
      );

  /// Drop every cached cloud lock. Called when the device unpairs: these
  /// verifiers belong to the account being left, and a re-pair to a *different*
  /// account that happens to reuse a profile id would otherwise inherit them
  /// and shut a profile nobody locked. Same reasoning as `CloudSync`'s sticky
  /// E2EE marks, which are cleared in the same place.
  Future<void> clearCloudPins() => _storage.delete(key: _kCloudPins);

  /// Update one profile's cached lock without waiting for the next listing —
  /// used right after this device sets or clears a PIN itself.
  Future<void> setCloudPin(
    String profileId,
    String? verifier, {
    String name = '',
  }) async {
    final map = Map<String, CloudProfileLock>.from(await cloudPins());
    if (verifier == null || verifier.isEmpty) {
      map.remove(profileId);
    } else {
      map[profileId] = CloudProfileLock(
        verifier: verifier,
        name: name.isEmpty ? (map[profileId]?.name ?? '') : name,
      );
    }
    await saveCloudPins(map);
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
