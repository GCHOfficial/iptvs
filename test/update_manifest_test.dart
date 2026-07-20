import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_manifest.dart';

Uint8List _manifestBytes({
  String version = '1.4.2',
  String platform = 'android',
  String filename = 'iptvs-1.4.2-android.apk',
  int byteSize = 12345,
  String sha256 =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 1,
      'version': version,
      'minimum_version': '1.0.0',
      'artifacts': [
        {
          'platform': platform,
          'filename': filename,
          'byte_size': byteSize,
          'sha256': sha256,
        },
      ],
    }),
  ),
);

Future<({String publicKey, String signature})> _sign(Uint8List bytes) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final signature = await algorithm.sign(bytes, keyPair: keyPair);
  return (
    publicKey: base64Encode(publicKey.bytes),
    signature: base64Encode(signature.bytes),
  );
}

void main() {
  const verifier = ReleaseManifestVerifier();

  test(
    'accepts a detached signature produced by the CI OpenSSL commands',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode(
          '{"schema":1,"version":"1.4.2","minimum_version":"0.1.0",'
          '"artifacts":[{"platform":"android",'
          '"filename":"iptvs-1.4.2-android.apk","byte_size":5,'
          '"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}',
        ),
      );

      final manifest = await verifier.verify(
        manifestBytes: bytes,
        signatureBase64:
            '62k6SPfz0orSnznIRn5LDfoRL4+zpFFlg15YPSNW1TGvXBXUOVqsU6ybbBz6VUh9brofaE7r/8COKZoTBgX0Bg==',
        publicKeyBase64: 'i6CuVlUd5rYtdQOIHmznHE70sizci80VJ/IvEZCnyAw=',
      );

      expect(manifest.version, '1.4.2');
    },
  );

  test('accepts a valid signature over the exact manifest bytes', () async {
    final bytes = _manifestBytes();
    final signed = await _sign(bytes);

    final manifest = await verifier.verify(
      manifestBytes: bytes,
      signatureBase64: signed.signature,
      publicKeyBase64: signed.publicKey,
    );

    expect(manifest.version, '1.4.2');
    expect(manifest.minimumVersion, '1.0.0');
    expect(manifest.artifacts['android']?.filename, 'iptvs-1.4.2-android.apk');
  });

  test('rejects a manifest changed after signing', () async {
    final original = _manifestBytes();
    final signed = await _sign(original);
    final altered = _manifestBytes(byteSize: 12346);

    await expectLater(
      verifier.verify(
        manifestBytes: altered,
        signatureBase64: signed.signature,
        publicKeyBase64: signed.publicKey,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a signature made by another key', () async {
    final bytes = _manifestBytes();
    final signer = await _sign(bytes);
    final other = await _sign(bytes);

    await expectLater(
      verifier.verify(
        manifestBytes: bytes,
        signatureBase64: signer.signature,
        publicKeyBase64: other.publicKey,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects filename not bound to platform and version', () async {
    final bytes = _manifestBytes(filename: 'different.apk');
    final signed = await _sign(bytes);

    await expectLater(
      verifier.verify(
        manifestBytes: bytes,
        signatureBase64: signed.signature,
        publicKeyBase64: signed.publicKey,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects oversized artifact metadata', () async {
    final bytes = _manifestBytes(byteSize: kMaxAndroidUpdateBytes + 1);
    final signed = await _sign(bytes);

    await expectLater(
      verifier.verify(
        manifestBytes: bytes,
        signatureBase64: signed.signature,
        publicKeyBase64: signed.publicKey,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('accepts the exact Linux AppImage platform and filename', () async {
    final bytes = _manifestBytes(
      platform: 'linux-x86_64',
      filename: 'iptvs-1.4.2-linux-x86_64.AppImage',
    );
    final signed = await _sign(bytes);

    final manifest = await verifier.verify(
      manifestBytes: bytes,
      signatureBase64: signed.signature,
      publicKeyBase64: signed.publicKey,
    );

    expect(
      manifest.artifacts['linux-x86_64']?.filename,
      'iptvs-1.4.2-linux-x86_64.AppImage',
    );
  });

  test(
    'ignores artifacts for unknown future platforms and keeps the known ones',
    () async {
      // Regression: 0.1.38 added a `linux-x86_64` artifact, and every ≤0.1.37
      // client's parser threw 'Unsupported release platform' on it, rejecting
      // the whole manifest and bricking auto-update on every platform. A client
      // must parse the platforms it knows and skip the rest.
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schema': 1,
            'version': '1.4.2',
            'minimum_version': '1.0.0',
            'artifacts': [
              {
                'platform': 'android',
                'filename': 'iptvs-1.4.2-android.apk',
                'byte_size': 12345,
                'sha256': List.filled(64, 'a').join(),
              },
              {
                // A platform this build has never heard of.
                'platform': 'macos-arm64',
                'filename': 'iptvs-1.4.2-macos-arm64.dmg',
                'byte_size': 999,
                'sha256': List.filled(64, 'b').join(),
              },
            ],
          }),
        ),
      );
      final signed = await _sign(bytes);

      final manifest = await verifier.verify(
        manifestBytes: bytes,
        signatureBase64: signed.signature,
        publicKeyBase64: signed.publicKey,
      );

      expect(manifest.artifacts.keys, ['android']);
      expect(manifest.artifacts['android']?.filename, 'iptvs-1.4.2-android.apk');
    },
  );

  test('rejects uppercase or malformed SHA-256 values', () async {
    for (final digest in [List.filled(64, 'A').join(), 'xyz']) {
      final bytes = _manifestBytes(sha256: digest);
      final signed = await _sign(bytes);
      await expectLater(
        verifier.verify(
          manifestBytes: bytes,
          signatureBase64: signed.signature,
          publicKeyBase64: signed.publicKey,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
