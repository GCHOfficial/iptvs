import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show BrowserCryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_crypto.dart';

Uint8List _unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Force the pure-Dart path even if a test host had Web Crypto (it doesn't on
  // the VM, but this keeps the KATs pinned to the shipped implementation).
  BrowserCryptography.isDisabledForTesting = true;

  final fixture =
      jsonDecode(
            File('test/fixtures/crypto_vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  List<Map<String, dynamic>> vectors(String key) => [
    for (final e in fixture[key] as List) Map<String, dynamic>.from(e as Map),
  ];

  test('canonical JSON: keys sorted ascending, no whitespace, UTF-8 non-ASCII', () {
    for (final v in vectors('canonicalJson')) {
      final input = (v['input'] as Map).map(
        (k, val) => MapEntry(k.toString(), val.toString()),
      );
      expect(canonicalJson(input), v['expected']);
    }
    // Explicit shape check.
    expect(
      canonicalJson({'b': '2', 'a': '1'}),
      '{"a":"1","b":"2"}',
    );
  });

  test('PBKDF2-HMAC-SHA256 matches published + self vectors', () async {
    for (final v in vectors('pbkdf2HmacSha256')) {
      final password = v.containsKey('password_utf8')
          ? utf8.encode(v['password_utf8'] as String)
          : _unhex(v['password_hex'] as String);
      final salt = v.containsKey('salt_utf8')
          ? utf8.encode(v['salt_utf8'] as String)
          : _unhex(v['salt_hex'] as String);
      final got = await pbkdf2Sha256(
        password,
        salt,
        v['iterations'] as int,
        v['dkLen'] as int,
      );
      expect(_hex(got), v['expected_hex'], reason: v['name'] as String);
    }
  });

  test('HKDF-SHA256 matches RFC 5869 cases 1–3', () async {
    for (final v in vectors('hkdfSha256')) {
      final got = await hkdfSha256(
        _unhex(v['ikm_hex'] as String),
        _unhex(v['salt_hex'] as String),
        _unhex(v['info_hex'] as String),
        v['length'] as int,
      );
      expect(_hex(got), v['okm_hex'], reason: v['name'] as String);
    }
  });

  test('AES-256-GCM matches NIST + self vectors (and decrypts back)', () async {
    for (final v in vectors('aesGcm256')) {
      final key = _unhex(v['key_hex'] as String);
      final iv = _unhex(v['iv_hex'] as String);
      final aad = _unhex(v['aad_hex'] as String);
      final pt = _unhex(v['plaintext_hex'] as String);
      final ctAndTag = await aesGcmEncrypt(key, iv, pt, aad);
      final ct = ctAndTag.sublist(0, ctAndTag.length - 16);
      final tag = ctAndTag.sublist(ctAndTag.length - 16);
      expect(_hex(ct), v['ciphertext_hex'], reason: v['name'] as String);
      expect(_hex(tag), v['tag_hex'], reason: v['name'] as String);
      final back = await aesGcmDecrypt(key, iv, ctAndTag, aad);
      expect(_hex(back), _hex(pt), reason: v['name'] as String);
    }
  });

  test('AES-256-GCM fails closed on a tampered tag', () async {
    final key = _unhex(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    );
    final iv = _unhex('101112131415161718191a1b');
    final ct = await aesGcmEncrypt(key, iv, utf8.encode('secret'), const []);
    ct[ct.length - 1] ^= 0x01;
    await expectLater(
      aesGcmDecrypt(key, iv, ct, const []),
      throwsA(isA<CloudCryptoException>()),
    );
  });

  group('ECDH P-256', () {
    test('matches published + leading-zero vectors, X is exactly 32 bytes', () {
      for (final v in vectors('ecdhP256')) {
        final got = ecdhSharedX(
          _unhex(v['privateKey_hex'] as String),
          _unhex(v['peerPublicKey_hex'] as String),
        );
        expect(got.length, 32, reason: v['name'] as String);
        expect(_hex(got), v['sharedX_hex'], reason: v['name'] as String);
      }
    });

    test('leading-zero shared X keeps its 0x00 first byte', () {
      final v = vectors('ecdhP256').firstWhere(
        (e) => e['name'] == 'leading-zero-shared-x',
      );
      final got = ecdhSharedX(
        _unhex(v['privateKey_hex'] as String),
        _unhex(v['peerPublicKey_hex'] as String),
      );
      expect(got[0], 0x00);
      expect(got.length, 32);
    });

    test('rejects an off-curve / malformed peer public key', () {
      // 0x04 prefix but (1,1) is not on P-256.
      final bad = Uint8List(65)..[0] = 0x04;
      bad[32] = 0x01;
      bad[64] = 0x01;
      expect(
        () => ecdhSharedX(_unhex('01' * 32), bad),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    // The shared `ecdhP256Invalid` fixture group, looped here so BOTH
    // implementations assert the same rejections. Peer public-key validation is
    // the control that prevents an invalid-curve attack — a malicious server
    // handing over a crafted `epk` could otherwise recover this device's
    // long-lived private scalar — and P-256's cofactor of 1 means an accepted
    // on-curve point is necessarily in the prime-order subgroup, so this check
    // is the whole defence. It works today; the point of looping the fixture is
    // that a refactor cannot silently drop a case on one side only.
    for (final v in vectors('ecdhP256Invalid')) {
      test('rejects invalid peer public key: ${v['name']}', () {
        expect(
          () => ecdhSharedX(
            _unhex(v['privateKey_hex'] as String),
            _unhex(v['peerPublicKey_hex'] as String),
          ),
          throwsA(isA<CloudCryptoException>()),
          reason: v['note'] as String?,
        );
      });
    }

    test('key pair round-trips scalar → public → shared symmetry', () {
      final a = generateP256KeyPair();
      final b = generateP256KeyPair();
      expect(a.publicKey.length, 65);
      expect(a.publicKey[0], 0x04);
      final ab = ecdhSharedX(a.privateKey, b.publicKey);
      final ba = ecdhSharedX(b.privateKey, a.publicKey);
      expect(_hex(ab), _hex(ba));
    });
  });

  group('device-wrapped CK', () {
    Map<String, dynamic> vec() => vectors('deviceWrap').first;

    test('fixture envelope decodes to the content key', () async {
      final v = vec();
      final ck = await decodeDeviceWrap(
        envelope: Map<String, dynamic>.from(v['envelope'] as Map),
        devicePrivateKey: _unhex(v['devicePrivateKey_hex'] as String),
        ckVersion: v['ckVersion'] as int,
        aad: deviceWrapAad(
          v['profileId'] as String,
          v['deviceUid'] as String,
          v['ckVersion'] as int,
        ),
      );
      expect(_hex(ck), v['contentKey_hex']);
    });

    test('wrong device private key fails closed', () async {
      final v = vec();
      final wrong = generateP256KeyPair();
      await expectLater(
        decodeDeviceWrap(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          devicePrivateKey: wrong.privateKey,
          ckVersion: v['ckVersion'] as int,
          aad: deviceWrapAad(
            v['profileId'] as String,
            v['deviceUid'] as String,
            v['ckVersion'] as int,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('wrong profile in the AAD fails closed', () async {
      final v = vec();
      await expectLater(
        decodeDeviceWrap(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          devicePrivateKey: _unhex(v['devicePrivateKey_hex'] as String),
          ckVersion: v['ckVersion'] as int,
          aad: deviceWrapAad(
            'ffffffff-ffff-4fff-8fff-ffffffffffff',
            v['deviceUid'] as String,
            v['ckVersion'] as int,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('ckv mismatch fails closed before decrypt', () async {
      final v = vec();
      await expectLater(
        decodeDeviceWrap(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          devicePrivateKey: _unhex(v['devicePrivateKey_hex'] as String),
          ckVersion: (v['ckVersion'] as int) + 1,
          aad: deviceWrapAad(
            v['profileId'] as String,
            v['deviceUid'] as String,
            (v['ckVersion'] as int) + 1,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('unknown kdf fails closed', () async {
      final v = vec();
      final env = Map<String, dynamic>.from(v['envelope'] as Map)
        ..['kdf'] = 'bogus';
      await expectLater(
        decodeDeviceWrap(
          envelope: env,
          devicePrivateKey: _unhex(v['devicePrivateKey_hex'] as String),
          ckVersion: v['ckVersion'] as int,
          aad: deviceWrapAad(
            v['profileId'] as String,
            v['deviceUid'] as String,
            v['ckVersion'] as int,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });
  });

  group('secret envelope (format 1)', () {
    Map<String, dynamic> vec() => vectors('secretEnvelope').first;

    test('fixture envelope decrypts to the non-ASCII secret', () async {
      final v = vec();
      final map = await decryptSecretEnvelope(
        envelope: Map<String, dynamic>.from(v['envelope'] as Map),
        contentKey: _unhex(v['contentKey_hex'] as String),
        ckVersion: v['ckVersion'] as int,
        aad: sourceSecretAad(
          v['profileId'] as String,
          v['sourceId'] as String,
          v['ckVersion'] as int,
        ),
      );
      final expected = (v['secret'] as Map).map(
        (k, val) => MapEntry(k.toString(), val.toString()),
      );
      expect(map, expected);
      expect(map['password'], 'pässword→€');
    });

    test('canonical plaintext matches the fixture', () {
      final v = vec();
      final secret = (v['secret'] as Map).map(
        (k, val) => MapEntry(k.toString(), val.toString()),
      );
      expect(canonicalJson(secret), v['canonicalPlaintext']);
    });

    test('round-trips a fresh encrypt/decrypt', () async {
      final ck = _unhex('11' * 32);
      final aad = sourceSecretAad('p', 's', 7);
      final env = await encryptSecretEnvelope(
        secret: {'a': '1', 'b': 'x'},
        contentKey: ck,
        ckVersion: 7,
        aad: aad,
        iv: _unhex('0102030405060708090a0b0c'),
      );
      final back = await decryptSecretEnvelope(
        envelope: env,
        contentKey: ck,
        ckVersion: 7,
        aad: aad,
      );
      expect(back, {'a': '1', 'b': 'x'});
    });

    test('wrong CK fails closed', () async {
      final v = vec();
      await expectLater(
        decryptSecretEnvelope(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          contentKey: _unhex('22' * 32),
          ckVersion: v['ckVersion'] as int,
          aad: sourceSecretAad(
            v['profileId'] as String,
            v['sourceId'] as String,
            v['ckVersion'] as int,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('wrong AAD (different source) fails closed', () async {
      final v = vec();
      await expectLater(
        decryptSecretEnvelope(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          contentKey: _unhex(v['contentKey_hex'] as String),
          ckVersion: v['ckVersion'] as int,
          aad: sourceSecretAad(
            v['profileId'] as String,
            'a-different-source-id',
            v['ckVersion'] as int,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('tampered ciphertext fails closed', () async {
      final v = vec();
      final env = Map<String, dynamic>.from(v['envelope'] as Map);
      final ct = b64Decode(env['ct'] as String);
      ct[ct.length - 1] ^= 0x80;
      env['ct'] = b64Encode(ct);
      await expectLater(
        decryptSecretEnvelope(
          envelope: env,
          contentKey: _unhex(v['contentKey_hex'] as String),
          ckVersion: v['ckVersion'] as int,
          aad: sourceSecretAad(
            v['profileId'] as String,
            v['sourceId'] as String,
            v['ckVersion'] as int,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('unknown version / alg fails closed', () async {
      final v = vec();
      final ck = _unhex(v['contentKey_hex'] as String);
      final aad = sourceSecretAad(
        v['profileId'] as String,
        v['sourceId'] as String,
        v['ckVersion'] as int,
      );
      final badVersion = Map<String, dynamic>.from(v['envelope'] as Map)
        ..['v'] = 2;
      final badAlg = Map<String, dynamic>.from(v['envelope'] as Map)
        ..['alg'] = 'A128GCM';
      await expectLater(
        decryptSecretEnvelope(
          envelope: badVersion,
          contentKey: ck,
          ckVersion: v['ckVersion'] as int,
          aad: aad,
        ),
        throwsA(isA<CloudCryptoException>()),
      );
      await expectLater(
        decryptSecretEnvelope(
          envelope: badAlg,
          contentKey: ck,
          ckVersion: v['ckVersion'] as int,
          aad: aad,
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });

    test('ckv mismatch fails closed', () async {
      final v = vec();
      await expectLater(
        decryptSecretEnvelope(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          contentKey: _unhex(v['contentKey_hex'] as String),
          ckVersion: (v['ckVersion'] as int) + 1,
          aad: sourceSecretAad(
            v['profileId'] as String,
            v['sourceId'] as String,
            (v['ckVersion'] as int) + 1,
          ),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });
  });

  group('CK-under-KEK', () {
    test('fixture envelope decodes with the passphrase', () async {
      final v = vectors('ckUnderKek').first;
      final ck = await decodeCkUnderKek(
        envelope: Map<String, dynamic>.from(v['envelope'] as Map),
        passphrase: v['passphrase_utf8'] as String,
        ckVersion: v['ckVersion'] as int,
        aad: kekAad(v['profileId'] as String, v['ckVersion'] as int),
      );
      expect(_hex(ck), v['contentKey_hex']);
    });

    test('wrong passphrase fails closed', () async {
      final v = vectors('ckUnderKek').first;
      await expectLater(
        decodeCkUnderKek(
          envelope: Map<String, dynamic>.from(v['envelope'] as Map),
          passphrase: 'not the passphrase',
          ckVersion: v['ckVersion'] as int,
          aad: kekAad(v['profileId'] as String, v['ckVersion'] as int),
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });
  });
}
