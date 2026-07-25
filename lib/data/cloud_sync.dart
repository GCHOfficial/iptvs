import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sources/source.dart';
import '../sources/source_config.dart';
import '../sources/source_identity.dart';
import 'app_database.dart';
import 'cloud_crypto.dart';
import 'metadata_config.dart';
import 'net.dart';
import 'secret_keys.dart';
import 'source_store.dart';
import 'source_identity_migration.dart';

/// The prefix the server puts on validation errors it wants surfaced verbatim
/// (`errcode check_violation`, e.g. "iptvs: too many favorites (max 200000)").
const _kServerMessagePrefix = 'iptvs: ';

/// A short, safe-to-display message for a cloud sync failure. Never uses
/// [Exception.toString] on a [PostgrestException]: it includes the `details`
/// field, which for a failing-row constraint violation can contain the row's
/// raw data (including credentials embedded in provider URLs). Only
/// `.message` is shown, and even that is run through [redactText] in case a
/// server message ever embeds a URL.
String friendlyCloudError(Object e) {
  final String raw;
  if (e is PostgrestException) {
    final message = e.message;
    raw = message.startsWith(_kServerMessagePrefix)
        ? message.substring(_kServerMessagePrefix.length)
        : message;
  } else if (e is AuthException) {
    raw = e.message;
  } else {
    return 'Cloud sync failed. Check your connection and try again.';
  }
  return redactText(raw);
}

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
  final DateTime? updatedAt;
  const CloudProfile({
    required this.id,
    required this.name,
    required this.position,
    this.updatedAt,
  });
}

/// Server-authoritative revision metadata used by a client before a
/// destructive push. It deliberately contains no profile/source payload.
class CloudRevision {
  final String profileId;
  final DateTime? updatedAt;

  const CloudRevision({required this.profileId, this.updatedAt});
}

/// Whether a destructive overwrite warning is warranted. A missing server
/// timestamp is treated conservatively as a conflict when the caller has a
/// local snapshot, since an old client must never silently replace unknown
/// remote state.
bool shouldWarnBeforeOverwrite({
  required DateTime? knownRemoteRevision,
  required DateTime? currentRemoteRevision,
  required bool hasLocalChanges,
}) {
  if (!hasLocalChanges) return false;
  if (knownRemoteRevision == null || currentRemoteRevision == null) return true;
  return currentRemoteRevision.isAfter(knownRemoteRevision);
}

/// The content kinds whose favorites are synced (live channels / movies /
/// series). Seasons/episodes aren't favorited at the top level.
const _favoriteKinds = [
  ContentKind.live,
  ContentKind.movie,
  ContentKind.series,
];

/// The end-to-end-encryption state of the active cloud profile as seen by this
/// device.
///
/// - [off] — the profile has no E2EE (cloud secrets are RLS+TLS protected only),
///   or the backend predates the secrets migration. Secrets travel as `format`
///   0 (plaintext).
/// - [ready] — E2EE is on and this device holds the unwrapped content key, so it
///   can decrypt pulled secrets and encrypt (`format` 1) on push.
/// - [locked] — E2EE is on but this device has no content key (never provisioned
///   / unwrap failed). It can still pull broad fields (credentials stay whatever
///   the device already had, via the defensive local overlay) but **push is
///   disabled**, and any source without a locally-known secret is surfaced as
///   needs-attention. Devices never prompt for the passphrase (TV constraint) —
///   the user unlocks by opening the panel.
enum CloudCryptoStatus { off, ready, locked }

/// Whether [e] is a "function does not exist" error from calling an RPC that a
/// pre-migration backend doesn't have yet. Such a call must degrade to "no cloud
/// secrets available", never crash the sync.
bool isMissingFunctionError(Object e) {
  if (e is! PostgrestException) return false;
  if (e.code == '42883' || e.code == 'PGRST202') return true;
  final m = e.message.toLowerCase();
  return m.contains('does not exist') || m.contains('could not find the function');
}

