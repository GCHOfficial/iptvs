import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/secret_locator_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('decrypts ciphertext written by the pre-memoization key path', () async {
    // The vault builds its key with `AesGcm.newSecretKeyFromBytes` (round-key
    // memoization) instead of the bare `SecretKey(bytes)` constructor it used
    // to. Same key material, so anything already on disk must still open —
    // this pins that, using the old constructor to produce the ciphertext.
    final keyBytes = List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF);
    FlutterSecureStorage.setMockInitialValues({
      SecretLocatorVault.keyName: base64UrlEncode(keyBytes),
    });
    final legacyBox = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode({'url': 'https://example.invalid/live?t=old'})),
      secretKey: SecretKey(keyBytes),
    );

    final vault = SecretLocatorVault();
    expect(await vault.decrypt(base64UrlEncode(legacyBox.concatenation())), {
      'url': 'https://example.invalid/live?t=old',
    });
    expect(vault.generatedNewKey, isFalse);
  });

  test('round-trips locators while keeping ciphertext opaque', () async {
    final vault = SecretLocatorVault();
    final encrypted = await vault.encrypt({
      'url': 'https://user:password@example.invalid/live/token.ts',
      'cmd': 'ffmpeg https://example.invalid/private?token=secret',
    });

    expect(encrypted, isNot(contains('password')));
    expect(encrypted, isNot(contains('secret')));
    expect(await vault.decrypt(encrypted), {
      'url': 'https://user:password@example.invalid/live/token.ts',
      'cmd': 'ffmpeg https://example.invalid/private?token=secret',
    });
  });

  test(
    'protects only locator fields and leaves provider metadata readable',
    () async {
      final vault = SecretLocatorVault();
      final protectedExtra = await protectSecretLocators({
        'streamId': '42',
        'tvgId': 'news.1',
        'url': 'https://example.invalid/live?token=secret',
      }, vault);

      expect(protectedExtra['streamId'], '42');
      expect(protectedExtra['tvgId'], 'news.1');
      expect(protectedExtra, isNot(contains('url')));
      final restored = await restoreSecretLocators(protectedExtra, vault);
      expect(restored['url'], 'https://example.invalid/live?token=secret');
    },
  );

  test('hasSealedLocator distinguishes cached from plaintext models', () async {
    final vault = SecretLocatorVault();
    final sealed = await protectSecretLocators({
      'url': 'https://example.invalid/live?token=secret',
    }, vault);

    expect(hasSealedLocator(sealed), isTrue);
    // Plaintext straight off a provider, an item with no locator at all, and
    // an empty/absent blob all read as "nothing to reveal".
    expect(hasSealedLocator(const {'url': 'https://example.invalid/x'}), false);
    expect(hasSealedLocator(const {'tvgId': 'news.1'}), isFalse);
    expect(hasSealedLocator(const {}), isFalse);
    expect(hasSealedLocator(const {secretLocatorKey: ''}), isFalse);

    // Revealing something that was never sealed returns the same map, and the
    // vault never opens anything.
    const plain = {'url': 'https://example.invalid/x'};
    expect(vault.decryptCount, 0);
    expect(identical(await restoreSecretLocators(plain, vault), plain), isTrue);
    expect(vault.decryptCount, 0);

    expect(await restoreSecretLocators(sealed, vault), {
      'url': 'https://example.invalid/live?token=secret',
    });
    expect(vault.decryptCount, 1);
  });

  /// The bulk path must be row-for-row indistinguishable from calling
  /// [protectSecretLocators] on each entry — it is the only thing writing the
  /// cache now, and the on-disk blob format is unchanged.
  Future<void> bulkMatchesSingle(int rows, {required String why}) async {
    final vault = SecretLocatorVault();
    final extras = <Map<String, dynamic>>[];
    for (var i = 0; i < rows; i++) {
      switch (i % 4) {
        case 0:
          extras.add({'url': 'https://example.invalid/live/$i?t=s$i', 'n': i});
        case 1:
          // No locator at all (Xtream live): must come back untouched.
          extras.add({'streamId': '$i', 'tvgId': 'c$i'});
        case 2:
          // Already sealed: the existing ciphertext has to be carried over.
          extras.add(
            await protectSecretLocators({'cmd': '/media/$i.mpg'}, vault),
          );
        default:
          extras.add({'cmd': '/media/$i.mpg', 'url': 'http://x.invalid/$i'});
      }
    }
    final bulk = await protectSecretLocatorsBulk(extras, vault);
    expect(bulk, hasLength(rows), reason: why);
    for (var i = 0; i < rows; i++) {
      final one = await protectSecretLocators(extras[i], vault);
      // AES-GCM uses a random nonce, so the ciphertexts differ by design;
      // compare the non-locator half exactly and the sealed half by what it
      // opens to.
      expect(
        {...bulk[i]}..remove(secretLocatorKey),
        {...one}..remove(secretLocatorKey),
        reason: why,
      );
      expect(
        bulk[i].containsKey(secretLocatorKey),
        one.containsKey(secretLocatorKey),
        reason: why,
      );
      if (i % 4 == 2) {
        // Carried verbatim, not re-encrypted.
        expect(bulk[i][secretLocatorKey], extras[i][secretLocatorKey]);
      }
      if (bulk[i].containsKey(secretLocatorKey)) {
        expect(
          await restoreSecretLocators(bulk[i], vault),
          await restoreSecretLocators(one, vault),
          reason: why,
        );
      }
    }
  }

  test('bulk seal matches the single-row path below the inline threshold', () {
    return bulkMatchesSingle(
      kInlineLocatorSealRows - 1,
      why: 'inline (no isolate hop)',
    );
  });

  test('bulk seal matches the single-row path across isolate chunks', () {
    // Past the inline threshold, so this is the real `compute` path. (The
    // chunk size itself is exercised by the 2300-row catalog in
    // persistence_test.dart; spawning enough rows to cross
    // `kLocatorSealChunkRows` here would only re-test the same loop.)
    return bulkMatchesSingle(
      kInlineLocatorSealRows + 7,
      why: 'worker isolate',
    );
  });

  test('an empty list needs no key and no worker', () async {
    final vault = SecretLocatorVault();
    expect(await protectSecretLocatorsBulk(const [], vault), isEmpty);
    expect(vault.decryptCount, 0);
  });
}
