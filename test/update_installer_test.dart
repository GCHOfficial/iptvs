import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_installer.dart';
import 'package:iptvs/data/update_manifest.dart';

const _artifact = ReleaseArtifact(
  platform: 'android',
  filename: 'iptvs-1.4.2-android.apk',
  byteSize: 5,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

void main() {
  test('accepts the signed byte size and digest', () {
    expect(
      () => validateDownloadedArtifact(
        artifact: _artifact,
        receivedBytes: 5,
        sha256Digest: _artifact.sha256,
      ),
      returnsNormally,
    );
  });

  test('rejects a truncated or extended artifact', () {
    for (final size in [4, 6]) {
      expect(
        () => validateDownloadedArtifact(
          artifact: _artifact,
          receivedBytes: size,
          sha256Digest: _artifact.sha256,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('rejects an artifact with a different digest', () {
    expect(
      () => validateDownloadedArtifact(
        artifact: _artifact,
        receivedBytes: 5,
        sha256Digest:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  group('Windows update script', () {
    final script = windowsUpdateScript(
      pid: 42,
      zipPath: r"C:\Users\O'Brien\update.zip",
      installDir: r'C:\Apps\IPTVS Player',
      exeName: 'iptvs.exe',
    );

    test('quotes user-controlled paths as PowerShell literals', () {
      expect(script, contains(r"$zipPath = 'C:\Users\O''Brien\update.zip'"));
      expect(script, contains(r"$installDir = 'C:\Apps\IPTVS Player'"));
      expect(script, contains('Wait-Process -Id 42'));
    });

    test('validates archive paths and links before extraction', () {
      expect(script, contains('[System.IO.Compression.ZipFile]::OpenRead'));
      expect(script, contains('[System.IO.Path]::IsPathRooted'));
      expect(script, contains(r'$entry.ExternalAttributes'));
      expect(script, contains('Update archive path escapes'));
      expect(script, contains('Update archive contains a symbolic link'));
    });

    test('extracts to staging and contains swap and rollback steps', () {
      expect(
        script,
        contains(
          r'Expand-Archive -LiteralPath $zipPath -DestinationPath $stageDir',
        ),
      );
      expect(script, isNot(contains(r'-DestinationPath $installDir -Force')));
      expect(
        script,
        contains(r'Move-Item -LiteralPath $installDir -Destination $backupDir'),
      );
      expect(
        script,
        contains(r'Move-Item -LiteralPath $backupDir -Destination $installDir'),
      );
      expect(script, contains('Updated application exited during startup'));
    });
  });
}
