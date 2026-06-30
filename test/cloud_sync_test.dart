import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  group('cloudRowToConfig', () {
    test('maps a well-formed Xtream row to a SourceConfig', () {
      final config = cloudRowToConfig({
        'id': 'abc-123',
        'kind': 'xtream',
        'label': 'My provider',
        'fields': {
          'host': 'http://host:8080',
          'username': 'u',
          'password': 'p',
        },
      });

      expect(config.id, 'abc-123');
      expect(config.kind, SourceKind.xtream);
      expect(config.label, 'My provider');
      expect(config.fields['host'], 'http://host:8080');
      // The mapped config builds a live Source without throwing.
      expect(config.build, returnsNormally);
    });

    test('coerces non-string field values to strings', () {
      final config = cloudRowToConfig({
        'id': 'id1',
        'kind': 'm3u',
        'label': '',
        'fields': {'playlistUrl': 'http://x/list.m3u', 'port': 8080},
      });

      expect(config.fields['port'], '8080');
      expect(config.label, '');
    });

    test('tolerates a missing label and empty fields', () {
      final config = cloudRowToConfig({
        'id': 'id2',
        'kind': 'demo',
        'fields': {},
      });

      expect(config.label, '');
      expect(config.fields, isEmpty);
      expect(config.kind, SourceKind.demo);
    });

    test('reads per-source settings (hidden categories) when present', () {
      final config = cloudRowToConfig({
        'id': 'id3',
        'kind': 'xtream',
        'label': 'P',
        'fields': {'host': 'h', 'username': 'u', 'password': 'p'},
        'settings': {
          'hiddenCategories': {
            'live': ['c1', 'c2'],
          },
        },
      });

      expect(config.hiddenCategoryIds(ContentKind.live), {'c1', 'c2'});
      expect(config.hiddenCategoryIds(ContentKind.movie), isEmpty);
    });

    test('defaults settings to empty when the column is absent (legacy row)', () {
      final config = cloudRowToConfig({
        'id': 'id4',
        'kind': 'm3u',
        'label': '',
        'fields': {'playlistUrl': 'http://x/list.m3u'},
      });

      expect(config.settings, isEmpty);
      expect(config.hiddenCategoryIds(ContentKind.live), isEmpty);
    });

    test('throws on an unknown kind (defends against bad cloud data)', () {
      expect(
        () => cloudRowToConfig({'id': 'x', 'kind': 'bogus', 'fields': {}}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('source ids (push round-trip)', () {
    test('newSourceId is a canonical v4 UUID', () {
      final id = newSourceId();
      expect(isUuid(id), isTrue);
      // Version nibble is 4, variant nibble is 8/9/a/b.
      expect(id[14], '4');
      expect('89ab'.contains(id[19]), isTrue);
    });

    test('newSourceId yields distinct ids', () {
      final ids = {for (var i = 0; i < 100; i++) newSourceId()};
      expect(ids.length, 100);
    });

    test('isUuid rejects legacy timestamp ids and accepts UUIDs', () {
      // The old id scheme (microsecond timestamps) is not a UUID, so push
      // rewrites it before sending to the uuid-typed cloud column.
      expect(isUuid('1719500000000000'), isFalse);
      expect(isUuid('not-a-uuid'), isFalse);
      expect(isUuid('123E4567-E89B-42D3-A456-426614174000'), isTrue);
    });
  });
}
