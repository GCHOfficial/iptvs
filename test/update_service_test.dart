import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_service.dart';

ReleaseInfo _rel(String version) => ReleaseInfo(
  version: version,
  tagName: 'v$version',
  name: 'iptvs $version',
  notes: '',
  htmlUrl: Uri.parse('https://github.com/GCHOfficial/iptvs/releases'),
);

void main() {
  group('compareVersions', () {
    test('orders numerically, not lexically', () {
      expect(compareVersions('1.2.10', '1.2.3'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.10'), lessThan(0));
    });

    test('pads differing part counts', () {
      expect(compareVersions('1.2.0', '1.2'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });

    test('equal versions', () {
      expect(compareVersions('2.0.0', '2.0.0'), 0);
    });

    test('ignores build metadata / suffixes', () {
      expect(compareVersions('1.2.3+45', '1.2.3'), 0);
      expect(compareVersions('1.2.3-beta', '1.2.3'), 0);
    });

    test('major and minor take precedence', () {
      expect(compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.3.0', '1.2.9'), greaterThan(0));
    });
  });

  group('isNewer', () {
    test('true only when release is strictly newer', () {
      expect(isNewer(_rel('1.3.0'), '1.2.0'), isTrue);
      expect(isNewer(_rel('1.2.0'), '1.2.0'), isFalse);
      expect(isNewer(_rel('1.1.0'), '1.2.0'), isFalse);
    });
  });

  group('shouldAutoCheck', () {
    final now = DateTime(2026, 7, 10, 12);

    test('runs when never checked', () {
      expect(shouldAutoCheck(null, now), isTrue);
    });

    test('throttled within the gap, allowed after', () {
      expect(shouldAutoCheck(now.subtract(const Duration(hours: 1)), now), isFalse);
      expect(shouldAutoCheck(now.subtract(const Duration(hours: 5)), now), isFalse);
      expect(shouldAutoCheck(now.subtract(const Duration(hours: 7)), now), isTrue);
    });
  });

  group('ReleaseInfo.fromJson', () {
    test('parses tag, notes, and picks platform assets by filename', () {
      final json = <String, dynamic>{
        'tag_name': 'v1.4.2',
        'name': 'iptvs 1.4.2',
        'body': 'Release notes here',
        'html_url': 'https://github.com/GCHOfficial/iptvs/releases/tag/v1.4.2',
        'assets': [
          {
            'name': 'iptvs-1.4.2-android.apk',
            'browser_download_url':
                'https://example.com/iptvs-1.4.2-android.apk',
            'size': 12345,
          },
          {
            'name': 'iptvs-1.4.2-windows-x64.zip',
            'browser_download_url':
                'https://example.com/iptvs-1.4.2-windows-x64.zip',
            'size': 67890,
          },
        ],
      };
      final info = ReleaseInfo.fromJson(json)!;
      expect(info.version, '1.4.2');
      expect(info.tagName, 'v1.4.2');
      expect(info.name, 'iptvs 1.4.2');
      expect(info.notes, 'Release notes here');
      expect(info.androidAsset.toString(), contains('android.apk'));
      expect(info.androidSize, 12345);
      expect(info.windowsAsset.toString(), contains('windows-x64.zip'));
      expect(info.windowsSize, 67890);
    });

    test('strips the leading v and defaults the title', () {
      final info = ReleaseInfo.fromJson(<String, dynamic>{
        'tag_name': '2.0.0',
        'assets': <dynamic>[],
      })!;
      expect(info.version, '2.0.0');
      expect(info.name, 'iptvs 2.0.0');
      expect(info.androidAsset, isNull);
      expect(info.windowsAsset, isNull);
    });

    test('returns null without a tag', () {
      expect(ReleaseInfo.fromJson(<String, dynamic>{'name': 'x'}), isNull);
      expect(ReleaseInfo.fromJson(<String, dynamic>{'tag_name': ''}), isNull);
    });
  });
}
