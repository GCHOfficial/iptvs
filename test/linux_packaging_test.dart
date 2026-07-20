import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppImage packaging keeps the Flutter bundle together', () {
    final script = File('tool/package_linux_appimage.sh').readAsStringSync();
    expect(script, contains('cp -a "\$bundle/." "\$appdir/usr/bin/"'));
    expect(
      script,
      contains(
        'linux/mpv/iptvs_overlay.lua "\$appdir/usr/share/iptvs/overlay.lua"',
      ),
    );
    expect(script, contains('cp "\$MPV_BINARY" "\$appdir/usr/bin/mpv"'));
    expect(script, contains('--runtime-file'));
    expect(script, contains('--output appimage'));
    expect(script, contains('test -s "\$output"'));
  });

  test('AppImage packaging installs the vendored overlay fonts', () {
    final script = File('tool/package_linux_appimage.sh').readAsStringSync();
    expect(script, contains('mkdir -p "\$appdir/usr/share/iptvs/fonts"'));
    expect(script, contains('linux/mpv/fonts/Inter-Regular.ttf'));
    expect(script, contains('linux/mpv/fonts/Inter-SemiBold.ttf'));
    expect(script, contains('linux/mpv/fonts/MaterialIcons-Regular.otf'));
    expect(script, contains('"\$appdir/usr/share/iptvs/fonts/"'));
  });

  test('vendored overlay fonts exist on disk', () {
    for (final name in [
      'Inter-Regular.ttf',
      'Inter-SemiBold.ttf',
      'MaterialIcons-Regular.otf',
    ]) {
      expect(
        File('linux/mpv/fonts/$name').existsSync(),
        isTrue,
        reason: 'linux/mpv/fonts/$name should be vendored',
      );
    }
  });

  test('release signs and publishes the Linux artifact', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    expect(workflow, contains('build-linux:'));
    expect(workflow, contains('linux-x86_64.AppImage'));
    expect(workflow, contains('platform:"linux-x86_64"'));
    expect(workflow, contains('UPDATE_MANIFEST_PUBLIC_KEY'));
    expect(
      workflow,
      contains('releases/download/12/appimagetool-x86_64.AppImage'),
    );
    expect(workflow, contains('releases/download/20251108/runtime-x86_64'));
    expect(workflow, isNot(contains('releases/download/continuous/')));
  });

  test('CI no longer bundles a build-time mpv into the AppImage', () {
    // Design A: the AppImage relies on the host's system mpv at runtime
    // (LinuxNativeSession version-probes and gates it), so CI must not set
    // MPV_BINARY — package_linux_appimage.sh's MPV_BINARY block stays purely
    // optional for anyone packaging with a hand-picked mpv build.
    for (final workflowPath in [
      '.github/workflows/build.yml',
      '.github/workflows/release.yml',
    ]) {
      final workflow = File(workflowPath).readAsStringSync();
      expect(
        workflow,
        isNot(contains('MPV_BINARY:')),
        reason: '$workflowPath should not set MPV_BINARY',
      );
    }
    final script = File('tool/package_linux_appimage.sh').readAsStringSync();
    expect(script, contains('if [[ -n "\${MPV_BINARY:-}" ]]; then'));
  });

  test('native mpv uses a filesystem IPC server socket', () {
    final session = File(
      'lib/player/linux_native_session.dart',
    ).readAsStringSync();
    expect(session, contains('--input-ipc-server=\$_socketPath'));
    expect(session, contains("'--script=\$overlayScript'"));
    expect(session, contains("'user-data/iptvs-control'"));
    expect(session, isNot(contains('--input-ipc-client=\$_socketPath')));
  });

  test('native mpv points libass at the vendored overlay fonts', () {
    final session = File(
      'lib/player/linux_native_session.dart',
    ).readAsStringSync();
    // The overlay renders as an OSD ass-events surface, so libass needs
    // --osd-fonts-dir (not --sub-fonts-dir) to find the bundled Inter/
    // Material Icons faces referenced by the Lua script's \fn tags.
    expect(session, contains("'--osd-fonts-dir=\$fontsDir'"));
    expect(session, contains('findFontsDir'));
  });

  test('desktop identity matches the Linux runner', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final desktop = File(
      'linux/com.gchofficial.iptvs.desktop',
    ).readAsStringSync();
    expect(cmake, contains('com.gchofficial.iptvs'));
    expect(desktop, contains('StartupWMClass=com.gchofficial.iptvs'));
  });
}
