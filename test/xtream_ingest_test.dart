import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

import 'support/workload_fixtures.dart';

void main() {
  group('decodeLiveChannelsBytes (one-pass get_live_streams worker)', () {
    test('matches the two-step decode+map pipeline field-by-field', () {
      const itemCount = 500;
      final bytes = WorkloadFixtures.xtreamLiveJson(itemCount);

      final onePass = decodeLiveChannelsBytes(bytes);
      final twoStep = mapLiveChannels(
        jsonDecode(utf8.decode(bytes, allowMalformed: true)),
      );

      expect(onePass, hasLength(itemCount));
      expect(twoStep, hasLength(itemCount));

      // Even index: tv_archive on, 7-day duration. Odd index: archive off.
      for (final channels in [onePass, twoStep]) {
        final even = channels[0];
        expect(even.id, '1');
        expect(even.name, 'Live 0');
        expect(even.number, isNull);
        expect(even.logo, 'https://images.example.invalid/live/0.png');
        expect(even.categoryId, '0');
        expect(even.archiveDays, 7);
        expect(even.hasArchive, isTrue);
        expect(even.extra['streamId'], '1');
        expect(even.extra['tvgId'], 'channel.0');

        final odd = channels[1];
        expect(odd.id, '2');
        expect(odd.name, 'Live 1');
        expect(odd.categoryId, '1');
        expect(odd.archiveDays, 0);
        expect(odd.hasArchive, isFalse);
        expect(odd.extra['tvgId'], 'channel.1');
      }
    });

    test('drops non-map rows without throwing', () {
      final rows = <Object?>[
        for (var i = 0; i < 20; i++) {'stream_id': i + 1, 'name': 'Live $i'},
        null,
        'not-a-channel',
        42,
        true,
      ];
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(rows)));

      final channels = decodeLiveChannelsBytes(bytes);

      expect(channels, hasLength(20));
      expect(channels.map((c) => c.id), everyElement(isNotEmpty));
    });

    test('a malformed JSON payload throws FormatException, same as jsonDecode',
        () {
      final bytes = Uint8List.fromList(utf8.encode('{not valid json'));
      expect(() => decodeLiveChannelsBytes(bytes), throwsFormatException);
      expect(
        () => jsonDecode(utf8.decode(bytes)),
        throwsFormatException,
      );
    });
  });

  group('decodeMediaItemsBytes (one-pass get_vod_streams/get_series worker)', () {
    test('movie payload matches the two-step decode+map pipeline', () {
      const itemCount = 500;
      final bytes = WorkloadFixtures.xtreamVodJson(itemCount);
      final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);

      final onePass = decodeMediaItemsBytes(args);
      final twoStep = mapMediaItemsFromDecoded(
        jsonDecode(utf8.decode(bytes, allowMalformed: true)),
        ContentKind.movie,
      );

      expect(onePass, hasLength(itemCount));
      expect(twoStep, hasLength(itemCount));

      for (final items in [onePass, twoStep]) {
        final first = items[0];
        expect(first.id, '1');
        expect(first.title, 'Movie 0');
        expect(first.kind, ContentKind.movie);
        expect(first.categoryId, '0');
        expect(first.poster, 'https://images.example.invalid/movie/0.png');
        expect(first.rating, 5.0);
        expect(first.extra['container_extension'], 'mkv');
      }
    });

    test('series payload matches the two-step decode+map pipeline', () {
      const itemCount = 500;
      final bytes = WorkloadFixtures.xtreamSeriesJson(itemCount);
      final args = XtreamMediaDecodeArgs(bytes, ContentKind.series);

      final onePass = decodeMediaItemsBytes(args);
      final twoStep = mapMediaItemsFromDecoded(
        jsonDecode(utf8.decode(bytes, allowMalformed: true)),
        ContentKind.series,
      );

      expect(onePass, hasLength(itemCount));
      expect(twoStep, hasLength(itemCount));

      for (final items in [onePass, twoStep]) {
        final first = items[0];
        expect(first.id, '1');
        expect(first.title, 'Series 0');
        expect(first.kind, ContentKind.series);
        expect(first.categoryId, '0');
        expect(first.poster, 'https://images.example.invalid/series/0.png');
        expect(first.rating, 5.0);
      }
    });

    test('drops non-map rows and rows without an id, never throws', () {
      final rows = <Object?>[
        for (var i = 0; i < 15; i++)
          {'stream_id': i + 1, 'name': 'Movie $i', 'category_id': 'cat-a'},
        // No id-shaped field at all -> filtered by the empty-id guard.
        {'name': 'No id fields', 'category_id': 'cat-a'},
        null,
        'not-a-movie',
      ];
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(rows)));
      final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);

      final items = decodeMediaItemsBytes(args);

      expect(items, hasLength(15));
      expect(items.map((i) => i.id), everyElement(isNotEmpty));
    });

    test('a malformed JSON payload throws FormatException, same as jsonDecode',
        () {
      final bytes = Uint8List.fromList(utf8.encode('[1, 2,'));
      final args = XtreamMediaDecodeArgs(bytes, ContentKind.movie);
      expect(() => decodeMediaItemsBytes(args), throwsFormatException);
      expect(
        () => jsonDecode(utf8.decode(bytes)),
        throwsFormatException,
      );
    });
  });
}
