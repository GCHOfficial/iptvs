/// Client-side crypto for cloud sync's opt-in end-to-end encryption (Phase 3).
///
/// This is the **only** crypto surface the device uses for cloud secrets. It is
/// deliberately dependency-light: symmetric primitives (PBKDF2 / HKDF / AES-GCM)
/// come from `package:cryptography`, but the P-256 elliptic-curve arithmetic is
/// implemented here in pure Dart. That is a considered choice, not an oversight:
/// `package:cryptography` 2.9.0 ships **no working ECDH on the Dart VM or on
/// native Flutter** — `DartEcdh` throws `UnimplementedError`, and only the
/// browser Web-Crypto path is implemented — so relying on it would make the
/// device unable to unwrap its content key on Android TV / Windows / Linux and
/// would make these vectors untestable under `flutter test`. The pure-Dart
/// P-256 here is validated against the RFC 5903 §8.1 known-answer vector (see
/// `test/cloud_crypto_test.dart`), which is the cross-language interop anchor
/// the panel's WebCrypto/Node implementation must also satisfy.
///
/// # Envelopes (all JSON; every binary field is standard base64, RFC 4648 **with
/// padding** — never base64url)
///
/// - **Secret** (`format` 1): fields `v`=1, `alg`="A256GCM", `ckv` (int), `iv`
///   (b64 of the 12-byte nonce), `ct` (b64 of `ciphertext||tag`). Plaintext =
///   UTF-8 of the secret map as **canonical JSON** (keys sorted ascending, no
///   whitespace). AES key = the content key.
/// - **Device-wrapped CK**: fields `v`=1, `alg`="A256GCM", `kdf`="HKDF-SHA256",
///   `ckv`, `epk` (b64 of the 65-byte uncompressed `0x04||X||Y` ephemeral key),
///   `iv`, `ct`. AES key = HKDF-SHA256(ikm = ECDH shared X (32B, left-padded),
///   salt = empty, info = AAD, L = 32).
/// - **CK-under-KEK** (panel-side; encode/decode provided for tests): fields
///   `v`=1, `alg`="A256GCM", `kdf`="PBKDF2-SHA256", `ckv`, `salt` (b64 of 16B),
///   `iter` (int), `iv`, `ct`. AES key = PBKDF2-HMAC-SHA256.
///
/// The **AAD is always reconstructed from context and passed to AES-GCM**; it is
/// never read from the envelope. `ckv` is additionally cross-checked against the
/// expected content-key version before decrypting. For the device-wrap the AAD
/// is *also* bound through the HKDF `info`, so a wrong profile/device/version
/// yields a different key and fails closed. Any parse / version / auth failure
/// throws [CloudCryptoException] — a decrypt path **never** returns an empty map
/// or silently drops a credential.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A typed, fail-closed crypto failure. Surfaced by cloud sync as a
/// "needs attention" state, never as a dropped/empty secret.
class CloudCryptoException implements Exception {
  final String message;
  const CloudCryptoException(this.message);
  @override
  String toString() => 'CloudCryptoException: $message';
}

const int kEnvelopeVersion = 1;
const String kEnvelopeAlg = 'A256GCM';
const String kHkdfName = 'HKDF-SHA256';
const String kPbkdf2Name = 'PBKDF2-SHA256';

/// Production PBKDF2 iteration count for the passphrase KEK (panel-side).
const int kPbkdf2ProductionIterations = 600000;

/// Accepted range for an envelope's `iter` on the READ path. The server's
/// `>= 100000` floor validates `profile_crypto.kdf_iterations`, a column no read
/// path consults — [decodeCkUnderKek] takes `iter` from the envelope, which is
/// attacker-writable. Confidentiality never rested on this (a forged low count
/// still cannot produce a valid GCM tag), but an unbounded value is a DoS in
/// both directions. Keep in lockstep with `panel/src/crypto.js`.
const int kPbkdf2MinIterations = 100000;
const int kPbkdf2MaxIterations = 10000000;

// ── base64 (standard, padded) ────────────────────────────────────────────────

String b64Encode(List<int> bytes) => base64.encode(bytes);

