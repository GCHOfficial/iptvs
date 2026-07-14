import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xmltv.dart';

import 'support/workload_fixtures.dart';

const _enabledVariable = 'IPTVS_RUN_BASELINE';
final _enabled = Platform.environment[_enabledVariable] == '1';

void main() {
  group(
    'opt-in ingestion baseline',
    () {
      for (final channelCount in [10000, 50000, 250000]) {
        test('M3U $channelCount channels', () {
          final beforeRss = ProcessInfo.currentRss;
          final inputWatch = Stopwatch()..start();
          final playlist = WorkloadFixtures.m3uPlaylist(channelCount);
          inputWatch.stop();
          final parseWatch = Stopwatch()..start();
          final parsed = parseM3uPlaylist(playlist);
          parseWatch.stop();

          expect(parsed.channels, hasLength(channelCount));
          _report('m3u', {
            'items': channelCount,
            'inputBytes': utf8.encode(playlist).length,
            'fixtureMs': inputWatch.elapsedMilliseconds,
            'parseMs': parseWatch.elapsedMilliseconds,
            'rssDeltaBytes': ProcessInfo.currentRss - beforeRss,
            'maxRssBytes': ProcessInfo.maxRss,
          });
        });
      }

      test('XMLTV 100000 programmes', () async {
        const channelCount = 500;
        const programmesPerChannel = 200;
        final beforeRss = ProcessInfo.currentRss;
        final fixtureWatch = Stopwatch()..start();
        final bytes = WorkloadFixtures.xmltv(
          channelCount: channelCount,
          programmesPerChannel: programmesPerChannel,
          gzip: true,
        );
        fixtureWatch.stop();
        final channelMap = {
          for (var i = 0; i < channelCount; i++) 'channel.$i': 'id-$i',
        };
        final parseWatch = Stopwatch()..start();
        final programmes = await parseXmltv(bytes, channelMap);
        parseWatch.stop();

        expect(programmes, hasLength(channelCount * programmesPerChannel));
        _report('xmltv-gzip', {
          'items': programmes.length,
          'compressedBytes': bytes.length,
          'fixtureMs': fixtureWatch.elapsedMilliseconds,
          'parseMs': parseWatch.elapsedMilliseconds,
          'rssDeltaBytes': ProcessInfo.currentRss - beforeRss,
          'maxRssBytes': ProcessInfo.maxRss,
        });
      });

      for (final itemCount in [10000, 50000]) {
        test('provider JSON decode $itemCount items', () {
          for (final fixture in {
            'xtream-live': WorkloadFixtures.xtreamLiveJson(itemCount),
            'xtream-vod': WorkloadFixtures.xtreamVodJson(itemCount),
            'xtream-series': WorkloadFixtures.xtreamSeriesJson(itemCount),
            'stalker': WorkloadFixtures.stalkerChannelsJson(itemCount),
          }.entries) {
            final beforeRss = ProcessInfo.currentRss;
            final watch = Stopwatch()..start();
            final decoded = jsonDecode(utf8.decode(fixture.value));
            watch.stop();
            final decodedCount = fixture.key == 'stalker'
                ? (((decoded as Map<String, dynamic>)['js']
                              as Map<String, dynamic>)['data']
                          as List<dynamic>)
                      .length
                : (decoded as List<dynamic>).length;
            expect(decodedCount, itemCount);
            _report(fixture.key, {
              'items': itemCount,
              'inputBytes': fixture.value.length,
              'decodeMs': watch.elapsedMilliseconds,
              'rssDeltaBytes': ProcessInfo.currentRss - beforeRss,
              'maxRssBytes': ProcessInfo.maxRss,
            });
          }
        });
      }

      test('SQLite 50000 channels and 100000 programmes', () async {
        const channelCount = 50000;
        final tempDir = Directory.systemTemp.createTempSync(
          'iptvs_baseline_db',
        );
        AppDatabase? db;
        try {
          db = await AppDatabase.openAt('${tempDir.path}/baseline.db');
          final categories = List.generate(
            50,
            (i) => Category(id: 'group-$i', title: 'Group $i'),
            growable: false,
          );
          final channels = List.generate(
            channelCount,
            (i) => Channel(
              id: 'channel-$i',
              name: 'Channel $i',
              number: i + 1,
              categoryId: 'group-${i % categories.length}',
              extra: {'tvgId': 'channel.$i'},
            ),
            growable: false,
          );

          final libraryWatch = Stopwatch()..start();
          await db.replaceLibrary(
            'baseline-source',
            'Baseline',
            categories,
            channels,
          );
          libraryWatch.stop();
          final readWatch = Stopwatch()..start();
          final readChannels = await db.readChannels('baseline-source');
          readWatch.stop();
          expect(readChannels, hasLength(channelCount));

          final firstStart = DateTime.utc(2026, 1, 1);
          final programmes = <Programme>[];
          for (var i = 0; i < channelCount; i++) {
            programmes
              ..add(
                Programme(
                  channelId: 'channel-$i',
                  start: firstStart,
                  stop: firstStart.add(const Duration(hours: 1)),
                  title: 'Current $i',
                ),
              )
              ..add(
                Programme(
                  channelId: 'channel-$i',
                  start: firstStart.add(const Duration(hours: 1)),
                  stop: firstStart.add(const Duration(hours: 2)),
                  title: 'Next $i',
                ),
              );
          }
          final epgWatch = Stopwatch()..start();
          await db.replaceEpg('baseline-source', programmes);
          epgWatch.stop();
          final queryWatch = Stopwatch()..start();
          final result = await db.nowNext(
            'baseline-source',
            firstStart.add(const Duration(minutes: 30)),
          );
          queryWatch.stop();
          expect(result.now, hasLength(channelCount));
          expect(result.next, hasLength(channelCount));

          _report('sqlite-library-epg', {
            'channels': channelCount,
            'programmes': programmes.length,
            'libraryWriteMs': libraryWatch.elapsedMilliseconds,
            'channelReadMs': readWatch.elapsedMilliseconds,
            'epgWriteMs': epgWatch.elapsedMilliseconds,
            'nowNextMs': queryWatch.elapsedMilliseconds,
            'maxRssBytes': ProcessInfo.maxRss,
          });
        } finally {
          await db?.close();
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        }
      });
    },
    skip: _enabled
        ? false
        : 'Set $_enabledVariable=1 to run large ingestion baselines.',
  );
}

void _report(String workload, Map<String, Object> values) {
  // A stable prefix and JSON body make reports easy to extract from test logs.
  // ignore: avoid_print
  print('IPTVS_BASELINE ${jsonEncode({'workload': workload, ...values})}');
}
