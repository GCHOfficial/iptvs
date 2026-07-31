import XCTest

@testable import IptvsPlayerCore

/// docs/ios.md's **second** `engineFailed` detection shape — "ready but no
/// picture" — which was specified, deliberately left unbuilt because the obvious
/// detector misfires on audio-only content, and is now built around positive
/// evidence instead.
///
/// The whole reason the decision lives in `Core`: every case below is a synthetic
/// clock and a handful of booleans, where the UIKit/AVFoundation half is an
/// `AVPlayerItem` and an `AVPlayerLayer` that `swift test` cannot reach on a CI
/// host with no simulator.
final class VideoPresenceBackstopTests: XCTestCase {
  private let timeout = VideoPresenceBackstop.timeoutMs
  private let giveUp = VideoPresenceBackstop.giveUpMs

  /// Every test anchors the first frame here, so `nowMs` reads as
  /// `anchor + elapsed` and the `max(nowMs, 1)` clamp never has to be reasoned
  /// about twice (it has its own test).
  private let anchor: Int64 = 1_000

  /// A started, healthy, picture-less tick. Individual tests override one field
  /// at a time so the difference that matters is the only thing on the line.
  private func poll(
    _ backstop: inout VideoPresenceBackstop,
    elapsed: Int64,
    isPlaying: Bool = true,
    isBuffering: Bool = false,
    ended: Bool = false,
    evidence: DeclaredVideoEvidence = .present,
    isPresentingVideo: Bool = false,
    isSuppressed: Bool = false
  ) -> VideoPresenceAction {
    backstop.poll(
      isPlaying: isPlaying,
      isBuffering: isBuffering,
      ended: ended,
      evidence: evidence,
      isPresentingVideo: isPresentingVideo,
      isSuppressed: isSuppressed,
      nowMs: anchor + elapsed
    )
  }

  private func started() -> VideoPresenceBackstop {
    var backstop = VideoPresenceBackstop()
    backstop.markLoaded()
    backstop.markStarted(nowMs: anchor)
    return backstop
  }

  // MARK: - The hole this closes

  /// The failure the whole type exists for: an HLS ladder that declares video,
  /// audio decoding fine, and no picture ever. Before this, `hasEverStarted`
  /// latched, `PlaybackStartBackstop` disarmed, `LiveReconnectWatchdog` saw
  /// healthy playback, and the result was a black screen with sound, forever.
  func testDeclaredVideoThatNeverRendersHandsOffToTheFallbackEngine() {
    var backstop = started()
    XCTAssertTrue(backstop.isArmed)
    XCTAssertEqual(poll(&backstop, elapsed: 0), .wait)
    XCTAssertEqual(poll(&backstop, elapsed: timeout - 1), .wait)
    XCTAssertEqual(poll(&backstop, elapsed: timeout), .handOffEngine)
  }

  // MARK: - Not becoming a downgrade machine for audio

  /// **The contract that made the naive detector unshippable.** `selectIosEngine`
  /// rule 3 routes `m4a`/`mp3`/`aac` to AVPlayer on purpose, and an audio-only
  /// item reaches `.playing` with a zero presentation size for the whole of its
  /// life. Handing off would bounce it to mpv and pin the id in `IosEngineMemo`
  /// for the session — costing AirPlay, PiP and lock-screen transport on content
  /// whose only output is audio, and gaining nothing, since mpv has no video to
  /// render either.
  func testGenuinelyAudioOnlyContentNeverHandsOff() {
    var backstop = started()
    for elapsed in stride(from: Int64(500), through: 10 * giveUp, by: 500) {
      XCTAssertEqual(poll(&backstop, elapsed: elapsed, evidence: .absent), .wait)
    }
  }

