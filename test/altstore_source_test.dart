// Tests for tool/generate_altstore_source.dart — the AltStore Classic source
// manifest generator (docs/ios.md "Source manifest"). Pure-logic coverage of
// buildAltStoreSource() plus one end-to-end CLI run confined to a temp dir;
// no network access anywhere.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tool/generate_altstore_source.dart';

AltStoreVersionEntry _version({
  String version = '1.2.3',
  String buildVersion = '45',
  String date = '2026-07-29T12:00:00Z',
  String downloadURL =
      'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/iptvs-1.2.3-ios.ipa',
  int size = 87654321,
  String? localizedDescription,
}) => AltStoreVersionEntry(
  version: version,
  buildVersion: buildVersion,
  date: date,
  downloadURL: downloadURL,
  size: size,
  localizedDescription: localizedDescription,
);

void main() {
  group('buildAltStoreSource', () {
    test('fresh manifest carries every required field', () {
      final source = buildAltStoreSource(
        existing: null,
        newVersion: _version(localizedDescription: '## Highlights\n- Fixed things'),
      );

      expect(source['name'], isA<String>());
      expect(source['news'], isA<List>());
      expect(source, isNot(contains('marketplaceID')));

      final apps = source['apps'] as List;
      expect(apps, hasLength(1));
      final app = apps.single as Map<String, dynamic>;
      for (final key in [
        'name',
        'bundleIdentifier',
        'developerName',
        'localizedDescription',
        'iconURL',
        'versions',
        'appPermissions',
      ]) {
        expect(app, contains(key), reason: 'app missing required field $key');
      }
      expect(app['bundleIdentifier'], 'com.gchofficial.iptvs.player.sideload');
      expect(app, isNot(contains('marketplaceID')));

      final versions = app['versions'] as List;
      expect(versions, hasLength(1));
      final entry = versions.single as Map<String, dynamic>;
      for (final key in [
        'version',
        'buildVersion',
        'date',
        'downloadURL',
        'size',
      ]) {
        expect(entry, contains(key), reason: 'version missing required field $key');
      }
      expect(entry['version'], '1.2.3');
      expect(entry['buildVersion'], '45');
      expect(entry['size'], 87654321);
      expect(entry['localizedDescription'], '## Highlights\n- Fixed things');
      expect(entry, isNot(contains('marketplaceID')));
    });

    test('a second version is prepended and history is preserved', () {
      final first = buildAltStoreSource(
        existing: null,
        newVersion: _version(version: '1.0.0', buildVersion: '10'),
      );

      final second = buildAltStoreSource(
        existing: first,
        newVersion: _version(
          version: '1.1.0',
          buildVersion: '11',
          downloadURL:
              'https://github.com/GCHOfficial/iptvs/releases/download/v1.1.0/iptvs-1.1.0-ios.ipa',
        ),
      );

      final versions =
          ((second['apps'] as List).single as Map<String, dynamic>)['versions']
              as List;
      expect(versions, hasLength(2));
      expect((versions[0] as Map)['version'], '1.1.0');
      expect((versions[1] as Map)['version'], '1.0.0');
    });

    test('re-running for an already-present version is a no-op', () {
      final first = buildAltStoreSource(
        existing: null,
        newVersion: _version(version: '1.0.0', buildVersion: '10'),
      );

      final rerun = buildAltStoreSource(
        existing: first,
        newVersion: _version(
          version: '1.0.0',
          buildVersion: '10',
          // Different metadata for the *same* version+build must not
          // overwrite the existing entry or add a duplicate.
          downloadURL: 'https://example.invalid/should-not-be-used.ipa',
          size: 1,
        ),
      );

      final app = (rerun['apps'] as List).single as Map<String, dynamic>;
      final versionList = app['versions'] as List;
      expect(versionList, hasLength(1));
      final entry = versionList.single as Map<String, dynamic>;
      expect(entry['downloadURL'], isNot('https://example.invalid/should-not-be-used.ipa'));
      expect(entry['size'], isNot(1));

      // A byte-identical rebuild should also be a stable fixed point.
      final rerunAgain = buildAltStoreSource(
        existing: rerun,
        newVersion: _version(version: '1.0.0', buildVersion: '10'),
      );
      expect(jsonEncode(rerunAgain), jsonEncode(rerun));
    });

    test('a different bundle identifier keeps its own app entry untouched', () {
      final existing = {
        'name': 'IPTVS Player AltStore Source',
        'apps': [
          {
            'name': 'Other App',
            'bundleIdentifier': 'com.example.other',
            'developerName': 'Someone',
            'localizedDescription': 'unrelated',
            'iconURL': 'https://example.invalid/icon.png',
            'versions': <Map<String, dynamic>>[],
            'appPermissions': {'entitlements': <String>[], 'privacy': {}},
          },
        ],
        'news': [],
      };

      final result = buildAltStoreSource(
        existing: existing,
        newVersion: _version(),
      );

      final apps = result['apps'] as List;
      expect(apps, hasLength(2));
      final other = apps.firstWhere(
        (app) => (app as Map)['bundleIdentifier'] == 'com.example.other',
      );
      expect(other, (existing['apps'] as List).single);
    });
  });

  group('generate_altstore_source.dart CLI', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iptvs-altstore-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<ProcessResult> run(List<String> args) {
      final scriptPath = p.join(
        Directory.current.path,
        'tool',
        'generate_altstore_source.dart',
      );
      return Process.run('dart', [
        'run',
        scriptPath,
        ...args,
      ], runInShell: true).timeout(const Duration(seconds: 60));
    }

    test('writes a fresh manifest to a new path', () async {
      final sourcePath = p.join(tempDir.path, 'source.json');

      final result = await run([
        '--source', sourcePath,
        '--version', '1.2.3',
        '--build', '45',
        '--download-url',
        'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/iptvs-1.2.3-ios.ipa',
        '--size', '87654321',
        '--date', '2026-07-29T12:00:00Z',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final file = File(sourcePath);
      expect(file.existsSync(), isTrue);
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(decoded, isNot(contains('marketplaceID')));
      final app = (decoded['apps'] as List).single as Map<String, dynamic>;
      expect(app['bundleIdentifier'], 'com.gchofficial.iptvs.player.sideload');
      final entry = (app['versions'] as List).single as Map<String, dynamic>;
      expect(entry['version'], '1.2.3');
      expect(entry['buildVersion'], '45');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('re-running for the same release does not duplicate the entry', () async {
      final sourcePath = p.join(tempDir.path, 'source.json');
      final args = [
        '--source', sourcePath,
        '--version', '1.2.3',
        '--build', '45',
        '--download-url',
        'https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/iptvs-1.2.3-ios.ipa',
        '--size', '87654321',
        '--date', '2026-07-29T12:00:00Z',
      ];

      final first = await run(args);
      expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
      final second = await run(args);
      expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');

      final decoded =
          jsonDecode(await File(sourcePath).readAsString()) as Map<String, dynamic>;
      final app = (decoded['apps'] as List).single as Map<String, dynamic>;
      expect(app['versions'], hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
