import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'diagnostics_log.dart';
import 'distribution_channel.dart';
import 'net.dart';
import 'update_manifest.dart';
import 'update_service.dart';

/// Outcome of kicking off a platform install.
enum InstallOutcome {
  /// The OS installer (Android) or update helper (Windows) was launched. On
  /// Windows the caller should now exit the app so `iptvs.exe` unlocks.
  launched,

  /// Android only: the app lacks the "install unknown apps" permission — the
  /// caller should prompt the user (see [requestInstallPermission]) and retry.
  needsPermission,

  /// No in-app install path (unsupported platform / failure); the release page
  /// was opened in a browser instead.
  openedInBrowser,
}

/// Downloads a release asset and hands it to the platform's install path:
/// Android fires the system package-installer via the `iptvs/updates`
/// MethodChannel; Windows writes a detached PowerShell helper that swaps the
/// portable folder and relaunches. Everything else falls back to the browser.
class UpdateInstaller {
  static const _channel = MethodChannel('iptvs/updates');
  final HttpClient _http;

  UpdateInstaller({HttpClient? http})
    : _http =
          http ??
          (HttpClient()
            ..connectionTimeout = _connectTimeout
            ..autoUncompress = false);

  static const _connectTimeout = Duration(seconds: 20);

  /// Whether an in-app download+install is supported here (the two release
  /// targets). Elsewhere the flow degrades to opening the release page.
  static bool get isSupported =>
      DistributionConfig.directUpdaterEnabled &&
      (Platform.isAndroid || Platform.isWindows);

  /// Streams [url] to a file in the temp dir, reporting fractional progress
  /// (0..1) as chunks arrive. Returns the written file. GitHub asset URLs 302
  /// to a CDN; each destination is approved before it is followed.
  Future<File> download(
    Uri url,
    ReleaseArtifact artifact, {
    void Function(double progress)? onProgress,
  }) async {
    if (!isApprovedUpdateUri(url)) {
      throw const FormatException('Unapproved update host');
    }
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, artifact.filename));
    final partial = File('${file.path}.partial');
    if (await partial.exists()) await partial.delete();
    final operation = HttpOperation(
      kUpdateArtifactWorkload.copyWith(
        maximumBodyBytes: artifact.byteSize,
        maximumDecodedBytes: artifact.byteSize,
      ),
    );
    final response = await openApprovedUpdateGet(
      _http,
      url,
      operation: operation,
      headers: const {HttpHeaders.userAgentHeader: 'iptvs-updater'},
    );
    if (response.statusCode != 200) {
      await operation.readBytes(response);
      throw StateError('Download HTTP ${response.statusCode}');
    }
    if (response.contentLength >= 0 &&
        response.contentLength != artifact.byteSize) {
      await response.drain<void>();
      throw const FormatException('Update Content-Length mismatch');
    }
    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var received = 0;
    var hashClosed = false;
    try {
      received = await operation.readToFile(
        response,
        partial,
        maximumBytes: artifact.byteSize,
        onChunk: (chunk, total) {
          hashSink.add(chunk);
          onProgress?.call(total / artifact.byteSize);
        },
      );
      hashSink.close();
      hashClosed = true;
      validateDownloadedArtifact(
        artifact: artifact,
        receivedBytes: received,
        sha256Digest: digestSink.value.toString(),
      );
      if (await file.exists()) await file.delete();
      return partial.rename(file.path);
    } catch (_) {
      if (!hashClosed) hashSink.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  /// Installs a downloaded [file] for the running platform. On failure or an
  /// unsupported platform, opens [ReleaseInfo.htmlUrl] in a browser.
  Future<InstallOutcome> install(ReleaseInfo release, File file) async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod<String>('installApk', {
          'path': file.path,
        });
        return result == 'needs_permission'
            ? InstallOutcome.needsPermission
            : InstallOutcome.launched;
      }
      if (Platform.isWindows) {
        await _launchWindowsUpdater(file);
        return InstallOutcome.launched;
      }
    } catch (e) {
      DiagnosticsLog.instance.add('update', 'Install failed: $e');
    }
    await openReleasePage(release.htmlUrl);
    return InstallOutcome.openedInBrowser;
  }

  /// Sends the user to Android's per-app "install unknown apps" settings.
  Future<bool> requestInstallPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestInstallPermission') ??
          false;
    } catch (e) {
      DiagnosticsLog.instance.add('update', 'Permission request failed: $e');
      return false;
    }
  }

  /// Opens [url] (the release page) in the system browser.
  Future<void> openReleasePage(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      DiagnosticsLog.instance.add(
        'update',
        'Open browser failed: ${redactUrl(url)}',
      );
    }
  }

  /// Writes a PowerShell helper that waits for this process to exit, unzips the
  /// new build over the install folder, and relaunches — then starts it
  /// detached so it survives the app quitting. The caller must then `exit(0)`.
  Future<void> _launchWindowsUpdater(File zip) async {
    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final exeName = p.basename(exePath);
    final dir = await getTemporaryDirectory();
    final script = File(p.join(dir.path, 'iptvs_update.ps1'));
    await script.writeAsString(
      windowsUpdateScript(
        pid: pid,
        zipPath: zip.path,
        installDir: installDir,
        exeName: exeName,
      ),
    );
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: dir.path,
    );
  }

  void close() => _http.close(force: true);
}