  /// An unreadable container (an HLS *media* playlist exposes neither
  /// `AVPlayerItemTrack.assetTrack` nor `AVURLAsset.variants`) is an absence of
  /// evidence, not evidence of absence. A missed detection is a black screen; a
  /// false one is a working stream downgraded for the session — so unknown waits.
  func testUnknownEvidenceNeverHandsOff() {
    var backstop = started()
    for elapsed in stride(from: Int64(500), through: 10 * giveUp, by: 500) {
      XCTAssertEqual(poll(&backstop, elapsed: elapsed, evidence: .unknown), .wait)
    }
  }

  /// Any sign of a real picture — a non-zero `presentationSize` or a layer that
  /// reached `isReadyForDisplay` — settles the load permanently. Losing video
  /// later is a *drop*, which belongs to the reconnect watchdog; switching
  /// engines for it would downgrade a stream that demonstrably rendered.
  func testAPictureSettlesTheLoadForGood() {
    var backstop = started()
    XCTAssertEqual(poll(&backstop, elapsed: 500, isPresentingVideo: true), .wait)
    XCTAssertFalse(backstop.isArmed)
    for elapsed in stride(from: Int64(1_000), through: 10 * giveUp, by: 500) {
      XCTAssertEqual(poll(&backstop, elapsed: elapsed), .wait)
    }
  }

  // MARK: - Suppression: the picture is elsewhere, not missing

  /// PiP, AirPlay/external playback and a backgrounded app all legitimately leave
  /// this layer without a picture on a perfectly good stream. Firing there would
  /// hand an AirPlaying video stream to an engine with **no AirPlay at all**.
  func testSuppressedTicksNeverFire() {
    var backstop = started()
    for elapsed in stride(from: Int64(500), through: giveUp - 500, by: 500) {
      XCTAssertEqual(poll(&backstop, elapsed: elapsed, isSuppressed: true), .wait)
    }
    XCTAssertTrue(backstop.isArmed)
  }

  /// Suppression blocks firing but does not extend the window: a load that spends
  /// its whole evaluation window in PiP gives up unjudged rather than firing the
  /// instant the user comes back.
  func testSuppressionDoesNotExtendTheWindow() {
    var backstop = started()
    XCTAssertEqual(poll(&backstop, elapsed: giveUp - 500, isSuppressed: true), .wait)
    XCTAssertEqual(poll(&backstop, elapsed: giveUp, isSuppressed: false), .wait)
    XCTAssertFalse(backstop.isArmed)
  }

  /// A suppression that lifts inside the window still lets the detector do its
  /// job — this is a delay, not a veto.
  func testFiringResumesOnceSuppressionLifts() {
    var backstop = started()
    XCTAssertEqual(poll(&backstop, elapsed: timeout, isSuppressed: true), .wait)
    XCTAssertTrue(backstop.isArmed)
    XCTAssertEqual(poll(&backstop, elapsed: timeout + 500), .handOffEngine)
  }

  // MARK: - Arming discipline

  func testAnUnarmedBackstopNeverFires() {
    var backstop = VideoPresenceBackstop()
    XCTAssertFalse(backstop.isArmed)
    XCTAssertEqual(poll(&backstop, elapsed: 10 * timeout), .wait)
  }

  /// The window opens at the **first frame**, not at the load — before that,
  /// `PlaybackStartBackstop` owns the load outright.
  func testTheWindowOpensAtTheFirstFrameNotAtTheLoad() {
    var backstop = VideoPresenceBackstop()
    backstop.markLoaded()
    XCTAssertFalse(backstop.isArmed)
    XCTAssertEqual(poll(&backstop, elapsed: 10 * timeout), .wait)
    backstop.markStarted(nowMs: anchor + 10 * timeout)
    XCTAssertEqual(poll(&backstop, elapsed: 11 * timeout - 1), .wait)
    XCTAssertEqual(poll(&backstop, elapsed: 11 * timeout), .handOffEngine)
  }

