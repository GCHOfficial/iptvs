// Cross-language crypto interop gate. Every vector in the shared fixture
// (test/fixtures/crypto_vectors.json — authored by the Dart side from
// lib/data/cloud_crypto.dart) MUST pass here, byte-for-byte, or the panel and
// the app disagree on the wire and a device can't unwrap what the panel wrote
// (and vice versa). Plus round-trips and fail-closed cases.
//
// Run with `npm test` (node --test over test/*.test.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  canonicalJson,
  pbkdf2Sha256,
  hkdfSha256,
  aesGcmEncrypt,
  aesGcmDecrypt,
  ecdhSharedX,
  p256KeyPairFromScalar,
  generateP256KeyPair,
  encodeDeviceWrap,
  decodeDeviceWrap,
  encryptSecretEnvelope,
  decryptSecretEnvelope,
  encodeCkUnderKek,
  decodeCkUnderKek,
  sourceSecretAad,
  metadataSecretAad,
  kekAad,
  deviceWrapAad,
  hexToBytes,
  bytesToHex,
  b64Decode,
  b64Encode,
  utf8Encode,
  randomBytes,
  CloudCryptoError,
} from '../src/crypto.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(
  readFileSync(join(__dirname, '../../test/fixtures/crypto_vectors.json'), 'utf-8'),
);

const hex = (b) => bytesToHex(b);
const concatBytes = (...arrs) => {
  const total = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const a of arrs) {
    out.set(a, o);
    o += a.length;
  }
  return out;
};

// ── canonicalJson ─────────────────────────────────────────────────────────────

for (const v of fixtures.canonicalJson) {
  test(`canonicalJson: ${v.name}`, () => {
    assert.equal(canonicalJson(v.input), v.expected);
  });
}

test('canonicalJson sorts keys ascending by code unit and adds no whitespace', () => {
  assert.equal(canonicalJson({ z: '1', a: '2', m: '3' }), '{"a":"2","m":"3","z":"1"}');
});

// ── PBKDF2-HMAC-SHA256 ────────────────────────────────────────────────────────

for (const v of fixtures.pbkdf2HmacSha256) {
  test(`pbkdf2HmacSha256: ${v.name}`, async () => {
    const password = v.password_hex
      ? hexToBytes(v.password_hex)
      : utf8Encode(v.password_utf8);
    const salt = v.salt_hex ? hexToBytes(v.salt_hex) : utf8Encode(v.salt_utf8);
    const out = await pbkdf2Sha256(password, salt, v.iterations, v.dkLen);
    assert.equal(hex(out), v.expected_hex);
  });
}

// ── HKDF-SHA256 ───────────────────────────────────────────────────────────────

for (const v of fixtures.hkdfSha256) {
  test(`hkdfSha256: ${v.name}`, async () => {
    const out = await hkdfSha256(
      hexToBytes(v.ikm_hex),
      hexToBytes(v.salt_hex),
      hexToBytes(v.info_hex),
      v.length,
    );
    assert.equal(hex(out), v.okm_hex);
  });
}

// ── AES-256-GCM ───────────────────────────────────────────────────────────────

for (const v of fixtures.aesGcm256) {
  test(`aesGcm256: ${v.name}`, async () => {
    const key = hexToBytes(v.key_hex);
    const iv = hexToBytes(v.iv_hex);
    const aad = hexToBytes(v.aad_hex);
    const pt = hexToBytes(v.plaintext_hex);
    const expected = v.ciphertext_hex + v.tag_hex;
    const ctAndTag = await aesGcmEncrypt(key, iv, pt, aad);
    assert.equal(hex(ctAndTag), expected, 'ciphertext||tag mismatch');
    const round = await aesGcmDecrypt(key, iv, ctAndTag, aad);
    assert.equal(hex(round), v.plaintext_hex, 'decrypt round-trip mismatch');
  });
}

