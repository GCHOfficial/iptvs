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

/// Builds a zip whose single entry [entryName] is a copy of the real file at
/// [sourcePath] — the success-path test needs a genuinely launchable binary,
/// which [_createZip]'s text entries can't provide.
Future<void> _createZipWithFile(
  String zipPath,
  String entryName,
  String sourcePath,
) async {
  final script =
      '''
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
\$stream = [System.IO.File]::Open(${_powerShellLiteral(zipPath)}, [System.IO.FileMode]::Create)
\$archive = [System.IO.Compression.ZipArchive]::new(\$stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
    \$archive, ${_powerShellLiteral(sourcePath)}, ${_powerShellLiteral(entryName)}
  ) | Out-Null
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

/// Reads a directory's Windows file attributes as a comma-separated string
/// (`Directory` exposes no attribute API). Used to prove the scratch folders
/// the updater creates beside the install never leave it hidden.
Future<String> _attributesOf(String dir) async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    '(Get-Item -LiteralPath ${_powerShellLiteral(dir)} -Force).Attributes',
  ]).timeout(const Duration(seconds: 30));
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return (result.stdout as String).trim();
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
      // The rollback restores the install from a *hidden* backup folder. If
      // the un-hide step were wrong (it is `-band -bnot` enum arithmetic
      // inside a `try{}catch{}`, so a failure would be swallowed silently),
      // the user's app folder would simply disappear from Explorer.
      expect(await _attributesOf(install.path), isNot(contains('Hidden')));
    },
    skip: windowsOnly,
  );

  test('a successful swap cleans up and leaves no hidden install', () async {
    final root = await Directory.systemTemp.createTemp('iptvs-update-test-');
    final install = await Directory(p.join(root.path, 'install')).create();
    await File(p.join(install.path, 'iptvs.exe')).writeAsString('old-install');
    await File(p.join(install.path, 'stale.dll')).writeAsString('old-only');
    // The script only treats the swap as good if the replacement is still
    // running after 5s, so the payload has to be a real, long-lived binary.
    // `cmd.exe` with no arguments waits on stdin forever; it is killed below.
    final zip = File(p.join(root.path, 'good.zip'));
    await _createZipWithFile(zip.path, 'iptvs.exe', r'C:\Windows\System32\cmd.exe');
    addTearDown(() async {
      await Process.run('taskkill.exe', ['/F', '/IM', 'iptvs.exe']);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await root.delete(recursive: true);
    });

    final result = await _runUpdater(root: root, zip: zip);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    // Swapped: the new payload replaced the old tree wholesale.
    expect(File(p.join(install.path, 'iptvs.exe')).lengthSync(), greaterThan(1000));
    expect(File(p.join(install.path, 'stale.dll')).existsSync(), isFalse);
    // The staging folder is created hidden and *becomes* the install folder,
    // so the attribute has to be cleared on the way in.
    expect(await _attributesOf(install.path), isNot(contains('Hidden')));
    // No scratch folders survive beside the install. They are unavoidable
    // siblings (the swap must be a rename, so they share the install's
    // volume), which is why they are created hidden and removed with retries
    // — an install on the Desktop otherwise flashed junk folders at the user
    // mid-update, and one failed delete would have stranded them for good.
    final leftovers = root
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .where((name) => name.startsWith('.iptvs-update-'))
        .toList();
    expect(leftovers, isEmpty);
  }, skip: windowsOnly);
}