/// Decode a pulled `{"format":0|1,"payload":...}` secret entry to a plain secret
/// map. Pure (crypto only, no network).
///
/// Returns an **empty** map when the entry is absent, or when the profile is
/// E2EE but this device is [CloudCryptoStatus.locked] (no key) — an expected,
/// non-integrity state that the caller resolves via the defensive local overlay.
/// **Throws** [CloudCryptoException] on a genuine integrity failure (bad format,
/// or a decrypt/version/auth failure while the device *does* hold a key), which
/// the caller catches per-source and surfaces as needs-attention. It never
/// returns a partial/empty map *as if* it were the real secret for a decryptable
/// entry — fail closed.
Future<Map<String, String>> decodeSecretEntry({
  required Map<String, dynamic>? entry,
  required CloudCryptoStatus status,
  required List<int>? contentKey,
  required int ckVersion,
  required List<int> aad,
}) async {
  if (entry == null) return const {};
  final format = entry['format'];
  final payload = entry['payload'];
  if (format == 0) {
    if (payload is! Map) return const {};
    return {
      for (final e in payload.entries) e.key.toString(): e.value?.toString() ?? '',
    };
  }
  if (format == 1) {
    if (status != CloudCryptoStatus.ready || contentKey == null) {
      // Locked: cannot decrypt; fall back to the local overlay (not an
      // integrity failure, so do not throw).
      return const {};
    }
    if (payload is! Map) {
      throw const CloudCryptoException('secret payload is not an object');
    }
    return decryptSecretEnvelope(
      envelope: Map<String, dynamic>.from(payload),
      contentKey: contentKey,
      ckVersion: ckVersion,
      aad: aad,
    );
  }
  throw CloudCryptoException('unknown secret format: $format');
}

/// Build the `secret` element for a push, or **null** when the device doesn't
/// know the secret ([secret] empty) — an absent element tells the server to
/// preserve whatever it has stored (never blank it). Pure (crypto only).
///
/// E2EE [ready] → `format` 1 (encrypted under [contentKey]); E2EE [off] →
/// `format` 0 (plaintext). [locked] must never reach here (push is disabled);
/// it is treated as [off] defensively but callers guard first.
Future<Map<String, dynamic>?> buildSecretElement({
  required Map<String, String> secret,
  required CloudCryptoStatus status,
  required List<int>? contentKey,
  required int ckVersion,
  required List<int> aad,
  List<int>? ivOverride,
}) async {
  if (secret.isEmpty) return null;
  if (status == CloudCryptoStatus.ready && contentKey != null) {
    final iv = ivOverride ?? randomBytes(12);
    final envelope = await encryptSecretEnvelope(
      secret: secret,
      contentKey: contentKey,
      ckVersion: ckVersion,
      aad: aad,
      iv: iv,
    );
    return {'format': 1, 'payload': envelope};
  }
  return {'format': 0, 'payload': secret};
}

/// Cryptographically-strong random bytes (IV/nonce generation).
List<int> randomBytes(int n) {
  final r = Random.secure();
  return List<int>.generate(n, (_) => r.nextInt(256));
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
  final rawSettings = row['settings'] as Map?;
  final config = SourceConfig(
    id: row['id'] as String,
    kind: SourceKind.values.byName(row['kind'] as String),
    label: (row['label'] as String?) ?? '',
    fields: fields,
    settings: rawSettings == null
        ? const {}
        : Map<String, dynamic>.from(rawSettings),
  );
  return config;
}

