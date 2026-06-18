// Unit tests for the IPTV app's pure logic.
//
// (Replaces the default counter widget test from `flutter create`, which
// referenced the old app and no longer applies.)

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/stalker_source.dart';
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

  group('MagIdentity', () {
    test('derives MAG identity fields from uppercase MAC', () {
      final identity = MagIdentity.fromMac('00:1a:79:12:34:56');

      expect(identity.mac, '00:1A:79:12:34:56');
      expect(identity.serial, '2213785DC6113');
      expect(
        identity.deviceId,
        '667094E7E8FF0347F6EC27A8E8115BE76E2AA9CD5C8F13C6FA00BCEDFAC02B41',
      );
      expect(identity.deviceId2, identity.deviceId);
      expect(
        identity.signature,
        '922F69DECA50A1E4883CDB6AF9A57D86B2C82BE460AE9AFCAF2B421C715A0D1B',
      );
      expect(identity.hwVersion2, 'A7B48B071A49ED4FE8EEF23EDE037A0BBC6C29D4');
    });

    test('builds strict get_profile params', () {
      final params = MagIdentity.fromMac(
        '00:1A:79:12:34:56',
      ).profileParams(profile: MagProfile.mag250, timestamp: 123456);

      expect(params['stb_type'], 'MAG250');
      expect(params['sn'], '2213785DC6113');
      expect(params['client_type'], 'STB');
      expect(params['auth_second_step'], '1');
      expect(params['not_valid_token'], '0');
      expect(params['device_id'], isNotEmpty);
      expect(params['device_id2'], params['device_id']);
      expect(params['signature'], isNotEmpty);
      expect(params['hw_version_2'], isNotEmpty);
      expect(params['metrics'], contains('"mac":"00:1A:79:12:34:56"'));
      expect(params['metrics'], contains('"model":"MAG250"'));
      expect(params['metrics'], contains('"random":"123456"'));
    });
  });

  group('stalkerItemIdentity', () {
    test('uses the first known stable id field', () {
      expect(stalkerItemIdentity({'id': 12}), 'id:12');
      expect(stalkerItemIdentity({'movie_id': 'm7'}), 'movie_id:m7');
      expect(stalkerItemIdentity({'video_id': 'v3'}), 'video_id:v3');
      expect(stalkerItemIdentity({'channel_id': 'c9'}), 'channel_id:c9');
      expect(stalkerItemIdentity({'ch_id': 'legacy'}), 'ch_id:legacy');
    });

    test('ignores missing and empty ids', () {
      expect(stalkerItemIdentity({'id': '', 'movie_id': 'm7'}), 'movie_id:m7');
      expect(stalkerItemIdentity({'name': 'No id'}), isNull);
    });
  });

  group('redactStalkerDiagnostic', () {
    test('removes common Stalker secrets', () {
      final redacted = redactStalkerDiagnostic(
        'mac=00:1A:79:12:34:56 token=abc123 Authorization: Bearer secret-token',
      );

      expect(redacted, isNot(contains('00:1A:79:12:34:56')));
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, isNot(contains('secret-token')));
      expect(redacted, contains('mac=<redacted>'));
      expect(redacted, contains('Bearer <redacted>'));
    });
  });
}
