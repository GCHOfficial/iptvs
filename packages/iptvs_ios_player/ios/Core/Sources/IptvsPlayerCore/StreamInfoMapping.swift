import Foundation

/// The raw colorimetry/codec facts AVFoundation can be asked for, in a
/// Foundation-only shape.
///
/// **Why a struct in `Core` rather than reading AVFoundation inline.** iOS has
/// *two* sources for these, and which one answers depends on the container — so
/// the collection step is genuinely branchy while the interpretation step is
/// pure table lookup. Splitting them puts the whole table under `swift test`:
///
/// 1. **Track format descriptions** (`AVPlayerItemTrack.assetTrack` →
///    `formatDescriptions`) — authoritative, and what a progressive MP4/fMP4
///    item exposes.
/// 2. **`AVAssetVariant`** (iOS 15+) — the HLS route, because
///    `AVPlayerItemTrack.assetTrack` is documented as `nil` for HTTP Live
///    Streaming. This matters more on iOS than it looks: defaulting Xtream to
///    `m3u8` (docs/ios.md "The `streamExtension` lever") makes HLS *the* common
///    AVPlayer path, so an implementation that only read format descriptions
///    would leave the HDR badge permanently blank on exactly the streams the
///    AVPlayer engine exists for.
///
/// Values are carried as strings deliberately: `CMFormatDescription`'s colour
/// tags are `CFString`s and the codec tags are FourCCs, and turning both into
/// text at the boundary is what lets this file be Foundation-only.
public struct IosStreamFormat: Equatable, Sendable {
  /// Video codec FourCC, e.g. `"hvc1"`, `"avc1"`, `"dvh1"`.
  public var videoCodecFourCC: String?

  /// `kCMFormatDescriptionExtension_TransferFunction` as text (e.g.
  /// `"SMPTE_ST_2084_PQ"`), or the `AVVideoRange`-derived `"pq"`/`"hlg"`/`"sdr"`.
  public var transferFunction: String?

  /// `kCMFormatDescriptionExtension_ColorPrimaries` as text, e.g. `"ITU_R_2020"`.
  public var colorPrimaries: String?

  /// `kCMFormatDescriptionExtension_YCbCrMatrix` as text.
  public var yCbCrMatrix: String?

  /// Container-declared frame rate when known (`0` otherwise). Never a measured
  /// one — see ``iosResolvedFrameRate(declared:measured:)``.
  public var declaredFrameRate: Double

  /// Live-measured frame rate (`AVPlayerItemTrack.currentVideoFrameRate`), used
  /// only when nothing declared one.
  public var measuredFrameRate: Double

  /// Audio codec FourCC, e.g. `"ac-3"`, `"aac "`, `"ec-3"`.
  public var audioCodecFourCC: String?

  /// Channel count, or `0` when unknown. Unknown is the normal answer on the
  /// HLS/variant route below iOS 17, where the per-rendition channel count
  /// simply isn't exposed.
  public var audioChannels: Int

  public init(
    videoCodecFourCC: String? = nil,
    transferFunction: String? = nil,
    colorPrimaries: String? = nil,
    yCbCrMatrix: String? = nil,
    declaredFrameRate: Double = 0,
    measuredFrameRate: Double = 0,
    audioCodecFourCC: String? = nil,
    audioChannels: Int = 0
  ) {
    self.videoCodecFourCC = videoCodecFourCC
    self.transferFunction = transferFunction
    self.colorPrimaries = colorPrimaries
    self.yCbCrMatrix = yCbCrMatrix
    self.declaredFrameRate = declaredFrameRate
    self.measuredFrameRate = measuredFrameRate
    self.audioCodecFourCC = audioCodecFourCC
    self.audioChannels = audioChannels
  }

  /// True when nothing usable was collected, so the caller keeps trying on later
  /// ticks instead of latching an empty readout.
  public var isEmpty: Bool {
    videoCodecFourCC == nil && transferFunction == nil && colorPrimaries == nil
      && audioCodecFourCC == nil && declaredFrameRate <= 0 && measuredFrameRate <= 0
  }
}