Uint8List b64Decode(String s) {
  try {
    return base64.decode(s);
  } on FormatException catch (e) {
    throw CloudCryptoException('invalid base64: ${e.message}');
  }
}

// ── canonical JSON ───────────────────────────────────────────────────────────

/// Canonical JSON for a secret map: keys sorted ascending (UTF-16 code-unit
/// order — every secret key is ASCII, so this equals byte order), standard JSON
/// string escaping, no whitespace. This is the exact byte sequence encrypted, so
/// the panel must produce the identical string before UTF-8 encoding.
String canonicalJson(Map<String, String> map) {
  final keys = map.keys.toList()..sort();
  final ordered = <String, String>{for (final k in keys) k: map[k]!};
  return jsonEncode(ordered);
}

// ── AAD builders (UTF-8 of a pipe-joined context string) ─────────────────────

List<int> sourceSecretAad(String profileId, String sourceId, int ckVersion) =>
    utf8.encode('iptvs.secret.v1|source|$profileId|$sourceId|$ckVersion');

List<int> metadataSecretAad(String profileId, int ckVersion) =>
    utf8.encode('iptvs.secret.v1|metadata|$profileId|$ckVersion');

List<int> kekAad(String profileId, int ckVersion) =>
    utf8.encode('iptvs.kek.v1|$profileId|$ckVersion');

List<int> deviceWrapAad(String profileId, String deviceUid, int ckVersion) =>
    utf8.encode('iptvs.devicewrap.v1|$profileId|$deviceUid|$ckVersion');

// ── symmetric primitives (package:cryptography) ──────────────────────────────

Future<Uint8List> pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int lengthBytes,
) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: lengthBytes * 8,
  );
  final key = await pbkdf2.deriveKey(
    secretKey: SecretKey(password),
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}

Future<Uint8List> hkdfSha256(
  List<int> ikm,
  List<int> salt,
  List<int> info,
  int lengthBytes,
) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: lengthBytes);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt,
    info: info,
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// AES-256-GCM encrypt → `ciphertext || tag` (16-byte tag appended).
Future<Uint8List> aesGcmEncrypt(
  List<int> key,
  List<int> iv,
  List<int> plaintext,
  List<int> aad,
) async {
  if (key.length != 32) throw const CloudCryptoException('key must be 32 bytes');
  if (iv.length != 12) throw const CloudCryptoException('iv must be 12 bytes');
  final algo = AesGcm.with256bits();
  final box = await algo.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: iv,
    aad: aad,
  );
  final tag = box.mac.bytes;
  final out = Uint8List(box.cipherText.length + tag.length);
  out.setAll(0, box.cipherText);
  out.setAll(box.cipherText.length, tag);
  return out;
}

/// AES-256-GCM decrypt of `ciphertext || tag`. Throws [CloudCryptoException] on
/// any authentication failure (fail closed).
Future<Uint8List> aesGcmDecrypt(
  List<int> key,
  List<int> iv,
  List<int> ctAndTag,
  List<int> aad,
) async {
  if (key.length != 32) throw const CloudCryptoException('key must be 32 bytes');
  if (iv.length != 12) throw const CloudCryptoException('iv must be 12 bytes');
  if (ctAndTag.length < 16) {
    throw const CloudCryptoException('ciphertext too short');
  }
  final ct = ctAndTag.sublist(0, ctAndTag.length - 16);
  final tag = ctAndTag.sublist(ctAndTag.length - 16);
  final algo = AesGcm.with256bits();
  try {
    final pt = await algo.decrypt(
      SecretBox(ct, nonce: iv, mac: Mac(tag)),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(pt);
  } on SecretBoxAuthenticationError {
    throw const CloudCryptoException('authentication failed');
  }
}

// ── P-256 (pure Dart) ────────────────────────────────────────────────────────

final BigInt _pP = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _aP = _pP - BigInt.from(3);
final BigInt _bP = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);
final BigInt _nP = BigInt.parse(
  'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
  radix: 16,
);
final BigInt _gxP = BigInt.parse(
  '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
  radix: 16,
);
final BigInt _gyP = BigInt.parse(
  '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
  radix: 16,
);
final BigInt _three = BigInt.from(3);
final BigInt _ff = BigInt.from(0xff);

