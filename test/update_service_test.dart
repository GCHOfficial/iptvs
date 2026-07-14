import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/distribution_channel.dart';
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

  group('isUpdateAllowed', () {
    test('rejects same-version installs and downgrades by default', () {
      expect(isUpdateAllowed(_rel('1.2.0'), '1.2.0'), isFalse);
      expect(isUpdateAllowed(_rel('1.1.9'), '1.2.0'), isFalse);
    });

    test('allows an explicitly labelled local downgrade override', () {
      expect(
        isUpdateAllowed(
          _rel('1.1.9'),
          '1.2.0',
          developerDowngradeOverride: true,
        ),
        isTrue,
      );
    });
  });

  group('release track selection', () {
    test('stable consumes the latest-release object', () {
      final payload = {'tag_name': 'v1.2.3'};
      expect(
        selectReleasePayload(payload, UpdateTrack.stable)?['tag_name'],
        'v1.2.3',
      );
    });

    test('beta selects the highest non-draft stable or prerelease', () {
      final payload = [
        {'tag_name': 'v1.2.4', 'prerelease': true, 'draft': true},
        {'tag_name': 'v1.2.3', 'prerelease': false, 'draft': false},
        {'tag_name': 'v1.3.0', 'prerelease': true, 'draft': false},
        {'tag_name': 'not-semver', 'prerelease': true, 'draft': false},
      ];
      expect(
        selectReleasePayload(payload, UpdateTrack.beta)?['tag_name'],
        'v1.3.0',
      );
    });
  });

  group('shouldAutoCheck', () {
    final now = DateTime(2026, 7, 10, 12);

    test('runs when never checked', () {
      expect(shouldAutoCheck(null, now), isTrue);
    });

    test('throttled within the gap, allowed after', () {
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 1)), now),
        isFalse,
      );
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 5)), now),
        isFalse,
      );
      expect(
        shouldAutoCheck(now.subtract(const Duration(hours: 7)), now),
        isTrue,
      );
    });
  });

  group('approved update URLs', () {
    test('accepts HTTPS GitHub release infrastructure', () {
      expect(
        isApprovedUpdateUri(
          Uri.parse(
            'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/x',
          ),
        ),
        isTrue,
      );
      expect(
        isApprovedUpdateUri(
          Uri.parse('https://release-assets.githubusercontent.com/file'),
        ),
        isTrue,
      );
    });

    test('rejects HTTP, user-controlled hosts, and lookalike suffixes', () {
      expect(isApprovedUpdateUri(Uri.parse('http://github.com/file')), isFalse);
      expect(
        isApprovedUpdateUri(Uri.parse('https://example.com/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://github.com.example.com/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://github.com:444/file')),
        isFalse,
      );
      expect(
        isApprovedUpdateUri(Uri.parse('https://user@github.com/file')),
        isFalse,
      );
    });

    test('resolves an approved relative redirect', () {
      expect(
        resolveApprovedUpdateRedirect(
          Uri.parse('https://github.com/GCHOfficial/iptvs/releases'),
          '/GCHOfficial/iptvs/releases/download/v1.2.3/file.apk',
        ),
        Uri.parse(
          'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/file.apk',
        ),
      );
    });

    test('rejects an unapproved redirect before it can be followed', () {
      for (final location in [
        'https://example.com/payload.apk',
        'http://github.com/payload.apk',
        'https://github.com.example.com/payload.apk',
        'https://github.com:444/payload.apk',
      ]) {
        expect(
          () => resolveApprovedUpdateRedirect(
            Uri.parse('https://github.com/release'),
            location,
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });
}
