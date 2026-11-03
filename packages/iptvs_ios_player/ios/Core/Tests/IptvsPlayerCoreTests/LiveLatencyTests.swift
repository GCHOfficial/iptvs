import XCTest

@testable import IptvsPlayerCore

/// Pins the wave-1 live-latency contract (`live-latency-contract.md`, shared
/// verbatim with Android/Windows/Linux) against this platform's tracker and
/// formatters. The parity-vector table in that document is asserted exactly —
/// any implementation that fails these exact strings has drifted from the
/// other three platforms' diagnostics output.
final class LiveLatencyTests: XCTestCase {

  // MARK: - Parity vectors (the contract's own table)

  private struct Vector {
    let driftMs: Int64
    let aheadMs: Int64
    let badge: String
    let infoValue: String
  }

  private let vectors: [Vector] = [
    Vector(driftMs: 0, aheadMs: 12_400, badge: "LIVE", infoValue: "0:00 · buffer 12s"),
    Vector(driftMs: 7_999, aheadMs: -1, badge: "LIVE", infoValue: "0:07"),
    Vector(driftMs: 29_999, aheadMs: 500, badge: "LIVE", infoValue: "0:29 · buffer 1s"),
    Vector(driftMs: 30_000, aheadMs: 24_600, badge: "LIVE -0:30", infoValue: "0:30 · buffer 25s"),
    Vector(driftMs: 83_000, aheadMs: 24_000, badge: "LIVE -1:23", infoValue: "1:23 · buffer 24s"),
    Vector(
      driftMs: 3_723_000,
      aheadMs: 0,
      badge: "LIVE -1:02:03",
      infoValue: "1:02:03 · buffer 0s"
    ),
  ]