/// The already-formatted stream-info fields the chrome renders.
public struct IosStreamInfo: Equatable, Sendable {
  public let dynamicRange: String
  public let videoCodec: String
  public let audioCodec: String
  public let audioChannels: Int
  public let fps: Double

  public init(
    dynamicRange: String,
    videoCodec: String,
    audioCodec: String,
    audioChannels: Int,
    fps: Double
  ) {
    self.dynamicRange = dynamicRange
    self.videoCodec = videoCodec
    self.audioCodec = audioCodec
    self.audioChannels = audioChannels
    self.fps = fps
  }
}

/// Dolby Vision FourCCs. `dvh1`/`dvhe` are HEVC-based (P5, P8.x), `dva1`/`dvav`
/// AVC-based. AVFoundation surfaces DV as the *codec*, never as a colour tag,
/// which is why this is the only DV signal on the platform.
private let dolbyVisionFourCCs: Set<String> = ["dvh1", "dvhe", "dva1", "dvav"]

/// Whether `fourCC` names a Dolby Vision video codec.
public func iosIsDolbyVision(_ fourCC: String?) -> Bool {
  guard let fourCC else { return false }
  return dolbyVisionFourCCs.contains(fourCC.trimmingCharacters(in: .whitespaces).lowercased())
}

/// Translates AVFoundation colour tags into the gamma/primaries/matrix
/// vocabulary ``dynamicRangeLabel(gamma:primaries:matrix:hdr10Plus:)`` speaks.
///
/// Kept as one function so the mapping table is in a single testable place, and
/// so **Dart stays the label authority**: this normalises inputs, it never
/// assembles an output string.
public func iosColorimetry(
  transferFunction: String?,
  colorPrimaries: String?,
  yCbCrMatrix: String?,
  videoCodecFourCC: String?
) -> (gamma: String?, primaries: String?, matrix: String?) {
  let dolby = iosIsDolbyVision(videoCodecFourCC)
  return (
    gamma: normalizedTransfer(transferFunction),
    primaries: normalizedPrimaries(colorPrimaries),
    // Dolby Vision has no colour-tag spelling on this platform, so it is folded
    // into the matrix slot — the same slot mpv's `colormatrix` fills on
    // Windows/Linux, and the one `dynamicRangeLabel` checks first.
    matrix: dolby ? "dolbyvision" : normalizedPrimaries(yCbCrMatrix)
  )
}

private func normalizedTransfer(_ value: String?) -> String? {
  guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
  let lower = raw.lowercased()
  // PQ before HLG: `ITU_R_2100_HLG` and `SMPTE_ST_2084_PQ` are both "2100-era"
  // spellings and a naive substring order would classify PQ as HLG.
  if lower.contains("2084") || lower.contains("pq") { return "pq" }
  if lower.contains("hlg") { return "hlg" }
  return lower
}

private func normalizedPrimaries(_ value: String?) -> String? {
  guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
  let lower = raw.lowercased()
  // `ITU_R_2020` → `bt.2020`, which is the spelling `dynamicRangeLabel`'s
  // `p.contains("2020")` check and the Dart/mpv originals both use.
  if lower.contains("2020") { return "bt.2020" }
  if lower.contains("709") { return "bt.709" }
  if lower.contains("601") || lower.contains("smpte_c") || lower.contains("ebu") {
    return "bt.601"
  }
  return lower
}

