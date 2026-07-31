import XCTest
@testable import IptvsPlayerCore

/// Step 9's colorimetry/codec table. The AVFoundation reads that feed it can
/// only be exercised on a device; everything downstream of them is here.
final class StreamInfoMappingTests: XCTestCase {
  // MARK: Colorimetry → the shared label vocabulary

  func testPqTransferMapsToTheGammaDartAlreadyUnderstands() {
    let mapped = iosColorimetry(
      transferFunction: "SMPTE_ST_2084_PQ",
      colorPrimaries: "ITU_R_2020",
      yCbCrMatrix: "ITU_R_2020",
      videoCodecFourCC: "hvc1"
    )
    XCTAssertEqual(mapped.gamma, "pq")
    XCTAssertEqual(mapped.primaries, "bt.2020")
    XCTAssertEqual(mapped.matrix, "bt.2020")
    XCTAssertEqual(
      dynamicRangeLabel(gamma: mapped.gamma, primaries: mapped.primaries, matrix: mapped.matrix),
      "HDR10 · PQ"
    )
  }

  func testHlgTransferIsNotMisreadAsPqAndViceVersa() {
    // Both spellings carry "2100"/"2084"-era tokens; the order of the checks is
    // what keeps them apart.
    XCTAssertEqual(
      iosColorimetry(
        transferFunction: "ITU_R_2100_HLG",
        colorPrimaries: "ITU_R_2020",
        yCbCrMatrix: nil,
        videoCodecFourCC: "hvc1"
      ).gamma,
      "hlg"
    )
    XCTAssertEqual(
      iosColorimetry(
        transferFunction: "SMPTE_ST_2084_PQ",
        colorPrimaries: nil,
        yCbCrMatrix: nil,
        videoCodecFourCC: nil
      ).gamma,
      "pq"
    )
  }

  func testDolbyVisionComesFromTheCodecTagBecauseAvFoundationHasNoColourSpelling() {
    for fourCC in ["dvh1", "dvhe", "dva1", "dvav", "DVH1"] {
      XCTAssertTrue(iosIsDolbyVision(fourCC), fourCC)
      let mapped = iosColorimetry(
        transferFunction: "ITU_R_709_2",
        colorPrimaries: "ITU_R_709_2",
        yCbCrMatrix: "ITU_R_709_2",
        videoCodecFourCC: fourCC
      )
      XCTAssertEqual(mapped.matrix, "dolbyvision")
      XCTAssertEqual(
        dynamicRangeLabel(gamma: mapped.gamma, primaries: mapped.primaries, matrix: mapped.matrix),
        "Dolby Vision"
      )
    }
    XCTAssertFalse(iosIsDolbyVision("hvc1"))
    XCTAssertFalse(iosIsDolbyVision(nil))
  }

  func testPlainRec709ReadsSdrAndNothingKnownStaysEmpty() {
    let sdr = iosStreamInfo(
      format: IosStreamFormat(
        videoCodecFourCC: "avc1",
        transferFunction: "ITU_R_709_2",
        colorPrimaries: "ITU_R_709_2",
        yCbCrMatrix: "ITU_R_709_2"
      ),
      edrHeadroom: 4.0
    )
    XCTAssertEqual(sdr.dynamicRange, "SDR")

    let unknown = iosStreamInfo(format: IosStreamFormat(), edrHeadroom: 4.0)
    // Empty, not "SDR": the info panel omits the row rather than making a claim.
    XCTAssertEqual(unknown.dynamicRange, "")
    XCTAssertTrue(IosStreamFormat().isEmpty)
  }

  // MARK: The EDR display gate

