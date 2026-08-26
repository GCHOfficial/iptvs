import XCTest

@testable import IptvsPlayerCore

/// Covers the chrome state's derived rules — the half of steps 4/5 that can be
/// verified without a simulator. The UIKit files
/// (`PlayerControlsView`/`ListMenuView`/`InfoPanelView`) deliberately hold no
/// decisions of their own: they read these properties and lay views out, so a
/// green run here means the *behaviour* is right even though the pixels are
/// unverified.
///
/// Where a rule is a port, the Kotlin original is named — these tests are the
/// only thing keeping the two implementations from drifting.
final class PlayerChromeStateTests: XCTestCase {

  // MARK: - Terminal error surface

  func testFreshStateHasNoTerminalError() {
    let state = PlayerChromeState()
    XCTAssertNil(state.errorMessage)
    XCTAssertFalse(state.showErrorOverlay)
  }

  /// The error surface renders **outside** the `controlsVisible` gate, like the
  /// reconnect chip: a failure the viewer only learns about if they happen to
  /// tap first is indistinguishable from the silent hang it exists to replace.
  func testErrorOverlayIsIndependentOfControlVisibility() {
    var state = PlayerChromeState()
    state.errorMessage = PlayerErrorMessages.playbackStopped
    state.setControlsVisible(false)
    XCTAssertTrue(state.showErrorOverlay)
  }

  /// "Reconnecting…" promises a retry is under way; a terminal error says it
  /// isn't. They must never render together, and the error wins.
  func testReconnectChipYieldsToATerminalError() {
    var state = PlayerChromeState()
    state.reconnecting = true
    XCTAssertTrue(state.showReconnectChip)
    state.errorMessage = PlayerErrorMessages.cannotPlay
    XCTAssertFalse(state.showReconnectChip)
    XCTAssertTrue(state.showErrorOverlay)
  }

  /// Fixed strings, never an `AVError` description — those interpolate the
  /// failing URL, and provider URLs carry credentials in the query string and in
  /// path segments (CLAUDE.md: secrets must never reach on-screen errors).
  func testErrorMessagesCarryNoLocatorShapedText() {
    for message in [PlayerErrorMessages.playbackStopped, PlayerErrorMessages.cannotPlay] {
      XCTAssertFalse(message.isEmpty)
      XCTAssertFalse(message.contains("://"))
      XCTAssertFalse(message.contains("http"))
    }
    XCTAssertNotEqual(PlayerErrorMessages.playbackStopped, PlayerErrorMessages.cannotPlay)
  }

  // MARK: - Live vs VOD

  /// The CLAUDE.md invariant, pinned at the one place the iOS chrome decides
  /// it: **live shows no scrubber**, and the decision reads `isLive` — the
  /// provider's own metadata — not the duration, which a live HLS window
  /// reports as a real number often enough to look inferable.
  func testLiveNeverShowsAScrubberEvenWithADuration() {
    var state = PlayerChromeState()
    state.isLive = true
    state.durationMs = 3_600_000
    XCTAssertFalse(state.showScrubber)
    XCTAssertFalse(state.showSkipButtons)
    XCTAssertFalse(state.showSpeedButton)

    state.isLive = false
    XCTAssertTrue(state.showScrubber)
    XCTAssertTrue(state.showSkipButtons)
    XCTAssertTrue(state.showSpeedButton)
  }

  /// VOD with no duration yet still shows the bar (it just reads 0:00) — the
  /// alternative is a control that appears a second into playback.
  func testVodShowsTheScrubberBeforeTheDurationIsKnown() {
    var state = PlayerChromeState()
    state.isLive = false
    state.durationMs = 0
    XCTAssertTrue(state.showScrubber)
    XCTAssertEqual(state.progressFraction, 0)
    XCTAssertEqual(state.durationLabel, "0:00")
  }

  func testProgressFractionClampsAndDividesByDuration() {
    var state = PlayerChromeState()
    state.durationMs = 200_000
    state.positionMs = 50_000
    XCTAssertEqual(state.progressFraction, 0.25, accuracy: 0.0001)
    // A position past the end (a live-edge seek landing beyond a stale
    // duration) must not overfill the bar.
    state.positionMs = 400_000
    XCTAssertEqual(state.progressFraction, 1)
    state.positionMs = -5_000
    XCTAssertEqual(state.progressFraction, 0)
  }

