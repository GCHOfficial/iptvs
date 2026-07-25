// Panel-side crypto for cloud sync's opt-in end-to-end encryption (Phase 3).
//
// This is the byte-exact WebCrypto twin of lib/data/cloud_crypto.dart. The two
// implementations MUST agree on every wire byte; the shared fixture
// test/fixtures/crypto_vectors.json is the interop gate (asserted by both
// test/cloud_crypto_test.dart on the Dart side and panel/test/crypto.test.js
// here).
//
// Primitives: PBKDF2-HMAC-SHA256, HKDF-SHA256, AES-256-GCM come from the native
// Web Crypto API (globalThis.crypto.subtle — present in the browser and in
// Node >= 20). The P-256 elliptic-curve arithmetic is implemented here in pure
// JS (BigInt), mirroring the pure-Dart curve in cloud_crypto.dart. That is a
// deliberate choice: deriving the ephemeral public key (epk) from a fixed
// scalar and importing a fixed-scalar private key for ECDH both need point
// multiplication anyway, and a single BigInt implementation guarantees
// byte-exact interop — including the leading-zero left-pad case that a
// WebCrypto/JWK round-trip would obscure. The ECDH multiply is validated
// against the RFC 5903 §8.1 known-answer vector in the fixture.
//
// # Envelopes (all JSON; every binary field is standard base64, RFC 4648 WITH
// padding — never base64url)
//
// - Secret (format 1): { v:1, alg:"A256GCM", ckv:<int>, iv, ct }. Plaintext =
//   UTF-8 of the secret map as canonical JSON. AES key = the content key (CK).
// - Device-wrapped CK: { v:1, alg:"A256GCM", kdf:"HKDF-SHA256", ckv, epk, iv,
//   ct }. AES key = HKDF-SHA256(ikm = ECDH shared X (32B, left-padded), salt =
//   empty, info = AAD). The AAD is bound twice (HKDF info AND GCM aad).
// - CK-under-KEK (passphrase): { v:1, alg:"A256GCM", kdf:"PBKDF2-SHA256", ckv,
//   salt, iter, iv, ct }. AES key = PBKDF2-HMAC-SHA256(passphrase, salt, iter).
//
// The AAD is ALWAYS reconstructed from context and passed to AES-GCM; it is
// never read from the envelope. ckv is additionally cross-checked against the
// expected content-key version. Any parse / version / auth failure throws
// CloudCryptoError — a decrypt path never returns an empty map or silently
// drops a credential (fail closed).

const subtle = globalThis.crypto.subtle;

export const ENVELOPE_VERSION = 1;
export const ENVELOPE_ALG = 'A256GCM';
export const HKDF_NAME = 'HKDF-SHA256';
export const PBKDF2_NAME = 'PBKDF2-SHA256';

// Production PBKDF2 iteration count for the passphrase KEK (panel-side).
export const PBKDF2_PRODUCTION_ITERATIONS = 600000;

// Accepted range for an envelope's `iter` on the READ path. The server's
// >= 100000 floor validates `profile_crypto.kdf_iterations`, a column no read
// path ever consults — `decodeCkUnderKek` takes `iter` from the envelope, which
// is attacker-writable. Confidentiality never depended on this (a forged low
// count still can't produce a valid GCM tag), but an unbounded value is a DoS
// in both directions: `iter: 1` derives instantly and silently, and a huge one
// wedges the tab for hours. Bounding it here is what makes the documented floor
// real rather than inert. Keep in lockstep with `cloud_crypto.dart`.
export const PBKDF2_MIN_ITERATIONS = 100000;
export const PBKDF2_MAX_ITERATIONS = 10000000;

// Constant-time byte comparison. Used to confirm a re-derived key matches the
// session's, without leaking where they diverge through timing.
export function constantTimeEqual(a, b) {
  if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// A typed, fail-closed crypto failure. Surfaced by the panel as a
// "needs attention" state, never as a dropped/empty secret.
export class CloudCryptoError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CloudCryptoError';
  }
}

// ── byte / hex / base64 / utf8 helpers ───────────────────────────────────────

const _te = new TextEncoder();
const _td = new TextDecoder('utf-8', { fatal: false });

export function utf8Encode(str) {
  return _te.encode(str);
}

