import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/expiry_service.dart';

void main() {
  group('parseExpiryValue', () {
    test('parses ISO date strings returned by Xtream panels', () {
      final dt = parseExpiryValue('2026-06-27');
      expect(dt, isNotNull);
      expect(dt!.year, 2026);
      expect(dt.month, 6);
      expect(dt.day, 27);
    });

    test('parses Unix timestamps encoded as strings', () {
      final dt = parseExpiryValue('1767225600');
      expect(dt, isNotNull);
      expect(dt!.year, 2026);
      expect(dt.month, 1);
      expect(dt.day, 1);
    });
  });
}
