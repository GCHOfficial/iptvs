// Unit tests for the IPTV app's pure logic.
//
// (Replaces the default counter widget test from `flutter create`, which
// referenced the old app and no longer applies.)

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/tmdb_client.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';
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
        'tmdbApiKey': 'eyJhbGciOiJIUzI1Ni.fake.token',
        'autoEnrich': true,
      });
      expect(config.autoEnrich, isTrue);
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
}
