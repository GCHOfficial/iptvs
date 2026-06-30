import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sources/source.dart';
import '../sources/source_config.dart';
import 'app_database.dart';
import 'metadata_config.dart';
import 'source_store.dart';

/// A pairing code a device shows so a signed-in panel user can claim it.
class PairingCode {
  final String code;
  final DateTime expiresAt;
  const PairingCode(this.code, this.expiresAt);
}

/// A named profile on the account. An account holds several; a device picks
/// which one it syncs. Created/managed only in the web panel.
class CloudProfile {
  final String id;
  final String name;
  final int position;
  const CloudProfile({
    required this.id,
    required this.name,
    required this.position,
  });
}

/// The content kinds whose favorites are synced (live channels / movies /
/// series). Seasons/episodes aren't favorited at the top level.
const _favoriteKinds = [ContentKind.live, ContentKind.movie, ContentKind.series];

/// Maps a Supabase `sources` row to a [SourceConfig]. Pure (no network) so it
/// can be unit-tested directly. `fields` arrives as a JSON object whose values
/// are coerced back to strings to match [SourceConfig.fields].
SourceConfig cloudRowToConfig(Map<String, dynamic> row) {
  final rawFields = (row['fields'] as Map?) ?? const {};
  final fields = <String, String>{
    for (final e in rawFields.entries)
      e.key.toString(): e.value?.toString() ?? '',
  };
  final rawSettings = row['settings'] as Map?;
  return SourceConfig(
    id: row['id'] as String,
    kind: SourceKind.values.byName(row['kind'] as String),
    label: (row['label'] as String?) ?? '',
    fields: fields,
    settings: rawSettings == null
        ? const {}
        : Map<String, dynamic>.from(rawSettings),
  );
}

/// Read-only cloud sync: a device pairs with a panel account, then pulls the
/// account's source list and metadata config into the local [SourceStore]. The
/// device authenticates anonymously and never writes credentials upstream — the
/// web panel is the source of truth (see `supabase/migrations/0001_init.sql`).
class CloudSync {
  final SupabaseClient _client;
  final FlutterSecureStorage _storage;

  /// Needed to sync favorites (which live in the local SQLite cache, not the
  /// SourceStore). Null in tests that don't exercise favorites.
  final AppDatabase? _db;

  /// Ids of sources that came from the cloud last pull. Tracked so a later pull
  /// can remove ones deleted in the panel without touching local-only sources.
  static const _kCloudIds = 'cloud_source_ids';

  /// The profile this device last synced, cached so the picker can preselect it
  /// offline; the `devices.active_profile_id` row is the source of truth.
  static const _kProfileId = 'cloud_profile_id';

  CloudSync({
    SupabaseClient? client,
    FlutterSecureStorage? storage,
    AppDatabase? db,
  })  : _client = client ?? Supabase.instance.client,
        _storage = storage ?? const FlutterSecureStorage(),
        // ignore: prefer_initializing_formals -- mirrors _client/_storage style
        _db = db;

  /// The stable anonymous identity of this device, if a session exists.
  String? get deviceId => _client.auth.currentUser?.id;

  /// Ensure the device has a (persisted) anonymous session to act under.
  Future<void> ensureAnonSession() async {
    if (_client.auth.currentSession == null) {
      await _client.auth.signInAnonymously();
    }
  }

  /// Whether this device is currently paired to a panel account.
  Future<bool> isPaired() async {
    final id = deviceId;
    if (id == null) return false;
    final row = await _client
        .from('devices')
        .select('device_uid')
        .eq('device_uid', id)
        .maybeSingle();
    return row != null;
  }

  /// Ask the backend for a fresh, short-lived code to display for pairing.
  Future<PairingCode> requestPairingCode() async {
    await ensureAnonSession();
    final res = await _client.rpc('request_pairing') as List;
    final row = Map<String, dynamic>.from(res.first as Map);
    return PairingCode(
      row['code'] as String,
      DateTime.parse(row['expires_at'] as String),
    );
  }

  /// Poll whether [code] has been claimed by a panel account yet.
  Future<bool> pairingStatus(String code) async {
    final res = await _client.rpc('pairing_status', params: {'p_code': code});
    return res == true;
  }

  // ── profiles ──────────────────────────────────────────────────────────────

