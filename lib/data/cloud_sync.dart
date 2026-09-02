import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../sources/source.dart';
import '../sources/source_config.dart';
import '../sources/source_identity.dart';
import 'app_database.dart';
import 'cloud_crypto.dart';
import 'local_profile_store.dart';
import 'device_label.dart';
import 'metadata_config.dart';
import 'net.dart';
import 'secret_keys.dart';
import 'source_store.dart';
import 'source_identity_migration.dart';

/// The prefix the server puts on validation errors it wants surfaced verbatim
/// (`errcode check_violation`, e.g. "iptvs: too many favorites (max 200000)").
const _kServerMessagePrefix = 'iptvs: ';

/// How PostgREST/Postgres phrase a permission or RLS denial. Mirrors the panel's
/// `PERMISSION_ERROR_RE` (panel/src/validate.js): the raw text names tables and
/// policies, so it is reduced to "not allowed" rather than shown.
final _kPermissionErrorRe = RegExp(
  r'permission denied|row-level security|not allowed|rls',
  caseSensitive: false,
);

/// Shown for a server-side failure this client has no specific wording for.
const _kGenericServerError = 'Cloud sync failed. Please try again.';

/// Shown for a failure that isn't a recognised server error at all (typically a
/// socket/TLS/timeout failure on the way out).
const _kGenericClientError =
    'Cloud sync failed. Check your connection and try again.';

