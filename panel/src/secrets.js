// Cloud-secrets + opt-in E2EE orchestration for the panel.
//
// Wraps the Phase 2 / Phase 3 RPCs (supabase/migrations/20260725*, 20260726*)
// and drives the client-side crypto in crypto.js. The per-profile content key
// (CK) is held ONLY in the module-closure `session` below while unlocked —
// never localStorage/sessionStorage — and is zeroed on lock / idle timeout /
// profile switch.
//
// All secret writes go through set_source_secret / set_metadata_secret; broad
// fields still ride the direct sources / metadata_configs table writes (a
// server strip-trigger drops any secret key that leaks into those). Reads come
// from get_secrets and are decrypted here when the profile is E2EE-on.

import { supabase } from './supabase.js';
import * as cc from './crypto.js';

const IDLE_LOCK_MS = 15 * 60 * 1000; // 15 minutes

// { profileId, key: Uint8Array (32B CK), ckVersion } — in memory only.
let session = null;
let idleTimer = null;
let onLockChange = null;

// A locked E2EE secret that the panel cannot currently decrypt (no CK). Callers
// render it as a neutral placeholder and offer "Unlock".
export const LOCKED = Symbol('locked-secret');

export function setLockChangeHandler(fn) {
  onLockChange = fn;
}

function armIdle() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = setTimeout(() => lock(), IDLE_LOCK_MS);
}

// Reset the idle timer on user activity (wired to document-level input events).
export function touchActivity() {
  if (session) armIdle();
}

// Zero the key material and drop the session. Idempotent.
export function lock() {
  if (session?.key) session.key.fill(0);
  session = null;
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
  if (onLockChange) onLockChange();
}

function setSession(profileId, key, ckVersion) {
  if (session?.key) session.key.fill(0);
  session = { profileId, key, ckVersion };
  armIdle();
}

// The unlocked CK for `profileId`, or null. Switching profiles invalidates it.
export function unlockedFor(profileId) {
  return session && session.profileId === profileId ? session : null;
}

function requireUnlocked(profileId) {
  const s = unlockedFor(profileId);
  if (!s) throw new cc.CloudCryptoError('locked');
  return s;
}

// A backend without the Phase 2/3 migration throws "function does not exist".
// The panel degrades to broad-only rather than crashing, mirroring the Dart
// isMissingFunctionError contract.
export function isMissingFunctionError(error) {
  if (!error) return false;
  if (error.code === '42883' || error.code === 'PGRST202') return true;
  const m = (error.message || '').toLowerCase();
  return (
    m.includes('does not exist') ||
    m.includes('could not find the function') ||
    m.includes('not find a function')
  );
}

// ── sticky E2EE state ─────────────────────────────────────────────────────────
//
// Implemented in validate.js (dependency-free, so `node:test` can exercise it —
// this module cannot load under node, since it transitively imports supabase.js)
// and re-exported here so callers keep importing it from `secrets`. The full
// rationale for distrusting the server on E2EE state lives with the code.
//
// Imported AND re-exported deliberately: a bare `export … from` re-exports
// without creating a local binding, which would leave the three call sites below
// throwing ReferenceError at runtime.
import { wasE2eeSeen, markE2eeSeen, acknowledgeDowngrade } from './validate.js';

export { wasE2eeSeen, markE2eeSeen, acknowledgeDowngrade };

// ── RPC wrappers ──────────────────────────────────────────────────────────────

// Returns `{ enabled, ck_version, missing?, downgraded? }`. `downgraded` is set
// when the server claims the profile is NOT encrypted but this browser has seen
// that it was: callers must refuse to write plaintext secrets in that state.
export async function getCryptoState(profileId) {
  const { data, error } = await supabase.rpc('get_crypto_state', { p_profile_id: profileId });
  if (error) {
    if (isMissingFunctionError(error)) {
      // "The RPC doesn't exist" is a legitimate pre-migration answer AND a
      // trivial way to fake a downgrade, so the mark decides which it is.
      return { enabled: false, missing: true, downgraded: wasE2eeSeen(profileId) };
    }
    throw error;
  }
  const state = data ?? { enabled: false };
  if (state.enabled) {
    markE2eeSeen(profileId);
    return state;
  }
  return { ...state, enabled: false, downgraded: wasE2eeSeen(profileId) };
}