  /// The account's profiles, in panel order. A paired device may read these to
  /// let the user choose which one to sync.
  Future<List<CloudProfile>> listProfiles() async {
    final rows = await _client
        .from('profiles')
        .select('id, name, position')
        .order('position');
    return [
      for (final r in rows)
        CloudProfile(
          id: r['id'] as String,
          name: (r['name'] as String?) ?? '',
          position: (r['position'] as int?) ?? 0,
        ),
    ];
  }

  /// The profile this device currently syncs (from its `devices` row, falling
  /// back to the cached value), or null if unset.
  Future<String?> activeProfileId() async {
    final id = deviceId;
    if (id != null) {
      final row = await _client
          .from('devices')
          .select('active_profile_id')
          .eq('device_uid', id)
          .maybeSingle();
      final pid = row?['active_profile_id'] as String?;
      if (pid != null) {
        await _storage.write(key: _kProfileId, value: pid);
        return pid;
      }
    }
    return _storage.read(key: _kProfileId);
  }

  /// Choose which profile this device syncs (persisted server-side via the
  /// `set_device_profile` RPC and cached locally).
  Future<void> setProfile(String profileId) async {
    await _client.rpc('set_device_profile', params: {'p_profile_id': profileId});
    await _storage.write(key: _kProfileId, value: profileId);
  }

  /// Pull the given profile's sources into [store]. Cloud-managed sources are
  /// replaced and ordered to match the panel; any local-only sources the user
  /// added on the device are kept (after the cloud ones). Returns the number of
  /// cloud sources synced.
  Future<int> pullSources(SourceStore store, String profileId) async {
    final rows = await _client
        .from('sources')
        .select()
        .eq('profile_id', profileId)
        .order('position');
    final configs = [
      for (final r in rows) cloudRowToConfig(Map<String, dynamic>.from(r)),
    ];
    final newIds = configs.map((c) => c.id).toSet();
    final prevIds = await _readCloudIds();

    // Keep sources the user added on the device (never cloud-managed) in their
    // existing order; cloud sources go first, in the panel's order, so panel
    // reordering is reflected here. Previously-managed sources dropped from the
    // panel fall out of both lists and are removed.
    final localOnly = [
      for (final c in await store.list())
        if (!newIds.contains(c.id) && !prevIds.contains(c.id)) c,
    ];
    await store.setAll([...configs, ...localOnly]);
    await _writeCloudIds(newIds);
    return configs.length;
  }

  /// Pull the given profile's metadata provider config into [store], replacing
  /// the local one. Returns true when a config was applied; when the profile has
  /// none, the local config is left untouched and this returns false.
  Future<bool> pullMetadata(SourceStore store, String profileId) async {
    final row = await _client
        .from('metadata_configs')
        .select('config')
        .eq('profile_id', profileId)
        .maybeSingle();
    if (row == null) return false;
    final config = Map<String, dynamic>.from(row['config'] as Map);
    await store.saveMetadataConfig(MetadataConfig.fromJson(config));
    return true;
  }

  /// Pull the given profile's favorites into the local cache, replacing those of
  /// the cloud-managed sources. Cloud favorites reference the `SourceConfig`
  /// UUID; local favorites are keyed by the credential-derived `Source.id`, so
  /// we map between them via `config.build().id`. Run after [pullSources] so the
  /// cloud-managed set and source configs are current. No-op without a database.
  Future<void> pullFavorites(SourceStore store, String profileId) async {
    final db = _db;
    if (db == null) return;
    final row = await _client
        .from('profiles')
        .select('favorites')
        .eq('id', profileId)
        .maybeSingle();
    final favorites = (row?['favorites'] as List?) ?? const [];

    final managed = await _readCloudIds();
    final byUuid = {for (final c in await store.list()) c.id: c};

    // Clear existing favorites for the cloud-managed sources, then apply the
    // profile's set (so a pull mirrors the profile, last-write-wins).
    for (final uuid in managed) {
      final config = byUuid[uuid];
      if (config == null) continue;
      final sourceId = config.build().id;
      for (final kind in _favoriteKinds) {
        for (final itemId in await db.readFavoriteIds(sourceId, kind)) {
          await db.setFavorite(sourceId, kind, itemId, false);
        }
      }
    }
    for (final entry in favorites) {
      final fav = Map<String, dynamic>.from(entry as Map);
      final config = byUuid[fav['source_id']];
      if (config == null) continue;
      final kindName = fav['kind'] as String?;
      final itemId = fav['item_id'] as String?;
      if (kindName == null || itemId == null) continue;
      final kind = ContentKind.values.asNameMap()[kindName];
      if (kind == null) continue;
      await db.setFavorite(config.build().id, kind, itemId, true);
    }
  }

