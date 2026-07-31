import XCTest
@testable import IptvsPlayerCore

/// The live auto-reconnect watchdog, driven with a synthetic clock.
///
/// Ports the behaviour `HdrPlayerActivity.pollLiveReconnect`/`reconnectLive`
/// implements in Kotlin and `test/reconnect_policy_test.dart` pins for the Dart
/// watchdogs. The timing constants themselves are covered by
/// `ReconnectPolicyTests`; these cases are about *when* the policy is consulted
/// and what state survives each transition.
final class LiveReconnectWatchdogTests: XCTestCase {
  func testVodNeverReconnectsHoweverBadlyItStalls() {
    var watchdog = LiveReconnectWatchdog(isLive: false)
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 0), .healthy)
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 60_000), .healthy)
    // A VOD stream reaching its end is a legitimate end of playback, not a drop.
    XCTAssertEqual(watchdog.poll(isBuffering: false, ended: true, nowMs: 120_000), .healthy)
    XCTAssertEqual(watchdog.forceReconnect(nowMs: 120_000), .healthy)
    XCTAssertEqual(watchdog.attempts, 0)
  }

  func testLiveStallReconnectsOnlyAfterTheStallThreshold() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 1_000), .wait)
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 5_000), .wait)
    // Threshold is measured from the *first* stalled tick, not from this one.
    XCTAssertEqual(
      watchdog.poll(isBuffering: true, ended: false, nowMs: 1_000 + ReconnectPolicy.stallReconnectMs),
      .reconnect
    )
    XCTAssertEqual(watchdog.attempts, 1)
  }

  func testLiveCleanEofUsesTheFasterEndedThreshold() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    XCTAssertTrue(shouldReconnectOnCompleted(isLive: true))
    XCTAssertFalse(shouldReconnectOnCompleted(isLive: false))

    XCTAssertEqual(watchdog.poll(isBuffering: false, ended: true, nowMs: 1_000), .wait)
    // Still short of the 2s ended threshold, and well short of the 8s stall one.
    XCTAssertEqual(watchdog.poll(isBuffering: false, ended: true, nowMs: 2_500), .wait)
    XCTAssertEqual(
      watchdog.poll(
        isBuffering: false,
        ended: true,
        nowMs: 1_000 + ReconnectPolicy.endedReconnectMs
      ),
      .reconnect
    )
  }

  func testHealthyPollClearsTheStallClockAndAttemptCount() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 1_000), .wait)
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 9_000), .reconnect)
    XCTAssertEqual(watchdog.attempts, 1)

    XCTAssertEqual(watchdog.poll(isBuffering: false, ended: false, nowMs: 10_000), .healthy)
    XCTAssertEqual(watchdog.attempts, 0)
    XCTAssertEqual(watchdog.stalledSinceMs, 0)
    // `lastReconnectMs` deliberately survives, exactly as on Android: a stream
    // that recovers for a second and drops again must not reconnect with no gap.
    XCTAssertEqual(watchdog.lastReconnectMs, 9_000)
  }

  func testRepeatedFailuresBackOffOnTheSharedPolicySchedule() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    // First hard error: forced, so no stall threshold and no prior attempt to
    // rate-limit against.
    XCTAssertEqual(watchdog.forceReconnect(nowMs: 1_000), .reconnect)
    // A second hard error one second later is inside the forced min gap.
    XCTAssertEqual(watchdog.forceReconnect(nowMs: 2_000), .wait)
    XCTAssertEqual(watchdog.attempts, 1)

    // `minGapMs(priorAttempts: 1, force: true)` is the base stall threshold.
    let secondAllowed = 1_000 + ReconnectPolicy.minGapMs(priorAttempts: 1, force: true)
    XCTAssertEqual(watchdog.forceReconnect(nowMs: secondAllowed), .reconnect)
    XCTAssertEqual(watchdog.attempts, 2)
  }

  func testUnforcedBackoffScalesWithAttemptsAndIsCapped() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    var now: Int64 = 1_000
    // Prime the stall clock — the first stalled tick only starts it.
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: now), .wait)

    // Drive ten consecutive stall-driven reconnects. Each one has to clear both
    // gates: the stall threshold since the clock restarted, and the
    // attempt-scaled backoff since the previous attempt.
    for attempt in 0..<10 {
      let expectedGap = ReconnectPolicy.minGapMs(priorAttempts: attempt, force: false)
      XCTAssertLessThanOrEqual(expectedGap, ReconnectPolicy.maxBackoffMs)
      let wait = max(ReconnectPolicy.stallReconnectMs, attempt == 0 ? 0 : expectedGap)
      XCTAssertEqual(
        watchdog.poll(isBuffering: true, ended: false, nowMs: now + wait - 1),
        .wait
      )
      now += wait
      XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: now), .reconnect)
      XCTAssertEqual(watchdog.attempts, attempt + 1)
    }
    // Ten failures in, the gap has settled on the cap rather than growing without
    // bound — the whole point of `maxBackoffMs`.
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: watchdog.attempts, force: false),
      ReconnectPolicy.maxBackoffMs
    )
  }

  func testForcedReconnectSkipsTheStallThresholdButNotTheGap() {
    var watchdog = LiveReconnectWatchdog(isLive: true)
    // Barely stalled — a poll would wait.
    XCTAssertEqual(watchdog.poll(isBuffering: true, ended: false, nowMs: 100), .wait)
    // A hard error at the same instant reconnects immediately.
    XCTAssertEqual(watchdog.forceReconnect(nowMs: 100), .reconnect)
    // And the stall clock restarts from the attempt, so the next unforced
    // threshold is measured from the reload rather than from the original drop.
    XCTAssertEqual(watchdog.stalledSinceMs, 100)
    XCTAssertEqual(
      watchdog.poll(isBuffering: true, ended: false, nowMs: 100 + ReconnectPolicy.stallReconnectMs - 1),
      .wait
    )
  }
}

