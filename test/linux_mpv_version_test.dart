import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/linux_native_session.dart';

void main() {
  group('parseMpvVersion', () {
    test('parses an upstream build version', () {
      expect(
        parseMpvVersion(
          'mpv v0.41.0 Copyright © 2000-2025 mpv/MPlayer/mplayer2 projects\n'
          ' built on Feb 13 2026 22:37:10\n',
        ),
        (0, 41),
      );
    });

    test('parses a distro-patched version with no v prefix', () {
      expect(
        parseMpvVersion(
          'mpv 0.37.0-1ubuntu4+build2 Copyright © 2000-2023 mpv/MPlayer/mplayer2 '
          'projects\n',
        ),
        (0, 37),
      );
    });

    test('parses a git snapshot / -dev version', () {
      expect(
        parseMpvVersion('mpv v0.42.0-dev-123-gabcdef1 Copyright © 2000-2026\n'),
        (0, 42),
      );
    });

    test('parses a version with an extended patch suffix', () {
      expect(parseMpvVersion('mpv v0.40.0-15-g1234567\n'), (0, 40));
    });

    test('returns null for unparseable output', () {
      expect(parseMpvVersion(''), isNull);
      expect(parseMpvVersion('command not found'), isNull);
    });
  });

  group('mpvSupportsNativeHdr', () {
    test('rejects versions below the 0.40 floor', () {
      expect(mpvSupportsNativeHdr((0, 39)), isFalse);
      expect(mpvSupportsNativeHdr((0, 37)), isFalse);
      expect(mpvSupportsNativeHdr((0, 34)), isFalse);
    });

    test('accepts 0.40 and newer', () {
      expect(mpvSupportsNativeHdr((0, 40)), isTrue);
      expect(mpvSupportsNativeHdr((0, 41)), isTrue);
      expect(mpvSupportsNativeHdr((0, 42)), isTrue);
    });

    test('accepts a hypothetical future major version', () {
      expect(mpvSupportsNativeHdr((1, 0)), isTrue);
    });
  });

  group('mpvColorspaceHintArgs', () {
    test('0.40 needs the explicit yes value (auto does not exist yet)', () {
      expect(mpvColorspaceHintArgs((0, 40)), ['--target-colorspace-hint=yes']);
    });

    test('0.41 and newer omit the flag (default is auto)', () {
      expect(mpvColorspaceHintArgs((0, 41)), isEmpty);
      expect(mpvColorspaceHintArgs((0, 42)), isEmpty);
    });
  });

  group('mpvGpuContextArgs', () {
    test('X11 stays pinned to the EGL context (no HDR output path)', () {
      expect(mpvGpuContextArgs(LinuxNativeBackend.x11), [
        '--gpu-context=x11egl',
      ]);
    });

    test('Wayland omits the flag so mpv picks its own context', () {
      expect(mpvGpuContextArgs(LinuxNativeBackend.wayland), isEmpty);
    });
  });

  group('LinuxHdrColorimetry.hasHdr10PlusMetadata', () {
    test('false when every scene field is null or zero', () {
      const colorimetry = LinuxHdrColorimetry();
      expect(colorimetry.hasHdr10PlusMetadata, isFalse);
      const zeroed = LinuxHdrColorimetry(
        sceneMaxR: 0,
        sceneMaxG: 0,
        sceneMaxB: 0,
        sceneAvg: 0,
      );
      expect(zeroed.hasHdr10PlusMetadata, isFalse);
    });

    test('true when any scene field is positive', () {
      const colorimetry = LinuxHdrColorimetry(sceneAvg: 120.5);
      expect(colorimetry.hasHdr10PlusMetadata, isTrue);
    });
  });
}