  /// Push this device's full source list up to the paired account, replacing the
  /// panel's set (last-write-wins, mediated by the `push_sources` RPC so the
  /// device never has direct write access). Legacy non-UUID local ids are first
  /// rewritten to UUIDs and persisted, so device and cloud share ids and the push
  /// is idempotent. After a push the whole local list is cloud-managed. Returns
  /// the number of sources pushed.
  Future<int> pushSources(SourceStore store, String profileId) async {
    final all = await store.list();
    final activeOld = await store.activeId();
    String? activeNew = activeOld;
    var rewroteAny = false;
    final normalized = <SourceConfig>[];
    for (final c in all) {
      if (isUuid(c.id)) {
        normalized.add(c);
        continue;
      }
      final fresh = SourceConfig(
        id: newSourceId(),
        kind: c.kind,
        label: c.label,
        fields: c.fields,
        settings: c.settings,
      );
      if (c.id == activeOld) activeNew = fresh.id;
      normalized.add(fresh);
      rewroteAny = true;
    }
    if (rewroteAny) {
      await store.setAll(normalized); // may reset active; restore it next
      await store.setActive(activeNew);
    }

    final payload = [
      for (var i = 0; i < normalized.length; i++)
        {
          'id': normalized[i].id,
          'kind': normalized[i].kind.name,
          'label': normalized[i].label,
          'fields': normalized[i].fields,
          'settings': normalized[i].settings,
          'position': i,
        },
    ];
    await _client.rpc('push_sources', params: {
      'p_sources': payload,
      'p_profile_id': profileId,
    });
    // Everything we just pushed is now cloud-managed.
    await _writeCloudIds(normalized.map((c) => c.id).toSet());
    return normalized.length;
  }

  /// Push this device's metadata provider config up to the given profile
  /// (last-write-wins, via the `push_metadata` RPC).
  Future<void> pushMetadata(SourceStore store, String profileId) async {
    final config = await store.metadataConfig();
    await _client.rpc('push_metadata', params: {
      'p_config': config.toJson(),
      'p_profile_id': profileId,
    });
  }

  /// Push this device's favorites (for the cloud-managed sources) up to the
  /// given profile, mapping each `Source.id` back to its `SourceConfig` UUID.
  /// Run after [pushSources] so ids are normalized and cloud-managed. No-op
  /// without a database.
  Future<void> pushFavorites(SourceStore store, String profileId) async {
    final db = _db;
    if (db == null) return;
    final managed = await _readCloudIds();
    final byUuid = {for (final c in await store.list()) c.id: c};
    final favorites = <Map<String, dynamic>>[];
    for (final uuid in managed) {
      final config = byUuid[uuid];
      if (config == null) continue;
      final sourceId = config.build().id;
      for (final kind in _favoriteKinds) {
        for (final itemId in await db.readFavoriteIds(sourceId, kind)) {
          favorites.add({
            'source_id': config.id,
            'kind': kind.name,
            'item_id': itemId,
          });
        }
      }
    }
    await _client.rpc('push_favorites', params: {
      'p_favorites': favorites,
      'p_profile_id': profileId,
    });
  }

  /// Self-unpair: drop the cloud-managed sources locally and remove this
  /// device's pairing rows. The account can also revoke from the panel.
  Future<void> unpair(SourceStore store) async {
    for (final id in await _readCloudIds()) {
      await store.delete(id);
    }
    await _storage.delete(key: _kCloudIds);
    await _storage.delete(key: _kProfileId);
    final id = deviceId;
    if (id == null) return;
    try {
      await _client.from('devices').delete().eq('device_uid', id);
      await _client.from('pairings').delete().eq('device_uid', id);
    } catch (_) {
      // Best-effort cleanup; the panel can still revoke server-side.
    }
  }

  Future<Set<String>> _readCloudIds() async {
    final raw = await _storage.read(key: _kCloudIds);
    if (raw == null || raw.isEmpty) return <String>{};
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _writeCloudIds(Set<String> ids) =>
      _storage.write(key: _kCloudIds, value: ids.join(','));
}