export function utf8Decode(bytes) {
  return _td.decode(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
}

export function bytesToHex(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let out = '';
  for (let i = 0; i < b.length; i++) out += b[i].toString(16).padStart(2, '0');
  return out;
}

export function hexToBytes(hex) {
  const clean = hex.length % 2 === 0 ? hex : '0' + hex;
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substr(i * 2, 2), 16);
  }
  return out;
}

// Standard base64 (RFC 4648, WITH padding) — never base64url.
export function b64Encode(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
  return btoa(bin);
}

export function b64Decode(s) {
  let bin;
  try {
    bin = atob(s);
  } catch (e) {
    throw new CloudCryptoError('invalid base64');
  }
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function randomBytes(n) {
  const out = new Uint8Array(n);
  globalThis.crypto.getRandomValues(out);
  return out;
}

// ── canonical JSON ───────────────────────────────────────────────────────────

// Canonical JSON for a secret map: keys sorted ascending (UTF-16 code-unit
// order — every secret key is ASCII, so this equals byte order), standard JSON
// string escaping, no whitespace. This is the exact byte sequence encrypted, so
// it must match Dart's canonicalJson (jsonEncode of a key-sorted map) exactly.
export function canonicalJson(map) {
  const keys = Object.keys(map).sort();
  const ordered = {};
  for (const k of keys) ordered[k] = map[k];
  return JSON.stringify(ordered);
}

// ── AAD builders (UTF-8 of a pipe-joined context string) ─────────────────────

export function sourceSecretAad(profileId, sourceId, ckVersion) {
  return utf8Encode(`iptvs.secret.v1|source|${profileId}|${sourceId}|${ckVersion}`);
}

export function metadataSecretAad(profileId, ckVersion) {
  return utf8Encode(`iptvs.secret.v1|metadata|${profileId}|${ckVersion}`);
}

export function kekAad(profileId, ckVersion) {
  return utf8Encode(`iptvs.kek.v1|${profileId}|${ckVersion}`);
}

export function deviceWrapAad(profileId, deviceUid, ckVersion) {
  return utf8Encode(`iptvs.devicewrap.v1|${profileId}|${deviceUid}|${ckVersion}`);
}

// ── symmetric primitives (Web Crypto) ────────────────────────────────────────

export async function pbkdf2Sha256(password, salt, iterations, lengthBytes) {
  const baseKey = await subtle.importKey(
    'raw',
    _asBytes(password),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: _asBytes(salt), iterations },
    baseKey,
    lengthBytes * 8,
  );
  return new Uint8Array(bits);
}

export async function hkdfSha256(ikm, salt, info, lengthBytes) {
  const baseKey = await subtle.importKey('raw', _asBytes(ikm), 'HKDF', false, [
    'deriveBits',
  ]);
  const bits = await subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: _asBytes(salt), info: _asBytes(info) },
    baseKey,
    lengthBytes * 8,
  );
  return new Uint8Array(bits);
}

// AES-256-GCM encrypt → `ciphertext || tag` (16-byte tag appended, matching
// Web Crypto's own output layout).
export async function aesGcmEncrypt(key, iv, plaintext, aad) {
  const k = _asBytes(key);
  const nonce = _asBytes(iv);
  if (k.length !== 32) throw new CloudCryptoError('key must be 32 bytes');
  if (nonce.length !== 12) throw new CloudCryptoError('iv must be 12 bytes');
  const cryptoKey = await subtle.importKey('raw', k, 'AES-GCM', false, ['encrypt']);
  const buf = await subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, additionalData: _asBytes(aad), tagLength: 128 },
    cryptoKey,
    _asBytes(plaintext),
  );
  return new Uint8Array(buf);
}

// AES-256-GCM decrypt of `ciphertext || tag`. Throws CloudCryptoError on any
// authentication failure (fail closed).
export async function aesGcmDecrypt(key, iv, ctAndTag, aad) {
  const k = _asBytes(key);
  const nonce = _asBytes(iv);
  const data = _asBytes(ctAndTag);
  if (k.length !== 32) throw new CloudCryptoError('key must be 32 bytes');
  if (nonce.length !== 12) throw new CloudCryptoError('iv must be 12 bytes');
  if (data.length < 16) throw new CloudCryptoError('ciphertext too short');
  const cryptoKey = await subtle.importKey('raw', k, 'AES-GCM', false, ['decrypt']);
  try {
    const buf = await subtle.decrypt(
      { name: 'AES-GCM', iv: nonce, additionalData: _asBytes(aad), tagLength: 128 },
      cryptoKey,
      data,
    );
    return new Uint8Array(buf);
  } catch (e) {
    throw new CloudCryptoError('authentication failed');
  }
}