/// Revalidates a previously downloaded APK before resuming installation.
///
/// The pending record lives in secure storage, but the cache file can disappear
/// or be replaced while the app is away. Keep the same exact-byte checks used
/// at download time, and reject paths outside the application temp directory.
Future<void> validateCachedArtifact(
  File file,
  ReleaseArtifact artifact, {
  Directory? tempDirectory,
}) async {
  final temp = tempDirectory ?? await getTemporaryDirectory();
  final tempPath = await temp.resolveSymbolicLinks();
  if (!await file.exists()) {
    throw const FileSystemException('Cached update is missing');
  }
  final filePath = await file.resolveSymbolicLinks();
  if (!p.isWithin(tempPath, filePath) ||
      p.basename(filePath) != artifact.filename) {
    throw const FileSystemException('Cached update path is invalid');
  }
  final length = await file.length();
  final digest = await sha256.bind(file.openRead()).first;
  validateDownloadedArtifact(
    artifact: artifact,
    receivedBytes: length,
    sha256Digest: digest.toString(),
  );
}

void validateDownloadedArtifact({
  required ReleaseArtifact artifact,
  required int receivedBytes,
  required String sha256Digest,
}) {
  if (receivedBytes != artifact.byteSize) {
    throw const FormatException('Update byte size mismatch');
  }
  if (sha256Digest != artifact.sha256) {
    throw const FormatException('Update SHA-256 mismatch');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('Digest is not complete'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

/// The Windows self-update helper script. It validates every archive path,
/// extracts into a new sibling staging directory, verifies the expected
/// executable, swaps whole directories, and restores the backup when launch
/// fails. Split out as a pure string builder for readability/testability.
String windowsUpdateScript({
  required int pid,
  required String zipPath,
  required String installDir,
  required String exeName,
}) {
  // Single-quote + double any embedded quote for safe PowerShell literals.
  String q(String s) => "'${s.replaceAll("'", "''")}'";
  return '''
\$ErrorActionPreference = 'Stop'
\$zipPath = ${q(zipPath)}
\$installDir = ${q(installDir)}
\$exeName = ${q(exeName)}
\$parentDir = [System.IO.Directory]::GetParent(\$installDir).FullName
\$token = [Guid]::NewGuid().ToString('N')
\$stageDir = Join-Path \$parentDir ('.iptvs-update-stage-' + \$token)
\$backupDir = Join-Path \$parentDir ('.iptvs-update-backup-' + \$token)
\$backupCreated = \$false
\$swapped = \$false

try { Wait-Process -Id $pid -Timeout 60 } catch {}
Start-Sleep -Milliseconds 800
try {
  New-Item -ItemType Directory -Path \$stageDir -ErrorAction Stop | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  \$separator = [System.IO.Path]::DirectorySeparatorChar
  \$stageRoot = [System.IO.Path]::GetFullPath(\$stageDir + \$separator)
  \$archive = [System.IO.Compression.ZipFile]::OpenRead(\$zipPath)
  try {
    foreach (\$entry in \$archive.Entries) {
      \$entryName = \$entry.FullName.Replace('/', \$separator)
      if ([string]::IsNullOrWhiteSpace(\$entryName)) { continue }
      if ([System.IO.Path]::IsPathRooted(\$entryName) -or
          \$entryName.StartsWith('/') -or \$entryName.StartsWith('\\')) {
        throw 'Update archive contains an absolute path.'
      }
      \$unixMode = (\$entry.ExternalAttributes -shr 16) -band 0xF000
      if (\$unixMode -eq 0xA000) {
        throw 'Update archive contains a symbolic link.'
      }
      \$target = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine(\$stageDir, \$entryName)
      )
      if (-not \$target.StartsWith(
          \$stageRoot,
          [System.StringComparison]::OrdinalIgnoreCase
      )) {
        throw 'Update archive path escapes the staging directory.'
      }
    }
  } finally {
    \$archive.Dispose()
  }

  Expand-Archive -LiteralPath \$zipPath -DestinationPath \$stageDir -Force
  \$stagedExe = Join-Path \$stageDir \$exeName
  if (-not (Test-Path -LiteralPath \$stagedExe -PathType Leaf)) {
    throw 'Update archive is missing the expected executable.'
  }

  Move-Item -LiteralPath \$installDir -Destination \$backupDir
  \$backupCreated = \$true
  Move-Item -LiteralPath \$stageDir -Destination \$installDir
  \$swapped = \$true
  \$newExe = Join-Path \$installDir \$exeName
  \$newProcess = Start-Process -FilePath \$newExe -WorkingDirectory \$installDir -PassThru
  Start-Sleep -Seconds 5
  \$newProcess.Refresh()
  if (\$newProcess.HasExited -and \$newProcess.ExitCode -ne 0) {
    throw 'Updated application exited during startup.'
  }
  Remove-Item -LiteralPath \$backupDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  if (\$backupCreated) {
    if (\$swapped) {
      Remove-Item -LiteralPath \$installDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath \$backupDir -PathType Container) {
      Move-Item -LiteralPath \$backupDir -Destination \$installDir
      \$oldExe = Join-Path \$installDir \$exeName
      Start-Process -FilePath \$oldExe -WorkingDirectory \$installDir
    }
  }
  Remove-Item -LiteralPath \$stageDir -Recurse -Force -ErrorAction SilentlyContinue
  throw
}
''';
}
