import Foundation

/// Which iOS playback engine handles a resolved stream URL. Mirrors Android's
/// `HdrPlayerActivity` dual-engine shape: a capable default (`avPlayer`, the
/// AVFoundation/AVPlayerLayer path) and a wide-format fallback (`mpv`, libmpv
/// via media_kit). See docs/ios.md "What routes to which engine".
public enum PlaybackEngineKind: Equatable {
  case avPlayer
  case mpv
}

/// Extensions AVPlayer accepts: HLS and MP4/fMP4-family containers.
private let avPlayerExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "m4a", "mp3", "aac"]

/// Extensions AVPlayer rejects outright — raw MPEG-TS, MKV, and the rest of
/// the wide-format set mpv covers. Listed explicitly (rather than left
/// implicit in the `mpv` default) so the routing table in docs/ios.md and
/// this source stay readably in sync; membership does not change behavior,
/// since anything not in `avPlayerExtensions` already falls through to mpv.
/// Kept identical to Dart's `_kMpvExtensions` (`lib/player/ios_engine.dart`).
private let mpvExtensions: Set<String> = [
  "ts", "m2ts", "mkv", "avi", "flv", "webm", "mpg", "mpeg", "wmv", "vob",
  "divx", "rmvb", "ogv",
]

private let avPlayerSchemes: Set<String> = ["http", "https", "file"]

/// Defensive **mirror** of the Dart engine selector (`selectIosEngine` in
/// `lib/player/ios_engine.dart`) — selection is decided in Dart because the
/// trigger is the resolved stream's container, which Dart already knows, and
/// because a pure function is unit-testable at zero cost there too. This
/// Swift copy exists only to reject an impossible scheme defensively; it
/// never overrides the Dart decision it mirrors. Does **not** implement the
/// Dart selector's rule 1 (a per-session memo of "this content already
/// failed on AVPlayer") — that is caller-side runtime-fallback state, not a
/// pure function of the URL, and stays entirely in Dart. Rules, in order,
/// from docs/ios.md "What routes to which engine":
///
/// 1. Scheme not `http`/`https`/`file` (rtmp, rtsp, udp, rtp, mms) → mpv.
/// 2. Extension of the last path segment, query and fragment stripped:
///    `m3u8`/`mp4`/`m4v`/`mov`/`m4a`/`mp3`/`aac` → AVPlayer;
///    `ts`/`m2ts`/`mkv`/`avi`/`flv`/`webm`/`mpg`/`mpeg`/`wmv`/`vob` → mpv.
/// 3. No extension, or an unknown one → mpv (the load-bearing default: a
///    wrong guess toward mpv costs quality/SDR, a wrong guess toward AVPlayer
///    costs a visible failure and a reopen beat).
public func selectEngine(url: String) -> PlaybackEngineKind {
  guard let components = URLComponents(string: url) else { return .mpv }
  guard let scheme = components.scheme?.lowercased(), avPlayerSchemes.contains(scheme) else {
    return .mpv
  }

  // `components.path` already excludes the query string and fragment, so no
  // separate stripping step is needed once the URL is parsed this way.
  let ext = fileExtension(ofPath: components.path)
  if ext.isEmpty { return .mpv }

  return avPlayerExtensions.contains(ext) ? .avPlayer : .mpv
}

/// Lowercased extension of `path`'s last non-empty segment, or `""` when
/// there isn't one: no path, a trailing slash, a dotless segment, a segment
/// ending in `.`, or a **dotfile** — a segment whose name starts with `.`
/// (the dot is position 0, so there is nothing before it to call a
/// filename). Mirrors Dart's `_extensionOf` (`lib/player/ios_engine.dart`)
/// exactly, including the dotfile exclusion: a naive "substring after the
/// last dot" would wrongly read `.mp4` as extension `mp4` instead of `''`.
private func fileExtension(ofPath path: String) -> String {
  var last = ""
  for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
    if !segment.isEmpty { last = String(segment) }
  }
  guard let dotIndex = last.lastIndex(of: "."), dotIndex != last.startIndex else { return "" }
  let afterDot = last.index(after: dotIndex)
  if afterDot == last.endIndex { return "" }
  return String(last[afterDot...]).lowercased()
}
