import 'dart:io' show Platform;

import 'package:media_kit/media_kit.dart';

/// Live-stream mpv network/demuxer tuning: no on-disk cache (IPTV streams don't
/// benefit from one, and it can fail on restricted temp/cache paths), a short
/// network timeout, and transparent reconnect on transient HTTP drops. Shared by
/// the fullscreen player and the live preview player so both get the same
/// resilience.
const Map<String, String> kLiveMpvOptions = {
  'cache-on-disk': 'no',
  'demuxer-max-back-bytes': '0',
  'network-timeout': '15',
  'stream-lavf-o':
      'reconnect=1,reconnect_streamed=1,reconnect_at_eof=1,'
      'reconnect_delay_max=5',
  'demuxer-lavf-analyzeduration': '3',
  'demuxer-lavf-probesize': '10000000',
  'demuxer-lavf-o':
      'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
      'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],'
      'analyzeduration=3000000,probesize=10000000',
};

/// Hardware-decode-friendly options for **embedded** (non-native-surface) playback
/// on non-Windows platforms — notably Android, where the fallback/preview path
/// renders through a Flutter texture rather than the native HDR Activity. Without
/// these, mpv falls back to its untuned defaults, which on Android tends to mean
/// software decode — fine at low resolutions but increasingly expensive as source
/// resolution climbs. Also asks mpv to tone-map HDR/10-bit down to SDR, since
/// Flutter's texture path can't display HDR passthrough.
const Map<String, String> kEmbeddedAndroidVideoOptions = {
  'hwdec': 'auto-safe',
  'target-prim': 'bt.709',
  'target-trc': 'bt.1886',
  'target-peak': '100',
  'tone-mapping': 'bt.2390',
  'hdr-compute-peak': 'yes',
};

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
