import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/m3u_source.dart';

void main() {
  test('extracts Xtream credentials from userinfo in playlist URL', () {
    final creds = M3uSource.extractXtreamCredentials(
      Uri.parse('http://user:pw@example.com:8080/get.php?type=m3u'),
    );

    expect(creds, isNotNull);
    expect(creds!.host, 'http://example.com:8080');
    expect(creds.username, 'user');
    expect(creds.password, 'pw');
  });

  test('extracts Xtream credentials from query parameters', () {
    final creds = M3uSource.extractXtreamCredentials(
      Uri.parse('http://example.com/get.php?username=user&password=pw&type=m3u'),
    );

    expect(creds, isNotNull);
    expect(creds!.host, 'http://example.com');
    expect(creds.username, 'user');
    expect(creds.password, 'pw');
  });

  test('returns null when playlist URL has no valid Xtream credentials', () {
    final creds = M3uSource.extractXtreamCredentials(
      Uri.parse('http://example.com/get.php?type=m3u'),
    );

    expect(creds, isNull);
  });
}
