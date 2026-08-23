import Foundation

/// A live EPG programme snapshot (now or next), captured at play time.
///
/// Port of Android's `com.gchofficial.iptvs.player.EpgEntry`, including its
/// validity rule: a programme with no title, a negative start, or a stop at or
/// before its start is treated as *absent* rather than rendered as a degenerate
/// zero-length strip (`HdrPlayerActivity.epgEntry`).
public struct PlayerEpgEntry: Equatable, Sendable {
  public let title: String
  public let startMs: Int64
  public let stopMs: Int64
  public let description: String?

  public init(title: String, startMs: Int64, stopMs: Int64, description: String? = nil) {
    self.title = title
    self.startMs = startMs
    self.stopMs = stopMs
    self.description = description
  }

  /// Fraction elapsed at `atMs` within `startMs..stopMs`, clamped to `0...1`.
  /// Mirrors Kotlin `EpgEntry.progressAt`.
  public func progress(at atMs: Int64) -> Double {
    let span = max(stopMs - startMs, 1)
    let elapsed = Double(atMs - startMs) / Double(span)
    return min(max(elapsed, 0), 1)
  }
}

/// An external subtitle track passed in on `open`. Port of Android's
/// `SubtitleSpec`; `label`/`language` default to empty rather than nil so the
/// chrome can render them without optional juggling.
public struct PlayerSubtitleSpec: Equatable, Sendable {
  public let url: String
  public let label: String
  public let language: String

  public init(url: String, label: String, language: String) {
    self.url = url
    self.label = label
    self.language = language
  }
}

/// How much media to hold ahead of playback — the per-source preset chosen in
/// the app, mirrored here so one setting means the same thing on every surface.
///
/// Values match Dart's `BufferPreset` and Kotlin's, including the fallback:
/// anything unrecognised — a name a newer app build wrote — is `.normal`,
/// because degrading to the default is always safe and guessing is not.
public enum PlayerBufferPreset: String, Sendable {
  case low
  case normal
  case high

  public init(name: String?) {
    switch name?.lowercased() {
    case "low": self = .low
    case "high": self = .high
    default: self = .normal
    }
  }

  /// Seconds to hand `AVPlayerItem.preferredForwardBufferDuration`, or `nil` to
  /// leave it at AVFoundation's automatic behaviour.
  ///
  /// `.normal` is deliberately `nil` rather than a number. The documented
  /// default is `0`, meaning "the player picks an appropriate level", and that
  /// adaptive choice is what every build so far has shipped — writing a
  /// concrete duration in its place would silently change the default install
  /// while claiming to preserve it, which is the one thing this preset must not
  /// do. The same reason `mpvBufferOptions(.normal)` is an empty map.
  ///
  /// Apple's own warning applies to `.low`: a small value raises the chance of
  /// a stall. That is exactly the trade the preset offers, and the app's hint
  /// text says so.
  public var preferredForwardBufferSeconds: Double? {
    switch self {
    case .low: return 3
    case .normal: return nil
    case .high: return 30
    }
  }
}

