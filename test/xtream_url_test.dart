import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  group('xtreamCredentialsFromUrl', () {
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
