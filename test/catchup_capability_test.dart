import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

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
}
