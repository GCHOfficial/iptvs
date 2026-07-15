import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:package_info_plus/package_info_plus.dart';

import 'diagnostics_log.dart';
import 'distribution_channel.dart';
import 'net.dart';
import 'update_manifest.dart';

/// GitHub repository the app publishes releases from (see
/// `.github/workflows/release.yml`). Used to build the releases API URL.
const String kGithubOwner = 'GCHOfficial';
const String kGithubRepo = 'iptvs';

/// Raw 32-byte Ed25519 public key, Base64 encoded at release build time.
const String kUpdateManifestPublicKey = String.fromEnvironment(
  'UPDATE_MANIFEST_PUBLIC_KEY',
);

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
  final ReleaseArtifact? androidArtifact;

  /// Direct download of the portable Windows zip (`iptvs-<ver>-windows-x64.zip`).
  final Uri? windowsAsset;
  final ReleaseArtifact? windowsArtifact;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.androidAsset,
    this.androidArtifact,
    this.windowsAsset,
    this.windowsArtifact,
  });

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
    if (Platform.isAndroid) return androidArtifact?.byteSize;
    if (Platform.isWindows) return windowsArtifact?.byteSize;
    return null;
  }

  ReleaseArtifact? artifactForCurrentPlatform() {
    if (Platform.isAndroid) return androidArtifact;
    if (Platform.isWindows) return windowsArtifact;
    return null;
  }
}

/// Queries GitHub for the latest release and reads the running app version.
/// Follows the `dart:io HttpClient` idiom used elsewhere (see
/// `mdblist_client.dart`) — GitHub's API rejects requests without a User-Agent.
class UpdateService {
  UpdateService({
    HttpClient? http,
    this.owner = kGithubOwner,
    this.repo = kGithubRepo,
    this.track = UpdateTrack.stable,
    this.manifestPublicKey = kUpdateManifestPublicKey,
    ReleaseManifestVerifier manifestVerifier = const ReleaseManifestVerifier(),
  }) : _http =
           http ??
           (HttpClient()
             ..connectionTimeout = _connectTimeout
             ..autoUncompress = false),
       _verifier = manifestVerifier;

  final HttpClient _http;
  final String owner;
  final String repo;
  final UpdateTrack track;
  final String manifestPublicKey;
  final ReleaseManifestVerifier _verifier;

  static const _connectTimeout = Duration(seconds: 15);
  static const _userAgent = 'iptvs-updater';
  Uri get _latestUrl => track == UpdateTrack.beta
      ? Uri.parse(
          'https://api.github.com/repos/$owner/$repo/releases?per_page=20',
        )
      : Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

