import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

import 'support/workload_fixtures.dart';

/// Covers the bounded one-pass `get_all_channels` ingestion worker
/// (`StalkerSource.debugIngestChannels`, backed by the top-level
/// `_ingestStalkerChannels`): decode + row-map done in a single pass, with
/// the same token-invalid/portal-error detection `_call` applies to every
/// other Stalker action, and per-row skip semantics so one bad row never
/// takes down the whole catalog.
void main() {
  group('one-pass worker matches the existing static mapper', () {
    test(
      'maps a large fixture identically to _mapChannel row-by-row',
      () async {
        const itemCount = 4000;
        final bytes = WorkloadFixtures.stalkerChannelsJson(itemCount);
        // Comfortably over the 256 KiB isolate threshold — this exercises the
        // Isolate.run path, not just the inline one.
        expect(bytes.length, greaterThan(256 * 1024));

        final expected = _referenceChannels(bytes);
        final result = await Isolate.run(
          () => StalkerSource.debugIngestChannels(bytes),
        );

        expect(result.tokenInvalid, isFalse);
        expect(result.portalErrorMessage, isNull);
        expect(result.channels, hasLength(itemCount));
        expect(result.channels.length, expected.length);

        for (var i = 0; i < expected.length; i++) {
          _expectSameChannel(result.channels[i], expected[i], reason: 'row $i');
        }

        // Sample a few rows explicitly for hasArchive/categoryId, since the
        // fixture alternates tv_archive_duration (odd index = 0 = no archive).
        expect(result.channels[0].hasArchive, isTrue); // i=0 is even → 3 days
        expect(result.channels[0].archiveDays, 3);
        expect(result.channels[1].hasArchive, isFalse); // i=1 is odd → 0 days
        expect(result.channels[0].categoryId, '0');
        expect(result.channels[49].categoryId, '49');
      },
    );

    test('runs inline for a small fixture and still matches _mapChannel', () {
      const itemCount = 20;
      final bytes = WorkloadFixtures.stalkerChannelsJson(itemCount);
      expect(bytes.length, lessThan(256 * 1024));

      final expected = _referenceChannels(bytes);
      final result = StalkerSource.debugIngestChannels(bytes);

      expect(result.channels, hasLength(itemCount));
      for (var i = 0; i < expected.length; i++) {
        _expectSameChannel(result.channels[i], expected[i], reason: 'row $i');
      }
    });
  });

  group('malformed rows never take down the batch', () {
    test(
      'stalkerChannelsJson(malformedEvery:) rows survive without throwing',
      () {
        const itemCount = 30;
        const malformedEvery = 5;
        final bytes = WorkloadFixtures.stalkerChannelsJson(
          itemCount,
          malformedEvery: malformedEvery,
        );

        final result = StalkerSource.debugIngestChannels(bytes);

        expect(result.tokenInvalid, isFalse);
        expect(result.portalErrorMessage, isNull);
        // The odd-typed fields (`name: null`, `cmd: 42`, a Map tv_genre_id)
        // don't stop _mapChannel from producing a Channel — every row still
        // maps, none crash the worker.
        expect(result.channels, hasLength(itemCount));
        for (var i = malformedEvery; i < itemCount; i += malformedEvery) {
          // No id/ch_id/channel_id/stream_id field on these rows, so
          // _mapChannel falls back to the (stringified, null) name.
          expect(result.channels[i].id, 'null');
        }
      },
    );

    test('a row that is not a Map is dropped, not fatal', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'js': {
              'total_items': 3,
              'data': [
                {'id': '1', 'name': 'Channel 1'},
                'not a channel row', // malformed: not a Map at all
                {'id': '2', 'name': 'Channel 2'},
              ],
            },
          }),
        ),
      );

      final result = StalkerSource.debugIngestChannels(bytes);

      expect(result.tokenInvalid, isFalse);
      expect(result.portalErrorMessage, isNull);
      expect(result.channels.map((c) => c.id), ['1', '2']);
    });
  });

  group('non-JSON / portal-error / token-invalid contract', () {
    test('non-JSON bytes throw the same StalkerException as _request', () {
      final bytes = Uint8List.fromList(utf8.encode('<html>not json</html>'));

      expect(
        () => StalkerSource.debugIngestChannels(bytes),
        throwsA(
          isA<StalkerException>().having(
            (e) => e.message,
            'message',
            contains('Non-JSON response'),
          ),
        ),
      );
    });

    test('a non-Map top-level JSON value throws Unexpected response shape', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode([1, 2, 3])));

      expect(
        () => StalkerSource.debugIngestChannels(bytes),
        throwsA(
          isA<StalkerException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected response shape'),
          ),
        ),
      );
    });

    test('an auth-shaped error response is reported as tokenInvalid', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'error': 'Invalid token: authorization denied'}),
        ),
      );

      final result = StalkerSource.debugIngestChannels(bytes);

      expect(result.tokenInvalid, isTrue);
      expect(result.portalErrorMessage, isNull);
      expect(result.channels, isEmpty);
    });

    test('a null js payload is also reported as tokenInvalid', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({'js': null})));

      final result = StalkerSource.debugIngestChannels(bytes);

      expect(result.tokenInvalid, isTrue);
      expect(result.channels, isEmpty);
    });

    test('a portal error message surfaces as portalErrorMessage', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({'js': false})));

      final result = StalkerSource.debugIngestChannels(bytes);

      expect(result.tokenInvalid, isFalse);
      expect(result.portalErrorMessage, 'Portal returned false');
      expect(result.channels, isEmpty);
    });
  });
}

/// Reference mapping: decode the fixture bytes exactly like the worker does,
/// then run every row through the same static [StalkerSource.debugMapChannel]
/// the worker calls internally — proving the one-pass worker doesn't
/// diverge from the existing per-row mapper.
List<Channel> _referenceChannels(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final js = decoded['js'] as Map<String, dynamic>;
  final rows = (js['data'] as List).cast<Map<String, dynamic>>();
  return rows.map(StalkerSource.debugMapChannel).toList();
}

void _expectSameChannel(Channel actual, Channel expected, {String? reason}) {
  expect(actual.id, expected.id, reason: reason);
  expect(actual.name, expected.name, reason: reason);
  expect(actual.number, expected.number, reason: reason);
  expect(actual.logo, expected.logo, reason: reason);
  expect(actual.categoryId, expected.categoryId, reason: reason);
  expect(actual.archiveDays, expected.archiveDays, reason: reason);
  expect(actual.extra, expected.extra, reason: reason);
}
