import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/expiry.dart';
import 'package:iptvs/sources/source.dart';

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

  group('parseSubscriptionExpiryValue', () {
    test('recognises explicit unlimited provider values', () {
      for (final value in ['Unlimited', 'never', 'lifetime', 'no_expiry']) {
        expect(
          parseSubscriptionExpiryValue(value).kind,
          SubscriptionExpiryKind.unlimited,
          reason: value,
        );
      }
    });

    test('keeps missing and malformed metadata unknown', () {
      for (final value in [null, '', '0', 'null', 'not a date']) {
        expect(
          parseSubscriptionExpiryValue(value).kind,
          SubscriptionExpiryKind.unknown,
          reason: '$value',
        );
      }
    });

    test('retains a parsed date', () {
      final expiry = parseSubscriptionExpiryValue('2026-09-01');
      expect(expiry.kind, SubscriptionExpiryKind.dated);
      expect(expiry.date, DateTime(2026, 9, 1));
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
    test('recognises an unlimited named field', () {
      expect(
        subscriptionExpiryFromStalkerFields({'end_date': 'Unlimited'}).kind,
        SubscriptionExpiryKind.unlimited,
      );
    });
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

    test('a phone number is not a lifetime subscription', () {
      // Asserted on the *kind*, not the date: a phone number read as Unix
      // seconds lands centuries in the future, and the far-future sentinel
      // rule would otherwise call that unlimited — which carries no date, so
      // a date-only assertion sails straight past it.
      for (final number in ['0712345678', '+40712345678', '40712345678']) {
        expect(
          subscriptionExpiryFromStalkerFields({'phone': number}).kind,
          SubscriptionExpiryKind.unknown,
          reason: '$number must not read as unlimited',
        );
      }
      expect(
        parseSubscriptionExpiryValue('40712345678').kind,
        SubscriptionExpiryKind.unknown,
      );
    });

    test('reads the named fields in the formats panels actually send', () {
      // The regression behind "expiry unknown on every portal": only `phone`
      // got the lenient text extraction, so a perfectly ordinary `end_date`
      // that DateTime.parse happens to reject read as no answer at all.
      expect(
        expiryFromStalkerFields({'end_date': 'October 20, 2026'}),
        DateTime(2026, 10, 20),
      );
      expect(
        expiryFromStalkerFields({'end_date': '20.10.2026'}),
        DateTime(2026, 10, 20),
      );
      expect(
        expiryFromStalkerFields({'end_date': 'expires 2026-10-20 23:59:59'}),
        DateTime(2026, 10, 20, 23, 59, 59),
      );
    });

    test('reads the other field names panels use', () {
      expect(
        expiryFromStalkerFields({'expire_date': '2026-10-20'}),
        DateTime(2026, 10, 20),
      );
      expect(
        expiryFromStalkerFields({'tariff_expired_date': '2026-10-20'}),
        DateTime(2026, 10, 20),
      );
    });

    test('searches the nested payload some panels wrap the account in', () {
      expect(
        expiryFromStalkerFields({
          'account_info': {'end_date': '2026-10-20'},
        }),
        DateTime(2026, 10, 20),
      );
    });

    test('finds a date stuffed into the other identity fields, not just phone', () {
      // Resold Ministra skins show the expiry through whichever box their STB
      // screen happens to render, so it lands in fname/ls as readily as phone.
      expect(
        expiryFromStalkerFields({'fname': 'ACC-2211 exp 2026-10-20'}),
        DateTime(2026, 10, 20),
      );
      expect(
        expiryFromStalkerFields({'ls': '20.10.2026'}),
        DateTime(2026, 10, 20),
      );
    });

    test('a real name or account number is still not a date', () {
      expect(expiryFromStalkerFields({'fname': 'Ion Popescu'}), isNull);
      expect(expiryFromStalkerFields({'ls': '4411029'}), isNull);
    });

    test('a named field still beats a stuffed one', () {
      expect(
        expiryFromStalkerFields({
          'end_date': '2026-06-19',
          'fname': 'exp 2030-01-01',
        }),
        DateTime(2026, 6, 19),
      );
    });

    test('a far-future sentinel is unlimited, not unknown', () {
      // Panels spell "never" as a date. Reporting that as unknown throws away
      // an answer the user actually has — the exact collapse SubscriptionExpiry
      // exists to prevent.
      expect(
        subscriptionExpiryFromStalkerFields({'end_date': '9999-12-31'}).kind,
        SubscriptionExpiryKind.unlimited,
      );
      expect(
        parseSubscriptionExpiryValue('2999-01-01').kind,
        SubscriptionExpiryKind.unlimited,
      );
      // ...but an epoch-shaped nonsense value is still unknown, not unlimited.
      expect(
        parseSubscriptionExpiryValue('1970-01-01').kind,
        SubscriptionExpiryKind.unknown,
      );
    });
  });

  group('expiry diagnostics', () {
    test('a shape describes the format and carries no content', () {
      expect(expiryValueShape('2026-06-19'), 'dddd-dd-dd');
      expect(expiryValueShape('October 20, 2026'), 'aaaaaaa dd, dddd');
      expect(expiryValueShape(''), 'empty');
      expect(expiryValueShape(null), 'null');
    });

    test('a shape leaks no digits, letters or length past the cap', () {
      const secret = '+40 712 345 678';
      final shape = expiryValueShape(secret);
      expect(shape, isNot(contains('7')));
      expect(shape, isNot(contains('4')));
      expect(expiryValueShape('a' * 100).length, 33); // 32 + the ellipsis
    });

    test('the payload description names keys but never their values', () {
      final described = describeStalkerExpiryPayload({
        'mac': '00:1A:79:AA:BB:CC',
        'fname': 'Ion Popescu',
        'end_date': 'October 20, 2026',
      });
      expect(described, contains('end_date'));
      expect(described, contains('mac')); // a key name is schema, not data
      expect(described, contains('aaaaaaa dd, dddd'));
      expect(described, isNot(contains('Popescu')));
      expect(described, isNot(contains('October')));
      expect(described, isNot(contains('79')));
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

    test('accepts Xtream API-style exp_date in a playlist URL', () {
      expect(
        expiryFromPlaylistUrl('http://host/get.php?exp_date=2026-09-01'),
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
      expect(
        expiryFromPlaylistUrl('http://host/list.m3u?exp=not-a-date'),
        isNull,
      );
      expect(expiryFromPlaylistUrl('http://host/list.m3u?exp=0'), isNull);
    });
  });
}