  /// A reload gets its own window and does not inherit the previous load's
  /// elapsed time and fire instantly.
  func testEachLoadGetsAFreshWindow() {
    var backstop = started()
    XCTAssertEqual(poll(&backstop, elapsed: timeout - 1), .wait)
    backstop.markLoaded()
    XCTAssertFalse(backstop.isArmed)
    backstop.markStarted(nowMs: anchor + timeout)
    XCTAssertEqual(poll(&backstop, elapsed: 2 * timeout - 1), .wait)
    XCTAssertEqual(poll(&backstop, elapsed: 2 * timeout), .handOffEngine)
  }

  func testFiringIsOneShotPerLoad() {
    var backstop = started()
    XCTAssertEqual(poll(&backstop, elapsed: timeout), .handOffEngine)
    XCTAssertFalse(backstop.isArmed)
    XCTAssertEqual(poll(&backstop, elapsed: timeout + 500), .wait)
    XCTAssertEqual(poll(&backstop, elapsed: 10 * timeout), .wait)
  }

  /// `0` is the disarmed sentinel, so arming *at* a zero clock must not read as
  /// "never armed" — same clamp, same reason, as `PlaybackStartBackstop`.
  /// Unreachable in production (every caller passes epoch milliseconds).
  func testArmingAtAZeroClockStillArms() {
    var backstop = VideoPresenceBackstop()
    backstop.markStarted(nowMs: 0)
    XCTAssertTrue(backstop.isArmed)
    XCTAssertEqual(backstop.armedAtMs, 1)
  }

  /// Evaluation is bounded, which is what lets the VOD ticker stop: a film does
  /// not carry a 2 Hz timer (and its AVFoundation reads) for two hours.
  func testEvaluationGivesUpSoTheTickerCanStop() {
    var backstop = started()
    XCTAssertEqual(poll(&backstop, elapsed: giveUp - 500, evidence: .unknown), .wait)
    XCTAssertTrue(backstop.isArmed)
    XCTAssertEqual(poll(&backstop, elapsed: giveUp, evidence: .unknown), .wait)
    XCTAssertFalse(backstop.isArmed)
  }

  func testGiveUpIsLaterThanTheGraceWindow() {
    XCTAssertGreaterThan(VideoPresenceBackstop.giveUpMs, VideoPresenceBackstop.timeoutMs)
  }

  // MARK: - Three disjoint windows, executed rather than asserted in prose

  /// The healthy-but-black case, with all three deciders driven off one clock.
  ///
  /// This is the state the other two are blind to by construction: the start
  /// backstop is disarmed (the load *did* start) and the reconnect watchdog sees
  /// a full buffer and a moving timebase. Exactly one non-`wait` decision is
  /// taken over a minute, and it is this type's handoff.
  func testOnlyTheVideoBackstopCanActOnHealthyPlaybackWithNoPicture() {
    var startBackstop = PlaybackStartBackstop(isLive: true)
    var watchdog = LiveReconnectWatchdog(isLive: true)
    var videoBackstop = VideoPresenceBackstop()

    startBackstop.markLoaded(nowMs: anchor)
    startBackstop.markStarted()
    watchdog.markStarted()
    videoBackstop.markLoaded()
    videoBackstop.markStarted(nowMs: anchor)

    var starts = 0
    var reconnects = 0
    var handoffs = 0
    for elapsed in stride(from: Int64(500), through: 60_000, by: 500) {
      let nowMs = anchor + elapsed
      // `IptvsPlayerViewController.pollWatchdogs`'s tick order: start backstop,
      // video presence, reconnect watchdog. The order is documentation, not the
      // safety property — the exclusion below is what makes it deterministic.
      if startBackstop.poll(hasEverStarted: true, nowMs: nowMs) != .wait { starts += 1 }
      if poll(&videoBackstop, elapsed: elapsed) == .handOffEngine { handoffs += 1 }
      if watchdog.poll(hasEverStarted: true, isBuffering: false, ended: false, nowMs: nowMs)
        == .reconnect
      {
        reconnects += 1
      }
    }
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(reconnects, 0)
    XCTAssertEqual(handoffs, 1)
  }

