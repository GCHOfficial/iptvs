import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source_identity.dart';

void main() {
  group('parseM3uPlaylist', () {
    test('small and large playlists parse to the same shape '
        '(exercises both sides of the isolate-offload threshold)', () {
      String playlistOf(int channelCount) {
        final out = StringBuffer('#EXTM3U\n');
        for (var i = 0; i < channelCount; i++) {
          out
            ..writeln(
              '#EXTINF:-1 tvg-id="channel.$i" group-title="Group ${i % 5}",'
              'Channel $i',
            )
            ..writeln('http://server/live/$i.ts');
        }
        return out.toString();
      }

      // A handful of channels stays well under the 256 KB isolate
      // threshold; a few thousand pushes the same playlist shape past it.
      // Production only ever calls parseM3uPlaylist from the isolate
      // entrypoint or inline below the threshold — both paths run this
      // exact function, so parity here pins that the threshold only
      // decides *where* parsing runs, never *what* it produces.
      final small = playlistOf(5);
      final large = playlistOf(3000);
      expect(utf8.encode(small).length, lessThan(256 * 1024));
      expect(utf8.encode(large).length, greaterThan(256 * 1024));

      final parsedSmall = parseM3uPlaylist(small);
      final parsedLarge = parseM3uPlaylist(large);

      expect(parsedSmall.channels, hasLength(5));
      expect(parsedLarge.channels, hasLength(3000));
      for (final parsed in [parsedSmall, parsedLarge]) {
        final first = parsed.channels.first;
        expect(first.name, 'Channel 0');
        expect(first.categoryId, 'Group 0');
        expect(first.extra['tvgId'], 'channel.0');
        expect(first.extra['url'], 'http://server/live/0.ts');
      }
    });
    test(
      'duplicate tvg-ids yield distinct channels keyed by opaque locator IDs',
      () {
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
          {
            stableM3uChannelId('http://server/live/1.ts'),
            stableM3uChannelId('http://server/live/2.ts'),
          },
          reason: 'ids must be unique even when tvg-id repeats',
        );
        // Both variants keep the shared tvg-id for EPG mapping.
        for (final channel in parsed.channels) {
          expect(channel.extra['tvgId'], 'bbc1.uk');
          expect(channel.extra['url'], startsWith('http://server/live/'));
        }
        expect(parsed.headerEpgUrl, 'http://example.com/guide.xml');
      },
    );

    test('entry without tvg-id uses an opaque ID and omits tvgId', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1 group-title="News",Some Channel
http://server/live/3.ts
''';
      final parsed = parseM3uPlaylist(playlist);
      expect(
        parsed.channels.single.id,
        stableM3uChannelId('http://server/live/3.ts'),
      );
      expect(parsed.channels.single.extra.containsKey('tvgId'), isFalse);
      expect(parsed.channels.single.categoryId, 'News');
    });

    test('header catch-up applies to every channel', () {
      const playlist = '''
#EXTM3U catchup="append" catchup-days="3" catchup-source="https://archive.invalid/{start}/{end}"
#EXTINF:-1 group-title="News",One
http://stream.invalid/one
#EXTINF:-1 group-title="News",Two
http://stream.invalid/two
''';
      final parsed = parseM3uPlaylist(playlist);
      expect(parsed.channels, hasLength(2));
      expect(parsed.channels.map((c) => c.archiveDays), [3, 3]);
      expect(parsed.channels[1].extra['catchupSource'], contains('{start}'));
      expect(parsed.catchupCapability.supported, isTrue);
    });

    test('EXTINF catch-up overrides the header for one channel', () {
      const playlist = '''
#EXTM3U catchup-source="https://archive.invalid/default/{start}"
#EXTINF:-1 catchup="none",No archive
http://stream.invalid/one
#EXTINF:-1 catchup-days="5" catchup-source="https://archive.invalid/custom/{start}",Archive
http://stream.invalid/two
''';
      final parsed = parseM3uPlaylist(playlist);
      expect(parsed.channels[0].archiveDays, 0);
      expect(parsed.channels[1].archiveDays, 5);
      expect(
        parsed.channels[1].extra['catchupSource'],
        'https://archive.invalid/custom/{start}',
      );
    });
  });

  group('M3U identity normalization', () {
    test('equivalent locators produce the same channel ID', () {
      expect(
        stableM3uChannelId(' HTTP://Example.Invalid:80/a/../live/1.ts#now '),
        stableM3uChannelId('http://example.invalid/live/1.ts'),
      );
    });

    test(
      'distinct locators remain distinct across a representative corpus',
      () {
        final locators = <String>[
          for (var i = 0; i < 1000; i++)
            'https://stream.example.invalid/live/$i.ts?quality=${i % 4}',
        ];
        expect(
          locators.map(stableM3uChannelId).toSet(),
          hasLength(locators.length),
        );
      },
    );

    test('opaque IDs never contain locator credentials', () {
      final id = stableM3uChannelId(
        'https://user:password@example.invalid/live/secret.ts?token=value',
      );
      expect(isStableM3uChannelId(id), isTrue);
      expect(id, isNot(contains('user')));
      expect(id, isNot(contains('password')));
      expect(id, isNot(contains('token')));
    });
  });

  group('M3uSource.subscriptionExpiry', () {
    test('reads an expiry param embedded in the playlist URL', () async {
      final source = M3uSource(
        sourceId: 'm3u-test',
        playlistUrl: 'http://host/get.php?username=u&password=p&exp=2026-09-01',
      );
      expect(await source.subscriptionExpiry(), DateTime(2026, 9, 1));
    });

    test(
      'returns null when the playlist URL carries no expiry param',
      () async {
        final source = M3uSource(
          sourceId: 'm3u-test',
          playlistUrl: 'http://host/get.php?username=u&password=p',
        );
        expect(await source.subscriptionExpiry(), isNull);
      },
    );
  });
}