/// Applies the **display-honesty gate** to a source-derived dynamic-range label.
///
/// `edrHeadroom` is `UIScreen.potentialEDRHeadroom` (iOS 16+), or `nil` when the
/// platform can't say. A value of `1.0` means the display has no headroom above
/// SDR white at all, so AVFoundation's EDR pipeline is tone-mapping the HDR
/// source down before the viewer ever sees it — and a badge reading "HDR10 · PQ"
/// over a tone-mapped SDR picture is a lie the user has no way to check.
///
/// **This mirrors Linux, which is the platform that already faced the same
/// choice**: its badge reads mpv's `video-target-params` (post-tone-map) rather
/// than the source-side `video-params`, precisely so an HDR source rendered to
/// an SDR output reads SDR (docs/player.md, Linux section). Android and Windows
/// read source/decoder-side values instead, but they have a reason iOS doesn't:
/// Android's decoder `MediaFormat` *is* what goes out over HDMI, and Windows'
/// native HWND path presents through D3D11 to a display the user chose to put in
/// HDR mode. iOS's panel capability is a fixed property of the device.
///
/// Two deliberate conservatisms:
///
/// - **`nil` is an absence, not a veto** — the same rule
///   `decideIosFallbackAction` applies to its native opinions. On iOS 15, where
///   `potentialEDRHeadroom` does not exist, the badge simply reports the source.
/// - **`potentialEDRHeadroom`, never `currentEDRHeadroom`.** The current value
///   varies with brightness and ambient light and legitimately reads `1.0` on a
///   genuinely HDR panel; the potential value is a capability, so gating on it
///   cannot produce a false "SDR" on a phone that really is showing HDR.
///
/// An unknown source (empty label) stays unknown rather than being promoted to
/// `"SDR"` — the info panel omits the row entirely in that case, which is
/// honest, where "SDR" would be a claim.
public func iosDynamicRangeForDisplay(sourceLabel: String, edrHeadroom: Double?) -> String {
  guard !sourceLabel.isEmpty else { return "" }
  guard let edrHeadroom, edrHeadroom <= 1.0 else { return sourceLabel }
  return "SDR"
}

/// Video codec label. Output strings match Android's `ExoPlayerEngine.codecLabel`
/// so the info panel reads identically on both platforms.
public func iosVideoCodecLabel(_ fourCC: String?) -> String {
  guard let raw = fourCC?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
  switch raw.lowercased() {
  case "hvc1", "hev1", "hvc2": return "HEVC"
  case "dvh1", "dvhe", "dva1", "dvav": return "Dolby Vision"
  case "avc1", "avc3": return "H.264"
  case "av01": return "AV1"
  case "vp09", "vp9 ": return "VP9"
  case "mp1v", "mp2v", "hdv1": return "MPEG-2"
  case "mp4v": return "MPEG-4"
  case "jpeg": return "JPEG"
  default: return raw.uppercased()
  }
}

/// Audio codec label, same convention as ``iosVideoCodecLabel(_:)``.
///
/// Note the trailing space in `"aac "` and the leading dot in `".mp3"`: those
/// are the real FourCCs (`kAudioFormatMPEG4AAC`, `kAudioFormatMPEGLayer3`), and
/// trimming them here rather than at the collection site keeps the caller from
/// having to know that.
public func iosAudioCodecLabel(_ fourCC: String?) -> String {
  guard let raw = fourCC?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
  switch raw.lowercased() {
  case "aac", "aach", "aacp", "aacl", "mp4a": return "AAC"
  case "ac-3", "ac3": return "AC-3"
  case "ec-3", "ec3", "eac3": return "E-AC-3"
  case "ac-4", "ac4": return "AC-4"
  case ".mp3", "mp3", ".mp1", ".mp2": return "MP3"
  case "dts", "dtse", "dtsh", "dtsl": return "DTS"
  case "opus": return "Opus"
  case "alac": return "ALAC"
  case "lpcm", "sowt", "twos": return "PCM"
  case "flac": return "FLAC"
  case "vorb": return "Vorbis"
  default: return raw.uppercased()
  }
}

/// Frame rate to display: the container-declared value when there is one,
/// otherwise a live measurement snapped to a standard broadcast rate.
///
/// Same precedence as Android (`ExoPlayerEngine`: "the container-declared rate,
/// when present, is authoritative"), and the same snapping table
/// (`snapFps`, ±0.6 fps) so `50` doesn't render as `49.98`. A declared rate is
/// **not** snapped — `23.976` is exactly what the container said.
public func iosResolvedFrameRate(declared: Double, measured: Double) -> Double {
  if declared > 0 { return declared }
  guard measured > 0 else { return 0 }
  let common: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 120]
  for candidate in common where abs(measured - candidate) <= 0.6 { return candidate }
  return (measured * 100).rounded() / 100
}

