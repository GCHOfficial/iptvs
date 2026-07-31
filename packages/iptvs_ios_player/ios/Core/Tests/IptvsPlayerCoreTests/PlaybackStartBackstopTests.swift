import XCTest

@testable import IptvsPlayerCore

/// The "never started" backstop — docs/ios.md's third `engineFailed` detection
/// shape, which was specified and then never implemented, and the ordering rule
/// that keeps it from racing the live reconnect watchdog.
///
/// Everything here is driven with a synthetic clock, which is the whole reason
/// the decision lives in `Core`: the UIKit half is a `Timer` and an
/// `AVPlayerItem`, neither of which `swift test` can reach on a CI host with no
/// simulator.
final class PlaybackStartBackstopTests: XCTestCase {
  private let timeout = PlaybackStartBackstop.timeoutMs

  // MARK: - The hole this closes

  /// A live container AVPlayer accepts and then cannot decode: nothing ever
  /// plays, so the recovery is the mpv handoff, not another attempt on the
  /// engine that just failed.
  func testLiveThatNeverStartsHandsOffToTheFallbackEngine() {
    var backstop = PlaybackStartBackstop(isLive: true)
    backstop.markLoaded(nowMs: 1_000)
    XCTAssertTrue(backstop.isArmed)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000), .wait)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout - 1), .wait)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout), .handOffEngine)
  }

  /// The VOD case that used to hang forever: the live watchdog is inert for VOD
  /// and the controller had no error surface, so a container AVPlayer could not
  /// play left chrome over black with no way forward.
  func testVodThatNeverStartsHandsOffToTheFallbackEngineToo() {
    var backstop = PlaybackStartBackstop(isLive: false)
    backstop.markLoaded(nowMs: 1_000)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout - 1), .wait)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout), .handOffEngine)
  }

  // MARK: - Not regressing legitimate drops

  /// **The contract that stops this from being a downgrade machine.** Once
  /// AVPlayer has played the content, a reload that fails to come back is a
  /// network problem, not a container problem — and handing off would write the
  /// content id into `IosEngineMemo` and pin a working HDR channel to
  /// tone-mapped SDR for the rest of the session.
  func testAReloadOfAProvenStreamNeverHandsOff() {
    var backstop = PlaybackStartBackstop(isLive: false)
    backstop.markLoaded(nowMs: 0)
    backstop.markStarted()
    // Retry from the error surface, which never comes back either.
    backstop.markLoaded(nowMs: 60_000)
    XCTAssertEqual(backstop.poll(hasEverStarted: true, nowMs: 60_000 + timeout), .surfaceError)
  }

  /// A live reload is the reconnect watchdog's business — it is already retrying
  /// on the shared backoff schedule with "Reconnecting…" on screen, and a
  /// terminal error over the top of that would contradict it.
  func testALiveReloadIsLeftToTheReconnectWatchdog() {
    var backstop = PlaybackStartBackstop(isLive: true)
    backstop.markLoaded(nowMs: 0)
    backstop.markStarted()
    backstop.markLoaded(nowMs: 60_000)
    XCTAssertEqual(backstop.poll(hasEverStarted: true, nowMs: 60_000 + timeout), .wait)
  }

  // MARK: - Arming discipline

  func testFirstFrameDisarmsSoAHealthyStreamNeverFires() {
    var backstop = PlaybackStartBackstop(isLive: false)
    backstop.markLoaded(nowMs: 1_000)
    backstop.markStarted()
    XCTAssertFalse(backstop.isArmed)
    XCTAssertEqual(backstop.poll(hasEverStarted: true, nowMs: 10 * timeout), .wait)
  }

  func testAnUnarmedBackstopNeverFires() {
    var backstop = PlaybackStartBackstop(isLive: false)
    XCTAssertFalse(backstop.isArmed)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 10 * timeout), .wait)
  }

  /// Each load gets its own window; a reload does not inherit the previous
  /// load's elapsed time and fire instantly.
  func testEachLoadRestartsTheClock() {
    var backstop = PlaybackStartBackstop(isLive: false)
    backstop.markLoaded(nowMs: 1_000)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout - 1), .wait)
    // A reload one tick short of firing: the new window starts here, it does not
    // inherit the 9 999 ms the previous one had already run.
    backstop.markLoaded(nowMs: 1_000 + timeout - 1)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + 2 * timeout - 2), .wait)
    XCTAssertEqual(
      backstop.poll(hasEverStarted: false, nowMs: 1_000 + 2 * timeout - 1),
      .handOffEngine
    )
  }

  /// The action disarms, so a caller that cannot act on the first decision does
  /// not get it repeated on every subsequent tick — one handoff per load.
  func testFiringIsOneShotPerLoad() {
    var backstop = PlaybackStartBackstop(isLive: false)
    backstop.markLoaded(nowMs: 1_000)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout), .handOffEngine)
    XCTAssertFalse(backstop.isArmed)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 1_000 + timeout + 1), .wait)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: 10 * timeout), .wait)
  }

  /// `0` is the disarmed sentinel, so arming *at* a zero clock must not read as
  /// "never armed" — a silently disarmed backstop is exactly the failure this
  /// type exists to prevent. `markLoaded` clamps to 1 for that, which costs the
  /// window a single millisecond; pinned here so the clamp reads as deliberate.
  /// Unreachable in production (every caller passes epoch milliseconds).
  func testArmingAtAZeroClockStillArms() {
    var backstop = PlaybackStartBackstop(isLive: false)
    backstop.markLoaded(nowMs: 0)
    XCTAssertTrue(backstop.isArmed)
    XCTAssertEqual(backstop.armedAtMs, 1)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: timeout), .wait)
    XCTAssertEqual(backstop.poll(hasEverStarted: false, nowMs: timeout + 1), .handOffEngine)
  }

  // MARK: - Ordering against the live reconnect watchdog

  /// The ordering argument, executed rather than asserted in prose.
  ///
  /// Both watchdogs are driven off one clock over a live stream that never
  /// produces a frame. The reconnect watchdog's 8s stall threshold elapses
  /// *before* the backstop's 10s, so a naive "ask the backstop first" would
  /// still lose the race — the guarantee is that `LiveReconnectWatchdog` reports
  /// healthy for the whole pre-start window, leaving the backstop the only thing
  /// that can act. Exactly one non-`wait` decision is taken, and it is the
  /// handoff.
  func testOnlyTheBackstopCanActBeforeTheFirstFrame() {
    XCTAssertLessThan(ReconnectPolicy.stallReconnectMs, PlaybackStartBackstop.timeoutMs)

    var backstop = PlaybackStartBackstop(isLive: true)
    var watchdog = LiveReconnectWatchdog(isLive: true)
    backstop.markLoaded(nowMs: 0)

    var reconnects = 0
    var handoffs = 0
    for nowMs in stride(from: Int64(500), through: 60_000, by: 500) {
      // The controller's tick order: backstop, then reconnect watchdog.
      if backstop.poll(hasEverStarted: false, nowMs: nowMs) == .handOffEngine {
        handoffs += 1
        // The real controller tears down here; the watchdog below is polled
        // anyway to prove it would not have fired even if it kept running.
      }
      if watchdog.poll(hasEverStarted: false, isBuffering: true, ended: false, nowMs: nowMs)
        == .reconnect
      {
        reconnects += 1
      }
    }
    XCTAssertEqual(handoffs, 1)
    XCTAssertEqual(reconnects, 0)
  }

  /// And the mirror image: after the first frame the backstop is silent and the
  /// reconnect watchdog is the only thing that can act, so a genuine drop stays
  /// on AVPlayer.
  func testOnlyTheReconnectWatchdogCanActAfterTheFirstFrame() {
    var backstop = PlaybackStartBackstop(isLive: true)
    var watchdog = LiveReconnectWatchdog(isLive: true)
    backstop.markLoaded(nowMs: 0)
    backstop.markStarted()
    watchdog.markStarted()

    var reconnects = 0
    for nowMs in stride(from: Int64(500), through: 60_000, by: 500) {
      XCTAssertNotEqual(backstop.poll(hasEverStarted: true, nowMs: nowMs), .handOffEngine)
      if watchdog.poll(hasEverStarted: true, isBuffering: true, ended: false, nowMs: nowMs)
        == .reconnect
      {
        reconnects += 1
        // A real reload re-arms the backstop; it must still never hand off.
        backstop.markLoaded(nowMs: nowMs)
      }
    }
    XCTAssertGreaterThan(reconnects, 1)
  }

  // MARK: - Drop outcome

  func testDropOutcomeMirrorsTheCleanEofSplit() {
    // The same live/VOD split `shouldReconnectOnCompleted` encodes: live is
    // reconnected, VOD is surfaced. Asserted together so the two can't drift.
    XCTAssertEqual(playbackDropOutcome(isLive: true), .reconnect)
    XCTAssertEqual(playbackDropOutcome(isLive: false), .surfaceError)
    XCTAssertEqual(shouldReconnectOnCompleted(isLive: true), playbackDropOutcome(isLive: true) == .reconnect)
    XCTAssertEqual(
      shouldReconnectOnCompleted(isLive: false),
      playbackDropOutcome(isLive: false) == .reconnect
    )
  }

  // MARK: - Payload hygiene

  /// The `reason` is a short machine code, not error text — `AVError` userInfo
  /// embeds the failing URL and provider URLs carry credentials in the query
  /// *and* the path (CLAUDE.md). It must also be distinguishable from the other
  /// two detection shapes' codes in an exported diagnostics log.
  func testEngineFailedReasonIsACoarseCredentialFreeCode() {
    let reason = PlaybackStartBackstop.engineFailedReason
    XCTAssertFalse(reason.isEmpty)
    XCTAssertFalse(reason.contains("://"))
    XCTAssertFalse(reason.contains(" "))
    for other in ["item-failed", "failed-to-play-to-end", "invalid-url"] {
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
    // Unknown PiP stays an *omitted* key. An explicit `false` is read by Dart as
    // an authoritative "PiP is off" and clears a veto it has no basis to clear.
    XCTAssertNil(payload["pipActive"])
  }

  /// The timeout is the codebase's existing "a playback round trip that should
  /// have answered by now" unit, shared with the `resolveAgain` liveness
  /// backstop and Dart's `kIosFallbackSurfaceAfter`.
  func testTimeoutMatchesTheOtherTenSecondPlaybackDeadlines() {
    XCTAssertEqual(PlaybackStartBackstop.timeoutMs, LiveReconnectWatchdog.resolveTimeoutMs)
    XCTAssertGreaterThan(PlaybackStartBackstop.timeoutMs, ReconnectPolicy.stallReconnectMs)
  }
}