/// Two-way cloud sync: a device pairs with a panel account, then pulls the
/// account's source list and metadata config into the local [SourceStore] and
/// can optionally push its own list back up. The device authenticates
/// anonymously.
///
/// **Phase-2 isolated secrets + Phase-3 opt-in E2EE.** The cloud `sources.fields`
/// and `metadata_configs.config` rows now carry only the **broad** keys; secrets
/// (credentials/locators, API keys) travel through dedicated RPCs (`get_secrets`,
/// the per-source `secret` element on `push_sources`, `p_secret` on
/// `push_metadata`). When a profile has E2EE enabled, secrets are encrypted
/// client-side under a per-profile content key that this device unwraps with its
/// own P-256 key pair ([cloud_crypto.dart]); when it's off, they travel as
/// plaintext (`format` 0), still RLS+TLS protected. A push can never blank a
/// stored value (empty/absent secret → server preserves), and a pull applies a
/// defensive local overlay so a locked device never loses a credential it
/// already holds. See docs/cloud-sync.md for the protocol and threat boundary.
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

  /// This device's long-lived P-256 key pair for E2EE content-key unwrapping,
  /// persisted in the keychain (base64). The private scalar is a device secret
  /// on par with the provider credentials already stored here.
  static const _kDevicePriv = 'cloud_device_priv_key';
  static const _kDevicePub = 'cloud_device_pub_key';

  CloudSync({
    SupabaseClient? client,
    FlutterSecureStorage? storage,
    AppDatabase? db,
  }) : _client = client ?? Supabase.instance.client,
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
        .select('id, name, position, updated_at')
        .order('position');
    return [
      for (final r in rows)
        CloudProfile(
          id: r['id'] as String,
          name: (r['name'] as String?) ?? '',
          position: (r['position'] as int?) ?? 0,
          updatedAt: r['updated_at'] == null
              ? null
              : DateTime.tryParse(r['updated_at'].toString()),
        ),
    ];
  }

  Future<CloudRevision?> profileRevision(String profileId) async {
    final row = await _client
        .from('profiles')
        .select('id, updated_at')
        .eq('id', profileId)
        .maybeSingle();
    if (row == null) return null;
    return CloudRevision(
      profileId: row['id'] as String,
      updatedAt: row['updated_at'] == null
          ? null
          : DateTime.tryParse(row['updated_at'].toString()),
    );
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
    await _client.rpc(
      'set_device_profile',
      params: {'p_profile_id': profileId},
    );
    await _storage.write(key: _kProfileId, value: profileId);
  }

  /// Pull the given profile's sources into [store]. Cloud-managed sources are
  /// replaced and ordered to match the panel; any local-only sources the user
  /// added on the device are kept (after the cloud ones). Returns the number of
  /// cloud sources synced.
  Future<int> pullSources(SourceStore store, String profileId) async {
    final crypto = await _resolveCryptoState(profileId);
    final rows = await _client
        .from('sources')
        .select()
        .eq('profile_id', profileId)
        .order('position');
    final secrets = await _fetchSecrets(profileId);
    final secretSources = (secrets?['sources'] as Map?) ?? const {};
    final localById = {for (final c in await store.list()) c.id: c};

    // Merge each source's broad row with its (decrypted) secret map, then apply
    // the defensive local overlay so a locked/partial profile can't blank a
    // credential this device already holds (amendment B1).
    final configs = <SourceConfig>[];
    for (final r in rows) {
      final base = cloudRowToConfig(Map<String, dynamic>.from(r));
      final rawEntry = secretSources[base.id];
      Map<String, String> secretMap = const {};
      try {
        secretMap = await decodeSecretEntry(
          entry: rawEntry == null
              ? null
              : Map<String, dynamic>.from(rawEntry as Map),
          status: crypto.status,
          contentKey: crypto.ck,
          ckVersion: crypto.ckVersion,
          aad: sourceSecretAad(profileId, base.id, crypto.ckVersion),
        );
      } on CloudCryptoException {
        // A per-source integrity failure surfaces as needs-attention (empty
        // secret → missing credential badge), without aborting the whole pull.
        secretMap = const {};
      }
      var fields = mergeFields(base.fields, secretMap);
      final local = localById[base.id];
      if (local != null) {
        fields = fillGapsFromLocal(fields, local.fields, kSourceSecretKeys);
      }
      configs.add(base.copyWith(fields: fields));
    }
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
    final broad = Map<String, dynamic>.from(row['config'] as Map);
    final crypto = await _resolveCryptoState(profileId);
    final secrets = await _fetchSecrets(profileId);
    final rawEntry = secrets?['metadata'];
    Map<String, String> secretMap = const {};
    if (rawEntry != null) {
      try {
        secretMap = await decodeSecretEntry(
          entry: Map<String, dynamic>.from(rawEntry as Map),
          status: crypto.status,
          contentKey: crypto.ck,
          ckVersion: crypto.ckVersion,
          aad: metadataSecretAad(profileId, crypto.ckVersion),
        );
      } on CloudCryptoException {
        secretMap = const {};
      }
    }
    final local = await store.metadataConfig();
    final merged = MetadataConfig.fromCloudParts(
      broad: broad,
      secret: secretMap,
      local: local,
    );
    await store.saveMetadataConfig(merged);
    return true;
  }

  /// Pull the given profile's favorites into the local cache, replacing those of
  /// the cloud-managed sources. Cloud and local rows share the `SourceConfig`
  /// UUID namespace. Run after [pullSources] so the managed set is current.
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
    //
    // Both halves are set-wise, not row-wise: a per-row `setFavorite` is its
    // own implicit transaction, so mirroring a profile used to cost one commit
    // (and one desktop fsync) per favorite, twice over. The visible result is
    // unchanged — same rows cleared, same rows written, clears still all
    // ordered before writes so a cleared source that reappears in the payload
    // keeps its favorites.
    for (final uuid in managed) {
      final config = byUuid[uuid];
      if (config == null) continue;
      await migrateSourceIdentity(db, config);
      for (final kind in _favoriteKinds) {
        await db.clearFavorites(config.id, kind);
      }
    }
    final incoming = <String, Map<ContentKind, List<String>>>{};
    for (final entry in favorites) {
      final fav = Map<String, dynamic>.from(entry as Map);
      final config = byUuid[fav['source_id']];
      if (config == null) continue;
      final kindName = fav['kind'] as String?;
      final itemId = fav['item_id'] as String?;
      if (kindName == null || itemId == null) continue;
      final kind = ContentKind.values.asNameMap()[kindName];
      if (kind == null) continue;
      final stableItemId =
          config.kind == SourceKind.m3u &&
              kind == ContentKind.live &&
              !isStableM3uChannelId(itemId)
          ? stableM3uChannelId(itemId)
          : itemId;
      ((incoming[config.id] ??= {})[kind] ??= []).add(stableItemId);
    }
    for (final bySource in incoming.entries) {
      for (final byKind in bySource.value.entries) {
        await db.setFavorites(bySource.key, byKind.key, byKind.value);
      }
    }
  }

  /// Push this device's full source list (full `fields`, credentials included)
  /// up to the paired account, replacing the panel's set except that the server
  /// merges each source's `fields` field-wise so a push never blanks a stored
  /// non-empty credential (last-write-wins refined by field-preserve, mediated by
  /// the `push_sources` RPC so the device never has direct write access). Legacy
  /// non-UUID local ids are first
  /// rewritten to UUIDs and persisted, so device and cloud share ids and the push
  /// is idempotent. After a push the whole local list is cloud-managed. Returns
  /// the number of sources pushed.
  Future<int> pushSources(SourceStore store, String profileId) async {
    final crypto = await _resolveCryptoState(profileId);
    if (crypto.status == CloudCryptoStatus.locked) {
      throw const CloudCryptoException(_kLockedPushMessage);
    }
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

    final payload = <Map<String, dynamic>>[];
    for (var i = 0; i < normalized.length; i++) {
      final c = normalized[i];
      final (broad, secret) = splitFields(c.fields, kSourceSecretKeys);
      final element = await buildSecretElement(
        secret: secret,
        status: crypto.status,
        contentKey: crypto.ck,
        ckVersion: crypto.ckVersion,
        aad: sourceSecretAad(profileId, c.id, crypto.ckVersion),
      );
      payload.add({
        'id': c.id,
        'kind': c.kind.name,
        'label': c.label,
        'fields': broad,
        'settings': c.settings,
        'position': i,
        // Absent 'secret' → server preserves the stored one for this source.
        'secret': ?element,
      });
    }
    await _client.rpc(
      'push_sources',
      params: {'p_sources': payload, 'p_profile_id': profileId},
    );
    // Everything we just pushed is now cloud-managed.
    await _writeCloudIds(normalized.map((c) => c.id).toSet());
    return normalized.length;
  }

  /// Push this device's metadata provider config up to the given profile
  /// (last-write-wins, via the `push_metadata` RPC).
  Future<void> pushMetadata(SourceStore store, String profileId) async {
    final crypto = await _resolveCryptoState(profileId);
    if (crypto.status == CloudCryptoStatus.locked) {
      throw const CloudCryptoException(_kLockedPushMessage);
    }
    final config = await store.metadataConfig();
    final element = await buildSecretElement(
      secret: config.cloudSecretFields(),
      status: crypto.status,
      contentKey: crypto.ck,
      ckVersion: crypto.ckVersion,
      aad: metadataSecretAad(profileId, crypto.ckVersion),
    );
    await _client.rpc(
      'push_metadata',
      params: {
        'p_config': config.cloudBroadJson(),
        'p_profile_id': profileId,
        'p_secret': element,
      },
    );
  }

  /// Push this device's favorites (for the cloud-managed sources) up to the
  /// given profile. Local and cloud records share the `SourceConfig` UUID.
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
      await migrateSourceIdentity(db, config);
      final sourceId = config.id;
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
    await _client.rpc(
      'push_favorites',
      params: {'p_favorites': favorites, 'p_profile_id': profileId},
    );
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

  /// The cloud-managed source ids from the last pull/push, exposed so profile
  /// switching can snapshot/restore them alongside the source list (restoring
  /// a local profile clears the set, so a later pull can't merge cloud sources
  /// into it). Pure bookkeeping — no network.
  Future<Set<String>> managedSourceIds() => _readCloudIds();

  Future<void> setManagedSourceIds(Set<String> ids) => _writeCloudIds(ids);

  /// The E2EE state of [profileId] as seen by this device, for the sync screen's
  /// status line and to gate push. Degrades to [CloudCryptoStatus.off] against a
  /// pre-migration backend.
  Future<CloudCryptoStatus> cryptoStatus(String profileId) async =>
      (await _resolveCryptoState(profileId)).status;

  /// Resolve crypto state + (when [ready]) the unwrapped content key. Never
  /// throws for an expected condition: a missing RPC or a missing/undecryptable
  /// CK becomes [off]/[locked], not an exception.
  Future<_CryptoState> _resolveCryptoState(String profileId) async {
    Map<String, dynamic>? state;
    try {
      final res = await _client.rpc(
        'get_crypto_state',
        params: {'p_profile_id': profileId},
      );
      state = res == null ? null : Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      if (isMissingFunctionError(e)) return const _CryptoState.off();
      rethrow;
    }
    final enabled = state?['enabled'] == true;
    final ckVersion = (state?['ck_version'] as int?) ?? 0;
    if (!enabled) return const _CryptoState.off();

    // E2EE is on: register this device's public key (idempotent) and try to
    // unwrap the content key. Any failure downgrades to locked (fail closed).
    try {
      final keyPair = await _ensureDeviceKeyPair();
      await _publishDevicePublicKey(keyPair);
      final ckRow = await _getDeviceCk(profileId);
      if (ckRow == null) {
        return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: ckVersion);
      }
      final rowCkv = (ckRow['ck_version'] as int?) ?? ckVersion;
      final wrapped = _asJsonMap(ckRow['wrapped_ck']);
      if (wrapped == null) {
        return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: rowCkv);
      }
      final uid = deviceId;
      if (uid == null) {
        return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: rowCkv);
      }
      final ck = await decodeDeviceWrap(
        envelope: wrapped,
        devicePrivateKey: keyPair.privateKey,
        ckVersion: rowCkv,
        aad: deviceWrapAad(profileId, uid, rowCkv),
      );
      return _CryptoState(
        status: CloudCryptoStatus.ready,
        ckVersion: rowCkv,
        ck: ck,
      );
    } on CloudCryptoException {
      return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: ckVersion);
    } on PostgrestException catch (e) {
      if (isMissingFunctionError(e)) {
        return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: ckVersion);
      }
      rethrow;
    }
  }

  /// Fetch the per-profile secrets bundle (`{sources:{id:{format,payload}},
  /// metadata:{...}|null}`), or null against a pre-migration backend.
  Future<Map<String, dynamic>?> _fetchSecrets(String profileId) async {
    try {
      final res = await _client.rpc(
        'get_secrets',
        params: {'p_profile_id': profileId},
      );
      return res == null ? null : Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      if (isMissingFunctionError(e)) return null;
      rethrow;
    }
  }

  /// This device's P-256 key pair, generating + persisting one on first use.
  Future<EcKeyPair> _ensureDeviceKeyPair() async {
    final privB64 = await _storage.read(key: _kDevicePriv);
    if (privB64 != null && privB64.isNotEmpty) {
      final priv = b64Decode(privB64);
      final pubB64 = await _storage.read(key: _kDevicePub);
      if (pubB64 != null && pubB64.isNotEmpty) {
        return EcKeyPair(privateKey: priv, publicKey: b64Decode(pubB64));
      }
      final rebuilt = p256KeyPairFromScalar(priv);
      await _storage.write(key: _kDevicePub, value: b64Encode(rebuilt.publicKey));
      return rebuilt;
    }
    final fresh = generateP256KeyPair();
    await _storage.write(key: _kDevicePriv, value: b64Encode(fresh.privateKey));
    await _storage.write(key: _kDevicePub, value: b64Encode(fresh.publicKey));
    return fresh;
  }

  Future<void> _publishDevicePublicKey(EcKeyPair keyPair) async {
    try {
      await _client.rpc(
        'set_device_public_key',
        params: {'p_public_key': b64Encode(keyPair.publicKey)},
      );
    } on PostgrestException catch (e) {
      if (isMissingFunctionError(e)) return;
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _getDeviceCk(String profileId) async {
    final res = await _client.rpc(
      'get_device_ck',
      params: {'p_profile_id': profileId},
    );
    if (res == null) return null;
    if (res is List) {
      return res.isEmpty ? null : Map<String, dynamic>.from(res.first as Map);
    }
    if (res is Map) return Map<String, dynamic>.from(res);
    return null;
  }

  Future<Set<String>> _readCloudIds() async {
    final raw = await _storage.read(key: _kCloudIds);
    if (raw == null || raw.isEmpty) return <String>{};
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _writeCloudIds(Set<String> ids) =>
      _storage.write(key: _kCloudIds, value: ids.join(','));
}

/// The user-facing message shown when push is blocked on a locked E2EE device.
const _kLockedPushMessage =
    'This profile is end-to-end encrypted. Open the panel and unlock it to '
    'finish setting up this device.';

/// Coerce a jsonb-or-JSON-string value to a `Map<String, dynamic>`, or null.
Map<String, dynamic>? _asJsonMap(Object? value) {
  if (value == null) return null;
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Resolved E2EE state + the unwrapped content key when [CloudCryptoStatus.ready].
class _CryptoState {
  final CloudCryptoStatus status;
  final int ckVersion;
  final List<int>? ck;

  const _CryptoState({
    required this.status,
    this.ckVersion = 0,
    this.ck,
  });

  const _CryptoState.off()
      : status = CloudCryptoStatus.off,
        ckVersion = 0,
        ck = null;
}