export async function getSecrets(profileId) {
  const { data, error } = await supabase.rpc('get_secrets', { p_profile_id: profileId });
  if (error) {
    if (isMissingFunctionError(error)) return { sources: {}, metadata: null, missing: true };
    throw error;
  }
  return data ?? { sources: {}, metadata: null };
}

async function getProfileCrypto(profileId) {
  const { data, error } = await supabase.rpc('get_profile_crypto', { p_profile_id: profileId });
  if (error) {
    if (isMissingFunctionError(error)) return null;
    throw error;
  }
  return data; // null when no row
}

async function readRevision(profileId) {
  const { data, error } = await supabase
    .from('profiles')
    .select('updated_at')
    .eq('id', profileId)
    .single();
  if (error) throw error;
  return data.updated_at;
}

async function devicesWithKeys() {
  const { data, error } = await supabase.from('devices').select('device_uid, public_key');
  if (error) throw error;
  return data ?? [];
}

// ── decode (read side) ────────────────────────────────────────────────────────

// Decrypt one {format, payload} secret entry to a plaintext string map. Returns
// LOCKED when it's a format-1 envelope and the profile isn't unlocked. The AAD
// (and the ckv cross-check) are reconstructed from the SESSION's ck_version —
// the trusted context — never from the envelope's own fields.
async function decodeEntry(entry, profileId, kind, id) {
  if (!entry) return {};
  if (entry.format === 0) return entry.payload ?? {};
  const s = unlockedFor(profileId); // format 1 needs the CK
  if (!s) return LOCKED;
  const aad =
    kind === 'source'
      ? cc.sourceSecretAad(profileId, id, s.ckVersion)
      : cc.metadataSecretAad(profileId, s.ckVersion);
  return cc.decryptSecretEnvelope({
    envelope: entry.payload,
    contentKey: s.key,
    ckVersion: s.ckVersion,
    aad,
  });
}

// Load + decode every secret for a profile. Returns
// { sources: { <id>: (map|LOCKED) }, metadata: (map|LOCKED|null), missing }.
export async function loadDecodedSecrets(profileId) {
  const secrets = await getSecrets(profileId);
  const out = { sources: {}, metadata: null, missing: !!secrets.missing };
  for (const [sourceId, entry] of Object.entries(secrets.sources ?? {})) {
    try {
      out.sources[sourceId] = await decodeEntry(entry, profileId, 'source', sourceId);
    } catch (e) {
      out.sources[sourceId] = LOCKED; // fail closed — never surface a wrong map
    }
  }
  if (secrets.metadata) {
    try {
      out.metadata = await decodeEntry(secrets.metadata, profileId, 'metadata', profileId);
    } catch (e) {
      out.metadata = LOCKED;
    }
  }
  return out;
}

// ── encode (write side) ───────────────────────────────────────────────────────

// Build a { format, payload } secret element for a write, honoring the profile's
// E2EE state. Throws CloudCryptoError('locked') if E2EE is on but not unlocked,
// and CloudCryptoError('downgraded') if the server claims it is off for a
// profile this browser has seen encrypted.
async function encodeSecretElement(profileId, kind, id, secretMap, cryptoState) {
  if (!cryptoState.enabled) {
    // Re-check the mark here rather than trusting the passed-in state: this is
    // the single place plaintext can leave the browser, so it fails closed on
    // its own evidence even if a caller hands over a stale/forged state object.
    if (cryptoState.downgraded || wasE2eeSeen(profileId)) {
      throw new cc.CloudCryptoError('downgraded');
    }
    return { format: 0, payload: secretMap };
  }
  const s = requireUnlocked(profileId);
  const aad =
    kind === 'source'
      ? cc.sourceSecretAad(profileId, id, s.ckVersion)
      : cc.metadataSecretAad(profileId, s.ckVersion);
  const envelope = await cc.encryptSecretEnvelope({
    secret: secretMap,
    contentKey: s.key,
    ckVersion: s.ckVersion,
    aad,
    iv: cc.randomBytes(12),
  });
  return { format: 1, payload: envelope };
}

export async function setSourceSecret(profileId, sourceId, secretMap, cryptoState) {
  const el = await encodeSecretElement(profileId, 'source', sourceId, secretMap, cryptoState);
  const { error } = await supabase.rpc('set_source_secret', {
    p_source_id: sourceId,
    p_profile_id: profileId,
    p_format: el.format,
    p_payload: el.payload,
  });
  if (error) throw error;
}