  /// The mirror image: a genuine stall belongs to the reconnect watchdog, and
  /// this type must stay silent through it — a drop on proven content must never
  /// become an engine downgrade.
  func testAStalledStreamStaysWithTheReconnectWatchdog() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    var videoBackstop = VideoPresenceBackstop()
    watchdog.markStarted()
    videoBackstop.markLoaded()
    videoBackstop.markStarted(nowMs: anchor)

    var reconnects = 0
    for elapsed in stride(from: Int64(500), through: 60_000, by: 500) {
      if watchdog.poll(
        hasEverStarted: true,
        isBuffering: true,
        ended: false,
        nowMs: anchor + elapsed
      ) == .reconnect {
        reconnects += 1
      }
      XCTAssertEqual(poll(&videoBackstop, elapsed: elapsed, isBuffering: true), .wait)
    }
    XCTAssertGreaterThan(reconnects, 1)
  }

  /// A clean EOF is the reconnect watchdog's (live) or a legitimate end (VOD).
  /// Either way it is not "this load never rendered".
  func testAnEndedStreamNeverFires() {
    var backstop = started()
    for elapsed in stride(from: Int64(500), through: giveUp - 500, by: 500) {
      XCTAssertEqual(poll(&backstop, elapsed: elapsed, ended: true), .wait)
    }
  }

  /// The pre-first-start window belongs to `PlaybackStartBackstop` exclusively.
  /// Here the load never starts at all: the start backstop hands off, and this
  /// type — never armed, because no frame was ever produced — stays out of it.
  func testThePreStartWindowIsStillExclusivelyTheStartBackstops() {
    var startBackstop = PlaybackStartBackstop(isLive: false)
    var videoBackstop = VideoPresenceBackstop()
    startBackstop.markLoaded(nowMs: anchor)
    videoBackstop.markLoaded()

    var starts = 0
    var handoffs = 0
    for elapsed in stride(from: Int64(500), through: 60_000, by: 500) {
      if startBackstop.poll(hasEverStarted: false, nowMs: anchor + elapsed) == .handOffEngine {
        starts += 1
      }
      if poll(&videoBackstop, elapsed: elapsed, isPlaying: false, isBuffering: true)
        == .handOffEngine
      {
        handoffs += 1
      }
    }
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(handoffs, 0)
  }

  // MARK: - Payload hygiene

  /// The `reason` is a short machine code, not error text, and must be
  /// distinguishable from every other detection shape's code in an exported
  /// diagnostics log — that log is the only channel a sideloaded device has for
  /// saying which detector fired.
  func testEngineFailedReasonIsACoarseCredentialFreeCode() {
    let reason = VideoPresenceBackstop.engineFailedReason
    XCTAssertFalse(reason.isEmpty)
    XCTAssertFalse(reason.contains("://"))
    XCTAssertFalse(reason.contains(" "))
    for other in [
      PlaybackStartBackstop.engineFailedReason,
      "item-failed",
      "failed-to-play-to-end",
      "invalid-url",
    ] {
      XCTAssertNotEqual(reason, other)
    }

    let payload = PlaybackEventPayload.engineFailed(
      reason: reason,
      positionMs: 0,
      pipWasActive: false,
      visibility: HostVisibility(appActive: true, pipActive: nil)
    )
    XCTAssertEqual(payload["reason"] as? String, reason)
    XCTAssertEqual(payload[PlaybackEventPayload.eventKey] as? String, "engineFailed")
    // Unknown PiP stays an *omitted* key — an explicit `false` is read by Dart as
    // an authoritative "PiP is off" and clears a veto it has no basis to clear.
    XCTAssertNil(payload["pipActive"])
  }

  func testTimeoutMatchesTheOtherTenSecondPlaybackDeadlines() {
    XCTAssertEqual(VideoPresenceBackstop.timeoutMs, PlaybackStartBackstop.timeoutMs)
    XCTAssertEqual(VideoPresenceBackstop.timeoutMs, LiveReconnectWatchdog.resolveTimeoutMs)
  }
}
