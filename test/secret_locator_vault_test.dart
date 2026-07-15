import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/secret_locator_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

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
}
