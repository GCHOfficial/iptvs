import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'diagnostics_log.dart';
import 'net.dart';
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
    : _http = http ?? (HttpClient()..connectionTimeout = _connectTimeout);

  static const _connectTimeout = Duration(seconds: 20);

  /// Whether an in-app download+install is supported here (the two release
  /// targets). Elsewhere the flow degrades to opening the release page.
  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  /// Streams [url] to a file in the temp dir, reporting fractional progress
  /// (0..1) as chunks arrive. Returns the written file. GitHub asset URLs 302
  /// to a CDN; `HttpClient` follows redirects by default.
  Future<File> download(
    Uri url,
    String filename, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, filename));
    final request = await _http.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'iptvs-updater');
    final response = await request.close().timeout(kHttpReadTimeout);
    if (response.statusCode != 200) {
      throw StateError('Download HTTP ${response.statusCode}');
    }
    final total = response.contentLength; // -1 when unknown
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(kHttpReadTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.close();
    }
    return file;
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
  Future<void> requestInstallPermission() async {
    try {
      await _channel.invokeMethod('requestInstallPermission');
    } catch (e) {
      DiagnosticsLog.instance.add('update', 'Permission request failed: $e');
    }
  }

  /// Opens [url] (the release page) in the system browser.
  Future<void> openReleasePage(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      DiagnosticsLog.instance.add('update', 'Open browser failed: ${redactUrl(url)}');
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
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
    ], mode: ProcessStartMode.detached);
  }

  void close() => _http.close(force: true);
}

/// The Windows self-update helper script. Waits for the running app (by [pid])
/// to exit so its files unlock, extracts [zipPath] over [installDir] (the zip
/// holds the Release folder *contents*, so it overlays in place), and relaunches
/// [exeName]. Split out as a pure string builder for readability/testability.
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
try { Wait-Process -Id $pid -Timeout 60 } catch {}
Start-Sleep -Milliseconds 800
Expand-Archive -Path ${q(zipPath)} -DestinationPath ${q(installDir)} -Force
Start-Process -FilePath (Join-Path ${q(installDir)} ${q(exeName)})
''';
}