function _asBytes(v) {
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (Array.isArray(v)) return new Uint8Array(v);
  throw new CloudCryptoError('expected bytes');
}

// ── P-256 (pure JS, mirrors cloud_crypto.dart) ───────────────────────────────

const _pP = BigInt(
  '0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
);
const _aP = _pP - 3n;
const _bP = BigInt(
  '0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
);
const _nP = BigInt(
  '0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
);
const _gxP = BigInt(
  '0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
);
const _gyP = BigInt(
  '0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
);

// A point is { x, y } with x === null meaning the point at infinity.
const _INF = { x: null, y: null };
const _G = { x: _gxP, y: _gyP };

function _mod(a) {
  const r = a % _pP;
  return r < 0n ? r + _pP : r;
}

// Modular inverse via Fermat's little theorem (p is prime).
function _modInverse(a) {
  return _modPow(_mod(a), _pP - 2n, _pP);
}

function _modPow(base, exp, mod) {
  let result = 1n;
  let b = base % mod;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % mod;
    b = (b * b) % mod;
    e >>= 1n;
  }
  return result;
}

function _isInfinity(p) {
  return p.x === null;
}

function _double(p) {
  if (_isInfinity(p)) return p;
  const x1 = p.x;
  const y1 = p.y;
  if (y1 === 0n) return _INF;
  const s = _mod(_mod(3n * x1 * x1 + _aP) * _modInverse(2n * y1));
  const x3 = _mod(s * s - 2n * x1);
  const y3 = _mod(s * (x1 - x3) - y1);
  return { x: x3, y: y3 };
}

function _add(p, q) {
  if (_isInfinity(p)) return q;
  if (_isInfinity(q)) return p;
  const x1 = p.x;
  const y1 = p.y;
  const x2 = q.x;
  const y2 = q.y;
  if (x1 === x2) {
    if (_mod(y1 + y2) === 0n) return _INF;
    return _double(p);
  }
  const s = _mod(_mod(y2 - y1) * _modInverse(_mod(x2 - x1)));
  const x3 = _mod(s * s - x1 - x2);
  const y3 = _mod(s * (x1 - x3) - y1);
  return { x: x3, y: y3 };
}

function _scalarMult(k, p) {
  let result = _INF;
  let addend = p;
  let kk = k;
  while (kk > 0n) {
    if (kk & 1n) result = _add(result, addend);
    addend = _double(addend);
    kk >>= 1n;
  }
  return result;
}

function _isOnCurve(x, y) {
  const lhs = _mod(y * y);
  const rhs = _mod(x * x * x + _aP * x + _bP);
  return lhs === rhs;
}

function _bigIntToBytes(v, length) {
  const out = new Uint8Array(length);
  let tmp = v;
  for (let i = length - 1; i >= 0; i--) {
    out[i] = Number(tmp & 0xffn);
    tmp >>= 8n;
  }
  return out;
}

function _bytesToBigInt(b) {
  const bytes = _asBytes(b);
  let r = 0n;
  for (let i = 0; i < bytes.length; i++) r = (r << 8n) | BigInt(bytes[i]);
  return r;
}

function _encodePublic(p) {
  if (_isInfinity(p)) {
    throw new CloudCryptoError('cannot encode point at infinity');
  }
  const out = new Uint8Array(65);
  out[0] = 0x04;
  out.set(_bigIntToBytes(p.x, 32), 1);
  out.set(_bigIntToBytes(p.y, 32), 33);
  return out;
}

function _decodePublic(bytes) {
  const b = _asBytes(bytes);
  if (b.length !== 65 || b[0] !== 0x04) {
    throw new CloudCryptoError('invalid uncompressed P-256 public key');
  }
  const x = _bytesToBigInt(b.subarray(1, 33));
  const y = _bytesToBigInt(b.subarray(33, 65));
  if (x >= _pP || y >= _pP) {
    throw new CloudCryptoError('P-256 public key out of range');
  }
  if (!_isOnCurve(x, y)) {
    throw new CloudCryptoError('P-256 public key not on curve');
  }
  return { x, y };
}

