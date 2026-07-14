import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int kReleaseManifestSchema = 1;
const int kMaxReleaseManifestBytes = 64 * 1024;
const int kMaxReleaseSignatureBytes = 1024;
const int kMaxAndroidUpdateBytes = 512 * 1024 * 1024;
const int kMaxWindowsUpdateBytes = 1024 * 1024 * 1024;

/// One installable file described by an authenticated release manifest.
class ReleaseArtifact {
  const ReleaseArtifact({
    required this.platform,
    required this.filename,
    required this.byteSize,
    required this.sha256,
  });

  final String platform;
  final String filename;
  final int byteSize;
  final String sha256;

  static ReleaseArtifact fromJson(Map<String, dynamic> json, String version) {
    final platform = json['platform'];
    final filename = json['filename'];
    final byteSize = json['byte_size'];
    final sha256 = json['sha256'];
    if (platform is! String || !{'android', 'windows-x64'}.contains(platform)) {
      throw const FormatException('Unsupported release platform');
    }
    final expectedFilename = platform == 'android'
        ? 'iptvs-$version-android.apk'
        : 'iptvs-$version-windows-x64.zip';
    if (filename is! String || filename != expectedFilename) {
      throw const FormatException('Unexpected release filename');
    }
    final maximum = platform == 'android'
        ? kMaxAndroidUpdateBytes
        : kMaxWindowsUpdateBytes;
    if (byteSize is! int || byteSize <= 0 || byteSize > maximum) {
      throw const FormatException('Invalid release artifact size');
    }
    if (sha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid release artifact SHA-256');
    }
    return ReleaseArtifact(
      platform: platform,
      filename: filename,
      byteSize: byteSize,
      sha256: sha256,
    );
  }
}

/// Exact metadata authenticated before an update download is trusted.
class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.minimumVersion,
    required this.artifacts,
  });

  final String version;
  final String minimumVersion;
  final Map<String, ReleaseArtifact> artifacts;

  static ReleaseManifest parse(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Release manifest must be an object');
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json['schema'] != kReleaseManifestSchema) {
      throw const FormatException('Unsupported release manifest schema');
    }
    final version = json['version'];
    final minimumVersion = json['minimum_version'];
    final versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
    if (version is! String || !versionPattern.hasMatch(version)) {
      throw const FormatException('Invalid release version');
    }
    if (minimumVersion is! String || !versionPattern.hasMatch(minimumVersion)) {
      throw const FormatException('Invalid minimum release version');
    }
    final rawArtifacts = json['artifacts'];
    if (rawArtifacts is! List || rawArtifacts.isEmpty) {
      throw const FormatException('Release manifest has no artifacts');
    }
    final artifacts = <String, ReleaseArtifact>{};
    for (final raw in rawArtifacts) {
      if (raw is! Map) {
        throw const FormatException('Invalid release artifact');
      }
      final artifact = ReleaseArtifact.fromJson(
        Map<String, dynamic>.from(raw),
        version,
      );
      if (artifacts.containsKey(artifact.platform)) {
        throw const FormatException('Duplicate release platform');
      }
      artifacts[artifact.platform] = artifact;
    }
    return ReleaseManifest(
      version: version,
      minimumVersion: minimumVersion,
      artifacts: Map.unmodifiable(artifacts),
    );
  }
}

/// Verifies the detached Ed25519 signature over the exact manifest bytes.
class ReleaseManifestVerifier {
  const ReleaseManifestVerifier();

  Future<ReleaseManifest> verify({
    required Uint8List manifestBytes,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    if (manifestBytes.isEmpty ||
        manifestBytes.length > kMaxReleaseManifestBytes) {
      throw const FormatException('Invalid release manifest size');
    }
    final publicKey = _decodeBase64(publicKeyBase64, 'public key');
    final signature = _decodeBase64(signatureBase64.trim(), 'signature');
    if (publicKey.length != 32 || signature.length != 64) {
      throw const FormatException('Invalid release signature material');
    }
    final valid = await Ed25519().verify(
      manifestBytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const FormatException('Invalid release manifest signature');
    }
    return ReleaseManifest.parse(manifestBytes);
  }

  Uint8List _decodeBase64(String value, String field) {
    try {
      return base64Decode(value);
    } on FormatException {
      throw FormatException('Invalid release $field encoding');
    }
  }
}