  func testParityVectors() {
    for vector in vectors {
      XCTAssertEqual(
        LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: vector.driftMs),
        vector.badge,
        "badge for drift=\(vector.driftMs)"
      )
      XCTAssertEqual(
        LiveLatencyFormatting.liveDelayInfoValue(driftMs: vector.driftMs, aheadMs: vector.aheadMs),
        vector.infoValue,
        "info value for drift=\(vector.driftMs) ahead=\(vector.aheadMs)"
      )
    }
  }

  // MARK: - fmtDelay

  func testFmtDelayFloorsToWholeSeconds() {
    XCTAssertEqual(LiveLatencyFormatting.fmtDelay(0), "0:00")
    XCTAssertEqual(LiveLatencyFormatting.fmtDelay(999), "0:00")
    XCTAssertEqual(LiveLatencyFormatting.fmtDelay(1_000), "0:01")
    XCTAssertEqual(LiveLatencyFormatting.fmtDelay(1_999), "0:01")
  }

  func testFmtDelaySwitchesToHoursPastThirtySixHundredSeconds() {
    XCTAssertEqual(LiveLatencyFormatting.fmtDelay(3_599_000), "59:59")
    XCTAssertEqual(LiveLatencyFormatting.fmtDelay(3_600_000), "1:00:00")
  }

  // MARK: - Badge threshold

  func testBadgeFlipsExactlyAtTheWarnThreshold() {
    XCTAssertEqual(LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: kLiveDriftWarnMs - 1), "LIVE")
    XCTAssertEqual(
      LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: kLiveDriftWarnMs),
      "LIVE -0:30"
    )
    // ASCII hyphen-minus, never U+2212 — the GDI/ASS renderers this string
    // format mirrors don't all carry the Unicode glyph.
    XCTAssertTrue(LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: kLiveDriftWarnMs).contains("-"))
    XCTAssertFalse(
      LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: kLiveDriftWarnMs).contains("\u{2212}")
    )
  }

  // MARK: - Baseline

  /// Before a baseline, drift is 0 regardless of how much wall time passes —
  /// there is nothing to measure before the stream has ever progressed.
  func testDriftStaysZeroBeforeBaseline() {
    var tracker = LiveLatencyTracker()
    XCTAssertFalse(tracker.hasBaseline)
    // Not playing yet: no baseline, whatever the position reads.
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 0, isPlaying: false, isBuffering: true))
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 0, isPlaying: false, isBuffering: true))
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
    // Now playing, but the position still hasn't moved from the previous
    // sample (0 -> 0): "played" alone isn't enough, media time must actually
    // have advanced, so a big wall-clock gap buys no baseline on its own.
    tracker.sample(LiveLatencySample(nowMs: 60_000, positionMs: 0, isPlaying: true, isBuffering: false))
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
  }

  /// The baseline-forming tick itself contributes no drift — it only seeds the
  /// wall/media reference point for the *next* sample's delta.
  func testBaselineEstablishesOnFirstProgressWhilePlaying() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 0, isPlaying: true, isBuffering: false))
    XCTAssertFalse(tracker.hasBaseline, "no previous position to compare against yet")
    tracker.sample(LiveLatencySample(nowMs: 1_500, positionMs: 500, isPlaying: true, isBuffering: false))
    XCTAssertTrue(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
  }

  /// A stream that never advances (frozen pre-roll, audio-only silence with no
  /// timestamp movement) never baselines, however long it's sampled.
  func testStoppedPositionNeverBaselines() {
    var tracker = LiveLatencyTracker()
    for tick in stride(from: Int64(500), through: 30_000, by: 500) {
      tracker.sample(
        LiveLatencySample(nowMs: tick, positionMs: 0, isPlaying: true, isBuffering: false)
      )
    }
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
  }

  // MARK: - Steady playback

  /// Media time keeping pace with wall time accumulates no drift at all —
  /// healthy realtime playback.
  func testSteadyPlaybackAccumulatesNoDrift() {
    var tracker = LiveLatencyTracker()
    var positionMs: Int64 = 0
    for tick in stride(from: Int64(500), through: 30_000, by: 500) {
      tracker.sample(
        LiveLatencySample(nowMs: tick, positionMs: positionMs, isPlaying: true, isBuffering: false)
      )
      positionMs += 500
    }
    XCTAssertEqual(tracker.driftMs, 0)
    XCTAssertEqual(tracker.discontinuities, 0)
  }

  // MARK: - Pause / stall accumulate real lag, with no cap

  /// A pause (media time frozen, wall time advancing) is not a discontinuity —
  /// it is exactly the lag this contract exists to measure, and there is no
  /// cap on how long a single gap may run.
  func testPauseAccumulatesDriftWithNoCap() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false))
    XCTAssertTrue(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)

    // Paused for a full minute: media time does not move, wall time does.
    tracker.sample(LiveLatencySample(nowMs: 60_500, positionMs: 500, isPlaying: false, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, 60_000)

    // Resumed: media time now advances again from where it left off, so this
    // tick adds nothing further.
    tracker.sample(LiveLatencySample(nowMs: 61_000, positionMs: 1_000, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, 60_000)
  }

  /// A stall (buffering, media time frozen) is the same shape as a pause from
  /// the tracker's point of view — the wall/media mismatch is what accrues —
  /// and is additionally attributed via ``LiveLatencyTracker/stalls`` and
  /// ``LiveLatencyTracker/stalledMs``.
  func testStallAccumulatesDriftAndIsAttributedSeparately() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false))

    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 500, isPlaying: false, isBuffering: true))
    tracker.sample(LiveLatencySample(nowMs: 1_500, positionMs: 500, isPlaying: false, isBuffering: true))
    tracker.sample(LiveLatencySample(nowMs: 5_500, positionMs: 500, isPlaying: false, isBuffering: true))
    // Recovered: this tick's own delta (4000ms wall, 0 media since the last
    // sample) is still folded into drift — attribution doesn't exempt it.
    tracker.sample(LiveLatencySample(nowMs: 6_000, positionMs: 1_000, isPlaying: true, isBuffering: false))

    XCTAssertEqual(tracker.driftMs, 5_000)
    XCTAssertEqual(tracker.stalls, 1)
    XCTAssertEqual(tracker.stalledMs, 5_000)
  }

  func testMultipleStallsEachCountAndSumIndependently() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false))

    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 500, isPlaying: false, isBuffering: true))
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 1_000, isPlaying: true, isBuffering: false))

    tracker.sample(LiveLatencySample(nowMs: 2_500, positionMs: 1_500, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 3_000, positionMs: 1_500, isPlaying: false, isBuffering: true))
    tracker.sample(LiveLatencySample(nowMs: 4_000, positionMs: 2_000, isPlaying: true, isBuffering: false))

    XCTAssertEqual(tracker.stalls, 2)
  }

  // MARK: - Discontinuities

  /// A backward jump (seek, reconnect landing earlier) re-baselines without
  /// adding to drift or treating the jump itself as lag.
  func testBackwardJumpIsADiscontinuityThatPreservesDrift() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 10_000, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 10_500, isPlaying: true, isBuffering: false))
    // Accrue some real drift first, so the test can show the discontinuity
    // doesn't erase it.
    tracker.sample(LiveLatencySample(nowMs: 10_500, positionMs: 10_600, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, 9_900)
    let driftBeforeJump = tracker.driftMs

    // Position jumps backward by more than 500ms with no matching wall-time
    // gap: a discontinuity, not 9+ seconds of sudden "negative lag".
    tracker.sample(LiveLatencySample(nowMs: 11_000, positionMs: 5_000, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, driftBeforeJump, "the jump itself must not move drift")
    XCTAssertEqual(tracker.discontinuities, 1)

    // The tick after re-baselines cleanly from the new position.
    tracker.sample(LiveLatencySample(nowMs: 11_500, positionMs: 5_500, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, driftBeforeJump)
  }

  /// A forward jump far larger than the elapsed wall time (a reconnect that
  /// lands minutes ahead, e.g. after re-resolving a live-edge locator) is the
  /// same shape of discontinuity as a backward one.
  func testLargeForwardJumpIsADiscontinuityToo() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, 0)

    // 500ms of wall time passes, but media jumps forward by a whole minute —
    // `dMedia (60_000) > dWall (500) + 2000`.
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 60_500, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.driftMs, 0, "the jump must not read as negative lag")
    XCTAssertEqual(tracker.discontinuities, 1)
  }

  /// The boundary values themselves: exactly at the threshold is *not* a
  /// discontinuity (the contract's comparisons are strict `<`/`>`).
  func testDiscontinuityBoundariesAreExclusive() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 1_000, isPlaying: true, isBuffering: false))

    // dWall = 1000, dMedia = -500 exactly: not < -500, so this is ordinary
    // (very large) drift, not a discontinuity.
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 500, isPlaying: true, isBuffering: false))
    XCTAssertEqual(tracker.discontinuities, 0)
    XCTAssertEqual(tracker.driftMs, 1_500)
  }

  // MARK: - Reset

  func testResetClearsEveryAccumulatedFigure() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    // The second sample is the one that baselines (playing, media advanced);
    // only after it can a stall accrue drift.
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 1_000, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 61_000, positionMs: 1_500, isPlaying: false, isBuffering: true))
    XCTAssertEqual(tracker.driftMs, 59_500)
    XCTAssertEqual(tracker.stalls, 1)

    tracker.reset()
    XCTAssertEqual(tracker, LiveLatencyTracker())
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
    XCTAssertEqual(tracker.stalls, 0)
    XCTAssertEqual(tracker.stalledMs, 0)
    XCTAssertEqual(tracker.discontinuities, 0)
  }

  /// A fresh baseline forms independently after a reset — the tracker is not
  /// left in some half-initialised state that needs an extra tick to recover.
  func testTrackerBehavesAsFreshAfterReset() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false))
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false))
    tracker.reset()

    tracker.sample(LiveLatencySample(nowMs: 100_000, positionMs: 0, isPlaying: true, isBuffering: false))
    XCTAssertFalse(tracker.hasBaseline)
    tracker.sample(LiveLatencySample(nowMs: 100_500, positionMs: 500, isPlaying: true, isBuffering: false))
    XCTAssertTrue(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
  }

  // MARK: - Reset reasons / log lines

  func testResetLineCarriesTheReasonDriftAndStalls() {
    XCTAssertEqual(
      LiveLatencyLogging.resetLine(reason: .reconnect, driftMs: 12_345, stalls: 3),
      "live latency reset reason=reconnect drift=12345ms stalls=3"
    )
    for reason in [
      LiveLatencyResetReason.load, .reconnect, .zap, .golive, .engine, .claim,
    ] {
      XCTAssertTrue(
        LiveLatencyLogging.resetLine(reason: reason, driftMs: 1, stalls: 0)
          .contains("reason=\(reason.rawValue)")
      )
    }
  }

  /// `IptvsPlayerViewController.resetLiveLatency` (not unit-testable directly —
  /// it is UIKit-bound) gates on `driftMs >= resetLogMinDriftMs` before calling
  /// `resetLine`. Pins the parity constant itself (1s, matching Dart's
  /// `kLiveLatencyResetLogMinDriftMs` and Kotlin's
  /// `LiveLatency.RESET_LOG_MIN_DRIFT_MS`) and the boundary the caller's `>=`
  /// comparison relies on, so a change to one can't silently drift from the
  /// other two platforms.
  func testResetLogMinDriftMsIsOneSecondAndInclusiveAtTheBoundary() {
    XCTAssertEqual(LiveLatencyLogging.resetLogMinDriftMs, 1_000)
    XCTAssertFalse(999 >= LiveLatencyLogging.resetLogMinDriftMs)
    XCTAssertTrue(1_000 >= LiveLatencyLogging.resetLogMinDriftMs)
  }

  func testPeriodicAndBehindLinesShareTheirBody() {
    let periodic = LiveLatencyLogging.periodicLine(
      driftMs: 31_000,
      aheadMs: 2_000,
      stalls: 2,
      stalledMs: 4_000,
      discontinuities: 1
    )
    XCTAssertEqual(periodic, "live latency drift=31000ms ahead=2000ms stalls=2 stalled=4000ms disc=1")

    let behind = LiveLatencyLogging.behindLine(
      driftMs: 31_000,
      aheadMs: 2_000,
      stalls: 2,
      stalledMs: 4_000,
      discontinuities: 1
    )
    XCTAssertEqual(behind, "live latency behind " + periodic)
  }

  func testShouldLogPeriodicGatesOnEitherDriftOrAhead() {
    XCTAssertFalse(LiveLatencyLogging.shouldLogPeriodic(driftMs: 0, aheadMs: 0))
    XCTAssertTrue(LiveLatencyLogging.shouldLogPeriodic(driftMs: 5_000, aheadMs: 0))
    XCTAssertTrue(LiveLatencyLogging.shouldLogPeriodic(driftMs: 0, aheadMs: 30_000))
    XCTAssertFalse(LiveLatencyLogging.shouldLogPeriodic(driftMs: 4_999, aheadMs: 29_999))
  }

  func testCrossedWarnThresholdFiresOnlyOnTheEdge() {
    XCTAssertFalse(
      LiveLatencyLogging.crossedWarnThreshold(previousDriftMs: 0, currentDriftMs: 29_999)
    )
    XCTAssertTrue(
      LiveLatencyLogging.crossedWarnThreshold(previousDriftMs: 29_999, currentDriftMs: 30_000)
    )
    // Already behind: no repeated edge.
    XCTAssertFalse(
      LiveLatencyLogging.crossedWarnThreshold(previousDriftMs: 30_000, currentDriftMs: 31_000)
    )
  }
}