class _EcPoint {
  final BigInt? x;
  final BigInt? y;
  const _EcPoint(this.x, this.y);
  static const _EcPoint infinity = _EcPoint(null, null);
  bool get isInfinity => x == null;
}

final _EcPoint _g = _EcPoint(_gxP, _gyP);

_EcPoint _double(_EcPoint p) {
  if (p.isInfinity) return p;
  final x1 = p.x!, y1 = p.y!;
  if (y1 == BigInt.zero) return _EcPoint.infinity;
  final s =
      ((_three * x1 * x1 + _aP) % _pP) * (BigInt.two * y1).modInverse(_pP) % _pP;
  final x3 = (s * s - BigInt.two * x1) % _pP;
  final y3 = (s * (x1 - x3) - y1) % _pP;
  return _EcPoint(x3, y3);
}

_EcPoint _add(_EcPoint p, _EcPoint q) {
  if (p.isInfinity) return q;
  if (q.isInfinity) return p;
  final x1 = p.x!, y1 = p.y!, x2 = q.x!, y2 = q.y!;
  if (x1 == x2) {
    if ((y1 + y2) % _pP == BigInt.zero) return _EcPoint.infinity;
    return _double(p);
  }
  final s = ((y2 - y1) % _pP) * ((x2 - x1) % _pP).modInverse(_pP) % _pP;
  final x3 = (s * s - x1 - x2) % _pP;
  final y3 = (s * (x1 - x3) - y1) % _pP;
  return _EcPoint(x3, y3);
}

_EcPoint _scalarMult(BigInt k, _EcPoint p) {
  var result = _EcPoint.infinity;
  var addend = p;
  var kk = k;
  while (kk > BigInt.zero) {
    if (kk.isOdd) result = _add(result, addend);
    addend = _double(addend);
    kk = kk >> 1;
  }
  return result;
}

bool _isOnCurve(BigInt x, BigInt y) {
  final lhs = (y * y) % _pP;
  final rhs = (x * x * x + _aP * x + _bP) % _pP;
  return lhs == rhs;
}

Uint8List _bigIntToBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var tmp = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (tmp & _ff).toInt();
    tmp = tmp >> 8;
  }
  return out;
}

BigInt _bytesToBigInt(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

Uint8List _encodePublic(_EcPoint p) {
  if (p.isInfinity) {
    throw const CloudCryptoException('cannot encode point at infinity');
  }
  final out = Uint8List(65);
  out[0] = 0x04;
  out.setAll(1, _bigIntToBytes(p.x!, 32));
  out.setAll(33, _bigIntToBytes(p.y!, 32));
  return out;
}

_EcPoint _decodePublic(List<int> bytes) {
  if (bytes.length != 65 || bytes[0] != 0x04) {
    throw const CloudCryptoException('invalid uncompressed P-256 public key');
  }
  final x = _bytesToBigInt(bytes.sublist(1, 33));
  final y = _bytesToBigInt(bytes.sublist(33, 65));
  if (x >= _pP || y >= _pP) {
    throw const CloudCryptoException('P-256 public key out of range');
  }
  if (!_isOnCurve(x, y)) {
    throw const CloudCryptoException('P-256 public key not on curve');
  }
  return _EcPoint(x, y);
}

/// A device's long-lived P-256 key pair. [privateKey] is the 32-byte scalar;
/// [publicKey] is the 65-byte uncompressed point (`0x04 || X || Y`).
class EcKeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  const EcKeyPair({required this.privateKey, required this.publicKey});
}

/// Derive a key pair from a fixed 32-byte scalar in `[1, n-1]` (deterministic;
/// used for test vectors and to rebuild the public key from a stored private).
EcKeyPair p256KeyPairFromScalar(List<int> scalar) {
  if (scalar.length != 32) {
    throw const CloudCryptoException('P-256 scalar must be 32 bytes');
  }
  final d = _bytesToBigInt(scalar);
  if (d == BigInt.zero || d >= _nP) {
    throw const CloudCryptoException('P-256 scalar out of range');
  }
  return EcKeyPair(
    privateKey: Uint8List.fromList(scalar),
    publicKey: _encodePublic(_scalarMult(d, _g)),
  );
}

