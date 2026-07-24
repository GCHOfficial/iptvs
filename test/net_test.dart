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

  group('redactText', () {
    test('redacts credential path segments of a URL inside a message', () {
      const message =
          'PlayerError: failed to open '
          'http://panel.example.com:8080/live/someuser12345/s3cretp4ssw0rd/9001.ts '
          '(timed out)';
      final redacted = redactText(message);
      expect(redacted, isNot(contains('someuser12345')));
      expect(redacted, isNot(contains('s3cretp4ssw0rd')));
      expect(redacted, contains('panel.example.com:8080'));
      expect(redacted, contains('(timed out)'));
    });

    test('keeps short, non-token path segments readable', () {
      const message = 'HTTP 404 fetching http://host/movie/list.m3u8';
      expect(redactText(message), contains('/movie/list.m3u8'));
    });

    test('passes through plain text without URLs or slashes', () {
      expect(redactText('connection refused'), 'connection refused');
    });

    test('structurally redacts short creds after each keyword', () {
      // Short (< 12 char) user/pass that the length/token heuristic misses.
      for (final keyword in [
        'live',
        'movie',
        'movies',
        'series',
        'timeshift',
        'play',
      ]) {
        final message =
            'HTTP 403 fetching http://host:8080/$keyword/john/1234/99.ts';
        final redacted = redactText(message);
        expect(
          redacted,
          isNot(contains('john')),
          reason: 'user leaked after "$keyword"',
        );
        expect(
          redacted,
          isNot(contains('1234')),
          reason: 'pass leaked after "$keyword"',
        );
        // Keyword, host, and the stream id/filename stay intact.
        expect(redacted, contains('/$keyword/'));
        expect(redacted, contains('99.ts'));
        expect(redacted, contains('host:8080'));
      }
    });

    test('does not crash when a keyword is the final path segment', () {
      expect(
        redactText('HTTP 500 fetching http://host/live'),
        contains('/live'),
      );
    });

    test('does not over-redact a keyword with one following segment', () {
      // `/series/list.json` — the segment after the keyword is also the final
      // segment (the resource name), so it must stay readable.
      const message = 'HTTP 404 fetching http://host/series/list.json';
      final redacted = redactText(message);
      expect(redacted, contains('/series/list.json'));
      expect(redacted, isNot(contains('<redacted>')));
    });
  });
}
