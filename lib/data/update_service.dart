import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'diagnostics_log.dart';
import 'net.dart';

/// GitHub repository the app publishes releases from (see
/// `.github/workflows/release.yml`). Used to build the releases API URL.
const String kGithubOwner = 'GCHOfficial';
const String kGithubRepo = 'iptvs';

/// The running app's version name — the build-name CI sets from the release tag
/// (`--build-name <tag-without-v>`), so a released build reports e.g. `1.2.3`
/// and compares equal to tag `v1.2.3`. Local `flutter run` builds report the
/// pubspec version (`1.0.0`).
Future<String> appVersion() async => (await PackageInfo.fromPlatform()).version;

/// A published GitHub release, reduced to what the updater needs. Kept free of
/// any `Source`/UI coupling so [fromJson] is a pure, unit-testable parser.
class ReleaseInfo {
  /// Release tag with the leading `v` stripped, e.g. `1.2.3`.
  final String version;

  /// The raw tag, e.g. `v1.2.3`.
  final String tagName;

  /// Human title (`iptvs 1.2.3`).
  final String name;

  /// Release body / changelog (markdown text; shown as-is).
  final String notes;

  /// The release page — the cross-platform browser fallback.
  final Uri htmlUrl;

  /// Direct download of the universal APK (`iptvs-<ver>-android.apk`).
  final Uri? androidAsset;
  final int? androidSize;

  /// Direct download of the portable Windows zip (`iptvs-<ver>-windows-x64.zip`).
  final Uri? windowsAsset;
  final int? windowsSize;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.androidAsset,
    this.androidSize,
    this.windowsAsset,
    this.windowsSize,
  });

  /// Parses a GitHub `releases/latest` JSON object. Returns null when the
  /// payload carries no usable tag. Assets are matched by filename (the
  /// `-android.apk` / windows `.zip` shapes produced by `release.yml`).
  static ReleaseInfo? fromJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String?)?.trim();
    if (tag == null || tag.isEmpty) return null;
    final version = (tag.startsWith('v') || tag.startsWith('V'))
        ? tag.substring(1)
        : tag;

    Uri? androidAsset;
    int? androidSize;
    Uri? windowsAsset;
    int? windowsSize;
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets.whereType<Map>()) {
        final name = (asset['name'] as String?)?.toLowerCase() ?? '';
        final url = asset['browser_download_url'] as String?;
        if (url == null) continue;
        final uri = Uri.tryParse(url);
        if (uri == null) continue;
        final size = (asset['size'] as num?)?.toInt();
        if (name.endsWith('.apk')) {
          androidAsset = uri;
          androidSize = size;
        } else if (name.contains('windows') && name.endsWith('.zip')) {
          windowsAsset = uri;
          windowsSize = size;
        }
      }
    }

    final htmlUrl =
        Uri.tryParse((json['html_url'] as String?) ?? '') ??
        Uri.parse('https://github.com/$kGithubOwner/$kGithubRepo/releases');
    final title = (json['name'] as String?)?.trim();

    return ReleaseInfo(
      version: version,
      tagName: tag,
      name: (title != null && title.isNotEmpty) ? title : 'iptvs $version',
      notes: (json['body'] as String?)?.trim() ?? '',
      htmlUrl: htmlUrl,
      androidAsset: androidAsset,
      androidSize: androidSize,
      windowsAsset: windowsAsset,
      windowsSize: windowsSize,
    );
  }

  /// The download URL for the running platform, or null if this release ships
  /// no matching asset (e.g. on macOS/Linux, where only the browser fallback
  /// applies).
  Uri? assetForCurrentPlatform() {
    if (Platform.isAndroid) return androidAsset;
    if (Platform.isWindows) return windowsAsset;
    return null;
  }

  /// Byte size of [assetForCurrentPlatform], for a determinate progress bar.
  int? sizeForCurrentPlatform() {
    if (Platform.isAndroid) return androidSize;
    if (Platform.isWindows) return windowsSize;
    return null;
  }
}

/// Queries GitHub for the latest release and reads the running app version.
/// Follows the `dart:io HttpClient` idiom used elsewhere (see
/// `mdblist_client.dart`) — GitHub's API rejects requests without a User-Agent.
class UpdateService {
  UpdateService({HttpClient? http, this.owner = kGithubOwner, this.repo = kGithubRepo})
    : _http = http ?? (HttpClient()..connectionTimeout = _connectTimeout);

  final HttpClient _http;
  final String owner;
  final String repo;

  static const _connectTimeout = Duration(seconds: 15);
  static const _userAgent = 'iptvs-updater';

  Uri get _latestUrl =>
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

  /// Fetches the latest *published* release (the `/latest` endpoint already
  /// excludes drafts and pre-releases). A 404 means no releases exist yet and
  /// is treated as "up to date" (null), not an error.
  Future<ReleaseInfo?> fetchLatest() async {
    final request = await _http.getUrl(_latestUrl);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close().timeout(kHttpReadTimeout);
    if (response.statusCode == 404) {
      await response.drain<void>();
      DiagnosticsLog.instance.add('update', 'No releases published yet');
      return null;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw StateError('GitHub HTTP ${response.statusCode}');
    }
    final data = jsonDecode(
      utf8.decode(await response.readBytes(), allowMalformed: true),
    );
    if (data is! Map) return null;
    final info = ReleaseInfo.fromJson(Map<String, dynamic>.from(data));
    if (info != null) {
      DiagnosticsLog.instance.add('update', 'Latest release ${info.tagName}');
    }
    return info;
  }

  Future<String> currentVersion() => appVersion();

  void close() => _http.close(force: true);
}

/// Compares two dotted numeric version strings. Build metadata (anything after
/// the first `+`, `-`, or space) is ignored, differing part counts are padded
/// (`1.2` == `1.2.0`), and parts compare numerically (`1.2.10` > `1.2.9`).
/// Returns <0 when [a] < [b], 0 when equal, >0 when [a] > [b].
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v.trim().split(RegExp(r'[+\- ]')).first;
    return core
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Whether [release] is strictly newer than the running [current] version.
bool isNewer(ReleaseInfo release, String current) =>
    compareVersions(release.version, current) > 0;

/// Throttle for the boot-time auto-check: run only if we've never checked or
/// the last check was at least [minGap] ago. Pure so it's unit-testable.
bool shouldAutoCheck(
  DateTime? lastCheck,
  DateTime now, {
  Duration minGap = const Duration(hours: 6),
}) {
  if (lastCheck == null) return true;
  return now.difference(lastCheck) >= minGap;
}