  func testHdrSourceOnAnSdrPanelReportsSdr() {
    // The whole point: an iPhone SE-class LCD has no EDR headroom, AVFoundation
    // tone-maps, and a badge reading HDR10 would be a claim the viewer can't
    // check. Mirrors Linux reading post-tone-map `video-target-params`.
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "HDR10 · PQ", edrHeadroom: 1.0), "SDR")
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "Dolby Vision", edrHeadroom: 1.0), "SDR")
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "HLG", edrHeadroom: 0.9), "SDR")
  }

  func testHdrSourceOnAnEdrPanelIsReportedAsIs() {
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "HDR10 · PQ", edrHeadroom: 8.0), "HDR10 · PQ")
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "HLG", edrHeadroom: 1.01), "HLG")
  }

  func testAbsentHeadroomIsAnAbsenceNotAVeto() {
    // iOS 15 has no `potentialEDRHeadroom`. Absence must not silently downgrade
    // every badge on the platform — the same "a null opinion is an absence"
    // rule `decideIosFallbackAction` applies to its native facts.
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "HDR10 · PQ", edrHeadroom: nil), "HDR10 · PQ")
  }

  func testUnknownSourceStaysUnknownThroughTheGate() {
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "", edrHeadroom: 1.0), "")
    XCTAssertEqual(iosDynamicRangeForDisplay(sourceLabel: "", edrHeadroom: nil), "")
  }

  func testGatedBadgeFlowsThroughToTheCompactHdrBadge() {
    let info = iosStreamInfo(
      format: IosStreamFormat(
        videoCodecFourCC: "hvc1",
        transferFunction: "SMPTE_ST_2084_PQ",
        colorPrimaries: "ITU_R_2020"
      ),
      edrHeadroom: 1.0
    )
    XCTAssertEqual(info.dynamicRange, "SDR")
    XCTAssertNil(BadgeFormatting.hdrBadge(dynamicRange: info.dynamicRange))
  }

  func testHdr10PlusIsNeverReportedOnThisPlatform() {
    // AVFoundation exposes no ST2094-40 metadata, so a real HDR10+ stream reads
    // as plain HDR10 — an under-claim by design (docs/ios.md "Known parity gaps").
    let info = iosStreamInfo(
      format: IosStreamFormat(
        videoCodecFourCC: "hvc1",
        transferFunction: "SMPTE_ST_2084_PQ",
        colorPrimaries: "ITU_R_2020"
      ),
      edrHeadroom: 8.0
    )
    XCTAssertEqual(info.dynamicRange, "HDR10 · PQ")
    XCTAssertEqual(BadgeFormatting.hdrBadge(dynamicRange: info.dynamicRange), "HDR10")
  }

  // MARK: Codec labels

  func testVideoCodecLabelsMatchAndroid() {
    XCTAssertEqual(iosVideoCodecLabel("hvc1"), "HEVC")
    XCTAssertEqual(iosVideoCodecLabel("hev1"), "HEVC")
    XCTAssertEqual(iosVideoCodecLabel("avc1"), "H.264")
    XCTAssertEqual(iosVideoCodecLabel("dvh1"), "Dolby Vision")
    XCTAssertEqual(iosVideoCodecLabel("av01"), "AV1")
    XCTAssertEqual(iosVideoCodecLabel("vp09"), "VP9")
    XCTAssertEqual(iosVideoCodecLabel("mp2v"), "MPEG-2")
    XCTAssertEqual(iosVideoCodecLabel("zzzz"), "ZZZZ")
    XCTAssertEqual(iosVideoCodecLabel(nil), "")
    XCTAssertEqual(iosVideoCodecLabel("   "), "")
  }

  func testAudioCodecLabelsTolerateTheRealFourCcSpellings() {
    // `kAudioFormatMPEG4AAC` really is "aac " with a trailing space, and
    // `kAudioFormatMPEGLayer3` really is ".mp3" with a leading dot.
    XCTAssertEqual(iosAudioCodecLabel("aac "), "AAC")
    XCTAssertEqual(iosAudioCodecLabel(".mp3"), "MP3")
    XCTAssertEqual(iosAudioCodecLabel("ac-3"), "AC-3")
    XCTAssertEqual(iosAudioCodecLabel("ec-3"), "E-AC-3")
    XCTAssertEqual(iosAudioCodecLabel("ac-4"), "AC-4")
    XCTAssertEqual(iosAudioCodecLabel("opus"), "Opus")
    XCTAssertEqual(iosAudioCodecLabel(nil), "")
  }

  func testAudioRowRendersCodecAndChannelsTogether() {
    var state = PlayerChromeState()
    let info = iosStreamInfo(
      format: IosStreamFormat(audioCodecFourCC: "ac-3", audioChannels: 6),
      edrHeadroom: nil
    )
    state.audioCodec = info.audioCodec
    state.audioChannels = info.audioChannels
    XCTAssertEqual(
      state.infoRows(),
      [PlayerInfoRow(label: "Audio", value: "AC-3 · 5.1")]
    )
  }

  // MARK: Frame rate

  func testDeclaredFrameRateWinsAndIsNotSnapped() {
    XCTAssertEqual(iosResolvedFrameRate(declared: 23.976, measured: 30), 23.976)
    XCTAssertEqual(iosResolvedFrameRate(declared: 50, measured: 0), 50)
  }

  func testMeasuredFrameRateSnapsToAStandardRate() {
    XCTAssertEqual(iosResolvedFrameRate(declared: 0, measured: 49.87), 50)
    XCTAssertEqual(iosResolvedFrameRate(declared: 0, measured: 25.2), 25)
    XCTAssertEqual(iosResolvedFrameRate(declared: 0, measured: 29.98), 29.97)
    // First match wins, exactly as in Android's `snapFps`: 24.1 is within 0.6 of
    // 23.976 *and* of 24, and the table's order decides. Pinned so a reordering
    // of the table reads as the behaviour change it is.
    XCTAssertEqual(iosResolvedFrameRate(declared: 0, measured: 24.1), 23.976)
    // Nothing within tolerance: rounded to 2 dp rather than snapped to a lie.
    XCTAssertEqual(iosResolvedFrameRate(declared: 0, measured: 15.333), 15.33)
    XCTAssertEqual(iosResolvedFrameRate(declared: 0, measured: 0), 0)
  }

  func testFpsBadgeReadsTheSnappedValue() {
    let info = iosStreamInfo(
      format: IosStreamFormat(declaredFrameRate: 0, measuredFrameRate: 59.9),
      edrHeadroom: nil
    )
    XCTAssertEqual(info.fps, 59.94)
    XCTAssertEqual(BadgeFormatting.fpsBadge(fps: info.fps), "59.94fps")
  }

  // MARK: Media selection

  func testOptionIdsRoundTripAndTheOffSentinelDoesNot() {
    XCTAssertEqual(iosMediaOptionId(index: 0), "0")
    XCTAssertEqual(iosMediaOptionIndex(id: iosMediaOptionId(index: 3)), 3)
    // "Off" is what maps to `select(nil, in:)`, so it must never parse as an
    // index — a subtitle group's option 0 would otherwise be selected instead.
    XCTAssertNil(iosMediaOptionIndex(id: playerSubtitleOffId))
    XCTAssertNil(iosMediaOptionIndex(id: nil))
    XCTAssertNil(iosMediaOptionIndex(id: "english"))
    XCTAssertNil(iosMediaOptionIndex(id: "-1"))
  }

  func testOptionLabelFallsBackWhenAvFoundationOffersNoDisplayName() {
    XCTAssertEqual(
      iosMediaOptionLabel(displayName: "English (SDH)", languageTag: "en", index: 0),
      "English (SDH)"
    )
    XCTAssertEqual(iosMediaOptionLabel(displayName: "  ", languageTag: "fr", index: 1), "fr")
    XCTAssertEqual(iosMediaOptionLabel(displayName: nil, languageTag: nil, index: 2), "Track 3")
  }

  func testSubtitleMenuPrependsOffOnlyWhenThereIsARealTrack() {
    XCTAssertEqual(iosSubtitleMenuOptions(tracks: []), [])

    let options = iosSubtitleMenuOptions(
      tracks: [PlayerTrackOption(id: "0", label: "English")]
    )
    XCTAssertEqual(options.first?.id, playerSubtitleOffId)
    XCTAssertEqual(options.count, 2)

    var state = PlayerChromeState()
    state.subtitleTracks = options
    XCTAssertTrue(state.showSubtitleButton)

    state.subtitleTracks = iosSubtitleMenuOptions(tracks: [])
    XCTAssertFalse(state.showSubtitleButton)
  }

  func testAudioButtonNeedsARealChoice() {
    var state = PlayerChromeState()
    state.audioTracks = [PlayerTrackOption(id: "0", label: "English")]
    XCTAssertFalse(state.showAudioButton)
    state.audioTracks.append(PlayerTrackOption(id: "1", label: "Français"))
    XCTAssertTrue(state.showAudioButton)
  }
}
