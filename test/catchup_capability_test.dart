import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';
import 'package:iptvs/sources/demo_source.dart';

void main() {
  test('provider fixed offset wins over device timezone', () {
    final capability = const CatchupCapability(
      mode: CatchupUrlMode.xtreamTimeshift,
      fixedOffsetMinutes: 120,
    );
    final stamp = formatCatchupTime(
      DateTime.utc(2024, 7, 1, 10, 5),
      capability,
    );
    expect(stamp, '2024-07-01:12-05');
  });

  test('UTC conversion remains stable across DST boundaries', () {
    const capability = CatchupCapability(
      mode: CatchupUrlMode.xtreamTimeshift,
      timezone: 'UTC',
    );
    expect(
      formatCatchupTime(DateTime.utc(2024, 3, 31, 1, 30), capability),
      '2024-03-31:01-30',
    );
    expect(
      formatCatchupTime(DateTime.utc(2024, 10, 27, 1, 30), capability),
      '2024-10-27:01-30',
    );
  });

  test('IANA timezone conversion follows DST boundaries', () {
    const capability = CatchupCapability(
      mode: CatchupUrlMode.xtreamTimeshift,
      timezone: 'Europe/London',
    );
    expect(
      formatCatchupTime(DateTime.utc(2024, 3, 31, 0, 30), capability),
      '2024-03-31:00-30',
    );
    expect(
      formatCatchupTime(DateTime.utc(2024, 3, 31, 1, 30), capability),
      '2024-03-31:02-30',
    );
  });

  test('unsupported capability is explicit', () {
    final source = XtreamSource(
      sourceId: 'x',
      host: 'http://example.invalid',
      username: 'u',
      password: 'p',
    );
    expect(source.catchupCapability.supported, isTrue);
    expect(CatchupCapability.unsupported.supported, isFalse);
  });

  test('source capability reporting does not infer universal adaptiveness', () {
    final xtream = XtreamSource(
      sourceId: 'x',
      host: 'http://example.invalid',
      username: 'u',
      password: 'p',
    );
    expect(
      capabilitiesOf(xtream).resolution,
      ResolutionCapability.providerDefined,
    );
    expect(capabilitiesOf(DemoSource()).resolution, ResolutionCapability.fixed);
  });

  test(
    'Xtream prefers a provider-reported timezone when no override exists',
    () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://example.invalid',
        username: 'u',
        password: 'p',
        debugApi: (_) async => {
          'user_info': {'auth': 1},
          'server_info': {'timezone': 'Europe/London'},
        },
      );
      await source.connect();
      expect(source.catchupCapability.timezone, 'Europe/London');
    },
  );
}
