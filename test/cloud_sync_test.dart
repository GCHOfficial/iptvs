import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
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

    test('throws on an unknown kind (defends against bad cloud data)', () {
      expect(
        () => cloudRowToConfig({'id': 'x', 'kind': 'bogus', 'fields': {}}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