// A device's long-lived P-256 key pair. privateKey is the 32-byte scalar;
// publicKey is the 65-byte uncompressed point (0x04 || X || Y).
export function p256KeyPairFromScalar(scalar) {
  const s = _asBytes(scalar);
  if (s.length !== 32) {
    throw new CloudCryptoError('P-256 scalar must be 32 bytes');
  }
  const d = _bytesToBigInt(s);
  if (d === 0n || d >= _nP) {
    throw new CloudCryptoError('P-256 scalar out of range');
  }
  return {
    privateKey: new Uint8Array(s),
    publicKey: _encodePublic(_scalarMult(d, _G)),
  };
}

export function generateP256KeyPair() {
  let d;
  let bytes;
  do {
    bytes = randomBytes(32);
    d = _bytesToBigInt(bytes);
  } while (d === 0n || d >= _nP);
  return p256KeyPairFromScalar(bytes);
}

// ECDH shared secret = the X coordinate of `privateKey * peerPublic`, encoded as
// exactly 32 bytes, big-endian, LEFT-PADDED with zeros. A leading-zero X must
// round-trip to a 32-byte value whose first byte is 0x00 (a classic interop
// bug when an implementation trims leading zeros).
export function ecdhSharedX(privateKey, peerPublic) {
  const priv = _asBytes(privateKey);
  if (priv.length !== 32) {
    throw new CloudCryptoError('P-256 private key must be 32 bytes');
  }
  const d = _bytesToBigInt(priv);
  if (d === 0n || d >= _nP) {
    throw new CloudCryptoError('P-256 private key out of range');
  }
  const shared = _scalarMult(d, _decodePublic(peerPublic));
  if (_isInfinity(shared)) {
    throw new CloudCryptoError('degenerate ECDH result');
  }
  return _bigIntToBytes(shared.x, 32);
}

// ── envelope helpers ─────────────────────────────────────────────────────────

function _requireInt(env, key) {
  const v = env[key];
  if (typeof v === 'number' && Number.isInteger(v)) return v;
  throw new CloudCryptoError(`envelope missing int "${key}"`);
}

function _requireString(env, key) {
  const v = env[key];
  if (typeof v === 'string') return v;
  throw new CloudCryptoError(`envelope missing string "${key}"`);
}

function _checkHeader(env, expectedCkVersion, kdf) {
  if (!env || typeof env !== 'object') {
    throw new CloudCryptoError('envelope is not an object');
  }
  if (_requireInt(env, 'v') !== ENVELOPE_VERSION) {
    throw new CloudCryptoError('unsupported envelope version');
  }
  if (_requireString(env, 'alg') !== ENVELOPE_ALG) {
    throw new CloudCryptoError('unsupported envelope alg');
  }
  if (kdf != null && _requireString(env, 'kdf') !== kdf) {
    throw new CloudCryptoError('unsupported envelope kdf');
  }
  // The ckv is cross-checked against the AAD binding: the AAD embeds the
  // expected content-key version, so a mismatch here means the envelope was
  // built under a different key generation and must fail closed.
  if (_requireInt(env, 'ckv') !== expectedCkVersion) {
    throw new CloudCryptoError('content-key version mismatch');
  }
}

// ── secret envelope (format 1) ───────────────────────────────────────────────

// Encrypt a secret map under the content key (32 bytes) into a format-1 secret
// envelope. `iv` must be a fresh 12-byte random nonce.
export async function encryptSecretEnvelope({ secret, contentKey, ckVersion, aad, iv }) {
  const plaintext = utf8Encode(canonicalJson(secret));
  const ctAndTag = await aesGcmEncrypt(contentKey, iv, plaintext, aad);
  return {
    v: ENVELOPE_VERSION,
    alg: ENVELOPE_ALG,
    ckv: ckVersion,
    iv: b64Encode(iv),
    ct: b64Encode(ctAndTag),
  };
}

