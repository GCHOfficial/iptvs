// Generates/updates the AltStore Classic source manifest — the JSON feed
// AltStore polls to offer updates. This replaces the in-app updater on iOS,
// which is impossible inside the sandbox (see docs/ios.md "Why not the App
// Store" and "No direct updater on iOS, ever").
//
// Usage (see docs/ios.md "Source manifest" for the schema rationale):
//   dart run tool/generate_altstore_source.dart \
//     --source altstore/source.json \
//     --version 1.2.3 \
//     --build 45 \
//     --download-url https://github.com/GCHOfficial/iptvs/releases/download/v1.2.3/iptvs-1.2.3-ios.ipa \
//     --size 87654321 \
//     [--date 2026-07-29T12:00:00Z] \
//     [--changelog "..." | --changelog-file body.md] \
//     [--source-name "..."] [--app-name "..."] [--bundle-id "..."] \
//     [--developer-name "..."] [--app-description "..."] [--icon-url "..."]
//
// Idempotent by design: re-running with the same --version/--build pair is a
// no-op (the manifest already carries that release). Otherwise the new
// version entry is *prepended* to the app's `versions` array so history is
// preserved — AltStore uses that history to offer downgrades.
//
// `marketplaceID` is never emitted: that field is PAL-only, and AltStore PAL
// was deliberately dropped (docs/ios.md "Decision: AltStore PAL dropped").
library;

import 'dart:convert';
import 'dart:io';

/// Reverse-DNS bundle identifier for the AltStore Classic sideload channel.
/// Case-sensitive; must match `ios/Runner/Info.plist` exactly once that is
/// wired up (docs/ios.md "Bundle identities").
const String kDefaultBundleIdentifier = 'com.gchofficial.iptvs.player.sideload';

/// Reserved public product name (docs/store-publishing.md).
const String kDefaultAppName = 'IPTVS Player';

const String kDefaultSourceName = 'IPTVS Player AltStore Source';

/// Matches the Windows Store `PublisherDisplayName` identity
/// (docs/store-publishing.md) so the developer name is consistent across
/// distribution channels.
const String kDefaultDeveloperName = 'George-Cosmin Hanta';

/// Keep in sync with the `description:` field in pubspec.yaml.
const String kDefaultAppDescription =
    'Cross-platform IPTV player with true HDR and Android TV support.';

const String kDefaultIconURL =
    'https://raw.githubusercontent.com/GCHOfficial/iptvs/main/assets/icon/icon.png';

/// No entitlements or privacy-sensitive APIs are declared yet. Update this
/// alongside Info.plist when iOS work adds any (docs/ios.md "Other work
/// required" — e.g. the ATS arbitrary-loads exception is a build setting,
/// not a runtime permission, so it does not belong here).
const Map<String, dynamic> kDefaultAppPermissions = {
  'entitlements': <String>[],
  'privacy': <String, dynamic>{},
};

/// One entry in an app's `versions` array. Required fields per docs/ios.md
/// "Source manifest": `version` (CFBundleShortVersionString), `buildVersion`
/// (CFBundleVersion), `date` (ISO 8601), `downloadURL`, `size` (bytes).
/// `localizedDescription` here is optional per-version release notes (the AI
/// changelog release.yml already generates), distinct from the app-level
/// `localizedDescription` (the static app description).
class AltStoreVersionEntry {
  const AltStoreVersionEntry({
    required this.version,
    required this.buildVersion,
    required this.date,
    required this.downloadURL,
    required this.size,
    this.localizedDescription,
  });

  final String version;
  final String buildVersion;

  /// ISO 8601 timestamp string.
  final String date;
  final String downloadURL;
  final int size;
  final String? localizedDescription;

  Map<String, dynamic> toJson() => {
    'version': version,
    'buildVersion': buildVersion,
    'date': date,
    'downloadURL': downloadURL,
    'size': size,
    if (localizedDescription != null && localizedDescription!.isNotEmpty)
      'localizedDescription': localizedDescription,
  };
}

