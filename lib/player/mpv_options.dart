import 'dart:io' show Platform;

import 'package:media_kit/media_kit.dart';

/// Live-stream mpv network/demuxer tuning: no on-disk cache (IPTV streams don't
/// benefit from one, and it can fail on restricted temp/cache paths), a short
/// network timeout, and transparent reconnect on transient HTTP drops. Shared by
/// the fullscreen player and the live preview player so both get the same
/// resilience.
///
/// `reconnect_at_eof` must stay out of `stream-lavf-o`: an HLS live stream's
/// manifest is a *finite* HTTP resource, and with that flag ffmpeg (verified on
/// FFmpeg 8 / mpv 0.41) treats its EOF as an error and reconnects forever, so
/// the demuxer probe never completes and the stream never opens at all. A clean
/// server-side end-of-stream on an infinite TS instead surfaces as mpv
/// `eof-reached`, which media_kit maps to `completed=true` *and*
/// `buffering=false` — so the buffering-gated stall watchdog can't see it. The
/// embedded/Windows path therefore treats a *live* `completed` as a drop and
/// reconnects (the `stream.completed` listener in `player_screen.dart`,
/// `shouldReconnectOnCompleted`); the Linux-native path gets the equivalent
/// `end-file` eof/error drop over IPC (`LinuxNativePlaybackSignal.dropped`).
const Map<String, String> kLiveMpvOptions = {
  'cache-on-disk': 'no',
  'demuxer-max-back-bytes': '0',
  'network-timeout': '15',
  'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
  'demuxer-lavf-analyzeduration': '3',
  'demuxer-lavf-probesize': '10000000',
  'demuxer-lavf-o':
      'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
      'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],'
      'analyzeduration=3000000,probesize=10000000',
};

/// Tone-map-to-SDR options for **embedded** (non-native-surface) playback on
/// non-Windows platforms — notably Android, where the fallback/preview path
/// renders through a Flutter texture (which can't display HDR passthrough) rather
/// than the native HDR Activity.
///
/// Note: `hwdec` is deliberately **not** here — `media_kit_video`'s
/// [VideoController] sets `hwdec` itself at creation (default `auto-safe`),
/// overriding any value set via `setProperty`, so decode mode must be chosen on
/// the `VideoControllerConfiguration` ([kAndroidPreviewHwdec]) instead. Nor is
/// `hdr-compute-peak` — its per-frame GPU histogram is expensive and pointless
/// here (we tone-map to a fixed SDR target anyway).
const Map<String, String> kEmbeddedAndroidVideoOptions = {
  'target-prim': 'bt.709',
  'target-trc': 'bt.1886',
  'target-peak': '100',
  'tone-mapping': 'bt.2390',
};

/// Decode mode for the embedded Android preview, applied on the
/// [VideoController]'s configuration (the only place `hwdec` sticks — see
/// [kEmbeddedAndroidVideoOptions]). `mediacodec-copy` forces real hardware decode
/// on the device's codec and copies frames into the GL texture path, so it works
/// with `vo=gpu`. The controller default `auto-safe` silently falls back to
/// software on some weak TV boxes → 4K HEVC plays in slow-motion at ~100% CPU.
const String kAndroidPreviewHwdec = 'mediacodec-copy';

/// Applies [options] as mpv properties on [platform], warning via [onWarn]
/// (non-fatal — a single bad property shouldn't abort playback) instead of
/// throwing.
Future<void> applyMpvOptions(
  NativePlayer platform,
  Map<String, String> options, {
  void Function(String message)? onWarn,
}) async {
  for (final entry in options.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (error) {
      onWarn?.call('mpv option ${entry.key} failed: $error');
    }
  }
}

/// The embedded-path video options for the current platform (empty on Windows,
/// which either uses the native HDR surface or, without one, needs no extra
/// tuning here).
Map<String, String> embeddedVideoOptionsForPlatform() => Platform.isWindows
    ? const <String, String>{}
    : kEmbeddedAndroidVideoOptions;
