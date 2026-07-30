import XCTest

@testable import IptvsPlayerCore

/// Pins the lock-screen / Control-Centre description and the remote-command
/// set. Neither is observable on a Simulator in any useful way (the Simulator
/// has no lock screen and no hardware transport), so the rules are pinned here
/// rather than left to be checked by eye on a device.
final class NowPlayingPolicyTests: XCTestCase {

  // MARK: - Snapshot

  func testVodCarriesDurationAndElapsed() {
    let snapshot = nowPlayingSnapshot(
      title: "Some Film",
      sourceName: "Provider",
      isLive: false,
      positionMs: 90_000,
      durationMs: 5_400_000,
      isPlaying: true,
      speed: 1
    )
    XCTAssertEqual(snapshot.title, "Some Film")
    XCTAssertEqual(snapshot.artist, "Provider")
    XCTAssertFalse(snapshot.isLive)
    XCTAssertEqual(snapshot.durationSeconds, 5_400)
    XCTAssertEqual(snapshot.elapsedSeconds, 90)
    XCTAssertEqual(snapshot.playbackRate, 1)
  }

  func testLiveReportsNeitherDurationNorElapsed() {
    let snapshot = nowPlayingSnapshot(
      title: "Channel One",
      sourceName: "Provider",
      isLive: true,
      // A live item that happens to expose a seekable window would still report
      // a position here; the rule is keyed on `isLive`, never on the numbers.
      positionMs: 120_000,
      durationMs: 3_600_000,
      isPlaying: true,
      speed: 1
    )
    XCTAssertTrue(snapshot.isLive)
    XCTAssertNil(snapshot.durationSeconds)
    XCTAssertNil(snapshot.elapsedSeconds)
  }

  /// `AvPlayerEngine.milliseconds(from:)` collapses every non-numeric `CMTime`
  /// to `0`, so `0` means "unknown" and must not become a zero-length bar.
  func testUnknownVodDurationIsOmittedRatherThanZero() {
    let snapshot = nowPlayingSnapshot(
      title: "Some Film",
      sourceName: nil,
      isLive: false,
      positionMs: 0,
      durationMs: 0,
      isPlaying: false,
      speed: 1
    )
    XCTAssertNil(snapshot.durationSeconds)
    XCTAssertEqual(snapshot.elapsedSeconds, 0)
  }

  func testPausedPlayerReportsRateZeroWhateverTheSpeed() {
    let snapshot = nowPlayingSnapshot(
      title: "Some Film",
      sourceName: nil,
      isLive: false,
      positionMs: 1_000,
      durationMs: 10_000,
      isPlaying: false,
      speed: 1.5
    )
    XCTAssertEqual(
      snapshot.playbackRate,
      0,
      "the system extrapolates elapsed time from the rate — a paused player must report 0"
    )
  }

  func testPlayingAtNonUnitSpeedReportsThatSpeed() {
    let snapshot = nowPlayingSnapshot(
      title: "Some Film",
      sourceName: nil,
      isLive: false,
      positionMs: 1_000,
      durationMs: 10_000,
      isPlaying: true,
      speed: 1.5
    )
    XCTAssertEqual(snapshot.playbackRate, 1.5)
  }

  func testBlankTitleFallsBackToSourceAndDropsTheDuplicateArtist() {
    let snapshot = nowPlayingSnapshot(
      title: "   ",
      sourceName: "Provider",
      isLive: true,
      positionMs: 0,
      durationMs: 0,
      isPlaying: true,
      speed: 1
    )
    XCTAssertEqual(snapshot.title, "Provider")
    XCTAssertNil(
      snapshot.artist,
      "the fallback would otherwise print the provider name on both lines"
    )
  }

  func testBlankSourceIsNotRenderedAsAnEmptySecondLine() {
    let snapshot = nowPlayingSnapshot(
      title: "Channel One",
      sourceName: "  ",
      isLive: true,
      positionMs: 0,
      durationMs: 0,
      isPlaying: true,
      speed: 1
    )
    XCTAssertEqual(snapshot.title, "Channel One")
    XCTAssertNil(snapshot.artist)
  }

  func testEverythingBlankStillProducesARenderableSnapshot() {
    let snapshot = nowPlayingSnapshot(
      title: "",
      sourceName: nil,
      isLive: true,
      positionMs: 0,
      durationMs: 0,
      isPlaying: true,
      speed: 1
    )
    XCTAssertEqual(snapshot.title, "")
    XCTAssertNil(snapshot.artist)
  }

  // MARK: - Remote commands

  func testLiveOffersNoSeekingCommands() {
    let policy = remoteCommandPolicy(isLive: true)
    XCTAssertTrue(policy.play)
    XCTAssertTrue(policy.pause)
    XCTAssertTrue(policy.togglePlayPause)
    XCTAssertFalse(policy.skipForward)
    XCTAssertFalse(policy.skipBackward)
    XCTAssertFalse(policy.changePlaybackPosition)
  }

  func testVodOffersTheFullTransport() {
    let policy = remoteCommandPolicy(isLive: false)
    XCTAssertTrue(policy.skipForward)
    XCTAssertTrue(policy.skipBackward)
    XCTAssertTrue(policy.changePlaybackPosition)
    XCTAssertEqual(policy.skipIntervalSeconds, 10)
  }

  /// The remote transport and the on-screen transport must describe the same
  /// stream. `IptvsPlayerViewController.seekBy`/`seekToFraction` both refuse
  /// live outright, so a remote command the overlay doesn't offer would be a
  /// control that silently does nothing.
  func testRemoteTransportMatchesTheOnScreenTransport() {
    for isLive in [true, false] {
      var state = PlayerChromeState()
      state.isLive = isLive
      let policy = remoteCommandPolicy(isLive: isLive)
      XCTAssertEqual(policy.skipForward, state.showSkipButtons)
      XCTAssertEqual(policy.skipBackward, state.showSkipButtons)
      XCTAssertEqual(policy.changePlaybackPosition, state.showScrubber)
    }
  }
}
