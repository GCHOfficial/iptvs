import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/m3u_source.dart';

void main() {
  group('parseM3uPlaylist', () {
    test('duplicate tvg-ids yield distinct channels keyed by URL', () {
      const playlist = '''
#EXTM3U url-tvg="http://example.com/guide.xml"
#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://logo/hd.png" group-title="UK",BBC One HD
http://server/live/1.ts
#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://logo/fhd.png" group-title="UK",BBC One FHD
http://server/live/2.ts
''';
      final parsed = parseM3uPlaylist(playlist);

      expect(parsed.channels, hasLength(2));
      expect(
        parsed.channels.map((c) => c.id).toSet(),
        {'http://server/live/1.ts', 'http://server/live/2.ts'},
        reason: 'ids must be unique even when tvg-id repeats',
      );
      // Both variants keep the shared tvg-id for EPG mapping.
      for (final channel in parsed.channels) {
        expect(channel.extra['tvgId'], 'bbc1.uk');
        expect(channel.extra['url'], channel.id);
      }
      expect(parsed.headerEpgUrl, 'http://example.com/guide.xml');
    });

    test('entry without tvg-id still keys by URL and omits tvgId', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1 group-title="News",Some Channel
http://server/live/3.ts
''';
      final parsed = parseM3uPlaylist(playlist);
      expect(parsed.channels.single.id, 'http://server/live/3.ts');
      expect(parsed.channels.single.extra.containsKey('tvgId'), isFalse);
      expect(parsed.channels.single.categoryId, 'News');
    });
  });

  group('M3uSource.subscriptionExpiry', () {
    test('reads an expiry param embedded in the playlist URL', () async {
      final source = M3uSource(
        playlistUrl: 'http://host/get.php?username=u&password=p&exp=2026-09-01',
      );
      expect(await source.subscriptionExpiry(), DateTime(2026, 9, 1));
    });

    test('returns null when the playlist URL carries no expiry param', () async {
      final source = M3uSource(
        playlistUrl: 'http://host/get.php?username=u&password=p',
      );
      expect(await source.subscriptionExpiry(), isNull);
    });
  });
}
