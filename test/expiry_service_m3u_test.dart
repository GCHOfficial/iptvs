import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/expiry_service.dart';

void main() {
  test('parses encoded M3U expiry timestamp', () {
    final dt = parseExpiryValue('http://example.com/get.php?username=user&password=pw&exp=1767225600');
    expect(dt, isNotNull);
    expect(dt!.year, 2026);
  });

  test('parses encoded M3U expiry ISO date', () {
    final dt = parseExpiryValue('http://example.com/get.php?username=user&password=pw&expiry=2026-12-31');
    expect(dt, isNotNull);
    expect(dt!.year, 2026);
    expect(dt.month, 12);
    expect(dt.day, 31);
  });

  test('does not treat unrelated query params as expiry', () {
    final dt = parseExpiryValue('http://example.com/get.php?username=user&password=pw&sid=1767225600');
    expect(dt, isNull);
  });

  test('extracts Xtream credentials from an M3U playlist URL', () {
    final creds = extractXtreamCredentials(Uri.parse('http://user:pw@example.com:8080/get.php?type=m3u')); 
    expect(creds, isNotNull);
    expect(creds!.host, 'http://example.com:8080');
    expect(creds.username, 'user');
    expect(creds.password, 'pw');
  });

  test('extracts Xtream credentials from query parameters', () {
    final creds = extractXtreamCredentials(Uri.parse('http://example.com/get.php?username=user&password=pw&type=m3u')); 
    expect(creds, isNotNull);
    expect(creds!.host, 'http://example.com');
    expect(creds.username, 'user');
    expect(creds.password, 'pw');
  });
}
