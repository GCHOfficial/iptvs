import Foundation

/// Compact top-bar/overlay badge strings, ported from Android's
/// `PlayerUiState`/`PlayerControls.kt` (`android/app/src/main/kotlin/.../player/`).
/// Free functions rather than methods on a UI-state object, since this Core
/// package has no view-model of its own — the iOS overlay is the existing
/// Dart `EmbeddedPlayerControls` (see docs/ios.md "Native code layout"),
/// which already owns badge formatting on its side; these exist for the
/// pieces of state, if any, that get formatted on the Swift engine-shim side
/// before crossing the method channel.
public enum BadgeFormatting {
  /// Compact resolution badge, e.g. "1080p" / "4K"; `nil` when the size isn't
  /// known yet. Matches Windows `ResolutionBadge` and Android
  /// `PlayerUiState.resolutionBadge`.
  public static func resolutionBadge(width: Int, height: Int) -> String? {
    guard height > 0, width > 0 else { return nil }
    if height >= 2000 || width >= 3500 { return "4K" }
    if height >= 1400 || width >= 2400 { return "1440p" }
    if height >= 1000 || width >= 1800 { return "1080p" }
    if height >= 700 || width >= 1200 { return "720p" }
    return "SD"
  }

  /// Compact HDR badge derived from an already-formatted dynamic-range label
  /// (see `dynamicRangeLabel`); `nil` when SDR/unknown. Matches Android
  /// `PlayerUiState.hdrBadge`.
  public static func hdrBadge(dynamicRange: String) -> String? {
    let lower = dynamicRange.lowercased()
    if lower.contains("dolby") { return "DV" }
    if dynamicRange.contains("HDR10+") { return "HDR10+" }
    if dynamicRange.contains("HDR10") { return "HDR10" }
    if dynamicRange.contains("HLG") { return "HLG" }
    if dynamicRange.hasPrefix("HDR") { return "HDR" }
    return nil
  }

  /// Compact frame-rate badge, e.g. "50fps" / "23.976fps"; `nil` when unknown
  /// (`fps <= 0`). Matches Android `PlayerUiState.fpsBadge`: rounds to 3
  /// decimal places, then drops a trailing `.000` (or trailing zeros) so
  /// whole frame rates print without a decimal point.
  public static func fpsBadge(fps: Double) -> String? {
    guard fps > 0 else { return nil }
    return "\(trimmedDecimal(fps))fps"
  }

  /// A number rendered the way every player label in this repo renders one:
  /// rounded to 3 decimal places, then stripped of trailing zeros so a whole
  /// value prints without a decimal point (`25`, `23.976`, `0.75`, `1`).
  ///
  /// Extracted from `fpsBadge` because three surfaces need the identical rule —
  /// the fps badge, the info panel's "Frame rate" row (`25 fps`), and the speed
  /// menu/button labels (`1×`, `0.75×`) — and Kotlin duplicates it in all three
  /// (`PlayerUiState.fpsBadge`, `InfoPanel.formatFps`, `speedOptionLabel`),
  /// which is exactly how they would drift.
  public static func trimmedDecimal(_ value: Double) -> String {
    let rounded = (value * 1000).rounded() / 1000
    if rounded == rounded.rounded(.towardZero) {
      return String(Int64(rounded))
    }
    var formatted = String(format: "%.3f", rounded)
    while formatted.hasSuffix("0") { formatted.removeLast() }
    if formatted.hasSuffix(".") { formatted.removeLast() }
    return formatted
  }

  /// Short source-name badge, truncated so a long provider label can't crowd
  /// the bar; `nil` when the name is blank. Matches Android
  /// `PlayerUiState.sourceBadge`.
  public static func sourceBadge(name: String?) -> String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > 20 else { return trimmed }
    let prefix = trimmed.prefix(19)
    return "\(prefix)…"
  }

  /// Elapsed/remaining time label for the seek bar, e.g. "3:07" or "1:02:03".
  /// `ms <= 0` reads as "0:00" rather than a negative or blank label. Matches
  /// Android `formatTime` (`PlayerControls.kt`).
  public static func formatTime(ms: Int64) -> String {
    guard ms > 0 else { return "0:00" }
    let totalSeconds = ms / 1000
    let h = totalSeconds / 3600
    let m = (totalSeconds % 3600) / 60
    let s = totalSeconds % 60
    // Built manually rather than via `String(format:)`: `%d` with a 64-bit
    // argument is platform-fragile (it can read the wrong vararg width), and
    // `Int64` is exactly what a millisecond timestamp needs here.
    if h > 0 {
      return "\(h):\(pad2(m)):\(pad2(s))"
    }
    return "\(m):\(pad2(s))"
  }

  private static func pad2(_ n: Int64) -> String {
    n < 10 ? "0\(n)" : "\(n)"
  }
}