/// The parsed `open` method-call payload for the native iOS player.
///
/// This exists in `Core` — Foundation-only, no Flutter or AVFoundation — for
/// exactly one reason: **the key names and the accept/reject rules are a
/// cross-language contract with `_tryOpenNativeHdrPlayer`
/// (`lib/player/player_screen.dart`), and a typo in either is otherwise
/// invisible.** A misspelled key silently degrades a feature (no EPG strip, no
/// favorite star, VOD restarting from zero) on a device the maintainer has to
/// reach for to notice. Here, `swift test` catches it on the CI host in seconds.
///
/// The payload is deliberately **identical to the one Android's `MainActivity`
/// unpacks into `HdrPlayerActivity`'s intent extras** (minus `adoptShared`,
/// which iOS has no shared-engine adoption for — see docs/ios.md "Known parity
/// gaps"), so the rules below are ports of that unpacking rather than new
/// policy:
///
/// - A missing or blank `url` makes the whole request invalid (`init?` returns
///   nil). Android's `open` handler answers `result.error("bad_args", …)` and
///   `HdrPlayerActivity` `finish()`es on a blank URL; iOS answers `false` so
///   Dart falls through to the embedded media_kit surface instead.
/// - `headers` drops any entry with a blank key or a blank value, and
///   stringifies non-string values (`MainActivity`: `entry.value.toString()`).
/// - `subtitles` drops entries with a blank `url`; `label`/`language` default to
///   `""` (`HdrPlayerActivity.subtitleSpecs`).
/// - EPG entries require a non-blank title, `startMs >= 0`, and
///   `stopMs > startMs`; otherwise the entry is nil
///   (`HdrPlayerActivity.epgEntry`).
/// - `resumeMs` is clamped to `>= 0`; `0` means "play from the top".
/// - `soakAutoCloseMs` survives only when strictly positive, matching the
///   Android extra's `> 0L` guard.
///
/// **Numbers arrive as `NSNumber`, not `Int`.** Dart sends the EPG epochs as
/// *doubles* (`_epgPayload`'s `.toDouble()`) and `resumeMs` as an int, and
/// Flutter's standard codec bridges both to `NSNumber`. Reading them as
/// `as? Int` would succeed for one and silently fail for the other, which is
/// why every numeric goes through `int64Value`. Android hits the same trap and
/// solves it the same way (`args[key] as? Number)?.toLong()`).
public struct PlayerOpenRequest: Equatable, Sendable {
  public let url: String
  public let title: String
  public let sourceName: String?
  public let headers: [String: String]
  public let isLive: Bool

  /// How much media to hold ahead of playback, chosen per source in the app.
  ///
  /// The same three-way preset Android and mpv take, so one setting means the
  /// same thing on every surface. See `docs/player.md` "Buffer presets" — in
  /// particular why `.normal` must leave AVPlayer's automatic buffering alone
  /// rather than pick a number that resembles it.
  public let bufferPreset: PlayerBufferPreset

  /// VOD resume point in ms; `0` plays from the top. Never set for live.
  public let resumeMs: Int64

  /// Whether to show the favorite star at all, and its seed state. The native
  /// controller toggles `isFavorite` locally and reports the final value back
  /// on `nativeClosed` — there is no live channel from the controller to Dart,
  /// exactly as on Android (docs/player.md "Live favorite star").
  public let canFavorite: Bool
  public let isFavorite: Bool

  /// Debug-only integration-test soak: auto-close the controller after this
  /// many ms so `integration_test/player_soak_test.dart` can cycle it
  /// unattended. Nil unless Dart sent a positive value.
  public let soakAutoCloseMs: Int64?

  public let epgNow: PlayerEpgEntry?
  public let epgNext: PlayerEpgEntry?
  public let subtitles: [PlayerSubtitleSpec]

  public init(
    url: String,
    title: String = "",
    sourceName: String? = nil,
    headers: [String: String] = [:],
    isLive: Bool = false,
    bufferPreset: PlayerBufferPreset = .normal,
    resumeMs: Int64 = 0,
    canFavorite: Bool = false,
    isFavorite: Bool = false,
    soakAutoCloseMs: Int64? = nil,
    epgNow: PlayerEpgEntry? = nil,
    epgNext: PlayerEpgEntry? = nil,
    subtitles: [PlayerSubtitleSpec] = []
  ) {
    self.url = url
    self.title = title
    self.sourceName = sourceName
    self.headers = headers
    self.isLive = isLive
    self.bufferPreset = bufferPreset
    self.resumeMs = resumeMs
    self.canFavorite = canFavorite
    self.isFavorite = isFavorite
    self.soakAutoCloseMs = soakAutoCloseMs
    self.epgNow = epgNow
    self.epgNext = epgNext
    self.subtitles = subtitles
  }

