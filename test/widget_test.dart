// Unit tests for the IPTV app's pure logic.
//
// (Replaces the default counter widget test from `flutter create`, which
// referenced the old app and no longer applies.)

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/demo_source.dart';
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
}