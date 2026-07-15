import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  group('xtreamCredentialsFromUrl', () {
    test('uses an M3U expiry hint when player API omits exp_date', () async {
      final source = XtreamSource(
        sourceId: 'test',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        playlistExpiryHint: '2026-09-01T00:00:00.000',
        debugApi: (_) async => {'user_info': {'exp_date': '0'}},
      );
      expect(await source.subscriptionExpiry(), DateTime(2026, 9, 1));
      await source.dispose();
    });

    test('extracts creds from get.php query params', () {
      final c = xtreamCredentialsFromUrl(Uri.parse(
          'http://panel.example.com:8080/get.php?username=u1&password=p1&type=m3u_plus'));
      expect(c, isNotNull);
      expect(c!.host, 'http://panel.example.com:8080');
      expect(c.username, 'u1');
      expect(c.password, 'p1');
    });

    test('extracts creds from userInfo form', () {
      final c = xtreamCredentialsFromUrl(
          Uri.parse('http://u2:p2@host.tv/get.php'));
      expect(c, isNotNull);
      expect(c!.host, 'http://host.tv');
      expect(c.username, 'u2');
      expect(c.password, 'p2');
    });

    test('returns null without credentials', () {
      expect(xtreamCredentialsFromUrl(Uri.parse('http://host.tv/list.m3u')),
          isNull);
    });

    test('returns null for empty host', () {
      expect(xtreamCredentialsFromUrl(Uri.parse('?username=u&password=p')),
          isNull);
    });
  });
}