export async function setMetadataSecret(profileId, secretMap, cryptoState) {
  const el = await encodeSecretElement(profileId, 'metadata', profileId, secretMap, cryptoState);
  const { error } = await supabase.rpc('set_metadata_secret', {
    p_profile_id: profileId,
    p_format: el.format,
    p_payload: el.payload,
  });
  if (error) throw error;
}

// ── device wrapping ───────────────────────────────────────────────────────────

// Wrap `ck` to every owner device that has registered a public key. Devices
// without a key yet are skipped (they self-provision or get provisioned later).
async function wrapCkForAllDevices(profileId, ck, ckVersion) {
  const out = [];
  for (const d of await devicesWithKeys()) {
    if (!d.public_key) continue;
    out.push({
      device_uid: d.device_uid,
      wrapped_ck: await wrapCkForPublicKey(profileId, d.device_uid, d.public_key, ck, ckVersion),
    });
  }
  return out;
}

async function wrapCkForPublicKey(profileId, deviceUid, publicKeyB64, ck, ckVersion) {
  const pub = cc.b64Decode(publicKeyB64);
  const eph = cc.generateP256KeyPair();
  const aad = cc.deviceWrapAad(profileId, deviceUid, ckVersion);
  return cc.encodeDeviceWrap({
    contentKey: ck,
    ckVersion,
    ephemeralPrivateKey: eph.privateKey,
    devicePublicKey: pub,
    iv: cc.randomBytes(12),
    aad,
  });
}

// ── unlock / enable / disable / rotate / provision ────────────────────────────

// Unlock this session by deriving the KEK from `passphrase` and unwrapping CK.
// Throws CloudCryptoError on a wrong passphrase (fail closed).
export async function unlock(profileId, passphrase) {
  const material = await getProfileCrypto(profileId);
  if (!material || !material.enabled) {
    throw new cc.CloudCryptoError('e2ee not enabled');
  }
  const aad = cc.kekAad(profileId, material.ck_version);
  const ck = await cc.decodeCkUnderKek({
    envelope: material.wrapped_ck,
    passphrase,
    ckVersion: material.ck_version,
    aad,
  });
  // A successful unwrap is proof the profile really is encrypted, so it is also
  // the strongest place to (re-)assert the sticky mark.
  markE2eeSeen(profileId);
  setSession(profileId, ck, material.ck_version);
}

// Collect the current plaintext secret maps for a profile (used by enable). The
// secrets are format 0 here, so no CK is required.
function plainSourceMaps(secrets) {
  const maps = {};
  for (const [id, entry] of Object.entries(secrets.sources ?? {})) {
    maps[id] = entry.format === 0 ? entry.payload ?? {} : {};
  }
  return maps;
}

export async function enableE2ee(profileId, passphrase) {
  const revision = await readRevision(profileId);
  const secrets = await getSecrets(profileId);
  const ck = cc.randomBytes(32);
  const salt = cc.randomBytes(16);
  const iters = cc.PBKDF2_PRODUCTION_ITERATIONS;
  const ckVersion = 1;

  const p_source_secrets = {};
  for (const [sourceId, map] of Object.entries(plainSourceMaps(secrets))) {
    p_source_secrets[sourceId] = await cc.encryptSecretEnvelope({
      secret: map,
      contentKey: ck,
      ckVersion,
      aad: cc.sourceSecretAad(profileId, sourceId, ckVersion),
      iv: cc.randomBytes(12),
    });
  }

  let p_metadata_secret = null;
  const metaMap = secrets.metadata?.format === 0 ? secrets.metadata.payload ?? {} : {};
  if (Object.keys(metaMap).length > 0) {
    p_metadata_secret = await cc.encryptSecretEnvelope({
      secret: metaMap,
      contentKey: ck,
      ckVersion,
      aad: cc.metadataSecretAad(profileId, ckVersion),
      iv: cc.randomBytes(12),
    });
  }

  const p_wrapped_ck = await cc.encodeCkUnderKek({
    contentKey: ck,
    ckVersion,
    passphrase,
    salt,
    iterations: iters,
    iv: cc.randomBytes(12),
    aad: cc.kekAad(profileId, ckVersion),
  });
  const p_device_cks = await wrapCkForAllDevices(profileId, ck, ckVersion);

  const { error } = await supabase.rpc('enable_e2ee', {
    p_profile_id: profileId,
    p_expected_revision: revision,
    p_salt: cc.b64Encode(salt),
    p_kdf_iterations: iters,
    p_wrapped_ck,
    p_source_secrets,
    p_metadata_secret,
    p_device_cks,
  });
  if (error) throw error;
  markE2eeSeen(profileId);
  setSession(profileId, ck, ckVersion);
}

