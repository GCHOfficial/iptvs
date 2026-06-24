// Tests for the shared networking helpers — credential redaction in
// particular, since redacted URLs surface in on-screen errors and exported
// diagnostics.

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/net.dart';

void main() {
  group('redactUrl', () {
    test('removes Xtream username/password query params', () {
      const url =
          'http://panel.example.com:8080/player_api.php'
          '?username=alice&password=s3cret&action=get_live_streams';
      final out = redactUrl(url);
      expect(out, 'http://panel.example.com:8080/player_api.php?<redacted>');
      expect(out, isNot(contains('alice')));
      expect(out, isNot(contains('s3cret')));
    });

    test('drops userinfo credentials embedded in the authority', () {
      const url = 'http://bob:hunter2@host.example.com/playlist.m3u';
      final out = redactUrl(url);
      expect(out, 'http://host.example.com/playlist.m3u');
      expect(out, isNot(contains('bob')));
      expect(out, isNot(contains('hunter2')));
    });

    test('keeps host and path for a credential-free URL', () {
      const url = 'https://api.themoviedb.org/3/movie/550';
      expect(redactUrl(url), url);
    });

    test('accepts a Uri as well as a String', () {
      final uri = Uri.parse('http://h/get.php?username=u&password=p');
      expect(redactUrl(uri), 'http://h/get.php?<redacted>');
    });

    test('falls back to stripping the query for non-URL input', () {
      expect(redactUrl('not a url?username=u'), 'not a url');
    });
  });
}