test('aesGcmDecrypt fails closed on a tampered tag', async () => {
  const v = fixtures.aesGcm256.find((x) => x.plaintext_hex.length > 0);
  const key = hexToBytes(v.key_hex);
  const iv = hexToBytes(v.iv_hex);
  const aad = hexToBytes(v.aad_hex);
  const ctAndTag = concatBytes(hexToBytes(v.ciphertext_hex), hexToBytes(v.tag_hex));
  ctAndTag[ctAndTag.length - 1] ^= 0x01;
  await assert.rejects(() => aesGcmDecrypt(key, iv, ctAndTag, aad), CloudCryptoError);
});

test('aesGcmDecrypt fails closed on wrong AAD', async () => {
  const v = fixtures.aesGcm256.find((x) => x.aad_hex.length > 0);
  const key = hexToBytes(v.key_hex);
  const iv = hexToBytes(v.iv_hex);
  const ctAndTag = concatBytes(hexToBytes(v.ciphertext_hex), hexToBytes(v.tag_hex));
  await assert.rejects(
    () => aesGcmDecrypt(key, iv, ctAndTag, utf8Encode('wrong-aad')),
    CloudCryptoError,
  );
});

// ── ECDH P-256 ────────────────────────────────────────────────────────────────

for (const v of fixtures.ecdhP256) {
  test(`ecdhP256: ${v.name}`, () => {
    const shared = ecdhSharedX(
      hexToBytes(v.privateKey_hex),
      hexToBytes(v.peerPublicKey_hex),
    );
    assert.equal(shared.length, 32, 'shared X must be exactly 32 bytes');
    assert.equal(hex(shared), v.sharedX_hex);
  });
}

test('ecdhSharedX preserves a leading-zero X byte (left-padded, not trimmed)', () => {
  const v = fixtures.ecdhP256.find((x) => x.sharedX_hex.startsWith('00'));
  const shared = ecdhSharedX(hexToBytes(v.privateKey_hex), hexToBytes(v.peerPublicKey_hex));
  assert.equal(shared.length, 32);
  assert.equal(shared[0], 0x00);
});

test('p256KeyPairFromScalar rebuilds the device public key in the deviceWrap vector', () => {
  const v = fixtures.deviceWrap[0];
  const pair = p256KeyPairFromScalar(hexToBytes(v.devicePrivateKey_hex));
  assert.equal(hex(pair.publicKey), v.devicePublicKey_hex);
});

test('generateP256KeyPair produces a valid, self-consistent pair', () => {
  const pair = generateP256KeyPair();
  assert.equal(pair.privateKey.length, 32);
  assert.equal(pair.publicKey.length, 65);
  assert.equal(pair.publicKey[0], 0x04);
  // ECDH of two fresh pairs agrees both ways (basic sanity, not a KAT).
  const a = generateP256KeyPair();
  const b = generateP256KeyPair();
  assert.equal(
    hex(ecdhSharedX(a.privateKey, b.publicKey)),
    hex(ecdhSharedX(b.privateKey, a.publicKey)),
  );
});

// ── device-wrapped CK ─────────────────────────────────────────────────────────

