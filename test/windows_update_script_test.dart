import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_installer.dart';
import 'package:path/path.dart' as p;

String _powerShellLiteral(String value) => "'${value.replaceAll("'", "''")}'";

Future<void> _createZip(String zipPath, Map<String, String> entries) async {
  final definitions = entries.entries
      .map(
        (entry) =>
            '@{Name=${_powerShellLiteral(entry.key)};'
            'Content=${_powerShellLiteral(entry.value)}}',
      )
      .join(',');
  final script =
      '''
Add-Type -AssemblyName System.IO.Compression
\$stream = [System.IO.File]::Open(${_powerShellLiteral(zipPath)}, [System.IO.FileMode]::Create)
\$archive = [System.IO.Compression.ZipArchive]::new(\$stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  \$entries = @($definitions)
  foreach (\$definition in \$entries) {
    \$entry = \$archive.CreateEntry(\$definition.Name)
    \$writer = [System.IO.StreamWriter]::new(\$entry.Open())
    try { \$writer.Write(\$definition.Content) } finally { \$writer.Dispose() }
  }
} finally {
  \$archive.Dispose()
  \$stream.Dispose()
}
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    script,
  ]).timeout(const Duration(seconds: 30));
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

Future<ProcessResult> _runUpdater({
  required Directory root,
  required File zip,
}) async {
  final install = Directory(p.join(root.path, 'install'));
  final script = File(p.join(root.path, 'update.ps1'));
  await script.writeAsString(
    windowsUpdateScript(
      pid: 2147483647,
      zipPath: zip.path,
      installDir: install.path,
      exeName: 'iptvs.exe',
    ),
  );
  return Process.run('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
  ]).timeout(const Duration(seconds: 30));
}

void main() {
  final windowsOnly = Platform.isWindows
      ? false
      : 'Generated PowerShell updater integration runs on Windows CI.';

  test('rejects zip-slip before extraction', () async {
    final root = await Directory.systemTemp.createTemp('iptvs-update-test-');
    addTearDown(() => root.delete(recursive: true));
    final install = await Directory(p.join(root.path, 'install')).create();
    final oldExe = File(p.join(install.path, 'iptvs.exe'));
    await oldExe.writeAsString('old-install');
    final zip = File(p.join(root.path, 'malicious.zip'));
    await _createZip(zip.path, {'../escaped.txt': 'escaped'});

    final result = await _runUpdater(root: root, zip: zip);

    expect(result.exitCode, isNot(0));
    expect(File(p.join(root.path, 'escaped.txt')).existsSync(), isFalse);
    expect(await oldExe.readAsString(), 'old-install');
  }, skip: windowsOnly);

  test('rejects an archive without a top-level executable', () async {
    final root = await Directory.systemTemp.createTemp('iptvs-update-test-');
    addTearDown(() => root.delete(recursive: true));
    final install = await Directory(p.join(root.path, 'install')).create();
    final oldExe = File(p.join(install.path, 'iptvs.exe'));
    await oldExe.writeAsString('old-install');
    final zip = File(p.join(root.path, 'wrong-layout.zip'));
    await _createZip(zip.path, {'nested/iptvs.exe': 'not-top-level'});

    final result = await _runUpdater(root: root, zip: zip);

    expect(result.exitCode, isNot(0));
    expect(await oldExe.readAsString(), 'old-install');
  }, skip: windowsOnly);

  test(
    'restores the previous install when replacement launch fails',
    () async {
      final root = await Directory.systemTemp.createTemp('iptvs-update-test-');
      addTearDown(() => root.delete(recursive: true));
      final install = await Directory(p.join(root.path, 'install')).create();
      final oldExe = File(p.join(install.path, 'iptvs.exe'));
      await oldExe.writeAsString('old-install');
      final zip = File(p.join(root.path, 'broken-replacement.zip'));
      await _createZip(zip.path, {'iptvs.exe': 'not-a-windows-executable'});

      final result = await _runUpdater(root: root, zip: zip);

      expect(result.exitCode, isNot(0));
      expect(await oldExe.readAsString(), 'old-install');
    },
    skip: windowsOnly,
  );
}