// Decrypt every current secret with the unlocked CK and hand them back plaintext.
async function decryptAllSecrets(profileId, secrets, ck, ckVersion) {
  const sources = {};
  for (const [id, entry] of Object.entries(secrets.sources ?? {})) {
    sources[id] =
      entry.format === 1
        ? await cc.decryptSecretEnvelope({
            envelope: entry.payload,
            contentKey: ck,
            ckVersion,
            aad: cc.sourceSecretAad(profileId, id, ckVersion),
          })
        : entry.payload ?? {};
  }
  let metadata = null;
  if (secrets.metadata) {
    metadata =
      secrets.metadata.format === 1
        ? await cc.decryptSecretEnvelope({
            envelope: secrets.metadata.payload,
            contentKey: ck,
            ckVersion,
            aad: cc.metadataSecretAad(profileId, ckVersion),
          })
        : secrets.metadata.payload ?? {};
  }
  return { sources, metadata };
}

export async function disableE2ee(profileId) {
  const s = requireUnlocked(profileId);
  const revision = await readRevision(profileId);
  const secrets = await getSecrets(profileId);
  const plain = await decryptAllSecrets(profileId, secrets, s.key, s.ckVersion);
  const p_metadata_secret =
    plain.metadata && Object.keys(plain.metadata).length > 0 ? plain.metadata : null;
  const { error } = await supabase.rpc('disable_e2ee', {
    p_profile_id: profileId,
    p_expected_revision: revision,
    p_source_secrets: plain.sources,
    p_metadata_secret,
  });
  if (error) throw error;
  // The user just turned E2EE off from this browser, so "the server says it is
  // off" is now expected rather than suspicious. Other browsers/devices keep
  // their own marks and must acknowledge the change themselves — that
  // asymmetry is the point: only a local, human action clears the mark.
  acknowledgeDowngrade(profileId);
  lock();
}

export async function rotatePassphrase(profileId, newPassphrase) {
  const s = requireUnlocked(profileId);
  const salt = cc.randomBytes(16);
  const iters = cc.PBKDF2_PRODUCTION_ITERATIONS;
  const p_wrapped_ck = await cc.encodeCkUnderKek({
    contentKey: s.key,
    ckVersion: s.ckVersion,
    passphrase: newPassphrase,
    salt,
    iterations: iters,
    iv: cc.randomBytes(12),
    aad: cc.kekAad(profileId, s.ckVersion),
  });
  const p_device_cks = await wrapCkForAllDevices(profileId, s.key, s.ckVersion);
  const { error } = await supabase.rpc('rotate_passphrase', {
    p_profile_id: profileId,
    p_salt: cc.b64Encode(salt),
    p_kdf_iterations: iters,
    p_wrapped_ck,
    p_device_cks,
  });
  if (error) throw error;
}