for (const v of fixtures.deviceWrap) {
  test(`deviceWrap encode matches the fixture envelope byte-for-byte: ${v.name}`, async () => {
    const aad = deviceWrapAad(v.profileId, v.deviceUid, v.ckVersion);
    assert.equal(hex(aad), hex(utf8Encode(v.aad_utf8)), 'AAD reconstruction mismatch');
    const env = await encodeDeviceWrap({
      contentKey: hexToBytes(v.contentKey_hex),
      ckVersion: v.ckVersion,
      ephemeralPrivateKey: hexToBytes(v.ephemeralPrivateKey_hex),
      devicePublicKey: hexToBytes(v.devicePublicKey_hex),
      iv: hexToBytes(v.iv_hex),
      aad,
    });
    assert.deepEqual(env, v.envelope);
  });

  test(`deviceWrap decode recovers the content key: ${v.name}`, async () => {
    const aad = deviceWrapAad(v.profileId, v.deviceUid, v.ckVersion);
    const ck = await decodeDeviceWrap({
      envelope: v.envelope,
      devicePrivateKey: hexToBytes(v.devicePrivateKey_hex),
      ckVersion: v.ckVersion,
      aad,
    });
    assert.equal(hex(ck), v.contentKey_hex);
  });

  test(`deviceWrap decode fails closed on wrong ckv: ${v.name}`, async () => {
    const aad = deviceWrapAad(v.profileId, v.deviceUid, v.ckVersion);
    await assert.rejects(
      () =>
        decodeDeviceWrap({
          envelope: v.envelope,
          devicePrivateKey: hexToBytes(v.devicePrivateKey_hex),
          ckVersion: v.ckVersion + 1,
          aad,
        }),
      CloudCryptoError,
    );
  });

  test(`deviceWrap decode fails closed on wrong profile in AAD: ${v.name}`, async () => {
    const wrongAad = deviceWrapAad(
      '99999999-9999-4999-8999-999999999999',
      v.deviceUid,
      v.ckVersion,
    );
    await assert.rejects(
      () =>
        decodeDeviceWrap({
          envelope: v.envelope,
          devicePrivateKey: hexToBytes(v.devicePrivateKey_hex),
          ckVersion: v.ckVersion,
          aad: wrongAad,
        }),
      CloudCryptoError,
    );
  });
}

// ── secret envelope (format 1) ────────────────────────────────────────────────

for (const v of fixtures.secretEnvelope) {
  test(`secretEnvelope encode matches the fixture byte-for-byte: ${v.name}`, async () => {
    assert.equal(
      canonicalJson(v.secret),
      v.canonicalPlaintext,
      'canonical plaintext mismatch',
    );
    const aad = sourceSecretAad(v.profileId, v.sourceId, v.ckVersion);
    assert.equal(hex(aad), hex(utf8Encode(v.aad_utf8)), 'AAD reconstruction mismatch');
    const env = await encryptSecretEnvelope({
      secret: v.secret,
      contentKey: hexToBytes(v.contentKey_hex),
      ckVersion: v.ckVersion,
      aad,
      iv: hexToBytes(v.iv_hex),
    });
    assert.deepEqual(env, v.envelope);
  });

  test(`secretEnvelope decode recovers the secret (incl. non-ASCII): ${v.name}`, async () => {
    const aad = sourceSecretAad(v.profileId, v.sourceId, v.ckVersion);
    const secret = await decryptSecretEnvelope({
      envelope: v.envelope,
      contentKey: hexToBytes(v.contentKey_hex),
      ckVersion: v.ckVersion,
      aad,
    });
    assert.deepEqual(secret, v.secret);
  });

  test(`secretEnvelope fails closed on a tampered ct: ${v.name}`, async () => {
    const aad = sourceSecretAad(v.profileId, v.sourceId, v.ckVersion);
    const bad = { ...v.envelope };
    const ct = b64Decode(bad.ct);
    ct[0] ^= 0x01;
    bad.ct = b64Encode(ct);
    await assert.rejects(
      () =>
        decryptSecretEnvelope({
          envelope: bad,
          contentKey: hexToBytes(v.contentKey_hex),
          ckVersion: v.ckVersion,
          aad,
        }),
      CloudCryptoError,
    );
  });

  test(`secretEnvelope fails closed on wrong ckv: ${v.name}`, async () => {
    const aad = sourceSecretAad(v.profileId, v.sourceId, v.ckVersion);
    await assert.rejects(
      () =>
        decryptSecretEnvelope({
          envelope: v.envelope,
          contentKey: hexToBytes(v.contentKey_hex),
          ckVersion: v.ckVersion + 1,
          aad,
        }),
      CloudCryptoError,
    );
  });

  test(`secretEnvelope fails closed on unknown envelope version: ${v.name}`, async () => {
    const aad = sourceSecretAad(v.profileId, v.sourceId, v.ckVersion);
    await assert.rejects(
      () =>
        decryptSecretEnvelope({
          envelope: { ...v.envelope, v: 2 },
          contentKey: hexToBytes(v.contentKey_hex),
          ckVersion: v.ckVersion,
          aad,
        }),
      CloudCryptoError,
    );
  });

  test(`secretEnvelope fails closed on wrong source id in AAD: ${v.name}`, async () => {
    const wrongAad = sourceSecretAad(
      v.profileId,
      '99999999-9999-4999-8999-999999999999',
      v.ckVersion,
    );
    await assert.rejects(
      () =>
        decryptSecretEnvelope({
          envelope: v.envelope,
          contentKey: hexToBytes(v.contentKey_hex),
          ckVersion: v.ckVersion,
          aad: wrongAad,
        }),
      CloudCryptoError,
    );
  });
}