// Decrypt a format-1 secret envelope back to a secret map. Fails closed on any
// version / auth / parse error.
export async function decryptSecretEnvelope({ envelope, contentKey, ckVersion, aad }) {
  _checkHeader(envelope, ckVersion, null);
  const iv = b64Decode(_requireString(envelope, 'iv'));
  const ctAndTag = b64Decode(_requireString(envelope, 'ct'));
  const plaintext = await aesGcmDecrypt(contentKey, iv, ctAndTag, aad);
  let decoded;
  try {
    decoded = JSON.parse(utf8Decode(plaintext));
  } catch (e) {
    throw new CloudCryptoError('secret plaintext is not valid JSON');
  }
  if (decoded === null || typeof decoded !== 'object' || Array.isArray(decoded)) {
    throw new CloudCryptoError('secret plaintext is not a JSON object');
  }
  const out = {};
  for (const [k, val] of Object.entries(decoded)) {
    out[k] = val == null ? '' : String(val);
  }
  return out;
}

// ── device-wrapped CK ────────────────────────────────────────────────────────

// Build a device-wrapped-CK envelope. Derives the AES key from ECDH(ephemeral
// private, device public) and HKDF(info = aad); the aad is bound twice.
export async function encodeDeviceWrap({
  contentKey,
  ckVersion,
  ephemeralPrivateKey,
  devicePublicKey,
  iv,
  aad,
}) {
  const shared = ecdhSharedX(ephemeralPrivateKey, devicePublicKey);
  const key = await hkdfSha256(shared, new Uint8Array(0), aad, 32);
  const ctAndTag = await aesGcmEncrypt(key, iv, contentKey, aad);
  const epk = p256KeyPairFromScalar(ephemeralPrivateKey).publicKey;
  return {
    v: ENVELOPE_VERSION,
    alg: ENVELOPE_ALG,
    kdf: HKDF_NAME,
    ckv: ckVersion,
    epk: b64Encode(epk),
    iv: b64Encode(iv),
    ct: b64Encode(ctAndTag),
  };
}

// Unwrap a device-wrapped-CK envelope with this device's private key, returning
// the 32-byte content key. Fails closed.
export async function decodeDeviceWrap({ envelope, devicePrivateKey, ckVersion, aad }) {
  _checkHeader(envelope, ckVersion, HKDF_NAME);
  const epk = b64Decode(_requireString(envelope, 'epk'));
  const iv = b64Decode(_requireString(envelope, 'iv'));
  const ctAndTag = b64Decode(_requireString(envelope, 'ct'));
  const shared = ecdhSharedX(devicePrivateKey, epk);
  const key = await hkdfSha256(shared, new Uint8Array(0), aad, 32);
  return aesGcmDecrypt(key, iv, ctAndTag, aad);
}

// ── CK-under-KEK (panel-side passphrase wrap) ─────────────────────────────────

export async function encodeCkUnderKek({
  contentKey,
  ckVersion,
  passphrase,
  salt,
  iterations,
  iv,
  aad,
}) {
  const kek = await pbkdf2Sha256(utf8Encode(passphrase), salt, iterations, 32);
  const ctAndTag = await aesGcmEncrypt(kek, iv, contentKey, aad);
  return {
    v: ENVELOPE_VERSION,
    alg: ENVELOPE_ALG,
    kdf: PBKDF2_NAME,
    ckv: ckVersion,
    salt: b64Encode(salt),
    iter: iterations,
    iv: b64Encode(iv),
    ct: b64Encode(ctAndTag),
  };
}

export async function decodeCkUnderKek({ envelope, passphrase, ckVersion, aad }) {
  _checkHeader(envelope, ckVersion, PBKDF2_NAME);
  const salt = b64Decode(_requireString(envelope, 'salt'));
  const iterations = _requireInt(envelope, 'iter');
  if (iterations < PBKDF2_MIN_ITERATIONS || iterations > PBKDF2_MAX_ITERATIONS) {
    throw new CloudCryptoError('envelope iteration count out of range');
  }
  const iv = b64Decode(_requireString(envelope, 'iv'));
  const ctAndTag = b64Decode(_requireString(envelope, 'ct'));
  const kek = await pbkdf2Sha256(utf8Encode(passphrase), salt, iterations, 32);
  return aesGcmDecrypt(kek, iv, ctAndTag, aad);
}