/// Generate a fresh P-256 key pair using [random] (defaults to [Random.secure]).
EcKeyPair generateP256KeyPair([Random? random]) {
  final r = random ?? Random.secure();
  BigInt d;
  List<int> bytes;
  do {
    bytes = List<int>.generate(32, (_) => r.nextInt(256));
    d = _bytesToBigInt(bytes);
  } while (d == BigInt.zero || d >= _nP);
  return p256KeyPairFromScalar(bytes);
}

/// ECDH shared secret = the X coordinate of `privateKey * peerPublic`, encoded
/// as **exactly 32 bytes, big-endian, left-padded with zeros**. A leading-zero X
/// must round-trip to a 32-byte value whose first byte is `0x00` (a classic
/// interop bug when an implementation trims leading zeros).
Uint8List ecdhSharedX(List<int> privateKey, List<int> peerPublic) {
  if (privateKey.length != 32) {
    throw const CloudCryptoException('P-256 private key must be 32 bytes');
  }
  final d = _bytesToBigInt(privateKey);
  if (d == BigInt.zero || d >= _nP) {
    throw const CloudCryptoException('P-256 private key out of range');
  }
  final shared = _scalarMult(d, _decodePublic(peerPublic));
  if (shared.isInfinity) {
    throw const CloudCryptoException('degenerate ECDH result');
  }
  return _bigIntToBytes(shared.x!, 32);
}

// ── envelope helpers ─────────────────────────────────────────────────────────

int _requireInt(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is int) return v;
  throw CloudCryptoException('envelope missing int "$key"');
}

String _requireString(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is String) return v;
  throw CloudCryptoException('envelope missing string "$key"');
}

void _checkHeader(Map<String, dynamic> env, int expectedCkVersion, String? kdf) {
  if (_requireInt(env, 'v') != kEnvelopeVersion) {
    throw const CloudCryptoException('unsupported envelope version');
  }
  if (_requireString(env, 'alg') != kEnvelopeAlg) {
    throw const CloudCryptoException('unsupported envelope alg');
  }
  if (kdf != null && _requireString(env, 'kdf') != kdf) {
    throw const CloudCryptoException('unsupported envelope kdf');
  }
  // The ckv is cross-checked against the AAD binding: the AAD embeds the
  // expected content-key version, so a mismatch here means the envelope was
  // built under a different key generation and must fail closed.
  if (_requireInt(env, 'ckv') != expectedCkVersion) {
    throw const CloudCryptoException('content-key version mismatch');
  }
}

// ── secret envelope (format 1) ───────────────────────────────────────────────

/// Encrypt a secret map under the content key [contentKey] (32 bytes) into a
/// `format` 1 secret envelope. [iv] must be a fresh 12-byte random nonce.
Future<Map<String, dynamic>> encryptSecretEnvelope({
  required Map<String, String> secret,
  required List<int> contentKey,
  required int ckVersion,
  required List<int> aad,
  required List<int> iv,
}) async {
  final plaintext = utf8.encode(canonicalJson(secret));
  final ctAndTag = await aesGcmEncrypt(contentKey, iv, plaintext, aad);
  return {
    'v': kEnvelopeVersion,
    'alg': kEnvelopeAlg,
    'ckv': ckVersion,
    'iv': b64Encode(iv),
    'ct': b64Encode(ctAndTag),
  };
}

/// Decrypt a `format` 1 secret envelope back to a secret map. Fails closed on
/// any version / auth / parse error.
Future<Map<String, String>> decryptSecretEnvelope({
  required Map<String, dynamic> envelope,
  required List<int> contentKey,
  required int ckVersion,
  required List<int> aad,
}) async {
  _checkHeader(envelope, ckVersion, null);
  final iv = b64Decode(_requireString(envelope, 'iv'));
  final ctAndTag = b64Decode(_requireString(envelope, 'ct'));
  final plaintext = await aesGcmDecrypt(contentKey, iv, ctAndTag, aad);
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(plaintext));
  } catch (_) {
    throw const CloudCryptoException('secret plaintext is not valid JSON');
  }
  if (decoded is! Map) {
    throw const CloudCryptoException('secret plaintext is not a JSON object');
  }
  return {
    for (final e in decoded.entries) e.key.toString(): e.value?.toString() ?? '',
  };
}

