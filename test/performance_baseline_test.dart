import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';
import 'package:iptvs/sources/xmltv.dart';
import 'package:iptvs/sources/xtream_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

      // The following four baselines exercise PR 10's one-pass isolate
      // ingestion paths directly (bytes in, typed lists out), rather than the
      // pre-PR-10 decode-then-map-inline shape the tests above still cover.
      // Each reports both the inline call (no isolate spawn) and the
      // production isolate round trip, so a regression in isolate spawn/copy
      // overhead is visible separately from the underlying parse cost.

      test(
        'Xtream live one-pass decodeLiveChannelsBytes 250000 items',
        () async {
          const itemCount = 250000;
          final bytes = WorkloadFixtures.xtreamLiveJson(itemCount);

          final inlineWatch = Stopwatch()..start();
          final inlineResult = decodeLiveChannelsBytes(bytes);
          inlineWatch.stop();
          expect(inlineResult, hasLength(itemCount));

          final isolateWatch = Stopwatch()..start();
          final isolateResult = await compute(decodeLiveChannelsBytes, bytes);
          isolateWatch.stop();
          expect(isolateResult, hasLength(itemCount));

          _report('xtream-live-onepass', {
            'items': itemCount,
            'inputBytes': bytes.length,
            'inlineMs': inlineWatch.elapsedMilliseconds,
            'isolateRoundTripMs': isolateWatch.elapsedMilliseconds,
            'maxRssBytes': ProcessInfo.maxRss,
          });
        },
      );

      test('Xtream VOD one-pass decodeMediaItemsBytes 250000 items', () async {
        const itemCount = 250000;
        final bytes = WorkloadFixtures.xtreamVodJson(itemCount);
        final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);

        final inlineWatch = Stopwatch()..start();
        final inlineResult = decodeMediaItemsBytes(args);
        inlineWatch.stop();
        expect(inlineResult, hasLength(itemCount));

        final isolateWatch = Stopwatch()..start();
        final isolateResult = await compute(decodeMediaItemsBytes, args);
        isolateWatch.stop();
        expect(isolateResult, hasLength(itemCount));

        _report('xtream-vod-onepass', {
          'items': itemCount,
          'inputBytes': bytes.length,
          'inlineMs': inlineWatch.elapsedMilliseconds,
          'isolateRoundTripMs': isolateWatch.elapsedMilliseconds,
          'maxRssBytes': ProcessInfo.maxRss,
        });
      });

      // No pre-PR-10 baseline exists for this path: the old
      // decode-into-a-dynamic-tree-then-map-inline Stalker ingestion had no
      // bytes-in/typed-list-out seam to benchmark directly, so this entry is
      // new rather than a comparison against a prior number.
      test('Stalker one-pass debugIngestChannels 250000 items', () async {
        const itemCount = 250000;
        final bytes = WorkloadFixtures.stalkerChannelsJson(itemCount);

        final inlineWatch = Stopwatch()..start();
        final inlineResult = StalkerSource.debugIngestChannels(bytes);
        inlineWatch.stop();
        expect(inlineResult.channels, hasLength(itemCount));

        final isolateWatch = Stopwatch()..start();
        final isolateResult = await Isolate.run(
          () => StalkerSource.debugIngestChannels(bytes),
        );
        isolateWatch.stop();
        expect(isolateResult.channels, hasLength(itemCount));

        _report('stalker-onepass', {
          'items': itemCount,
          'inputBytes': bytes.length,
          'inlineMs': inlineWatch.elapsedMilliseconds,
          'isolateRoundTripMs': isolateWatch.elapsedMilliseconds,
          'maxRssBytes': ProcessInfo.maxRss,
        });
      });

      // Compares against the 'xmltv-gzip' entry above (parseXmltv, one big
      // list) by draining parseXmltvBatched's streamed batches over the same
      // fixture end to end, so the two numbers are directly comparable.
      test('XMLTV batched parseXmltvBatched 100000 programmes', () async {
        const channelCount = 500;
        const programmesPerChannel = 200;
        final bytes = WorkloadFixtures.xmltv(
          channelCount: channelCount,
          programmesPerChannel: programmesPerChannel,
          gzip: true,
        );
        final channelMap = {
          for (var i = 0; i < channelCount; i++) 'channel.$i': 'id-$i',
        };

        final watch = Stopwatch()..start();
        var total = 0;
        var batches = 0;
        await for (final batch in parseXmltvBatched(bytes, channelMap)) {
          total += batch.length;
          batches++;
        }
        watch.stop();

        expect(total, channelCount * programmesPerChannel);
        _report('xmltv-batched', {
          'items': total,
          'batches': batches,
          'compressedBytes': bytes.length,
          'parseMs': watch.elapsedMilliseconds,
          'maxRssBytes': ProcessInfo.maxRss,
        });
      });

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
              // `url` is a secret-locator field, so the write encrypts it and the
              // read decrypts it. Without a locator field the vault short-circuits
              // and the run measures zero crypto — which is not what any real M3U
              // (`url`) or Stalker (`cmd`) source does. See the note in
              // docs/validation-baseline.md.
              extra: {
                'tvgId': 'channel.$i',
                'url': 'http://baseline.invalid/live/acct/tok/$i.ts',
              },
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

      // The workload above seeds exactly two programmes per channel, so both
      // halves of `nowNext` match almost every row they scan — the best case
      // for any plan, and blind to the cost this workload isolates. A real
      // guide is ~48 programmes per channel across a couple of days, where the
      // "now" query's discarded candidates and the "next" query's sort
      // dominate. Reported alongside the legacy SQL so the win is reproducible
      // rather than asserted.
      test('SQLite now/next on a realistic guide shape', () async {
        const channelCount = 5000;
        const perChannel = 48; // 240k programmes, ~2 days of guide.
        // Pinned back onto the pre-change index so this measures the old plan
        // even though `idx_prog_now` now exists.
        const legacyNowSql =
            'SELECT channel_id, title, start, stop, description FROM programmes '
            'INDEXED BY idx_prog_source_start '
            'WHERE source_id = ? AND start <= ? AND stop > ?';
        const legacyNextSql =
            'SELECT channel_id, title, MIN(start) AS start, stop, description '
            'FROM programmes WHERE source_id = ? AND start > ? '
            'GROUP BY channel_id';

        final tempDir = Directory.systemTemp.createTempSync('iptvs_baseline');
        AppDatabase? db;
        try {
          final path = '${tempDir.path}/nownext.db';
          db = await AppDatabase.openAt(path);
          final firstStart = DateTime.utc(2026, 1, 1);
          await db.replaceEpg('baseline-source', <Programme>[
            for (var c = 0; c < channelCount; c++)
              for (var i = 0; i < perChannel; i++)
                Programme(
                  channelId: 'channel-$c',
                  start: firstStart.add(Duration(hours: i)),
                  stop: firstStart.add(Duration(hours: i + 1)),
                  title: 'Programme $c-$i',
                ),
          ]);
          // Mid-guide, the shape the 60s refresh timer actually sees.
          final at = firstStart.add(
            const Duration(hours: perChannel ~/ 2, minutes: 30),
          );

          final watch = Stopwatch()..start();
          final result = await db.nowNext('baseline-source', at);
          watch.stop();
          expect(result.now, hasLength(channelCount));
          expect(result.next, hasLength(channelCount));

          // `singleInstance` hands back the AppDatabase's own connection, so
          // the legacy SQL runs against exactly the same cache and page state.
          // Deliberately not closed here — `db.close()` owns it.
          final shared = await databaseFactoryFfi.openDatabase(path);
          final t = at.millisecondsSinceEpoch;
          final legacyNowWatch = Stopwatch()..start();
          await shared.rawQuery(legacyNowSql, ['baseline-source', t, t]);
          legacyNowWatch.stop();
          final legacyNextWatch = Stopwatch()..start();
          await shared.rawQuery(legacyNextSql, ['baseline-source', t]);
          legacyNextWatch.stop();

          _report('sqlite-nownext-realistic', {
            'channels': channelCount,
            'programmes': channelCount * perChannel,
            'nowNextMs': watch.elapsedMilliseconds,
            // Legacy = pre-idx_prog_now "now" and unpinned "next".
            'legacyNowMs': legacyNowWatch.elapsedMilliseconds,
            'legacyNextMs': legacyNextWatch.elapsedMilliseconds,
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
