import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/expiry_service.dart';

void main() {
  test('parses named month expiry strings', () {
    final dt = parseExpiryValue('June 19, 2026, 8:34 pm');
    expect(dt, isNotNull);
    expect(dt!.year, 2026);
    expect(dt.month, 6);
    expect(dt.day, 19);
    expect(dt.hour, 20);
    expect(dt.minute, 34);
  });
}
