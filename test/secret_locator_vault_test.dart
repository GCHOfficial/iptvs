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
}
