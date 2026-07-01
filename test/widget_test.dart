// Unit tests for the IPTV app's pure logic.
//
// (Replaces the default counter widget test from `flutter create`, which
// referenced the old app and no longer applies.)

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/source_hint_parser.dart';
import 'package:iptvs/data/tmdb_client.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';
import 'package:iptvs/sources/xtream_source.dart';
import 'package:iptvs/sources/xmltv.dart';

void main() {
  group('DemoSource', () {
    test('exposes its built-in channels and categories', () async {
      final source = DemoSource();

      expect(await source.categories(), isNotEmpty);

      final channels = await source.channels();
      expect(channels.length, 4);

      final stream = await source.resolve(channels.first);
      expect(stream.url, startsWith('http'));

      // The demo source has no EPG.
      expect(await source.epg(channels), isEmpty);
    });
  });

  group('parseXmltvTime', () {
    test('parses a UTC timestamp', () {
      final t = parseXmltvTime('20240101120000 +0000');
      expect(t, isNotNull);
      expect(t!.isAtSameMomentAs(DateTime.utc(2024, 1, 1, 12)), isTrue);
    });

    test('applies the timezone offset', () {
      // 12:00 at +0100 is 11:00 UTC.
      final t = parseXmltvTime('20240101120000 +0100');
      expect(t!.isAtSameMomentAs(DateTime.utc(2024, 1, 1, 11)), isTrue);
    });

    test('treats a missing offset as UTC', () {
      final t = parseXmltvTime('20240101120000');
      expect(t!.isAtSameMomentAs(DateTime.utc(2024, 1, 1, 12)), isTrue);
    });

    test('returns null for malformed input', () {
      expect(parseXmltvTime(null), isNull);
      expect(parseXmltvTime('nope'), isNull);
    });
  });

  group('parseXmltv', () {
    Uint8List xmltv(String programmes) => Uint8List.fromList(
          utf8.encode('<?xml version="1.0"?><tv>$programmes</tv>'),
        );

    String programme(String channel, {String title = 'Show'}) =>
        '<programme channel="$channel" start="20240101120000 +0000" '
        'stop="20240101130000 +0000"><title>$title</title>'
        '<desc>Desc</desc></programme>';

    test('maps tvg-ids to channel ids and drops unmapped programmes', () async {
      final bytes = xmltv(
        programme('tvg.one', title: 'One') +
            programme('tvg.unknown', title: 'Nope') +
            programme('tvg.two', title: 'Two'),
      );
      final progs = await parseXmltv(bytes, {
        'tvg.one': 'ch1',
        'tvg.two': 'ch2',
      });

      expect(progs.map((p) => p.channelId), ['ch1', 'ch2']);
      expect(progs.first.title, 'One');
      expect(progs.first.description, 'Desc');
      expect(
        progs.first.start.isAtSameMomentAs(DateTime.utc(2024, 1, 1, 12)),
        isTrue,
      );
    });

    test('parses a large guide through the background isolate', () async {
      // Exceed the inline threshold so the compute() path runs; assert the
      // record + List<Programme> round-trip across the isolate boundary and the
      // mapping/filtering matches the inline path.
      final many = StringBuffer();
      for (var i = 0; i < 1500; i++) {
        many.write(programme(i.isEven ? 'tvg.one' : 'tvg.skip', title: 'P$i'));
      }
      final bytes = xmltv(many.toString());
      expect(bytes.length, greaterThan(64 * 1024));

      final progs = await parseXmltv(bytes, {'tvg.one': 'ch1'});

      expect(progs, hasLength(750)); // even indices only
      expect(progs.every((p) => p.channelId == 'ch1'), isTrue);
      expect(progs.first.title, 'P0');
    });
  });

  group('MagIdentity', () {
    test('derives MAG identity fields from uppercase MAC', () {
      final identity = MagIdentity.fromMac('00:1a:79:12:34:56');

      expect(identity.mac, '00:1A:79:12:34:56');
      expect(identity.serial, '2213785DC6113');
      expect(
        identity.deviceId,
        '667094E7E8FF0347F6EC27A8E8115BE76E2AA9CD5C8F13C6FA00BCEDFAC02B41',
      );
      expect(identity.deviceId2, identity.deviceId);
      expect(
        identity.signature,
        '922F69DECA50A1E4883CDB6AF9A57D86B2C82BE460AE9AFCAF2B421C715A0D1B',
      );
      expect(identity.hwVersion2, 'A7B48B071A49ED4FE8EEF23EDE037A0BBC6C29D4');
    });

    test('builds strict get_profile params', () {
      final params = MagIdentity.fromMac(
        '00:1A:79:12:34:56',
      ).profileParams(profile: MagProfile.mag250, timestamp: 123456);

      expect(params['stb_type'], 'MAG250');
      expect(params['sn'], '2213785DC6113');
      expect(params['client_type'], 'STB');
      expect(params['auth_second_step'], '1');
      expect(params['not_valid_token'], '0');
      expect(params['device_id'], isNotEmpty);
      expect(params['device_id2'], params['device_id']);
      expect(params['signature'], isNotEmpty);
      expect(params['hw_version_2'], isNotEmpty);
      expect(params['metrics'], contains('"mac":"00:1A:79:12:34:56"'));
      expect(params['metrics'], contains('"model":"MAG250"'));
      expect(params['metrics'], contains('"random":"123456"'));
    });
  });

  group('stalkerItemIdentity', () {
    test('uses the first known stable id field', () {
      expect(stalkerItemIdentity({'id': 12}), 'id:12');
      expect(stalkerItemIdentity({'movie_id': 'm7'}), 'movie_id:m7');
      expect(stalkerItemIdentity({'video_id': 'v3'}), 'video_id:v3');
      expect(stalkerItemIdentity({'channel_id': 'c9'}), 'channel_id:c9');
      expect(stalkerItemIdentity({'ch_id': 'legacy'}), 'ch_id:legacy');
    });

    test('ignores missing and empty ids', () {
      expect(stalkerItemIdentity({'id': '', 'movie_id': 'm7'}), 'movie_id:m7');
      expect(stalkerItemIdentity({'name': 'No id'}), isNull);
    });
  });

  group('redactStalkerDiagnostic', () {
    test('removes common Stalker secrets', () {
      final redacted = redactStalkerDiagnostic(
        'mac=00:1A:79:12:34:56 token=abc123 Authorization: Bearer secret-token',
      );

      expect(redacted, isNot(contains('00:1A:79:12:34:56')));
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, isNot(contains('secret-token')));
      expect(redacted, contains('mac=<redacted>'));
      expect(redacted, contains('Bearer <redacted>'));
    });
  });

  group('Stalker series detail fallback', () {
    final source = StalkerSource(
      portal: 'http://example.invalid/c/',
      mac: '00:1A:79:12:34:56',
    );
    const series = MediaItem(
      id: 'series-1',
      title: 'Example Series',
      kind: ContentKind.series,
      poster: 'poster.jpg',
      extra: {'movieId': 'series-1'},
    );

    test('builds seasons from grouped episodes', () {
      final seasons = source.debugSeasonsFromDetails(series, {
        'episodes': {
          '1': [
            {'id': 'e1', 'title': 'Pilot', 'episode': '1'},
          ],
          '2': [
            {'id': 'e2', 'title': 'Second', 'episode': '1'},
          ],
        },
      });

      expect(seasons.map((s) => s.title), ['Season 1', 'Season 2']);
      expect(seasons.first.extra['episodes'], isA<List>());
    });

    test('builds episodes from season payload', () {
      final season = source.debugSeasonsFromDetails(series, {
        'episodes': {
          '1': [
            {
              'id': 'e1',
              'title': 'Pilot',
              'episode': '1',
              'duration': '00:42:05',
            },
          ],
        },
      }).first;

      final episodes = source.debugEpisodesFromDetails(season, const {});

      expect(episodes, hasLength(1));
      expect(episodes.first.id, 'e1');
      expect(episodes.first.title, 'Pilot');
      expect(episodes.first.seasonNumber, 1);
      expect(episodes.first.episodeNumber, 1);
      expect(episodes.first.durationSeconds, 2525);
    });

    test('builds episodes from embedded Stalker season numbers', () {
      const season = MediaItem(
        id: '4977:season:22',
        title: 'Season 22',
        kind: ContentKind.season,
        parentId: '4977',
        seasonNumber: 22,
        extra: {
          'movieId': '4977',
          'seasonId': '22',
          'series': [1, 2],
        },
      );

      final episodes = source.debugEpisodesFromEmbeddedSeason(season);

      expect(episodes.map((e) => e.id), ['4977:1', '4977:2']);
      expect(episodes.first.title, 'Episode 1');
      expect(episodes.first.seasonNumber, 22);
      expect(episodes.first.episodeNumber, 1);
    });

    test('recognizes Stalker series without is_series flag', () {
      expect(
        source.debugMatchesVodListKind(
          {'id': 'show-1', 'name': 'Example Show'},
          ContentKind.series,
          categoryTitle: 'TV Shows',
        ),
        isTrue,
      );
      expect(
        source.debugMatchesVodListKind(
          {'id': 'movie-1', 'name': 'Example Movie', 'is_series': '0'},
          ContentKind.series,
          categoryTitle: 'TV Shows',
        ),
        isFalse,
      );
      expect(
        source.debugMatchesVodListKind({
          'id': 'show-2',
          'name': 'Example Show',
          'series_id': 'show-2',
        }, ContentKind.series),
        isTrue,
      );
    });

    test('does not treat season placeholder rows as episodes', () {
      expect(
        source.debugMatchesSeriesListKind({
          'id': '.',
          'name': 'Season 1',
          'cmd': '/play/movie.php?stream=.&type=series',
        }, ContentKind.episode),
        isFalse,
      );
      expect(
        source.debugMatchesSeriesListKind({
          'episode_id': 'ep-1',
          'name': 'Pilot',
        }, ContentKind.episode),
        isTrue,
      );
      expect(
        source.debugMatchesSeriesListKind({
          'id': '22769:4:1',
          'name': 'Episode 1',
        }, ContentKind.episode),
        isTrue,
      );
    });

    test('maps series seasons with stable season ids', () {
      final season = source.debugMapMediaItem(
        {'id': '.', 'name': 'Season 1'},
        ContentKind.season,
        parent: series,
        stalkerType: 'series',
      );

      expect(season.id, 'series-1:season:1');
      expect(season.seasonNumber, 1);
      expect(season.extra['seasonId'], '1');
    });

    test('splits Stalker composite season ids into series and season ids', () {
      final season = source.debugMapMediaItem(
        {'id': '22769:4', 'name': 'Season 4'},
        ContentKind.season,
        parent: const MediaItem(
          id: '22769',
          title: 'Composite Series',
          kind: ContentKind.series,
          extra: {'movieId': '22769'},
        ),
        stalkerType: 'series',
      );

      expect(season.id, '22769:season:4');
      expect(season.extra['movieId'], '22769');
      expect(season.extra['seasonId'], '4');
    });

    test('prefers episode row id over carried series id for playback', () {
      const episode = MediaItem(
        id: '22769:1',
        title: 'Episode 1',
        kind: ContentKind.episode,
        extra: {'id': '22769:1', 'movieId': '22769'},
      );

      expect(source.debugVodCommand(episode), '/media/file_22769:1.mpg');
    });

    test('keeps series season cmd for episode create_link params', () {
      const episode = MediaItem(
        id: '4977:1',
        title: 'Episode 1',
        kind: ContentKind.episode,
        episodeNumber: 1,
        extra: {
          'id': '4977:1',
          'movieId': '4977',
          'episode_number': '1',
          'cmd': '/play/movie.php?stream=.&type=series',
        },
      );

      expect(
        source.debugVodCommand(episode),
        '/play/movie.php?stream=.&type=series',
      );
    });
  });

  group('Xtream series mapping', () {
    final source = XtreamSource(
      host: 'http://example.invalid',
      username: 'user',
      password: 'pass',
    );

    test('uses alternate series id fields from provider payloads', () {
      final fromId = source.debugMapMediaItem({
        'id': 'series-1',
        'name': 'Example Series',
      }, ContentKind.series);
      final fromStreamId = source.debugMapMediaItem({
        'stream_id': 'series-2',
        'title': 'Alternate Series',
      }, ContentKind.series);

      expect(fromId.id, 'series-1');
      expect(fromId.title, 'Example Series');
      expect(fromStreamId.id, 'series-2');
      expect(fromStreamId.title, 'Alternate Series');
    });

    test('adds a VOD user agent for direct movie playback', () async {
      const movie = MediaItem(
        id: 'movie-1',
        title: 'Example Movie',
        kind: ContentKind.movie,
        extra: {'container_extension': 'mkv'},
      );

      final stream = await source.resolveMedia(movie);

      expect(stream.url, endsWith('/movie/user/pass/movie-1.mkv'));
      expect(stream.headers['user-agent'], contains('VLC'));
    });

    test('returns bounded category pages for large VOD lists', () async {
      final source = XtreamSource(
        host: 'http://example.invalid',
        username: 'user',
        password: 'pass',
        debugApi: (params) async {
          expect(params['action'], 'get_vod_streams');
          expect(params['category_id'], 'cat-a');
          return List.generate(
            75,
            (i) => {
              'stream_id': 'movie-$i',
              'name': 'Movie $i',
              'category_id': 'cat-a',
            },
          );
        },
      );

      final first = await source.mediaItemsPage(
        ContentKind.movie,
        categoryId: 'cat-a',
      );
      final second = await source.mediaItemsPage(
        ContentKind.movie,
        categoryId: 'cat-a',
        page: 2,
      );

      expect(first.items.length, 14);
      expect(first.totalPages, 6);
      expect(second.items.length, 14);
      expect(second.totalPages, 6);
    });

    test(
      'builds all-category pages without calling the unfiltered VOD list',
      () async {
        var unfilteredVodCalls = 0;
        final source = XtreamSource(
          host: 'http://example.invalid',
          username: 'user',
          password: 'pass',
          debugApi: (params) async {
            if (params['action'] == 'get_vod_categories') {
              return [
                {'category_id': 'cat-a', 'category_name': 'A'},
                {'category_id': 'cat-b', 'category_name': 'B'},
              ];
            }
            if (params['action'] == 'get_vod_streams') {
              final categoryId = params['category_id'];
              if (categoryId == null) unfilteredVodCalls++;
              return List.generate(
                categoryId == 'cat-a' ? 75 : 10,
                (i) => {
                  'stream_id': '$categoryId-movie-$i',
                  'name': 'Movie $i',
                  'category_id': categoryId,
                },
              );
            }
            return const [];
          },
        );

        final page = await source.mediaItemsPage(ContentKind.movie);

        expect(page.items.length, 14);
        expect(page.items.first.categoryId, 'cat-a');
        expect(unfilteredVodCalls, 0);
      },
    );

    test(
      'searches Xtream categories without fetching the unfiltered catalog',
      () async {
        var unfilteredVodCalls = 0;
        final source = XtreamSource(
          host: 'http://example.invalid',
          username: 'user',
          password: 'pass',
          debugApi: (params) async {
            if (params['action'] == 'get_vod_categories') {
              return [
                {'category_id': 'cat-a', 'category_name': 'A'},
                {'category_id': 'cat-b', 'category_name': 'B'},
              ];
            }
            if (params['action'] == 'get_vod_streams') {
              final categoryId = params['category_id'];
              if (categoryId == null) unfilteredVodCalls++;
              return [
                {
                  'stream_id': '$categoryId-1',
                  'name': categoryId == 'cat-b'
                      ? 'Needle Movie'
                      : 'Other Movie',
                  'category_id': categoryId,
                },
              ];
            }
            return const [];
          },
        );

        final results = await source.searchMedia(ContentKind.movie, 'needle');

        expect(results.single.id, 'cat-b-1');
        expect(unfilteredVodCalls, 0);
      },
    );
  });

  group('MetadataConfig', () {
    test('normalizes TMDB bearer credentials', () {
      final config = MetadataConfig.fromJson({
        'tmdbApiKey': '  Bearer eyJhbGciOiJIUzI1Ni.fake.token  ',
      });

      expect(config.tmdbApiKey, 'eyJhbGciOiJIUzI1Ni.fake.token');
      expect(config.normalizedTmdbCredential, config.tmdbApiKey);
      expect(config.hasTmdb, isTrue);
      expect(config.toJson(), {
        'provider': 'tmdb',
        'tmdbApiKey': 'eyJhbGciOiJIUzI1Ni.fake.token',
        'tvdbApiKey': '',
        'tvdbPin': '',
        'mdblistApiKey': '',
        'autoEnrich': true,
      });
      expect(config.autoEnrich, isTrue);
    });

    test('stores alternate provider credentials', () {
      final config = MetadataConfig.fromJson({
        'provider': 'tvdb',
        'tvdbApiKey': ' tvdb-key ',
        'tvdbPin': ' pin ',
        'mdblistApiKey': ' mdb-key ',
        'autoEnrich': false,
      });

      expect(config.provider, 'tvdb');
      expect(config.tvdbApiKey, 'tvdb-key');
      expect(config.tvdbPin, 'pin');
      expect(config.mdblistApiKey, 'mdb-key');
      expect(config.hasTvdb, isTrue);
      expect(config.hasMdblist, isTrue);
      expect(config.autoEnrich, isFalse);
    });

    test('normalizes ratings-only provider selection to visual default', () {
      final config = MetadataConfig.fromJson({'provider': 'mdblist'});

      expect(config.provider, 'tmdb');
      expect(config.preferredVisualProvider, 'tmdb');
    });

    test('keeps v3 API keys as api_key auth', () {
      final client = TmdbClient(apiKey: 'abc123');
      addTearDown(client.close);

      expect(client.usesBearerToken, isFalse);
      expect(client.authMode, 'api_key');
    });

    test('detects v4 read access tokens as bearer auth', () {
      final client = TmdbClient(apiKey: 'eyJhbGciOiJIUzI1Ni.fake.token');
      addTearDown(client.close);

      expect(client.usesBearerToken, isTrue);
      expect(client.authMode, 'bearer');
    });
  });

  group('source hint parsing', () {
    test('does not mark Arabic AR sources as Spanish', () {
      const item = MediaItem(
        id: 'movie-1',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': 'AR | Clean Movie Title'},
      );

      final hints = sourceHintLabels(item);

      expect(hints, contains('Arabic'));
      expect(hints, isNot(contains('Spanish')));
    });

    test('detects Persian and Turkmen country-style source tags', () {
      const persian = MediaItem(
        id: 'movie-2',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': '[IR] Clean Movie Title'},
      );
      const turkmen = MediaItem(
        id: 'movie-3',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': 'TM - Clean Movie Title'},
      );

      expect(sourceHintLabels(persian), contains('Persian'));
      expect(sourceHintLabels(turkmen), contains('Turkmen'));
    });

    test('ignores ambiguous shared country tags by themselves', () {
      const item = MediaItem(
        id: 'movie-4',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': 'UK | Clean Movie Title'},
      );

      final hints = sourceHintLabels(item);

      expect(hints, isNot(contains('English')));
      expect(hints, isNot(contains('Ukrainian')));
    });

    test('keeps weak country hints opt-in', () {
      const item = MediaItem(
        id: 'movie-5',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': 'AUDIO US | Clean Movie Title'},
      );

      expect(sourceHintLabels(item), isNot(contains('Audio: English')));
      expect(
        sourceHintLabels(item, includeWeak: true),
        contains('Audio: English'),
      );
    });

    test('handles SC as Seychellois Creole only with context', () {
      const bare = MediaItem(
        id: 'movie-6',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': 'SC | Clean Movie Title'},
      );
      const audio = MediaItem(
        id: 'movie-7',
        title: 'Clean Movie Title',
        kind: ContentKind.movie,
        extra: {'providerTitle': 'AUDIO SC | Clean Movie Title'},
      );

      expect(sourceHintLabels(bare), isNot(contains('Seychellois Creole')));
      expect(
        sourceHintLabels(audio, includeWeak: true),
        contains('Audio: Seychellois Creole'),
      );
    });
  });
}