/// A short, safe-to-display message for a cloud sync failure.
///
/// The contract mirrors the panel's `friendlyError` (panel/src/validate.js), and
/// deliberately **genericises** anything the server wasn't explicitly asked to
/// author. Only three things reach the user:
///
/// 1. `iptvs: `-prefixed messages — the server's own validation text, which the
///    migrations guarantee never interpolates payload values.
/// 2. A permission/RLS denial, collapsed to "Not allowed."
/// 3. A [CloudPushBlockedException] — a *client*-authored constant.
///
/// Everything else becomes a static generic string. This matters because a raw
/// Postgres message can carry row data of its own (e.g. `duplicate key value
/// violates unique constraint …`, which names the conflicting values on some
/// constraint types) — [redactText] scrubs URL-shaped credentials but cannot
/// know that a bare token *is* a credential. `details`/`hint` are never read at
/// all: for a failing-row constraint violation they contain the whole row.
String friendlyCloudError(Object e) {
  // Client-authored, static text — safe verbatim, and the only way the
  // locked/downgraded push explanation reaches the user.
  if (e is CloudPushBlockedException) return e.message;
  final String raw;
  if (e is PostgrestException) {
    final message = e.message;
    if (message.startsWith(_kServerMessagePrefix)) {
      raw = message.substring(_kServerMessagePrefix.length);
    } else if (_kPermissionErrorRe.hasMatch(message)) {
      return 'Not allowed.';
    } else {
      return _kGenericServerError;
    }
  } else if (e is AuthException) {
    // GoTrue messages are a fixed, server-authored set ("Anonymous sign-ins are
    // disabled", "Invalid login credentials") that never carry row data, and
    // they are the only actionable text a pairing failure has. Kept verbatim
    // (still redacted) on purpose — see test/cloud_sync_test.dart.
    raw = e.message;
  } else {
    return _kGenericClientError;
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

  /// The profile's PIN verifier (`profile_pin.dart`), or null when the profile
  /// is open. A **broad** column, deliberately: a four-digit PIN is a gate on a
  /// shared television, not a secret, and a verifier for one is brute-forceable
  /// by anyone holding it whatever the KDF cost — so encrypting it would buy
  /// nothing while making the gate unenforceable on an E2EE-locked device,
  /// which is the device most in need of it.
  final String? pin;

  const CloudProfile({
    required this.id,
    required this.name,
    required this.position,
    this.updatedAt,
    this.pin,
  });

  bool get locked => pin != null && pin!.isNotEmpty;
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

/// A push refused by this device's own E2EE state (locked, or a detected
/// downgrade) rather than by the server. Its [message] is a client-authored
/// constant, so [friendlyCloudError] renders it verbatim.
///
/// Extends [CloudCryptoException] so existing `on CloudCryptoException` handlers
/// keep catching it.
class CloudPushBlockedException extends CloudCryptoException {
  const CloudPushBlockedException(super.message);
}

/// The resolved E2EE state of a profile, with *why* it is what it is.
///
/// [downgraded] is the sticky-state verdict: this device has previously seen the
/// profile end-to-end encrypted, but the server now claims otherwise (E2EE off,
/// the crypto RPCs suddenly missing, or an older `ck_version` than this device
/// has already unwrapped). It is always paired with
/// [CloudCryptoStatus.locked] — fail closed — because the alternative is
/// exactly the attack: a backend that answers `{enabled: false}` and collects
/// every client's credentials in plaintext.
class CloudCryptoState {
  final CloudCryptoStatus status;
  final bool downgraded;

  const CloudCryptoState({required this.status, this.downgraded = false});
}

/// The user-facing explanation of a detected downgrade. Deliberately distinct
/// from [kCloudE2eeLockedMessage]: "not set up yet" and "the encryption this
/// profile had has disappeared" call for different user action.
const kCloudE2eeDowngradedMessage =
    'This profile was end-to-end encrypted, but the server now reports it as '
    'off (or at an older key). Nothing is being sent in the clear. Open the '
    'panel and verify this profile\'s Security settings.';

/// The user-facing message shown when push is blocked on a locked E2EE device.
const kCloudE2eeLockedMessage =
    'This profile is end-to-end encrypted. Open the panel and unlock it to '
    'finish setting up this device.';

/// This device's **sticky** record of a cloud profile's E2EE state — the whole
/// point of which is that it is not re-derived from the server on each call.
///
/// - [seenEnabled] is set the first time `get_crypto_state` reports the profile
///   as encrypted. It is server-asserted (so a hostile backend could set it
///   spuriously) but it can only ever *tighten* behaviour, never loosen it.
/// - [ckVersion] is a monotonic high-water mark recorded **only after a content
///   key at that version was successfully unwrapped** with this device's private
///   key. That unwrap is the authentication: the server cannot mint a device
///   wrap at a version it doesn't hold the CK for, so it cannot inflate this
///   number to wedge the device — it can only replay an older one, which is what
///   the high-water mark rejects.
class E2eeMark {
  final bool seenEnabled;
  final int ckVersion;

  const E2eeMark({this.seenEnabled = false, this.ckVersion = 0});

  /// Nothing known about this profile yet.
  static const none = E2eeMark();

  /// True once anything is worth persisting.
  bool get isSet => seenEnabled || ckVersion > 0;

  E2eeMark merge({bool? seenEnabled, int? ckVersion}) => E2eeMark(
    seenEnabled: this.seenEnabled || (seenEnabled ?? false),
    // Monotonic: a lower reported version never lowers the mark.
    ckVersion: ckVersion == null || ckVersion < this.ckVersion
        ? this.ckVersion
        : ckVersion,
  );
}

/// Whether the E2EE state the server *claims* contradicts what this device has
/// already established for the profile. Pure (no network, no storage).
///
/// Two shapes of the same attack:
/// - **Downgrade to plaintext** — the server says E2EE is off (or answers
///   "function does not exist", i.e. [serverEnabled] false) for a profile this
///   device has seen encrypted. Trusting that answer makes the device push
///   provider credentials and metadata API keys as `format` 0.
/// - **State rollback** — the server still says E2EE is on, but at a
///   `ck_version` older than one this device has already unwrapped, which is the
///   setup for pinning it to a revoked content-key generation.
///
/// A legitimate "disable E2EE" from the panel is indistinguishable from the
/// first case *by construction* (that is the whole difficulty), so it also lands
/// here: the device stays fail-closed until the user clears the mark via
/// [CloudSync.acknowledgeE2eeDowngrade] or unpairs.
bool isE2eeDowngrade({
  required bool serverEnabled,
  required int serverCkVersion,
  required E2eeMark mark,
}) {
  if (!serverEnabled) return mark.isSet;
  return serverCkVersion < mark.ckVersion;
}

/// Whether a `device_ck` row's version is older than it is allowed to be.
///
/// [serverCkVersion] (from `get_crypto_state`) is treated as a **floor**, not as
/// a fallback: the two RPCs were never compared before, so a backend serving a
/// *consistent* pre-rotation bundle (old `device_ck` row plus old
/// `source_secrets` envelopes, all at the same older version) got the device to
/// unwrap and happily use a **revoked** content key. The `ckv`-in-AAD binding
/// stops generations being *mixed*; it establishes no freshness on its own.
/// [watermark] adds freshness that survives both RPCs lying, since it is only
/// ever advanced by a successful unwrap.
///
/// A row *newer* than the reported state is allowed: that is the benign race
/// where the panel rotates the key between the two calls.
bool isCkVersionRollback({
  required int rowCkVersion,
  required int serverCkVersion,
  required int watermark,
}) =>
    rowCkVersion < serverCkVersion || rowCkVersion < watermark;

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
    // Plaintext is only ever accepted for a profile this device believes is
    // NOT encrypted. On an encrypted profile a `format` 0 entry is either the
    // server contradicting itself or an active backend feeding the device
    // attacker-chosen values — and a source secret includes `playlistUrl`,
    // i.e. which server the player connects to. Under real E2EE those bytes
    // would simply fail to decrypt, so refusing them here restores that
    // outcome: empty → the defensive local overlay keeps the credential the
    // device already holds.
    if (status != CloudCryptoStatus.off) return const {};
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
/// `format` 0 (plaintext).
///
/// **[locked] throws** [CloudCryptoException]. Both callers gate on the status
/// before getting here, so this branch is unreachable today — but a defensive
/// branch in a fail-closed design must not emit plaintext. The old "treated as
/// off defensively" behaviour would have put the credentials into a `format` 0
/// element; the server would have rejected the write, but the plaintext would
/// already have left the device. Same for [ready] with a null [contentKey]:
/// there is nothing to encrypt with, so refuse rather than downgrade.
Future<Map<String, dynamic>?> buildSecretElement({
  required Map<String, String> secret,
  required CloudCryptoStatus status,
  required List<int>? contentKey,
  required int ckVersion,
  required List<int> aad,
  List<int>? ivOverride,
}) async {
  // Checked first: an empty secret is "the device doesn't know this one", which
  // sends no element at all (the server preserves what it has). No plaintext is
  // involved, so it is safe even in a locked/downgraded state.
  if (secret.isEmpty) return null;
  if (status == CloudCryptoStatus.locked) {
    throw const CloudCryptoException(
      'refusing to encode a secret while the profile is locked',
    );
  }
  if (status == CloudCryptoStatus.ready) {
    if (contentKey == null) {
      throw const CloudCryptoException(
        'refusing to encode a secret without a content key',
      );
    }
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

  /// Sticky per-profile E2EE marks (see [E2eeMark]), as a JSON object
  /// `{"<profile_id>": {"seen": true, "ckv": 3}}`. Deliberately in the keychain
  /// next to the device key pair rather than in prefs: it is a security
  /// decision input, and prefs are trivially editable on a rooted device.
  /// Cleared wholesale by [unpair].
  static const _kE2eeMarks = 'cloud_e2ee_marks';

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

  /// Whether a persisted anonymous session already exists.
  ///
  /// Purely local: no network, and it never *creates* one — which is the whole
  /// point. **A device that has no session cannot be paired**, because pairing
  /// only ever happens through [requestPairingCode], which calls
  /// [ensureAnonSession] first, and the session is persisted to the keychain.
  /// So this is a definitive "not paired" that costs nothing, and callers on
  /// the boot path can use it instead of creating an account to ask.
  ///
  /// (If the session is somehow lost, the old pairing is unreachable anyway —
  /// a fresh anonymous user is a different device to the server — so treating
  /// that as unpaired is also correct.)
  bool get hasSession => _client.auth.currentSession != null;

  /// Ensure the device has a (persisted) anonymous session to act under.
  ///
  /// **Creates a cloud account on the server**, so call it only where the user
  /// has opted into cloud sync — opening the Cloud sync screen, or requesting a
  /// pairing code. It used to be called from the profile picker on the boot
  /// path, which meant every install that reached the picker minted an
  /// anonymous user whether or not it ever went near the feature: ~1,900 of
  /// them against 62 devices that actually paired. See [hasSession].
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
  ///
  /// Sends a platform-derived [label] suggestion ("Android TV", "Windows PC")
  /// so the device already has a name in the panel the moment it is claimed,
  /// instead of showing as "Device" until renamed. A name typed into the panel
  /// still wins; see [detectSuggestedDeviceLabel].
  Future<PairingCode> requestPairingCode({String? label}) async {
    await ensureAnonSession();
    final suggestion = (label ?? await detectSuggestedDeviceLabel()).trim();
    // The server truncates at 256; cap far shorter, since anything longer is a
    // bug rather than a name.
    final capped = suggestion.length > 64
        ? suggestion.substring(0, 64)
        : suggestion;
    final List res;
    try {
      res = await _client.rpc('request_pairing', params: {'p_label': capped})
          as List;
    } on PostgrestException catch (e) {
      // Only a backend that predates the suggestion migration may fall back —
      // a real rate-limit or auth rejection must surface, not silently retry.
      if (!isMissingFunctionError(e)) rethrow;
      return _requestPairingCodeLegacy();
    }
    final row = Map<String, dynamic>.from(res.first as Map);
    return PairingCode(
      row['code'] as String,
      DateTime.parse(row['expires_at'] as String),
    );
  }

  /// The pre-suggestion `request_pairing()` call, for a backend that has not
  /// run the suggestion migration yet. Pairing still works; the device just
  /// arrives unnamed, exactly as before.
  Future<PairingCode> _requestPairingCodeLegacy() async {
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
        .select('id, name, position, updated_at, pin')
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
          pin: (r['pin'] as String?)?.trim().isEmpty ?? true
              ? null
              : (r['pin'] as String).trim(),
        ),
    ];
  }

  /// Set (or, with a null [verifier], clear) a cloud profile's PIN.
  ///
  /// Devices hold no direct table writes, so this goes through the owner-scoped
  /// `set_profile_pin` RPC like every other device→cloud write. The server
  /// validates the verifier's *shape* only — it never sees a PIN, and could not
  /// check one if it did.
  Future<void> setProfilePin(String profileId, String? verifier) async {
    await _client.rpc(
      'set_profile_pin',
      params: {'p_profile_id': profileId, 'p_pin': verifier},
    );
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

  /// The profile this device last synced, **from the local cache only**.
  ///
  /// [activeProfileId] asks the server first and therefore throws when the
  /// device is offline. The boot-time PIN gate has to work then too — a locked
  /// profile must not be handed over just because the network was down — so it
  /// reads this instead.
  Future<String?> cachedProfileId() => _storage.read(key: _kProfileId);

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
    // Rebase local changes that haven't been pushed yet on top of the pulled
    // state. A pull mirrors the profile, so without this it would revert a
    // favorite the user just toggled here — visibly undoing their action — and
    // only put it back on the next push. The outbox is the record of exactly
    // those changes; applying it here keeps the device consistent with what it
    // is about to send. Done against the in-memory set rather than the
    // database, so the pull still writes each (source, kind) once.
    for (final entry in await db.readFavoritesOutbox()) {
      if (!byUuid.containsKey(entry.sourceId)) continue;
      final ids = (incoming[entry.sourceId] ??= {})[entry.kind] ??= [];
      if (entry.add) {
        if (!ids.contains(entry.itemId)) ids.add(entry.itemId);
      } else {
        ids.remove(entry.itemId);
      }
    }

    for (final bySource in incoming.entries) {
      for (final byKind in bySource.value.entries) {
        await db.setFavorites(bySource.key, byKind.key, byKind.value);
      }
    }
    // This rewrote favorites behind the UI's back — which now happens
    // unattended, on launch and resume, not only when the user pressed Pull.
    // Without this the on-screen stars and the Favorites category keep showing
    // the pre-pull set until some unrelated reload, and the next toggle writes
    // from that stale in-memory set.
    db.notifyFavoritesReplaced();
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
      throw CloudPushBlockedException(crypto.blockedPushMessage);
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
      throw CloudPushBlockedException(crypto.blockedPushMessage);
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
    // Snapshot before building the payload — see the clear at the end.
    final pendingAtStart = await db.readFavoritesOutbox();
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
    // The whole set just went up, so every queued delta is now redundant —
    // and worse than redundant: a stale `remove X` left here would be re-sent
    // later and delete an X that another device has since re-favorited. Clear
    // exactly what was pending when the payload was built, so a toggle made
    // during the round trip (not represented in it) still survives.
    await db.clearFavoritesOutbox(pendingAtStart);
  }

  /// Push only what changed locally since the last successful push, as a
  /// delta the server merges per row (`push_favorites_delta`).
  ///
  /// This is what makes *automatic* pushing safe. [pushFavorites] replaces the
  /// whole set, so two devices pushing on their own schedule race and the later
  /// push erases what the earlier one added; a delta only touches the rows the
  /// user actually toggled here, so the two can't collide unless they edited
  /// the *same* favorite — where the server's arrival order is the answer.
  ///
  /// Returns true when there was something to send. Only entries belonging to
  /// cloud-managed sources are pushed; a local-only source's favorites stay on
  /// the device, exactly as with the whole-set push.
  ///
  /// Outbox rows are cleared **after** the RPC returns, and only the exact
  /// entries that were sent: a toggle made while the push was in flight has
  /// already replaced its row and must survive to be sent next time.
  Future<bool> pushFavoritesDelta(SourceStore store, String profileId) async {
    final db = _db;
    if (db == null) return false;
    final pending = await db.readFavoritesOutbox();
    if (pending.isEmpty) return false;

    final managed = await _readCloudIds();
    final byUuid = {for (final c in await store.list()) c.id: c};
    final added = <Map<String, dynamic>>[];
    final removed = <Map<String, dynamic>>[];
    final sent =
        <({String sourceId, ContentKind kind, String itemId, bool add})>[];
    for (final entry in pending) {
      if (!managed.contains(entry.sourceId)) continue;
      if (!byUuid.containsKey(entry.sourceId)) continue;
      if (!_favoriteKinds.contains(entry.kind)) continue;
      final payload = {
        'source_id': entry.sourceId,
        'kind': entry.kind.name,
        'item_id': entry.itemId,
      };
      (entry.add ? added : removed).add(payload);
      sent.add(entry);
    }
    if (sent.isEmpty) {
      // Nothing here belongs to a cloud-managed source *right now*. Leave the
      // rows alone rather than clearing them: "not managed" is also what a
      // transient state looks like — mid-profile-switch, when the managed set
      // has been reset but the new one isn't stored yet — and clearing on that
      // reading silently loses real changes. Re-examining a handful of rows on
      // the next push is far cheaper than being wrong here.
      return false;
    }

    await _client.rpc(
      'push_favorites_delta',
      params: {
        'p_added': added,
        'p_removed': removed,
        'p_profile_id': profileId,
      },
    );
    await db.clearFavoritesOutbox(sent);
    return true;
  }

  /// Self-unpair: drop the cloud-managed sources locally and remove this
  /// device's pairing rows. The account can also revoke from the panel.
  Future<void> unpair(SourceStore store) async {
    for (final id in await _readCloudIds()) {
      await store.delete(id);
    }
    await _storage.delete(key: _kCloudIds);
    await _storage.delete(key: _kProfileId);
    // The sticky E2EE marks are scoped to the account we are leaving; keeping
    // them would fail-close a *different* account's profile that happens to
    // reuse an id. (Unpairing is an explicit user action, so this is not a
    // server-triggerable reset.)
    await _storage.delete(key: _kE2eeMarks);
    // The cached cloud profile PIN verifiers are account-scoped for exactly the
    // same reason, and live one store over.
    await const LocalProfileStore().clearCloudPins();
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
  /// pre-migration backend — unless this device has already seen the profile
  /// encrypted, in which case it fails closed to [CloudCryptoStatus.locked]
  /// (see [cryptoState] for the reason distinction).
  Future<CloudCryptoStatus> cryptoStatus(String profileId) async =>
      (await _resolveCryptoState(profileId)).status;

  /// Like [cryptoStatus] but keeps *why*: a locked device that has merely never
  /// been provisioned is a different user story from one whose profile the
  /// server has downgraded. UI should render [kCloudE2eeDowngradedMessage] for
  /// the latter and offer [acknowledgeE2eeDowngrade].
  Future<CloudCryptoState> cryptoState(String profileId) async {
    final resolved = await _resolveCryptoState(profileId);
    return CloudCryptoState(
      status: resolved.status,
      downgraded: resolved.downgraded,
    );
  }

  /// Clear this device's sticky E2EE mark for [profileId], accepting whatever
  /// the server now reports.
  ///
  /// This is the *only* way out of a detected downgrade short of unpairing, and
  /// it must stay an explicit user action: a legitimate "disable end-to-end
  /// encryption" in the panel is, from the device's side, byte-for-byte the
  /// attack this mark exists to catch. Nothing the backend can say may clear it.
  Future<void> acknowledgeE2eeDowngrade(String profileId) async {
    final marks = await _readE2eeMarks();
    if (marks.remove(profileId) == null) return;
    await _writeE2eeMarks(marks);
  }

  /// Resolve crypto state + (when [ready]) the unwrapped content key. Never
  /// throws for an expected condition: a missing RPC or a missing/undecryptable
  /// CK becomes [off]/[locked], not an exception.
  ///
  /// Every "off"/"proceed" decision here is cross-checked against this device's
  /// sticky [E2eeMark], because the server is not trusted on its own E2EE state:
  /// the plaintext-downgrade and content-key-rollback paths are both a backend
  /// simply answering with older/emptier truth than it previously did.
  Future<_CryptoState> _resolveCryptoState(String profileId) async {
    final mark = await _readE2eeMark(profileId);
    Map<String, dynamic>? state;
    try {
      final res = await _client.rpc(
        'get_crypto_state',
        params: {'p_profile_id': profileId},
      );
      state = res == null ? null : Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      // A pre-migration backend has no crypto RPCs at all — but so does one
      // pretending not to, which is just the downgrade by another route.
      if (isMissingFunctionError(e)) {
        return mark.isSet
            ? const _CryptoState.downgraded()
            : const _CryptoState.off();
      }
      rethrow;
    }
    final enabled = state?['enabled'] == true;
    final ckVersion = (state?['ck_version'] as int?) ?? 0;
    if (isE2eeDowngrade(
      serverEnabled: enabled,
      serverCkVersion: ckVersion,
      mark: mark,
    )) {
      return const _CryptoState.downgraded();
    }
    if (!enabled) return const _CryptoState.off();
    // Remember that this profile is encrypted *before* attempting the unwrap:
    // a device that never gets provisioned must still refuse a later "it's off
    // now" answer.
    await _markE2eeSeen(profileId);

    // E2EE is on: register this device's public key (idempotent) and try to
    // unwrap the content key. Any failure downgrades to locked (fail closed).
    try {
      final keyPair = await _ensureDeviceKeyPair();
      await _publishDevicePublicKey(keyPair);
      final ckRow = await _getDeviceCk(profileId);
      if (ckRow == null) {
        return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: ckVersion);
      }
      // No `?? ckVersion` fallback: a row without a version cannot be checked
      // for freshness, so it is not usable.
      final rowCkv = ckRow['ck_version'] as int?;
      if (rowCkv == null ||
          isCkVersionRollback(
            rowCkVersion: rowCkv,
            serverCkVersion: ckVersion,
            watermark: mark.ckVersion,
          )) {
        return _CryptoState(status: CloudCryptoStatus.locked, ckVersion: ckVersion);
      }
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
      // Only now is `rowCkv` authenticated — the wrap decrypted under this
      // device's private key, which the server cannot forge at a version whose
      // CK it doesn't hold. Safe to advance the high-water mark; advancing it
      // from an unverified number would hand the server a permanent lockout.
      await _recordCkVersion(profileId, rowCkv);
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

  // ── sticky E2EE marks ─────────────────────────────────────────────────────

  Future<Map<String, E2eeMark>> _readE2eeMarks() async {
    final raw = await _storage.read(key: _kE2eeMarks);
    if (raw == null || raw.isEmpty) return <String, E2eeMark>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, E2eeMark>{};
      return {
        for (final e in decoded.entries)
          if (e.value is Map)
            e.key.toString(): E2eeMark(
              seenEnabled: (e.value as Map)['seen'] == true,
              ckVersion: ((e.value as Map)['ckv'] as int?) ?? 0,
            ),
      };
    } catch (_) {
      // A corrupt mark store must not brick sync; the worst case is that the
      // sticky protection restarts from "nothing known".
      return <String, E2eeMark>{};
    }
  }

  Future<E2eeMark> _readE2eeMark(String profileId) async =>
      (await _readE2eeMarks())[profileId] ?? E2eeMark.none;

  Future<void> _writeE2eeMarks(Map<String, E2eeMark> marks) => _storage.write(
    key: _kE2eeMarks,
    value: jsonEncode({
      for (final e in marks.entries)
        if (e.value.isSet)
          e.key: {'seen': e.value.seenEnabled, 'ckv': e.value.ckVersion},
    }),
  );

  /// Merge [seenEnabled]/[ckVersion] into the profile's mark. Both directions
  /// only ever tighten (see [E2eeMark.merge]).
  Future<void> _updateE2eeMark(
    String profileId, {
    bool? seenEnabled,
    int? ckVersion,
  }) async {
    final marks = await _readE2eeMarks();
    final current = marks[profileId] ?? E2eeMark.none;
    final next = current.merge(seenEnabled: seenEnabled, ckVersion: ckVersion);
    if (next.seenEnabled == current.seenEnabled &&
        next.ckVersion == current.ckVersion) {
      return; // no-op writes would hit the keychain on every pull
    }
    marks[profileId] = next;
    await _writeE2eeMarks(marks);
  }

  Future<void> _markE2eeSeen(String profileId) =>
      _updateE2eeMark(profileId, seenEnabled: true);

  Future<void> _recordCkVersion(String profileId, int ckVersion) =>
      _updateE2eeMark(profileId, seenEnabled: true, ckVersion: ckVersion);

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

  /// Set when the state was forced to [CloudCryptoStatus.locked] because the
  /// server contradicted this device's sticky [E2eeMark] (see
  /// [isE2eeDowngrade]) rather than because the device simply has no key yet.
  final bool downgraded;

  // Only [_CryptoState.downgraded] sets that flag, so it is not a parameter here.
  const _CryptoState({
    required this.status,
    this.ckVersion = 0,
    this.ck,
  }) : downgraded = false;

  const _CryptoState.off()
      : status = CloudCryptoStatus.off,
        ckVersion = 0,
        ck = null,
        downgraded = false;

  /// Locked because the server's claim regressed. Carries no ck_version on
  /// purpose: nothing the server just said about versions is trustworthy.
  const _CryptoState.downgraded()
      : status = CloudCryptoStatus.locked,
        ckVersion = 0,
        ck = null,
        downgraded = true;

  /// The message a blocked push explains itself with.
  String get blockedPushMessage =>
      downgraded ? kCloudE2eeDowngradedMessage : kCloudE2eeLockedMessage;
}