// ── CK-under-KEK ──────────────────────────────────────────────────────────────

for (const v of fixtures.ckUnderKek) {
  test(`ckUnderKek encode matches the fixture byte-for-byte: ${v.name}`, async () => {
    const aad = kekAad(v.profileId, v.ckVersion);
    assert.equal(hex(aad), hex(utf8Encode(v.aad_utf8)), 'AAD reconstruction mismatch');
    const env = await encodeCkUnderKek({
      contentKey: hexToBytes(v.contentKey_hex),
      ckVersion: v.ckVersion,
      passphrase: v.passphrase_utf8,
      salt: b64Decode(v.envelope.salt),
      iterations: v.envelope.iter,
      iv: b64Decode(v.envelope.iv),
      aad,
    });
    assert.deepEqual(env, v.envelope);
  });

  test(`ckUnderKek decode recovers the content key: ${v.name}`, async () => {
    const aad = kekAad(v.profileId, v.ckVersion);
    const ck = await decodeCkUnderKek({
      envelope: v.envelope,
      passphrase: v.passphrase_utf8,
      ckVersion: v.ckVersion,
      aad,
    });
    assert.equal(hex(ck), v.contentKey_hex);
  });

  test(`ckUnderKek decode fails closed on wrong passphrase: ${v.name}`, async () => {
    const aad = kekAad(v.profileId, v.ckVersion);
    await assert.rejects(
      () =>
        decodeCkUnderKek({
          envelope: v.envelope,
          passphrase: v.passphrase_utf8 + 'x',
          ckVersion: v.ckVersion,
          aad,
        }),
      CloudCryptoError,
    );
  });
}

// ── metadata AAD builder (no dedicated envelope vector; check the string) ──────

test('metadataSecretAad builds the documented context string', () => {
  const aad = metadataSecretAad('11111111-1111-4111-8111-111111111111', 3);
  assert.equal(
    new TextDecoder().decode(aad),
    'iptvs.secret.v1|metadata|11111111-1111-4111-8111-111111111111|3',
  );
});

// ── full local round-trips with fresh random material ─────────────────────────

test('secret envelope round-trips with a random CK and IV', async () => {
  const ck = randomBytes(32);
  const iv = randomBytes(12);
  const aad = sourceSecretAad('p', 's', 7);
  const secret = { username: 'alice', password: 'p@ss·wörd€' };
  const env = await encryptSecretEnvelope({ secret, contentKey: ck, ckVersion: 7, aad, iv });
  const back = await decryptSecretEnvelope({ envelope: env, contentKey: ck, ckVersion: 7, aad });
  assert.deepEqual(back, secret);
});

test('device wrap round-trips with a fresh device + ephemeral pair', async () => {
  const ck = randomBytes(32);
  const device = generateP256KeyPair();
  const eph = generateP256KeyPair();
  const iv = randomBytes(12);
  const aad = deviceWrapAad('prof', 'dev', 2);
  const env = await encodeDeviceWrap({
    contentKey: ck,
    ckVersion: 2,
    ephemeralPrivateKey: eph.privateKey,
    devicePublicKey: device.publicKey,
    iv,
    aad,
  });
  const back = await decodeDeviceWrap({
    envelope: env,
    devicePrivateKey: device.privateKey,
    ckVersion: 2,
    aad,
  });
  assert.equal(bytesToHex(back), bytesToHex(ck));
});
