import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

import 'support/workload_fixtures.dart';

/// Covers the bounded one-pass `get_epg_info` ingestion worker
/// (`StalkerSource.debugIngestEpg`, backed by the top-level
/// `_ingestStalkerEpg`): decode + per-channel programme mapping done in a
/// single pass, with the same token-invalid/portal-error detection `_call`
/// applies to every other Stalker action, and the exact mapping `_portalEpg`
/// used to do inline before this PR (`WorkloadFixtures.stalkerEpgJson`
/// mirrors the channel-ingestion fixture's style).
void main() {
  group('one-pass worker matches the original inline mapping', () {
    test(
      'maps a large fixture identically to the reference mapper',
      () async {
        const channelCount = 3000;
        final bytes = WorkloadFixtures.stalkerEpgJson(channelCount);
        // Comfortably over the 256 KiB isolate threshold — this exercises the
        // Isolate.run path, not just the inline one.
        expect(bytes.length, greaterThan(256 * 1024));

        final expected = _referenceProgrammes(bytes);
        final result = await Isolate.run(
          () => StalkerSource.debugIngestEpg(bytes),
        );

        expect(result.tokenInvalid, isFalse);
        expect(result.portalErrorMessage, isNull);
        expect(result.programmes, hasLength(expected.length));
        expect(result.programmes.length, channelCount * 3);

        for (var i = 0; i < expected.length; i++) {
          _expectSameProgramme(
            result.programmes[i],
            expected[i],
            reason: 'row $i',
          );
        }
      },
    );

    test(
      'runs inline for a small fixture and still matches the reference mapper',
      () {
        const channelCount = 5;
        final bytes = WorkloadFixtures.stalkerEpgJson(channelCount);
        expect(bytes.length, lessThan(256 * 1024));

        final expected = _referenceProgrammes(bytes);
        final result = StalkerSource.debugIngestEpg(bytes);

        expect(result.programmes, hasLength(expected.length));
        for (var i = 0; i < expected.length; i++) {
          _expectSameProgramme(
            result.programmes[i],
            expected[i],
            reason: 'row $i',
          );
        }
      },
    );
  });

  group('malformed entries never take down the batch', () {
    test('a non-Map programme entry is dropped, not fatal', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'js': {
              'data': {
                '1': [
                  {
                    'start_timestamp': 1000,
                    'stop_timestamp': 2000,
                    'name': 'Good',
                  },
                  'not a programme', // malformed: not a Map at all
                ],
              },
            },
          }),
        ),
      );

      final result = StalkerSource.debugIngestEpg(bytes);

      expect(result.tokenInvalid, isFalse);
      expect(result.portalErrorMessage, isNull);
      expect(result.programmes, hasLength(1));
      expect(result.programmes.single.title, 'Good');
    });

    test('an entry with no usable start/stop timestamp is skipped', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'js': {
              'data': {
                '1': [
                  {'start_timestamp': 0, 'stop_timestamp': 0, 'name': 'Zero'},
                  {'name': 'Missing'},
                  {
                    'start_timestamp': 1000,
                    'stop_timestamp': 2000,
                    'name': 'Good',
                  },
                ],
              },
            },
          }),
        ),
      );

      final result = StalkerSource.debugIngestEpg(bytes);

      expect(result.programmes, hasLength(1));
      expect(result.programmes.single.title, 'Good');
    });

    test('a channel list that is not a List is skipped', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'js': {
              'data': {
                '1': 'not a list',
                '2': [
                  {
                    'start_timestamp': 1000,
                    'stop_timestamp': 2000,
                    'name': 'Good',
                  },
                ],
              },
            },
          }),
        ),
      );

      final result = StalkerSource.debugIngestEpg(bytes);

      expect(result.programmes, hasLength(1));
      expect(result.programmes.single.channelId, '2');
    });
  });

  group('non-JSON / portal-error / token-invalid contract', () {
    test('non-JSON bytes throw the same StalkerException as _request', () {
      final bytes = Uint8List.fromList(utf8.encode('<html>not json</html>'));

      expect(
        () => StalkerSource.debugIngestEpg(bytes),
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
        () => StalkerSource.debugIngestEpg(bytes),
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

      final result = StalkerSource.debugIngestEpg(bytes);

      expect(result.tokenInvalid, isTrue);
      expect(result.portalErrorMessage, isNull);
      expect(result.programmes, isEmpty);
    });

    test('a null js payload is also reported as tokenInvalid', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({'js': null})));

      final result = StalkerSource.debugIngestEpg(bytes);

      expect(result.tokenInvalid, isTrue);
      expect(result.programmes, isEmpty);
    });

    test('a portal error message surfaces as portalErrorMessage', () {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({'js': false})));

      final result = StalkerSource.debugIngestEpg(bytes);

      expect(result.tokenInvalid, isFalse);
      expect(result.portalErrorMessage, 'Portal returned false');
      expect(result.programmes, isEmpty);
    });
  });
}

/// Reference mapping: decode the fixture exactly like the worker does and
/// rebuild the [Programme] list by the same rules `_portalEpg` applied
/// inline before this PR, so the worker is proven not to diverge from it.
List<Programme> _referenceProgrammes(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final js = decoded['js'] as Map<String, dynamic>;
  final data = js['data'] as Map<String, dynamic>;
  final out = <Programme>[];
  data.forEach((chId, list) {
    for (final e in list as List) {
      final m = (e as Map).cast<String, dynamic>();
      final start = DateTime.fromMillisecondsSinceEpoch(
        (m['start_timestamp'] as int) * 1000,
      );
      final stop = DateTime.fromMillisecondsSinceEpoch(
        (m['stop_timestamp'] as int) * 1000,
      );
      out.add(
        Programme(
          channelId: chId,
          start: start,
          stop: stop,
          title: '${m['name'] ?? ''}',
          description: m['descr']?.toString(),
        ),
      );
    }
  });
  return out;
}

void _expectSameProgramme(
  Programme actual,
  Programme expected, {
  String? reason,
}) {
  expect(actual.channelId, expected.channelId, reason: reason);
  expect(actual.start, expected.start, reason: reason);
  expect(actual.stop, expected.stop, reason: reason);
  expect(actual.title, expected.title, reason: reason);
  expect(actual.description, expected.description, reason: reason);
}