/// Pure logic: builds (or updates) the AltStore source JSON object from an
/// optional existing manifest plus one new release. No file/network I/O —
/// callers (including tests) pass the decoded existing manifest in and get
/// the decoded new manifest back.
///
/// Idempotent: if `newVersion.version` + `newVersion.buildVersion` already
/// has a matching entry in the app's `versions` array, that array is left
/// untouched (no duplicate, no field-level overwrite of the existing entry).
/// Otherwise the new entry is prepended, preserving history for downgrades.
Map<String, dynamic> buildAltStoreSource({
  required Map<String, dynamic>? existing,
  required AltStoreVersionEntry newVersion,
  String sourceName = kDefaultSourceName,
  String appName = kDefaultAppName,
  String bundleIdentifier = kDefaultBundleIdentifier,
  String developerName = kDefaultDeveloperName,
  String appDescription = kDefaultAppDescription,
  String iconURL = kDefaultIconURL,
  Map<String, dynamic> appPermissions = kDefaultAppPermissions,
}) {
  final existingApps = (existing?['apps'] as List?) ?? const [];
  Map<String, dynamic>? matchedApp;
  final otherApps = <Map<String, dynamic>>[];
  for (final raw in existingApps) {
    final app = Map<String, dynamic>.from(raw as Map);
    if (matchedApp == null && app['bundleIdentifier'] == bundleIdentifier) {
      matchedApp = app;
    } else {
      otherApps.add(app);
    }
  }

  final existingVersions = matchedApp == null
      ? <Map<String, dynamic>>[]
      : List<Map<String, dynamic>>.from(
          ((matchedApp['versions'] as List?) ?? const []).map(
            (raw) => Map<String, dynamic>.from(raw as Map),
          ),
        );

  final alreadyPresent = existingVersions.any(
    (entry) =>
        entry['version'] == newVersion.version &&
        entry['buildVersion'] == newVersion.buildVersion,
  );

  final versions = alreadyPresent
      ? existingVersions
      : <Map<String, dynamic>>[newVersion.toJson(), ...existingVersions];

  final app = <String, dynamic>{
    'name': appName,
    'bundleIdentifier': bundleIdentifier,
    'developerName': developerName,
    'localizedDescription': appDescription,
    'iconURL': iconURL,
    'versions': versions,
    'appPermissions': appPermissions,
  };

  return <String, dynamic>{
    'name': sourceName,
    'apps': [app, ...otherApps],
    'news': (existing?['news'] as List?) ?? const [],
  };
}

class _UsageException implements Exception {
  _UsageException(this.message);
  final String message;
}

const String _usage = '''
Usage: dart run tool/generate_altstore_source.dart
  --source <path>          Path to the AltStore source JSON (created if missing)
  --version <str>           CFBundleShortVersionString for this release
  --build <str>              CFBundleVersion for this release
  --download-url <url>       .ipa download URL for this release
  --size <bytes>              .ipa file size in bytes

Optional:
  --date <iso8601>            Defaults to now (UTC)
  --changelog <text>          Per-version release notes
  --changelog-file <path>     Read release notes from a file instead
  --source-name <str>
  --app-name <str>
  --bundle-id <str>
  --developer-name <str>
  --app-description <str>
  --icon-url <str>''';

class _Options {
  _Options({
    required this.sourcePath,
    required this.sourceName,
    required this.appName,
    required this.bundleIdentifier,
    required this.developerName,
    required this.appDescription,
    required this.iconURL,
    required this.newVersion,
  });

  final String sourcePath;
  final String sourceName;
  final String appName;
  final String bundleIdentifier;
  final String developerName;
  final String appDescription;
  final String iconURL;
  final AltStoreVersionEntry newVersion;

