import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/expiry.dart';

void main() {
  group('parseExpiryValue', () {
    test('parses Unix seconds timestamp', () {
      final secs = DateTime.utc(2026, 6, 19).millisecondsSinceEpoch ~/ 1000;
      final dt = parseExpiryValue('$secs');
      expect(dt, isNotNull);
      expect(dt!.toUtc().year, 2026);
      expect(dt.toUtc().month, 6);
    });

    test('parses Unix milliseconds timestamp', () {
      final ms = DateTime.utc(2027, 3, 10).millisecondsSinceEpoch;
      final dt = parseExpiryValue('$ms');
      expect(dt!.toUtc().year, 2027);
    });

    test('parses ISO date', () {
      final dt = parseExpiryValue('2026-06-19');
      expect(dt, DateTime(2026, 6, 19));
    });

    test('parses space-separated datetime', () {
      final dt = parseExpiryValue('2026-06-19 20:34:00');
      expect(dt, DateTime(2026, 6, 19, 20, 34, 0));
    });

    test('returns null for zero / empty / null / garbage', () {
      expect(parseExpiryValue('0'), isNull);
      expect(parseExpiryValue(''), isNull);
      expect(parseExpiryValue(null), isNull);
      expect(parseExpiryValue('not a date'), isNull);
    });
  });
}