// ── device-wrapped CK ────────────────────────────────────────────────────────

/// Build a device-wrapped-CK envelope (panel-side / test-side). Derives the AES
/// key from ECDH(ephemeral private, device public) and HKDF(info = [aad]).
Future<Map<String, dynamic>> encodeDeviceWrap({
  required List<int> contentKey,
  required int ckVersion,
  required List<int> ephemeralPrivateKey,
  required List<int> devicePublicKey,
  required List<int> iv,
  required List<int> aad,
}) async {
  final shared = ecdhSharedX(ephemeralPrivateKey, devicePublicKey);
  final key = await hkdfSha256(shared, const [], aad, 32);
  final ctAndTag = await aesGcmEncrypt(key, iv, contentKey, aad);
  final epk = p256KeyPairFromScalar(ephemeralPrivateKey).publicKey;
  return {
    'v': kEnvelopeVersion,
    'alg': kEnvelopeAlg,
    'kdf': kHkdfName,
    'ckv': ckVersion,
    'epk': b64Encode(epk),
    'iv': b64Encode(iv),
    'ct': b64Encode(ctAndTag),
  };
}

/// Unwrap a device-wrapped-CK envelope with this device's [devicePrivateKey],
/// returning the 32-byte content key. Fails closed.
Future<Uint8List> decodeDeviceWrap({
  required Map<String, dynamic> envelope,
  required List<int> devicePrivateKey,
  required int ckVersion,
  required List<int> aad,
}) async {
  _checkHeader(envelope, ckVersion, kHkdfName);
  final epk = b64Decode(_requireString(envelope, 'epk'));
  final iv = b64Decode(_requireString(envelope, 'iv'));
  final ctAndTag = b64Decode(_requireString(envelope, 'ct'));
  final shared = ecdhSharedX(devicePrivateKey, epk);
  final key = await hkdfSha256(shared, const [], aad, 32);
  return aesGcmDecrypt(key, iv, ctAndTag, aad);
}

// ── CK-under-KEK (panel-side; encode/decode for completeness + tests) ─────────

Future<Map<String, dynamic>> encodeCkUnderKek({
  required List<int> contentKey,
  required int ckVersion,
  required String passphrase,
  required List<int> salt,
  required int iterations,
  required List<int> iv,
  required List<int> aad,
}) async {
  final kek = await pbkdf2Sha256(utf8.encode(passphrase), salt, iterations, 32);
  final ctAndTag = await aesGcmEncrypt(kek, iv, contentKey, aad);
  return {
    'v': kEnvelopeVersion,
    'alg': kEnvelopeAlg,
    'kdf': kPbkdf2Name,
    'ckv': ckVersion,
    'salt': b64Encode(salt),
    'iter': iterations,
    'iv': b64Encode(iv),
    'ct': b64Encode(ctAndTag),
  };
}

Future<Uint8List> decodeCkUnderKek({
  required Map<String, dynamic> envelope,
  required String passphrase,
  required int ckVersion,
  required List<int> aad,
}) async {
  _checkHeader(envelope, ckVersion, kPbkdf2Name);
  final salt = b64Decode(_requireString(envelope, 'salt'));
  final iterations = _requireInt(envelope, 'iter');
  if (iterations < kPbkdf2MinIterations || iterations > kPbkdf2MaxIterations) {
    throw const CloudCryptoException('envelope iteration count out of range');
  }
  final iv = b64Decode(_requireString(envelope, 'iv'));
  final ctAndTag = b64Decode(_requireString(envelope, 'ct'));
  final kek = await pbkdf2Sha256(utf8.encode(passphrase), salt, iterations, 32);
  return aesGcmDecrypt(kek, iv, ctAndTag, aad);
}