/// The whole step-9 readout, from collected facts to rendered fields.
public func iosStreamInfo(format: IosStreamFormat, edrHeadroom: Double?) -> IosStreamInfo {
  let colorimetry = iosColorimetry(
    transferFunction: format.transferFunction,
    colorPrimaries: format.colorPrimaries,
    yCbCrMatrix: format.yCbCrMatrix,
    videoCodecFourCC: format.videoCodecFourCC
  )
  // **HDR10+ is permanently `false` on iOS.** AVFoundation exposes no per-scene
  // ST2094-40 metadata API, unlike the decoder-level reads Android
  // (`KEY_HDR10_PLUS_INFO`), Windows and Linux (mpv `scene-max-r|g|b`) all have.
  // A dynamic-metadata stream therefore reports plain HDR10 here — an
  // under-claim, never an over-claim. See docs/ios.md "Known parity gaps".
  let sourceLabel = dynamicRangeLabel(
    gamma: colorimetry.gamma,
    primaries: colorimetry.primaries,
    matrix: colorimetry.matrix,
    hdr10Plus: false
  )
  return IosStreamInfo(
    dynamicRange: iosDynamicRangeForDisplay(
      sourceLabel: sourceLabel,
      edrHeadroom: edrHeadroom
    ),
    videoCodec: iosVideoCodecLabel(format.videoCodecFourCC),
    audioCodec: iosAudioCodecLabel(format.audioCodecFourCC),
    audioChannels: max(0, format.audioChannels),
    fps: iosResolvedFrameRate(
      declared: format.declaredFrameRate,
      measured: format.measuredFrameRate
    )
  )
}

// MARK: - Media selection

/// A stable id for the media-selection option at `index` in its group's
/// `options` array.
///
/// **Index-based on purpose.** `AVMediaSelectionOption` has no stable public
/// identifier — `displayName` is localised and routinely duplicated ("English"
/// twice, once normal once SDH), `extendedLanguageTag` is optional and equally
/// non-unique on a multi-track stream. The index into `group.options` is stable
/// for the lifetime of the item, and the item is replaced wholesale on every
/// reload (`AvPlayerEngine.load`), which is exactly when the track list is
/// rebuilt. The id space is therefore per-item by construction.
public func iosMediaOptionId(index: Int) -> String { "\(index)" }

/// Parses an id produced by ``iosMediaOptionId(index:)`` back to its index.
/// Returns nil for the subtitle "Off" sentinel and for anything malformed, both
/// of which the caller maps to `select(nil, in:)`.
public func iosMediaOptionIndex(id: String?) -> Int? {
  guard let id, id != playerSubtitleOffId else { return nil }
  guard let index = Int(id), index >= 0 else { return nil }
  return index
}

/// Menu label for a media-selection option, from the facts AVFoundation gives.
///
/// `displayName` is already localised and is what Apple's own UI shows, so it is
/// preferred outright. The fallbacks exist because it is documented as
/// best-effort and comes back empty on some provider HLS renditions.
public func iosMediaOptionLabel(
  displayName: String?,
  languageTag: String?,
  index: Int
) -> String {
  if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
    return displayName
  }
  if let languageTag, !languageTag.trimmingCharacters(in: .whitespaces).isEmpty {
    return languageTag
  }
  return "Track \(index + 1)"
}

/// The subtitle menu's rows: the "Off" sentinel first, then the real tracks.
///
/// Returns an **empty** list when there are no real tracks, rather than a
/// lone "Off" — `PlayerChromeState.showSubtitleButton` already refuses to show a
/// button for an Off-only list, and returning `[]` keeps the two rules from
/// having to agree separately.
public func iosSubtitleMenuOptions(tracks: [PlayerTrackOption]) -> [PlayerTrackOption] {
  guard !tracks.isEmpty else { return [] }
  return [PlayerTrackOption(id: playerSubtitleOffId, label: "Off")] + tracks
}