/// The `resolveAgain` reply contract. Every unusable shape must parse to `nil`
/// so the caller falls back to the locator it already holds rather than
/// reloading an empty URL.
final class FreshLocatorTests: XCTestCase {
  func testParsesUrlAndHeaders() {
    let locator = FreshLocator(
      reply: ["url": "http://host/live/1.m3u8", "headers": ["User-Agent": "MAG250"]]
    )
    XCTAssertEqual(locator?.url, "http://host/live/1.m3u8")
    XCTAssertEqual(locator?.headers, ["User-Agent": "MAG250"])
  }

  func testMissingHeadersIsAnEmptyMapNotAFailure() {
    let locator = FreshLocator(reply: ["url": "http://host/live/1.m3u8"])
    XCTAssertEqual(locator?.url, "http://host/live/1.m3u8")
    XCTAssertEqual(locator?.headers, [:])
  }

  func testBlankOrMissingUrlIsRejected() {
    XCTAssertNil(FreshLocator(reply: ["url": "   "]))
    XCTAssertNil(FreshLocator(reply: ["headers": ["a": "b"]]))
    XCTAssertNil(FreshLocator(reply: ["url": 42]))
  }

  func testNonMapRepliesAreRejected() {
    // `nil` is what a Dart route that has already unmounted answers; a string
    // stands in for the `FlutterMethodNotImplemented`/`FlutterError` sentinels,
    // neither of which is a dictionary.
    XCTAssertNil(FreshLocator(reply: nil))
    XCTAssertNil(FreshLocator(reply: "not-implemented"))
    XCTAssertNil(FreshLocator(reply: ["http://host/1.m3u8"]))
  }

  func testHeaderHygieneMatchesTheOpenPayload() {
    let locator = FreshLocator(
      reply: [
        "url": "http://host/1.m3u8",
        "headers": ["Referer": "http://portal/", "": "dropped", "Blank": "  ", "N": 7],
      ]
    )
    XCTAssertEqual(locator?.headers, ["Referer": "http://portal/", "N": "7"])
  }

  func testResolveTimeoutIsAFiniteLivenessBackstop() {
    // The point of the constant is that it exists and is finite — a completion
    // that never fires must never be able to stall the reconnect forever.
    XCTAssertGreaterThan(LiveReconnectWatchdog.resolveTimeoutMs, 0)
    XCTAssertLessThanOrEqual(
      LiveReconnectWatchdog.resolveTimeoutMs,
      ReconnectPolicy.maxBackoffMs
    )
  }
}
