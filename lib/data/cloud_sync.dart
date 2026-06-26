import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sources/source_config.dart';
import 'metadata_config.dart';
import 'source_store.dart';

/// A pairing code a device shows so a signed-in panel user can claim it.
class PairingCode {
  final String code;
  final DateTime expiresAt;
  const PairingCode(this.code, this.expiresAt);
}

/// Maps a Supabase `sources` row to a [SourceConfig]. Pure (no network) so it
/// can be unit-tested directly. `fields` arrives as a JSON object whose values
/// are coerced back to strings to match [SourceConfig.fields].
SourceConfig cloudRowToConfig(Map<String, dynamic> row) {
  final rawFields = (row['fields'] as Map?) ?? const {};
  final fields = <String, String>{
    for (final e in rawFields.entries)
      e.key.toString(): e.value?.toString() ?? '',
  };
  return SourceConfig(
    id: row['id'] as String,
    kind: SourceKind.values.byName(row['kind'] as String),
    label: (row['label'] as String?) ?? '',
    fields: fields,
  );
}

/// Read-only cloud sync: a device pairs with a panel account, then pulls the
/// account's source list and metadata config into the local [SourceStore]. The
/// device authenticates anonymously and never writes credentials upstream — the
/// web panel is the source of truth (see `supabase/migrations/0001_init.sql`).
class CloudSync {
  final SupabaseClient _client;
  final FlutterSecureStorage _storage;

  /// Ids of sources that came from the cloud last pull. Tracked so a later pull
  /// can remove ones deleted in the panel without touching local-only sources.
  static const _kCloudIds = 'cloud_source_ids';

  CloudSync({SupabaseClient? client, FlutterSecureStorage? storage})
      : _client = client ?? Supabase.instance.client,
        _storage = storage ?? const FlutterSecureStorage();

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

  /// Pull the paired account's sources into [store]. Cloud-managed sources are
  /// replaced and ordered to match the panel; any local-only sources the user
  /// added on the device are kept (after the cloud ones). Returns the number of
  /// cloud sources synced.
  Future<int> pullSources(SourceStore store) async {
    final rows = await _client.from('sources').select().order('position');
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

  /// Pull the paired account's metadata provider config into [store], replacing
  /// the local one. Returns true when a config was applied; when the panel has
  /// none, the local config is left untouched and this returns false.
  Future<bool> pullMetadata(SourceStore store) async {
    final row = await _client
        .from('metadata_configs')
        .select('config')
        .maybeSingle();
    if (row == null) return false;
    final config = Map<String, dynamic>.from(row['config'] as Map);
    await store.saveMetadataConfig(MetadataConfig.fromJson(config));
    return true;
  }

  /// Push this device's full source list up to the paired account, replacing the
  /// panel's set (last-write-wins, mediated by the `push_sources` RPC so the
  /// device never has direct write access). Legacy non-UUID local ids are first
  /// rewritten to UUIDs and persisted, so device and cloud share ids and the push
  /// is idempotent. After a push the whole local list is cloud-managed. Returns
  /// the number of sources pushed.
  Future<int> pushSources(SourceStore store) async {
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
          'position': i,
        },
    ];
    await _client.rpc('push_sources', params: {'p_sources': payload});
    // Everything we just pushed is now cloud-managed.
    await _writeCloudIds(normalized.map((c) => c.id).toSet());
    return normalized.length;
  }

  /// Push this device's metadata provider config up to the paired account
  /// (last-write-wins, via the `push_metadata` RPC).
  Future<void> pushMetadata(SourceStore store) async {
    final config = await store.metadataConfig();
    await _client.rpc('push_metadata', params: {'p_config': config.toJson()});
  }

  /// Self-unpair: drop the cloud-managed sources locally and remove this
  /// device's pairing rows. The account can also revoke from the panel.
  Future<void> unpair(SourceStore store) async {
    for (final id in await _readCloudIds()) {
      await store.delete(id);
    }
    await _storage.delete(key: _kCloudIds);
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