  func testLiveEpgStripReplacesTheScrubberOnlyWhenThereIsAProgramme() {
    var state = PlayerChromeState()
    state.isLive = true
    XCTAssertFalse(state.showLiveEpgStrip)
    state.epgNow = PlayerEpgEntry(title: "News", startMs: 1_000, stopMs: 2_000)
    XCTAssertTrue(state.showLiveEpgStrip)
    // VOD never shows it even if an entry somehow rode along.
    state.isLive = false
    XCTAssertFalse(state.showLiveEpgStrip)
  }

  func testGoLiveAppearsOnlyOnceBehindTheEdge() {
    var state = PlayerChromeState()
    state.isLive = true
    XCTAssertTrue(state.showLiveBadge)
    XCTAssertFalse(state.showGoLiveButton)
    state.liveSynced = false
    XCTAssertTrue(state.showGoLiveButton)
    // VOD has neither, whatever `liveSynced` happens to hold.
    state.isLive = false
    XCTAssertFalse(state.showGoLiveButton)
    XCTAssertFalse(state.showLiveBadge)
  }

  // MARK: - Track buttons

  func testAudioButtonNeedsARealChoice() {
    var state = PlayerChromeState()
    XCTAssertFalse(state.showAudioButton)
    state.audioTracks = [PlayerTrackOption(id: "a", label: "English")]
    XCTAssertFalse(state.showAudioButton, "a single track is not a choice")
    state.audioTracks.append(PlayerTrackOption(id: "b", label: "Français"))
    XCTAssertTrue(state.showAudioButton)
  }

  func testSubtitleButtonIgnoresAnOffOnlyList() {
    var state = PlayerChromeState()
    state.subtitleTracks = [PlayerTrackOption(id: playerSubtitleOffId, label: "Off")]
    XCTAssertFalse(state.showSubtitleButton)
    state.subtitleTracks.append(PlayerTrackOption(id: "s1", label: "English"))
    XCTAssertTrue(state.showSubtitleButton)
  }

  // MARK: - Menus

  func testMenuContentIsNilWhenNothingIsOpen() {
    XCTAssertNil(PlayerChromeState().menuContent())
  }

