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

  group('extractExpiryFromText', () {
    test('bare ISO date', () {
      expect(extractExpiryFromText('2026-09-01'), DateTime(2026, 9, 1));
    });

    test('ISO datetime embedded in surrounding text', () {
      expect(
        extractExpiryFromText('exp: 2026-09-01 00:00:00'),
        DateTime(2026, 9, 1),
      );
    });

    test('European DD.MM.YYYY and DD/MM/YYYY', () {
      expect(extractExpiryFromText('01.09.2026'), DateTime(2026, 9, 1));
      expect(extractExpiryFromText('01/09/2026'), DateTime(2026, 9, 1));
    });

    test('does not treat a phone number as a timestamp', () {
      expect(extractExpiryFromText('0712345678'), isNull);
      expect(extractExpiryFromText('+40 712 345 678'), isNull);
    });

    test('null / empty / garbage / absurd year', () {
      expect(extractExpiryFromText(null), isNull);
      expect(extractExpiryFromText(''), isNull);
      expect(extractExpiryFromText('unlimited'), isNull);
      expect(extractExpiryFromText('9999-01-01'), isNull);
    });
  });

  group('expiryFromStalkerFields', () {
    test('prefers the named fields over phone', () {
      final dt = expiryFromStalkerFields({
        'end_date': '2026-06-19',
        'phone': '01.01.2030',
      });
      expect(dt, DateTime(2026, 6, 19));
    });

    test('falls back through tariff to a date stuffed in phone', () {
      expect(
        expiryFromStalkerFields({
          'end_date': '',
          'tariff': {'expire_date': '0'},
          'phone': 'until 2026-09-01',
        }),
        DateTime(2026, 9, 1),
      );
    });

    test('tariff expire_date wins over phone', () {
      expect(
        expiryFromStalkerFields({
          'tariff': {'expire_date': '2026-05-05'},
          'phone': '2030-01-01',
        }),
        DateTime(2026, 5, 5),
      );
    });

    test('returns null when nothing carries a date', () {
      expect(expiryFromStalkerFields({'phone': '0712345678'}), isNull);
      expect(expiryFromStalkerFields(const {}), isNull);
    });
  });

  group('expiryFromPlaylistUrl', () {
    test('parses a Unix timestamp from `exp`', () {
      final secs = DateTime.utc(2026, 6, 19).millisecondsSinceEpoch ~/ 1000;
      final dt = expiryFromPlaylistUrl(
        'http://host/get.php?username=u&password=p&type=m3u_plus&exp=$secs',
      );
      expect(dt, isNotNull);
      expect(dt!.toUtc().year, 2026);
      expect(dt.toUtc().month, 6);
    });

    test('parses a date string from `expiry`, `expire`, `expires`', () {
      expect(
        expiryFromPlaylistUrl('http://host/list.m3u?expiry=2026-09-01'),
        DateTime(2026, 9, 1),
      );
      expect(
        expiryFromPlaylistUrl('http://host/list.m3u?expire=2026-09-01'),
        DateTime(2026, 9, 1),
      );
      expect(
        expiryFromPlaylistUrl('http://host/list.m3u?expires=2026-09-01'),
        DateTime(2026, 9, 1),
      );
    });

    test('matches the param name case-insensitively', () {
      expect(
        expiryFromPlaylistUrl('http://host/list.m3u?EXP=2026-09-01'),
        DateTime(2026, 9, 1),
      );
    });

    test('returns null when no recognised param is present', () {
      expect(
        expiryFromPlaylistUrl(
          'http://host/get.php?username=u&password=p&type=m3u_plus',
        ),
        isNull,
      );
    });

    test('returns null for an unparseable URL or value', () {
      expect(expiryFromPlaylistUrl(''), isNull);
      expect(expiryFromPlaylistUrl('http://host/list.m3u?exp=not-a-date'), isNull);
      expect(expiryFromPlaylistUrl('http://host/list.m3u?exp=0'), isNull);
    });
  });
}