  /// Fetches the latest *published* release (the `/latest` endpoint already
  /// excludes drafts and pre-releases). A 404 means no releases exist yet and
  /// is treated as "up to date" (null), not an error.
  Future<ReleaseInfo?> fetchLatest() async {
    final operation = HttpOperation(kUpdateDiscoveryWorkload);
    final response = await openApprovedUpdateGet(
      _http,
      _latestUrl,
      operation: operation,
      headers: const {
        HttpHeaders.acceptHeader: 'application/vnd.github+json',
        HttpHeaders.userAgentHeader: _userAgent,
      },
    );
    if (response.statusCode == 404) {
      await operation.readBytes(response);
      DiagnosticsLog.instance.add('update', 'No releases published yet');
      return null;
    }
    if (response.statusCode != 200) {
      await operation.readBytes(response);
      throw StateError('GitHub HTTP ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(await operation.readBytes(response)));
    final releaseJson = selectReleasePayload(data, track);
    if (releaseJson == null) return null;
    final discovery = _ReleaseDiscovery.fromJson(
      releaseJson,
      owner: owner,
      repo: repo,
    );
    if (discovery == null) return null;
    if (manifestPublicKey.isEmpty) {
      throw StateError('Update verification key is not configured');
    }
    final manifestBytes = await _getSmall(
      discovery.manifestUrl,
      kMaxReleaseManifestBytes,
    );
    final signatureBytes = await _getSmall(
      discovery.signatureUrl,
      kMaxReleaseSignatureBytes,
    );
    final manifest = await _verifier.verify(
      manifestBytes: manifestBytes,
      signatureBase64: utf8.decode(signatureBytes).trim(),
      publicKeyBase64: manifestPublicKey,
    );
    if (manifest.version != discovery.version) {
      throw const FormatException('Release version does not match manifest');
    }
    final android = manifest.artifacts['android'];
    final windows = manifest.artifacts['windows-x64'];
    final info = ReleaseInfo(
      version: manifest.version,
      tagName: discovery.tagName,
      name: discovery.name,
      notes: discovery.notes,
      htmlUrl: discovery.htmlUrl,
      androidAsset: android == null
          ? null
          : _artifactUrl(discovery.tagName, android.filename),
      androidArtifact: android,
      windowsAsset: windows == null
          ? null
          : _artifactUrl(discovery.tagName, windows.filename),
      windowsArtifact: windows,
    );
    DiagnosticsLog.instance.add('update', 'Verified release ${info.tagName}');
    return info;
  }

  Uri _artifactUrl(String tag, String filename) =>
      Uri.https('github.com', '/$owner/$repo/releases/download/$tag/$filename');

  Future<Uint8List> _getSmall(Uri url, int maximumBytes) async {
    if (!isApprovedUpdateUri(url)) {
      throw const FormatException('Unapproved update host');
    }
    final operation = HttpOperation(
      kUpdateDiscoveryWorkload.copyWith(
        name: 'update metadata',
        maximumBodyBytes: maximumBytes,
        maximumDecodedBytes: maximumBytes,
      ),
    );
    final response = await openApprovedUpdateGet(
      _http,
      url,
      operation: operation,
      headers: const {HttpHeaders.userAgentHeader: _userAgent},
    );
    if (response.statusCode != 200) {
      await operation.readBytes(response);
      throw StateError('Update metadata HTTP ${response.statusCode}');
    }
    return operation.readBytes(response);
  }

  Future<String> currentVersion() => appVersion();

  void close() => _http.close(force: true);
}

Map<String, dynamic>? selectReleasePayload(Object? data, UpdateTrack track) {
  if (track == UpdateTrack.stable) {
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }
  if (data is! List) return null;
  Map<String, dynamic>? selected;
  String? selectedVersion;
  for (final raw in data.whereType<Map>()) {
    final release = Map<String, dynamic>.from(raw);
    if (release['draft'] == true) continue;
    final tag = (release['tag_name'] as String?)?.trim();
    if (tag == null || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) continue;
    final version = tag.substring(1);
    if (selectedVersion == null ||
        compareVersions(version, selectedVersion) > 0) {
      selected = release;
      selectedVersion = version;
    }
  }
  return selected;
}

bool isApprovedUpdateUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    const {
      'api.github.com',
      'github.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
    }.contains(uri.host.toLowerCase());

/// Resolves one HTTP Location value and rejects it before any connection is
/// made unless the destination remains on approved HTTPS release
/// infrastructure. Relative redirects are resolved against [current].
Uri resolveApprovedUpdateRedirect(Uri current, String location) {
  final parsed = Uri.tryParse(location);
  if (parsed == null) {
    throw const FormatException('Invalid update redirect');
  }
  final resolved = current.resolveUri(parsed);
  if (!isApprovedUpdateUri(resolved)) {
    throw const FormatException('Unapproved update redirect');
  }
  return resolved;
}

/// Opens a GET while manually validating each redirect before following it.
/// `HttpClient` normally follows first and only reports the redirect chain on
/// the final response, which is too late for a security boundary.
Future<HttpClientResponse> openApprovedUpdateGet(
  HttpClient http,
  Uri initial, {
  required HttpOperation operation,
  Map<String, String> headers = const {},
  int maximumRedirects = 5,
}) async {
  if (!isApprovedUpdateUri(initial)) {
    throw const FormatException('Unapproved update host');
  }
  var current = initial;
  for (var redirects = 0; redirects <= maximumRedirects; redirects++) {
    final request = await operation.wait(http.getUrl(current));
    request.followRedirects = false;
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await operation.wait(request.close());
    if (!response.isRedirect) return response;

    final location = response.headers.value(HttpHeaders.locationHeader);
    await operation.readBytes(response);
    if (location == null || location.trim().isEmpty) {
      throw const FormatException('Update redirect has no destination');
    }
    if (redirects == maximumRedirects) {
      throw const FormatException('Too many update redirects');
    }
    current = resolveApprovedUpdateRedirect(current, location);
  }
  throw const FormatException('Too many update redirects');
}

class _ReleaseDiscovery {
  const _ReleaseDiscovery({
    required this.version,
    required this.tagName,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    required this.manifestUrl,
    required this.signatureUrl,
  });

  final String version;
  final String tagName;
  final String name;
  final String notes;
  final Uri htmlUrl;
  final Uri manifestUrl;
  final Uri signatureUrl;

  static _ReleaseDiscovery? fromJson(
    Map<String, dynamic> json, {
    required String owner,
    required String repo,
  }) {
    final tag = (json['tag_name'] as String?)?.trim();
    if (tag == null || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
      return null;
    }
    final version = tag.substring(1);
    final manifestName = 'iptvs-$version-manifest.json';
    final signatureName = '$manifestName.sig';
    Uri? manifestUrl;
    Uri? signatureUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final raw in assets.whereType<Map>()) {
        final name = raw['name'];
        final url = raw['browser_download_url'];
        if (name is! String || url is! String) continue;
        final uri = Uri.tryParse(url);
        if (uri == null || !isApprovedUpdateUri(uri)) continue;
        if (name == manifestName) manifestUrl = uri;
        if (name == signatureName) signatureUrl = uri;
      }
    }
    if (manifestUrl == null || signatureUrl == null) {
      throw const FormatException('Release is missing signed update metadata');
    }
    final title = (json['name'] as String?)?.trim();
    return _ReleaseDiscovery(
      version: version,
      tagName: tag,
      name: title == null || title.isEmpty ? 'IPTVS Player $version' : title,
      notes: (json['body'] as String?)?.trim() ?? '',
      htmlUrl: Uri.https('github.com', '/$owner/$repo/releases/tag/$tag'),
      manifestUrl: manifestUrl,
      signatureUrl: signatureUrl,
    );
  }
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

const bool _developerDowngradeOverride = bool.fromEnvironment(
  'ALLOW_UPDATE_DOWNGRADE',
);

/// Release builds always require a strict upgrade. A local debug build may opt
/// into downgrade testing with an explicitly named compile-time override.
bool isUpdateAllowed(
  ReleaseInfo release,
  String current, {
  bool developerDowngradeOverride = _developerDowngradeOverride,
}) {
  final comparison = compareVersions(release.version, current);
  if (comparison > 0) return true;
  return developerDowngradeOverride &&
      !const bool.fromEnvironment('dart.vm.product');
}

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
