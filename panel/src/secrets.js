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

// ── RPC wrappers ──────────────────────────────────────────────────────────────

export async function getCryptoState(profileId) {
  const { data, error } = await supabase.rpc('get_crypto_state', { p_profile_id: profileId });
  if (error) {
    if (isMissingFunctionError(error)) return { enabled: false, missing: true };
    throw error;
  }
  return data ?? { enabled: false };
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
// E2EE state. Throws CloudCryptoError('locked') if E2EE is on but not unlocked.
async function encodeSecretElement(profileId, kind, id, secretMap, cryptoState) {
  if (!cryptoState.enabled) {
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
  return { enabled: !!state.enabled, ckVersion: state.ck_version };
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
