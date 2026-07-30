import 'package:flutter/foundation.dart';

/// Which engine plays a stream on iOS.
///
/// iOS mirrors Android's dual-engine shape (see docs/player.md "Android"):
/// a **default** hardware engine that can actually signal HDR, plus a libmpv
/// **fallback** for containers the default engine refuses.
///
/// - [avPlayer] — a natively presented `UIViewController` owning an
///   `AVPlayerLayer` (the `HdrPlayerActivity` analogue: video lives outside
///   Flutter's compositor). This is the only path to HDR10/HLG/Dolby Vision,
///   PiP, AirPlay and lock-screen controls on iOS.
/// - [mpv] — the embedded `media_kit`/libmpv texture, always tone-mapped SDR
///   on iOS (`libmpv-darwin-build` patches VideoToolbox down to 8-bit BGRA
///   because iOS has no 10-bit GLES textures). Plays everything AVFoundation
///   won't: raw MPEG-TS, MKV, AVI, and anything behind a non-HTTP scheme.
enum IosPlaybackEngine { avPlayer, mpv }

/// Process-static memo of content that has already **failed** on
/// [IosPlaybackEngine.avPlayer] at runtime, so a second attempt at the same
/// channel/item goes straight to mpv instead of replaying the failure.
///
/// Deliberately the same shape as `LivePreviewController._nativeUnsupportedIds`
/// (the Android "this channel's video the shared ExoPlayer engine can't
/// decode" memo) — per-session, never persisted, keyed by the caller's stable
/// content id.
abstract final class IosEngineMemo {
  /// Content ids known to fail on AVPlayer for the rest of this session.
  /// Exposed (rather than hidden behind a lookup) because [selectIosEngine] is
  /// a pure function: callers pass this set in explicitly.
  static final Set<String> forcedMpv = <String>{};

  /// Records that [key]'s content could not be played by AVPlayer. A null or
  /// empty key means the caller opted out of memoisation (e.g. playback with
  /// no stable id), and is a no-op — never a wildcard.
  static void markMpvOnly(String? key) {
    if (key == null || key.isEmpty) return;
    forcedMpv.add(key);
  }

  /// Test-only: the memo is process-static, so leftovers would leak across
  /// tests.
  @visibleForTesting
  static void resetForTest() => forcedMpv.clear();
}

/// Extensions AVFoundation reliably accepts: HLS playlists and the
/// MP4/QuickTime family (plus the audio-only containers, which reach the
/// player through the same path).
const Set<String> _kAvPlayerExtensions = <String>{
  'm3u8',
  'mp4',
  'm4v',
  'mov',
  'm4a',
  'mp3',
  'aac',
};

/// Extensions AVFoundation is known to reject (a naked continuous MPEG-TS
/// stream, Matroska, and the rest of the "mpv-only" container zoo). Listed
/// explicitly rather than inferred so the routing table is readable, even
/// though rule 4 below would send all of them to mpv anyway.
const Set<String> _kMpvExtensions = <String>{
  'ts',
  'm2ts',
  'mkv',
  'avi',
  'flv',
  'webm',
  'mpg',
  'mpeg',
  'wmv',
  'vob',
  'divx',
  'rmvb',
  'ogv',
};

/// Chooses the iOS playback engine for [url], purely from the resolved
/// locator. Kept in Dart (not Swift) because the trigger is the *container*,
/// which Dart already knows from the resolved URL, and because a pure function
/// is unit-testable at zero cost — Swift keeps only a defensive mirror that may
/// reject an impossible scheme, never override this.
///
/// Rules, in order:
///
/// 1. [memoKey] is in [forcedMpv] — this content already failed on AVPlayer
///    this session → [IosPlaybackEngine.mpv].
/// 2. Scheme is not `http`/`https`/`file` (rtmp, rtsp, udp, rtp, mms, or an
///    unparseable locator) → [IosPlaybackEngine.mpv].
/// 3. The extension of the last path segment — query string and fragment
///    stripped, lowercased — is a known AVFoundation container →
///    [IosPlaybackEngine.avPlayer]; a known mpv-only one →
///    [IosPlaybackEngine.mpv].
/// 4. **No extension, or an unknown one → [IosPlaybackEngine.mpv].**
///
/// **Rule 4 is load-bearing, and the asymmetry is deliberate.** The two wrong
/// guesses do not cost the same: guessing *mpv* for a stream AVPlayer could
/// have played costs **quality** (tone-mapped SDR, no PiP) and nothing else —
/// playback still works. Guessing *AVPlayer* for a stream it can't decode
/// costs a **visible failure and a reopen beat** on the app's most common
/// path, live zapping. Asymmetric costs justify an asymmetric default, so
/// anything not positively recognised routes to the engine that plays
/// everything.
///
/// **Consequence to state plainly:** Stalker/MAG `create_link` locators are
/// extension-less (the portal returns an opaque play URL), so they hit rule 4
/// and **always route to mpv** — a Stalker portal gets HDR on iOS only when
/// `create_link` happens to return an `.m3u8` URL. The same is true of any
/// provider serving extension-less locators; Xtream's `streamExtension` lever
/// (`'m3u8'` vs `'ts'`) is what actually makes AVPlayer the common path there.
IosPlaybackEngine selectIosEngine({
  required String url,
  String? memoKey,
  Set<String> forcedMpv = const <String>{},
}) {
  // 1. Session memo: this content already failed on AVPlayer.
  if (memoKey != null && memoKey.isNotEmpty && forcedMpv.contains(memoKey)) {
    return IosPlaybackEngine.mpv;
  }

  // 2. Scheme gate. An unparseable locator is treated exactly like an
  //    unsupported scheme — fail toward the engine that plays everything.
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return IosPlaybackEngine.mpv;
  switch (uri.scheme.toLowerCase()) {
    case 'http':
    case 'https':
    case 'file':
      break;
    default:
      return IosPlaybackEngine.mpv;
  }

  // 3. Container from the last path segment. `Uri` has already removed the
  //    query and fragment, so `…/1.ts?token=x` and `…/1.ts` are identical here.
  final extension = _extensionOf(uri);
  if (_kAvPlayerExtensions.contains(extension)) return IosPlaybackEngine.avPlayer;
  if (_kMpvExtensions.contains(extension)) return IosPlaybackEngine.mpv;

  // 4. No extension, or one we don't recognise.
  return IosPlaybackEngine.mpv;
}

/// Lowercased extension of [uri]'s last non-empty path segment, or `''` when
/// there isn't one (no path, a trailing slash, a dotless segment, a dotfile,
/// or a segment ending in `.`).
String _extensionOf(Uri uri) {
  String last = '';
  for (final segment in uri.pathSegments) {
    if (segment.isNotEmpty) last = segment;
  }
  final dot = last.lastIndexOf('.');
  if (dot <= 0 || dot == last.length - 1) return '';
  return last.substring(dot + 1).toLowerCase();
}