  static _Options parse(List<String> args) {
    final flags = <String, String>{};
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        throw _UsageException('Unexpected argument: $arg');
      }
      final body = arg.substring(2);
      final eq = body.indexOf('=');
      if (eq != -1) {
        flags[body.substring(0, eq)] = body.substring(eq + 1);
        i++;
        continue;
      }
      if (i + 1 >= args.length) {
        throw _UsageException('Missing value for --$body');
      }
      flags[body] = args[i + 1];
      i += 2;
    }

    String require(String name) {
      final value = flags[name];
      if (value == null || value.isEmpty) {
        throw _UsageException('Missing required --$name');
      }
      return value;
    }

    final sourcePath = require('source');
    final version = require('version');
    final buildVersion = require('build');
    final downloadURL = require('download-url');
    final sizeRaw = require('size');
    final size = int.tryParse(sizeRaw);
    if (size == null || size <= 0) {
      throw _UsageException(
        '--size must be a positive integer, got: $sizeRaw',
      );
    }

    if (flags.containsKey('changelog') &&
        flags.containsKey('changelog-file')) {
      throw _UsageException(
        'Pass only one of --changelog / --changelog-file',
      );
    }
    String? changelog = flags['changelog'];
    final changelogFile = flags['changelog-file'];
    if (changelogFile != null) {
      changelog = File(changelogFile).readAsStringSync().trim();
    }

    final date = flags['date'] ?? DateTime.now().toUtc().toIso8601String();
    if (DateTime.tryParse(date) == null) {
      throw _UsageException(
        '--date is not a valid ISO 8601 timestamp: $date',
      );
    }

    return _Options(
      sourcePath: sourcePath,
      sourceName: flags['source-name'] ?? kDefaultSourceName,
      appName: flags['app-name'] ?? kDefaultAppName,
      bundleIdentifier: flags['bundle-id'] ?? kDefaultBundleIdentifier,
      developerName: flags['developer-name'] ?? kDefaultDeveloperName,
      appDescription: flags['app-description'] ?? kDefaultAppDescription,
      iconURL: flags['icon-url'] ?? kDefaultIconURL,
      newVersion: AltStoreVersionEntry(
        version: version,
        buildVersion: buildVersion,
        date: date,
        downloadURL: downloadURL,
        size: size,
        localizedDescription: (changelog == null || changelog.isEmpty)
            ? null
            : changelog,
      ),
    );
  }
}

void main(List<String> arguments) {
  try {
    final options = _Options.parse(arguments);
    final sourceFile = File(options.sourcePath);
    Map<String, dynamic>? existing;
    if (sourceFile.existsSync()) {
      final raw = sourceFile.readAsStringSync().trim();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw _UsageException(
            'Existing source at ${options.sourcePath} is not a JSON object',
          );
        }
        existing = Map<String, dynamic>.from(decoded);
      }
    }

    final alreadyPresent = existing != null &&
        ((existing['apps'] as List?) ?? const []).any((raw) {
          final app = Map<String, dynamic>.from(raw as Map);
          if (app['bundleIdentifier'] != options.bundleIdentifier) {
            return false;
          }
          return ((app['versions'] as List?) ?? const []).any((raw) {
            final entry = Map<String, dynamic>.from(raw as Map);
            return entry['version'] == options.newVersion.version &&
                entry['buildVersion'] == options.newVersion.buildVersion;
          });
        });

    final result = buildAltStoreSource(
      existing: existing,
      newVersion: options.newVersion,
      sourceName: options.sourceName,
      appName: options.appName,
      bundleIdentifier: options.bundleIdentifier,
      developerName: options.developerName,
      appDescription: options.appDescription,
      iconURL: options.iconURL,
    );

    const encoder = JsonEncoder.withIndent('  ');
    sourceFile.createSync(recursive: true);
    sourceFile.writeAsStringSync('${encoder.convert(result)}\n');

    stdout.writeln(
      alreadyPresent
          ? 'AltStore source already has ${options.newVersion.version} '
                '(build ${options.newVersion.buildVersion}); no-op.'
          : 'Wrote AltStore source ${options.sourcePath} with '
                '${options.newVersion.version} '
                '(build ${options.newVersion.buildVersion}).',
    );
  } on _UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(_usage);
    exit(2);
  } on FormatException catch (e) {
    stderr.writeln('generate_altstore_source: $e');
    exit(1);
  }
}