  /// Parses a Flutter `open` argument map. Returns nil when the payload cannot
  /// describe a playable stream, which the plugin answers as `false` rather
  /// than as a channel error — Dart treats both the same way (fall back to the
  /// embedded surface), and `false` keeps the diagnostics log free of a
  /// `PlatformException` for what is a routing decision, not a fault.
  public init?(arguments: Any?) {
    guard let map = arguments as? [AnyHashable: Any] else { return nil }
    guard let url = PlayerOpenRequest.nonBlankString(map["url"]) else { return nil }

    self.url = url
    title = PlayerOpenRequest.string(map["title"]) ?? ""
    sourceName = PlayerOpenRequest.nonBlankString(map["sourceName"])
    headers = PlayerOpenRequest.parseHeaders(map["headers"])
    isLive = map["isLive"] as? Bool ?? false
    bufferPreset = PlayerBufferPreset(
      name: PlayerOpenRequest.string(map["bufferPreset"])
    )
    resumeMs = max(0, PlayerOpenRequest.int64(map["resumeMs"]) ?? 0)
    canFavorite = map["canFavorite"] as? Bool ?? false
    isFavorite = map["isFavorite"] as? Bool ?? false

    let soak = PlayerOpenRequest.int64(map["soakAutoCloseMs"]) ?? 0
    soakAutoCloseMs = soak > 0 ? soak : nil

    epgNow = PlayerOpenRequest.parseEpg(
      map,
      titleKey: "epgNowTitle",
      startKey: "epgNowStartMs",
      stopKey: "epgNowStopMs",
      descriptionKey: "epgNowDesc"
    )
    epgNext = PlayerOpenRequest.parseEpg(
      map,
      titleKey: "epgNextTitle",
      startKey: "epgNextStartMs",
      stopKey: "epgNextStopMs",
      descriptionKey: nil
    )
    subtitles = PlayerOpenRequest.parseSubtitles(map["subtitles"])
  }

  // MARK: - Parsing helpers

  static func parseHeaders(_ value: Any?) -> [String: String] {
    guard let raw = value as? [AnyHashable: Any] else { return [:] }
    var headers: [String: String] = [:]
    for (key, value) in raw {
      // `key.base` rather than casting the `AnyHashable` itself: the documented
      // way back to the underlying value, and it doesn't rely on a dynamic cast
      // seeing through the box.
      guard let name = nonBlankString(key.base) else { continue }
      guard let text = nonBlankString(stringify(value)) else { continue }
      headers[name] = text
    }
    return headers
  }

  static func parseSubtitles(_ value: Any?) -> [PlayerSubtitleSpec] {
    guard let rows = value as? [Any] else { return [] }
    return rows.compactMap { row in
      guard let entry = row as? [AnyHashable: Any] else { return nil }
      guard let url = nonBlankString(entry["url"]) else { return nil }
      return PlayerSubtitleSpec(
        url: url,
        label: string(entry["label"]) ?? "",
        language: string(entry["language"]) ?? ""
      )
    }
  }

  static func parseEpg(
    _ map: [AnyHashable: Any],
    titleKey: String,
    startKey: String,
    stopKey: String,
    descriptionKey: String?
  ) -> PlayerEpgEntry? {
    guard let title = nonBlankString(map[titleKey]) else { return nil }
    guard let start = int64(map[startKey]), let stop = int64(map[stopKey]) else { return nil }
    guard start >= 0, stop > start else { return nil }
    let description = descriptionKey.flatMap { nonBlankString(map[$0]) }
    return PlayerEpgEntry(title: title, startMs: start, stopMs: stop, description: description)
  }

  /// `NSNumber`-first numeric read: Dart sends some of these as doubles and
  /// some as ints, and both bridge to `NSNumber`. See the type doc.
  static func int64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let int = value as? Int { return Int64(int) }
    if let double = value as? Double { return Int64(double) }
    return nil
  }

  static func string(_ value: Any?) -> String? {
    value as? String
  }

  static func stringify(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let value { return String(describing: value) }
    return nil
  }

  /// Non-nil only for a string with at least one non-whitespace character —
  /// the Swift equivalent of Kotlin's `isNullOrBlank()`/`takeIf { isNotBlank() }`
  /// guards the Android side uses on every one of these fields.
  static func nonBlankString(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }
}