export async function rotateContentKey(profileId, passphrase) {
  const s = requireUnlocked(profileId);
  const material = await getProfileCrypto(profileId);
  if (!material || !material.enabled) throw new cc.CloudCryptoError('e2ee not enabled');
  const oldCkVersion = material.ck_version;
  const newCkVersion = oldCkVersion + 1;

  // Verify the typed passphrase BEFORE anything is minted or pushed.
  //
  // `requireUnlocked` only proves a session CK exists — it says nothing about
  // what the user just typed into "Current passphrase". Without this check a
  // typo sailed through: the new CK was wrapped under a KEK derived from the
  // wrong passphrase, the server accepted it (it cannot tell), the toast said
  // success, and the browser stayed unlocked — while the old wrapped_ck was
  // overwritten. The correct passphrase then no longer worked either, and
  // `disableE2ee` requires an unlocked session, so the profile was permanently
  // unrecoverable from the panel. One typo, silent, irreversible.
  //
  // The GCM tag does the real work: a wrong passphrase derives a wrong KEK and
  // decryption fails closed. The constant-time comparison against the session
  // key is belt-and-braces for the case where the stored envelope somehow no
  // longer matches the session we are rotating.
  let reDerived;
  try {
    reDerived = await cc.decodeCkUnderKek({
      envelope: material.wrapped_ck,
      passphrase,
      ckVersion: oldCkVersion,
      aad: cc.kekAad(profileId, oldCkVersion),
    });
  } catch {
    throw new cc.CloudCryptoError('wrong passphrase');
  }
  if (!cc.constantTimeEqual(reDerived, s.key)) {
    throw new cc.CloudCryptoError('wrong passphrase');
  }
  const revision = await readRevision(profileId);
  const secrets = await getSecrets(profileId);
  const plain = await decryptAllSecrets(profileId, secrets, s.key, s.ckVersion);

  const newCk = cc.randomBytes(32);
  const p_source_secrets = {};
  for (const [sourceId, map] of Object.entries(plain.sources)) {
    p_source_secrets[sourceId] = await cc.encryptSecretEnvelope({
      secret: map,
      contentKey: newCk,
      ckVersion: newCkVersion,
      aad: cc.sourceSecretAad(profileId, sourceId, newCkVersion),
      iv: cc.randomBytes(12),
    });
  }
  let p_metadata_secret = null;
  if (plain.metadata && Object.keys(plain.metadata).length > 0) {
    p_metadata_secret = await cc.encryptSecretEnvelope({
      secret: plain.metadata,
      contentKey: newCk,
      ckVersion: newCkVersion,
      aad: cc.metadataSecretAad(profileId, newCkVersion),
      iv: cc.randomBytes(12),
    });
  }

  // CK rotation keeps the passphrase KDF params (salt/iterations) unchanged —
  // re-wrap the NEW CK under the SAME KEK, only the ckv (and thus the KEK AAD)
  // advances.
  const salt = cc.b64Decode(material.salt);
  const p_wrapped_ck = await cc.encodeCkUnderKek({
    contentKey: newCk,
    ckVersion: newCkVersion,
    passphrase,
    salt,
    iterations: material.kdf_iterations,
    iv: cc.randomBytes(12),
    aad: cc.kekAad(profileId, newCkVersion),
  });
  const p_device_cks = await wrapCkForAllDevices(profileId, newCk, newCkVersion);

  const { error } = await supabase.rpc('rotate_content_key', {
    p_profile_id: profileId,
    p_expected_revision: revision,
    p_wrapped_ck,
    p_ck_version: newCkVersion,
    p_source_secrets,
    p_metadata_secret,
    p_device_cks,
  });
  if (error) throw error;
  setSession(profileId, newCk, newCkVersion);
}

export async function provisionDevice(profileId, deviceUid, publicKeyB64) {
  const s = requireUnlocked(profileId);
  const wrapped = await wrapCkForPublicKey(
    profileId,
    deviceUid,
    publicKeyB64,
    s.key,
    s.ckVersion,
  );
  const { error } = await supabase.rpc('provision_device_ck', {
    p_device_uid: deviceUid,
    p_profile_id: profileId,
    p_ck_version: s.ckVersion,
    p_wrapped_ck: wrapped,
  });
  if (error) throw error;
}

// Whether E2EE is on for a profile (gates the Devices tab provisioning UI).
export async function deviceCryptoContext(profileId) {
  const state = await getCryptoState(profileId);
  return {
    enabled: !!state.enabled,
    ckVersion: state.ck_version,
    downgraded: !!state.downgraded,
  };
}

// Authoritative per-device provisioning state for the Devices page, via the
// owner-scoped list_device_ck accessor (state only — no key material). Returns
// { missing, byDevice: { <device_uid>: entry } }. `missing` is true on a
// pre-migration backend, so the caller can fall back to the public_key heuristic.
export async function listDeviceProvisioning(profileId) {
  const { data, error } = await supabase.rpc('list_device_ck', { p_profile_id: profileId });
  if (error) {
    if (isMissingFunctionError(error)) return { missing: true, byDevice: {} };
    throw error;
  }
  const byDevice = {};
  for (const e of data ?? []) byDevice[e.device_uid] = e;
  return { missing: false, byDevice };
}
