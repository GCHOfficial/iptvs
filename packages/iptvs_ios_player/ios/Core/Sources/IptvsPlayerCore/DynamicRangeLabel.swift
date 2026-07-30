import Foundation

/// Pure dynamic-range label from colorimetry (gamma/primaries/matrix).
///
/// Port of Dart's `dynamicRangeLabelFrom` (`lib/player/player_screen.dart`),
/// itself shared by the embedded/Windows and native-Linux paths — same
/// PQ/HLG/BT.2020/Dolby-Vision precedence either way. `hdr10Plus` only
/// distinguishes the two PQ labels; both are HDR. Output strings must stay
/// byte-identical to the Dart copy (`test/dynamic_range_test.dart`), down to
/// the middle-dot separator.
public func dynamicRangeLabel(
  gamma: String? = nil,
  primaries: String? = nil,
  matrix: String? = nil,
  hdr10Plus: Bool = false
) -> String {
  let g = gamma?.lowercased() ?? ""
  let p = primaries?.lowercased() ?? ""
  let m = matrix?.lowercased() ?? ""
  if m.contains("dolby") || g.contains("dolby") { return "Dolby Vision" }
  if g.contains("pq") { return hdr10Plus ? "HDR10+ · PQ" : "HDR10 · PQ" }
  if g.contains("hlg") { return "HLG" }
  if p.contains("2020") { return "HDR · BT.2020" }
  if g.isEmpty && p.isEmpty { return "" }
  return "SDR"
}

/// Whether these colorimetry params describe an HDR source (PQ/HLG/Dolby
/// Vision, or a BT.2020 primaries signal). Port of Dart's `isHdrColorimetry`,
/// derived from `dynamicRangeLabel` so the HDR/SDR precedence stays
/// single-sourced, same as the Dart original.
public func isHdrColorimetry(
  gamma: String? = nil,
  primaries: String? = nil,
  matrix: String? = nil
) -> Bool {
  let label = dynamicRangeLabel(gamma: gamma, primaries: primaries, matrix: matrix)
  return !label.isEmpty && label != "SDR"
}