  func testSpeedMenuIsSynthesisedAndSelectsTheCurrentSpeed() {
    var state = PlayerChromeState()
    state.speed = 1.5
    state.menu = .speed
    guard let content = state.menuContent() else { return XCTFail("no menu content") }
    XCTAssertEqual(content.header, "Playback speed")
    XCTAssertEqual(content.options.count, playerSpeedOptions.count)
    XCTAssertEqual(content.selectedId, playerSpeedId(1.5))
    XCTAssertEqual(content.options.map(\.label), ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"])
    // Round-trip: the id a row carries must parse back into the value the
    // controller applies to the player's rate.
    XCTAssertEqual(content.options.compactMap { Double($0.id) }, playerSpeedOptions)
  }

  func testAudioAndSubtitleMenusReadTheirOwnLists() {
    var state = PlayerChromeState()
    state.audioTracks = [PlayerTrackOption(id: "a", label: "English")]
    state.selectedAudioId = "a"
    state.subtitleTracks = [PlayerTrackOption(id: playerSubtitleOffId, label: "Off")]
    state.selectedSubtitleId = playerSubtitleOffId

    state.menu = .audio
    XCTAssertEqual(state.menuContent()?.header, "Audio")
    XCTAssertEqual(state.menuContent()?.selectedId, "a")

    state.menu = .subtitles
    XCTAssertEqual(state.menuContent()?.header, "Subtitles")
    XCTAssertEqual(state.menuContent()?.selectedId, playerSubtitleOffId)
  }

  func testToggleMenuOpensClosesAndSwapsWithoutTouchingInfo() {
    var state = PlayerChromeState()
    state.infoOpen = true

    state.toggleMenu(.audio)
    XCTAssertEqual(state.menu, .audio)
    // The ladder peels menu *then* info; closing info here would swallow a rung.
    XCTAssertTrue(state.infoOpen)

    state.toggleMenu(.subtitles)
    XCTAssertEqual(state.menu, .subtitles, "a second menu replaces the first")

    state.toggleMenu(.subtitles)
    XCTAssertEqual(state.menu, .none, "the same button closes it")
    XCTAssertTrue(state.infoOpen)
  }

  func testPinnedTracksAnyOpenPanel() {
    var state = PlayerChromeState()
    XCTAssertFalse(state.pinned)
    state.infoOpen = true
    XCTAssertTrue(state.pinned)
    state.infoOpen = false
    state.menu = .audio
    XCTAssertTrue(state.pinned)
  }

  /// The AirPlay route sheet pins the chrome too. AVKit presents it, so none of
  /// the interaction that keeps it up reaches `pokeControls`, and an unpinned
  /// overlay would auto-hide behind it — the viewer would dismiss the sheet onto
  /// a bare picture.
  func testRoutePickerSheetPinsTheChrome() {
    var state = PlayerChromeState()
    state.routePickerPresenting = true
    XCTAssertTrue(state.pinned)
    state.routePickerPresenting = false
    XCTAssertFalse(state.pinned)
  }

  /// …and unlike `menu`/`infoOpen`, hiding the controls must **not** clear it:
  /// this flag mirrors a system presentation whose lifetime only AVKit knows,
  /// so clearing it locally would leave the state lying about what is on screen.
  func testHidingControlsLeavesTheRoutePickerFlagAlone() {
    var state = PlayerChromeState()
    state.routePickerPresenting = true
    state.setControlsVisible(false)
    XCTAssertTrue(state.routePickerPresenting)
  }

  func testHidingControlsClosesTheMenuAndInfoPanel() {
    var state = PlayerChromeState()
    state.menu = .speed
    state.infoOpen = true

    state.setControlsVisible(false)
    XCTAssertFalse(state.controlsVisible)
    XCTAssertEqual(state.menu, .none)
    XCTAssertFalse(state.infoOpen)

    // Revealing again must not resurrect either panel.
    state.setControlsVisible(true)
    XCTAssertEqual(state.menu, .none)
    XCTAssertFalse(state.infoOpen)
  }

  // MARK: - Info panel

  func testInfoRowsOmitEverythingNotYetKnown() {
    var state = PlayerChromeState()
    XCTAssertTrue(state.infoRows().isEmpty)
    XCTAssertTrue(state.infoPanelIsEmpty)

    state.videoWidth = 1920
    state.videoHeight = 1080
    state.fps = 25
    state.dynamicRange = "HDR10 · PQ"
    state.videoCodec = "HEVC"
    state.audioCodec = "E-AC-3"
    state.audioChannels = 6

    XCTAssertEqual(
      state.infoRows(),
      [
        PlayerInfoRow(label: "Resolution", value: "1920 × 1080"),
        PlayerInfoRow(label: "Frame rate", value: "25 fps"),
        PlayerInfoRow(label: "Dynamic range", value: "HDR10 · PQ"),
        PlayerInfoRow(label: "Video", value: "HEVC"),
        PlayerInfoRow(label: "Audio", value: "E-AC-3 · 5.1"),
      ]
    )
    XCTAssertFalse(state.infoPanelIsEmpty)
  }

  func testAudioRowDropsTheChannelSuffixWhenTheCountIsUnknown() {
    var state = PlayerChromeState()
    state.audioCodec = "AAC"
    state.audioChannels = 0
    XCTAssertEqual(state.infoRows(), [PlayerInfoRow(label: "Audio", value: "AAC")])
  }

  func testSynopsisIsLiveOnlyAndNonBlank() {
    var state = PlayerChromeState()
    state.epgNow = PlayerEpgEntry(
      title: "News",
      startMs: 0,
      stopMs: 1,
      description: "The day's headlines."
    )
    state.isLive = false
    XCTAssertNil(state.infoSynopsis)
    state.isLive = true
    XCTAssertEqual(state.infoSynopsis, "The day's headlines.")

    state.epgNow = PlayerEpgEntry(title: "News", startMs: 0, stopMs: 1, description: "   ")
    XCTAssertNil(state.infoSynopsis)
    // A synopsis alone is enough to render the panel, with no info rows at all.
    state.epgNow = PlayerEpgEntry(title: "News", startMs: 0, stopMs: 1, description: "Something")
    XCTAssertTrue(state.infoRows().isEmpty)
    XCTAssertFalse(state.infoPanelIsEmpty)
  }

  // MARK: - Labels

  func testSpeedLabelsMatchTheKotlinShape() {
    XCTAssertEqual(playerSpeedOptionLabel(1.0), "1×")
    XCTAssertEqual(playerSpeedOptionLabel(2.0), "2×")
    XCTAssertEqual(playerSpeedOptionLabel(0.5), "0.5×")
    XCTAssertEqual(playerSpeedOptionLabel(0.75), "0.75×")
    XCTAssertEqual(playerSpeedOptionLabel(1.25), "1.25×")
  }

  func testAudioChannelLabels() {
    XCTAssertEqual(playerAudioChannelsLabel(0), "")
    XCTAssertEqual(playerAudioChannelsLabel(-2), "")
    XCTAssertEqual(playerAudioChannelsLabel(1), "Mono")
    XCTAssertEqual(playerAudioChannelsLabel(2), "Stereo")
    XCTAssertEqual(playerAudioChannelsLabel(6), "5.1")
    XCTAssertEqual(playerAudioChannelsLabel(8), "7.1")
    XCTAssertEqual(playerAudioChannelsLabel(3), "3ch")
  }

  func testEpgLabelsRenderInTheGivenZoneWithAFixedPattern() {
    let utc = TimeZone(identifier: "UTC")!
    // 1970-01-01 20:00:00Z .. 20:45:00Z
    let entry = PlayerEpgEntry(title: "Film", startMs: 72_000_000, stopMs: 74_700_000)
    XCTAssertEqual(playerClockHm(ms: 72_000_000, timeZone: utc), "20:00")
    XCTAssertEqual(playerEpgRangeLabel(entry, timeZone: utc), "20:00 – 20:45")
    XCTAssertEqual(playerEpgNextLabel(entry, timeZone: utc), "Next · 20:00 – 20:45 · Film")
  }

  func testLiveProgrammeProgressClampsAndIsZeroWithoutEpg() {
    var state = PlayerChromeState()
    XCTAssertEqual(state.liveProgrammeProgress(nowMs: 500), 0)
    state.epgNow = PlayerEpgEntry(title: "Film", startMs: 1_000, stopMs: 3_000)
    XCTAssertEqual(state.liveProgrammeProgress(nowMs: 2_000), 0.5, accuracy: 0.0001)
    XCTAssertEqual(state.liveProgrammeProgress(nowMs: 0), 0)
    XCTAssertEqual(state.liveProgrammeProgress(nowMs: 9_999), 1)
  }

  func testBadgesDelegateToBadgeFormatting() {
    var state = PlayerChromeState()
    state.videoWidth = 3840
    state.videoHeight = 2160
    state.dynamicRange = "HLG"
    state.fps = 23.976
    state.sourceName = "  My Provider  "
    XCTAssertEqual(state.resolutionBadge, "4K")
    XCTAssertEqual(state.hdrBadge, "HLG")
    XCTAssertEqual(state.fpsBadge, "23.976fps")
    XCTAssertEqual(state.sourceBadge, "My Provider")
  }

  /// The badge cluster is empty on a fresh open — the colorimetry and format
  /// reads that fill it are step 9. That is the *designed* state, not a bug, so
  /// it is pinned: the bar must render with no badges rather than with
  /// placeholder ones.
  func testFreshStateHasNoStreamInfoBadgesYet() {
    let state = PlayerChromeState()
    XCTAssertNil(state.resolutionBadge)
    XCTAssertNil(state.hdrBadge)
    XCTAssertNil(state.fpsBadge)
    XCTAssertNil(state.sourceBadge)
    XCTAssertFalse(state.showPictureInPictureButton)
    XCTAssertFalse(state.reconnecting)
  }

  // MARK: - Aspect

  /// This is the **seedless fallback**, not the product default. Every open
  /// carries `aspect` on its payload — the user's stored choice, or Dart's
  /// `defaultAspectModeIndex()`, which reads the window's shape and so answers
  /// Fit for a portrait handset — and the controller adopts it, so a fresh
  /// state is only what this type holds before that arrives.
  ///
  /// It stays `Fill`, matching Kotlin's `AspectMode.Fill`, because the two
  /// native surfaces must not differ from each other when neither was told.
  /// Dart owns the real decision; do not re-derive one here.
  func testAFreshStateStartsOnFillLikeEveryOtherSurface() {
    let state = PlayerChromeState()
    XCTAssertEqual(state.aspect, .fill)
    XCTAssertEqual(state.aspectLabel, "Fill")
  }

  func testAspectCyclesThroughTheGravitiesAVPlayerLayerHas() {
    var state = PlayerChromeState()
    // Walk from `fit` explicitly: the cycle's order is what this test is for,
    // and starting it at whatever the default happens to be couples the two.
    state.aspect = .fit
    XCTAssertEqual(state.aspect, .fit)
    XCTAssertEqual(state.aspectLabel, "Fit")
    state.cycleAspect()
    XCTAssertEqual(state.aspect, .fill)
    XCTAssertEqual(state.aspectLabel, "Fill")
    state.cycleAspect()
    XCTAssertEqual(state.aspect, .stretch)
    XCTAssertEqual(state.aspectLabel, "Stretch")
    state.cycleAspect()
    XCTAssertEqual(state.aspect, .fit)
  }

  /// `fill` and `stretch` are different framings, not two names for one.
  /// `fill` crops to fill and keeps the picture's shape; `stretch` distorts to
  /// fill and keeps every pixel. Collapsing them — which is easy to do by
  /// mapping both onto `resizeAspectFill` — silently removes the mode users ask
  /// for by name.
  func testFillAndStretchAreDistinctModes() {
    XCTAssertNotEqual(PlayerAspectMode.fill, PlayerAspectMode.stretch)
    XCTAssertNotEqual(
      PlayerAspectMode.fill.label,
      PlayerAspectMode.stretch.label
    )
  }

  /// Every mode has to be reachable by pressing the button, and the cycle has
  /// to return to where it started — a mode that only `CaseIterable` knows
  /// about is a mode no user can select.
  func testEveryAspectModeIsReachableByCycling() {
    var seen: [PlayerAspectMode] = []
    var mode = PlayerAspectMode.fit
    for _ in PlayerAspectMode.allCases {
      seen.append(mode)
      mode = mode.next()
    }
    XCTAssertEqual(Set(seen), Set(PlayerAspectMode.allCases))
    XCTAssertEqual(mode, .fit, "the cycle must close")
  }

  // MARK: - Seeding from the open payload

  func testStateSeedsPresentationFromTheOpenRequest() {
    let request = PlayerOpenRequest(
      url: "https://example.test/a.m3u8",
      title: "Channel One",
      sourceName: "Provider",
      isLive: true,
      canFavorite: true,
      isFavorite: true,
      epgNow: PlayerEpgEntry(title: "News", startMs: 1, stopMs: 2)
    )
    let state = PlayerChromeState(request: request)
    XCTAssertEqual(state.title, "Channel One")
    XCTAssertEqual(state.sourceName, "Provider")
    XCTAssertTrue(state.isLive)
    XCTAssertTrue(state.canFavorite)
    XCTAssertTrue(state.isFavorite)
    XCTAssertEqual(state.epgNow?.title, "News")
    // Chrome starts up, playback starts unknown.
    XCTAssertTrue(state.controlsVisible)
    XCTAssertFalse(state.isPlaying)
    XCTAssertEqual(state.menu, .none)
  }

  // MARK: - Auto-hide

  func testAutoHideRunsOnlyWhilePlayingAndUnpinned() {
    XCTAssertTrue(
      PlayerAutoHide.shouldSchedule(controlsVisible: true, pinned: false, isPlaying: true)
    )
    XCTAssertFalse(
      PlayerAutoHide.shouldSchedule(controlsVisible: false, pinned: false, isPlaying: true)
    )
    XCTAssertFalse(
      PlayerAutoHide.shouldSchedule(controlsVisible: true, pinned: true, isPlaying: true),
      "an open menu or info panel pins the chrome"
    )
    XCTAssertFalse(
      PlayerAutoHide.shouldSchedule(controlsVisible: true, pinned: false, isPlaying: false),
      "a paused player keeps its chrome — otherwise there is no way to resume"
    )
  }

  func testAutoHideGivesLiveTheLongerDelay() {
    XCTAssertEqual(PlayerAutoHide.delayMs(isLive: false), 3500)
    XCTAssertEqual(PlayerAutoHide.delayMs(isLive: true), 4500)
    XCTAssertGreaterThan(PlayerAutoHide.delayMs(isLive: true), PlayerAutoHide.delayMs(isLive: false))
  }
}
