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
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 0, isPlaying: false, isBuffering: true), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 0, isPlaying: false, isBuffering: true), aheadMs: -1)
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
    // Now playing, but the position still hasn't moved from the previous
    // sample (0 -> 0): "played" alone isn't enough, media time must actually
    // have advanced, so a big wall-clock gap buys no baseline on its own.
    tracker.sample(LiveLatencySample(nowMs: 60_000, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
  }

  /// The baseline-forming tick itself contributes no drift — it only seeds the
  /// wall/media reference point for the *next* sample's delta.
  func testBaselineEstablishesOnFirstProgressWhilePlaying() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertFalse(tracker.hasBaseline, "no previous position to compare against yet")
    tracker.sample(LiveLatencySample(nowMs: 1_500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertTrue(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
  }

  /// A stream that never advances (frozen pre-roll, audio-only silence with no
  /// timestamp movement) never baselines, however long it's sampled.
  func testStoppedPositionNeverBaselines() {
    var tracker = LiveLatencyTracker()
    for tick in stride(from: Int64(500), through: 30_000, by: 500) {
      tracker.sample(
        LiveLatencySample(nowMs: tick, positionMs: 0, isPlaying: true, isBuffering: false),
        aheadMs: -1
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
        LiveLatencySample(nowMs: tick, positionMs: positionMs, isPlaying: true, isBuffering: false),
        aheadMs: -1
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
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertTrue(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)

    // Paused for a full minute: media time does not move, wall time does.
    tracker.sample(LiveLatencySample(nowMs: 60_500, positionMs: 500, isPlaying: false, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, 60_000)

    // Resumed: media time now advances again from where it left off, so this
    // tick adds nothing further.
    tracker.sample(LiveLatencySample(nowMs: 61_000, positionMs: 1_000, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, 60_000)
  }

  /// A stall (buffering, media time frozen) is the same shape as a pause from
  /// the tracker's point of view — the wall/media mismatch is what accrues —
  /// and is additionally attributed via ``LiveLatencyTracker/stalls`` and
  /// ``LiveLatencyTracker/stalledMs``.
  func testStallAccumulatesDriftAndIsAttributedSeparately() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)

    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 500, isPlaying: false, isBuffering: true), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 1_500, positionMs: 500, isPlaying: false, isBuffering: true), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 5_500, positionMs: 500, isPlaying: false, isBuffering: true), aheadMs: -1)
    // Recovered: this tick's own delta (4000ms wall, 0 media since the last
    // sample) is still folded into drift — attribution doesn't exempt it.
    tracker.sample(LiveLatencySample(nowMs: 6_000, positionMs: 1_000, isPlaying: true, isBuffering: false), aheadMs: -1)

    XCTAssertEqual(tracker.driftMs, 5_000)
    XCTAssertEqual(tracker.stalls, 1)
    XCTAssertEqual(tracker.stalledMs, 5_000)
  }

  func testMultipleStallsEachCountAndSumIndependently() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)

    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 500, isPlaying: false, isBuffering: true), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 1_000, isPlaying: true, isBuffering: false), aheadMs: -1)

    tracker.sample(LiveLatencySample(nowMs: 2_500, positionMs: 1_500, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 3_000, positionMs: 1_500, isPlaying: false, isBuffering: true), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 4_000, positionMs: 2_000, isPlaying: true, isBuffering: false), aheadMs: -1)

    XCTAssertEqual(tracker.stalls, 2)
  }

  // MARK: - Discontinuities

  /// A backward jump (seek, reconnect landing earlier) re-baselines without
  /// adding to drift or treating the jump itself as lag.
  func testBackwardJumpIsADiscontinuityThatPreservesDrift() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 10_000, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 10_500, isPlaying: true, isBuffering: false), aheadMs: -1)
    // Accrue some real drift first, so the test can show the discontinuity
    // doesn't erase it.
    tracker.sample(LiveLatencySample(nowMs: 10_500, positionMs: 10_600, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, 9_900)
    let driftBeforeJump = tracker.driftMs

    // Position jumps backward by more than 500ms with no matching wall-time
    // gap: a discontinuity, not 9+ seconds of sudden "negative lag".
    tracker.sample(LiveLatencySample(nowMs: 11_000, positionMs: 5_000, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, driftBeforeJump, "the jump itself must not move drift")
    XCTAssertEqual(tracker.discontinuities, 1)

    // The tick after re-baselines cleanly from the new position.
    tracker.sample(LiveLatencySample(nowMs: 11_500, positionMs: 5_500, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, driftBeforeJump)
  }

  /// A forward jump far larger than the elapsed wall time (a reconnect that
  /// lands minutes ahead, e.g. after re-resolving a live-edge locator) is the
  /// same shape of discontinuity as a backward one.
  func testLargeForwardJumpIsADiscontinuityToo() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, 0)

    // 500ms of wall time passes, but media jumps forward by a whole minute —
    // `dMedia (60_000) > dWall (500) + 2000`.
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 60_500, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.driftMs, 0, "the jump must not read as negative lag")
    XCTAssertEqual(tracker.discontinuities, 1)
  }

  /// The boundary values themselves: exactly at the threshold is *not* a
  /// discontinuity (the contract's comparisons are strict `<`/`>`).
  func testDiscontinuityBoundariesAreExclusive() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 1_000, isPlaying: true, isBuffering: false), aheadMs: -1)

    // dWall = 1000, dMedia = -500 exactly: not < -500, so this is ordinary
    // (very large) drift, not a discontinuity.
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertEqual(tracker.discontinuities, 0)
    XCTAssertEqual(tracker.driftMs, 1_500)
  }

  // MARK: - Reset

  func testResetClearsEveryAccumulatedFigure() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    // The second sample is the one that baselines (playing, media advanced);
    // only after it can a stall accrue drift. (The baseline-forming tick
    // itself never folds into `backlogMs` either — see its own doc — so a
    // third, honest tick establishes a real backlog reading *before* the
    // stall, which would otherwise swamp the candidate with its huge drift
    // and leave `backlogMs` at its initial `0`.)
    tracker.sample(LiveLatencySample(nowMs: 1_000, positionMs: 1_000, isPlaying: true, isBuffering: false), aheadMs: 2_000)
    tracker.sample(LiveLatencySample(nowMs: 2_000, positionMs: 2_000, isPlaying: true, isBuffering: false), aheadMs: 2_000)
    tracker.sample(LiveLatencySample(nowMs: 62_000, positionMs: 2_500, isPlaying: false, isBuffering: true), aheadMs: 2_000)
    tracker.credit(500)
    XCTAssertEqual(tracker.driftMs, 59_500)
    XCTAssertEqual(tracker.stalls, 1)
    // Wave 2 (`live-latency-wave2-contract.md` (a)): the new accumulators have
    // something to clear too, not just zero to begin with.
    XCTAssertGreaterThan(tracker.backlogMs, 0)
    XCTAssertEqual(tracker.creditedMs, 500)
    XCTAssertGreaterThan(tracker.delayMs, 0)

    tracker.reset()
    XCTAssertEqual(tracker, LiveLatencyTracker())
    XCTAssertFalse(tracker.hasBaseline)
    XCTAssertEqual(tracker.driftMs, 0)
    XCTAssertEqual(tracker.stalls, 0)
    XCTAssertEqual(tracker.stalledMs, 0)
    XCTAssertEqual(tracker.discontinuities, 0)
    // Wave 2: "Reset ... clears `creditedMs` and `backlogMs` too."
    XCTAssertEqual(tracker.creditedMs, 0)
    XCTAssertEqual(tracker.backlogMs, 0)
    XCTAssertEqual(tracker.delayMs, 0)
  }

  /// A fresh baseline forms independently after a reset — the tracker is not
  /// left in some half-initialised state that needs an extra tick to recover.
  func testTrackerBehavesAsFreshAfterReset() {
    var tracker = LiveLatencyTracker()
    tracker.sample(LiveLatencySample(nowMs: 0, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.sample(LiveLatencySample(nowMs: 500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)
    tracker.reset()

    tracker.sample(LiveLatencySample(nowMs: 100_000, positionMs: 0, isPlaying: true, isBuffering: false), aheadMs: -1)
    XCTAssertFalse(tracker.hasBaseline)
    tracker.sample(LiveLatencySample(nowMs: 100_500, positionMs: 500, isPlaying: true, isBuffering: false), aheadMs: -1)
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
      discontinuities: 1,
      delayMs: 33_000,
      backlogMs: 5_000,
      creditedMs: 3_000
    )
    XCTAssertEqual(
      periodic,
      "live latency drift=31000ms ahead=2000ms stalls=2 stalled=4000ms disc=1"
        + " delay=33000ms backlog=5000ms credited=3000ms"
    )

    let behind = LiveLatencyLogging.behindLine(
      driftMs: 31_000,
      aheadMs: 2_000,
      stalls: 2,
      stalledMs: 4_000,
      discontinuities: 1,
      delayMs: 33_000,
      backlogMs: 5_000,
      creditedMs: 3_000
    )
    XCTAssertEqual(behind, "live latency behind " + periodic)
  }

  func testShouldLogPeriodicGatesOnEitherDriftOrAhead() {
    XCTAssertFalse(LiveLatencyLogging.shouldLogPeriodic(delayMs: 0, aheadMs: 0))
    XCTAssertTrue(LiveLatencyLogging.shouldLogPeriodic(delayMs: 5_000, aheadMs: 0))
    XCTAssertTrue(LiveLatencyLogging.shouldLogPeriodic(delayMs: 0, aheadMs: 30_000))
    XCTAssertFalse(LiveLatencyLogging.shouldLogPeriodic(delayMs: 4_999, aheadMs: 29_999))
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

  // MARK: - Wave 2: backlog / credit / delay

  /// `live-latency-wave2-contract.md` (a)'s own `credit(_:)` contract: grows
  /// only through an explicit call, clamped at `0`, and never shrinks.
  func testCreditGrowsCreditedMsAndClampsNegativeInput() {
    var tracker = LiveLatencyTracker()
    tracker.credit(500)
    XCTAssertEqual(tracker.creditedMs, 500)
    tracker.credit(250)
    XCTAssertEqual(tracker.creditedMs, 750)
    tracker.credit(-1_000)
    XCTAssertEqual(tracker.creditedMs, 750, "credit only ever grows")
  }

  // MARK: - Wave 2 parity scenarios (S1–S5)
  //
  // The exact sequences from `live-latency-wave2-contract.md` (a)'s "Tracker
  // parity scenarios" table — hand-verified arithmetic is recorded in the
  // implementing agent's report, not restated here as comments, to keep these
  // tests reading like the contract's own prose.

  /// S1, honest 1x: a healthy stream with a steady 2s cushion reads as exactly
  /// that cushion's worth of (unavoidable) delay, with zero drift.
  func testWave2ScenarioS1HonestOneX() {
    var tracker = LiveLatencyTracker()
    for t in stride(from: Int64(0), through: 60_000, by: 1_000) {
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: t, isPlaying: true, isBuffering: false),
        aheadMs: 2_000
      )
    }
    XCTAssertEqual(tracker.driftMs, 0)
    XCTAssertEqual(tracker.backlogMs, 2_000)
    XCTAssertEqual(tracker.delayMs, 2_000)
    XCTAssertEqual(LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: tracker.delayMs), "LIVE")
  }

  /// S2, burst: the same honest 1x stream, but the provider is holding a
  /// 30s connect-time backlog the whole time. Drift alone would miss this
  /// entirely (it stays 0); `delayMs` is what makes it visible, and is what
  /// crosses the warn threshold here even though drift never does.
  func testWave2ScenarioS2Burst() {
    var tracker = LiveLatencyTracker()
    for t in stride(from: Int64(0), through: 60_000, by: 1_000) {
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: t, isPlaying: true, isBuffering: false),
        aheadMs: 30_000
      )
    }
    XCTAssertEqual(tracker.driftMs, 0, "an honest 1x stream accrues no drift regardless of backlog")
    XCTAssertEqual(tracker.backlogMs, 30_000)
    XCTAssertEqual(tracker.delayMs, 30_000)
    XCTAssertEqual(LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: tracker.delayMs), "LIVE -0:30")
    XCTAssertTrue(
      LiveLatencyLogging.crossedWarnThreshold(previousDriftMs: 0, currentDriftMs: tracker.delayMs),
      "delay alone crosses the warn threshold"
    )
  }

  /// S3, pause on 1x: ten seconds of honest playback (backlog 2000, matching
  /// S1) followed by a minute-long pause during which the engine's own
  /// cushion keeps growing (the provider queues data while nothing drains
  /// it). The backlog figure must not be inflated by the pause — a provider
  /// queuing data during a pause raises `ahead` *with* `drift` in lockstep,
  /// so the running backlog maximum stays pinned at its pre-pause value and
  /// the pause shows up entirely as drift instead.
  func testWave2ScenarioS3PauseOnOneX() {
    var tracker = LiveLatencyTracker()
    for t in stride(from: Int64(0), through: 10_000, by: 1_000) {
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: t, isPlaying: true, isBuffering: false),
        aheadMs: 2_000
      )
    }
    for i in 0...59 {
      let t: Int64 = 11_000 + Int64(i) * 1_000
      let ahead: Int64 = 2_000 + (28_000 * Int64(i)) / 59
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: 10_000, isPlaying: false, isBuffering: false),
        aheadMs: ahead
      )
    }
    XCTAssertEqual(tracker.driftMs, 60_000)
    XCTAssertEqual(tracker.backlogMs, 2_000, "the pause must not inflate the backlog figure")
    XCTAssertEqual(tracker.delayMs, 62_000)
  }

  /// S4, skip then refill: an in-cache skip (`live-latency-wave2-contract.md`
  /// (b)) credits back the measured jump. The jump itself is a discontinuity
  /// — no drift added — and the backlog figure, read right after the skip,
  /// still reflects the pre-skip maximum (the skip reduced *delay*, not the
  /// provider's underlying backlog). As the buffer refills on an honest 1x
  /// stream afterward, the backlog maximum rises again to account for the
  /// credit, while delay stays pinned at the post-skip reading until the
  /// backlog actually exceeds it.
  func testWave2ScenarioS4SkipThenRefill() {
    var tracker = LiveLatencyTracker()
    for t in stride(from: Int64(0), through: 20_000, by: 1_000) {
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: t, isPlaying: true, isBuffering: false),
        aheadMs: 30_000
      )
    }
    XCTAssertEqual(tracker.backlogMs, 30_000)

    tracker.credit(27_000)
    XCTAssertEqual(tracker.creditedMs, 27_000)

    // The skip's jump: pos_prev (20000) + 28000, in one 1000ms tick — far
    // past the discontinuity threshold, so it re-anchors and adds nothing.
    tracker.sample(
      LiveLatencySample(nowMs: 21_000, positionMs: 20_000 + 28_000, isPlaying: true, isBuffering: false),
      aheadMs: 3_000
    )
    XCTAssertEqual(tracker.discontinuities, 1)
    XCTAssertEqual(tracker.driftMs, 0, "the jump itself must not read as drift")
    XCTAssertEqual(tracker.backlogMs, 30_000, "ties the existing max; the skip doesn't exceed it")
    XCTAssertEqual(tracker.delayMs, 3_000, "backlog 30000 + drift 0 - credited 27000")

    // Refill: honest 1x from the new position, ahead climbing back toward
    // 30000 over the next 19 one-second ticks (t=22000..40000).
    var positionMs: Int64 = 48_000
    for i in 1...19 {
      let t: Int64 = 21_000 + Int64(i) * 1_000
      positionMs += 1_000
      let ahead: Int64 = 3_000 + (27_000 * Int64(i)) / 19
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: positionMs, isPlaying: true, isBuffering: false),
        aheadMs: ahead
      )
    }
    XCTAssertEqual(tracker.driftMs, 0)
    XCTAssertEqual(tracker.backlogMs, 57_000, "30000 ahead + 27000 credited, once ahead rebuilds to 30000")
    XCTAssertEqual(tracker.delayMs, 30_000, "backlog 57000 + drift 0 - credited 27000")
  }

  /// S5, catch-up credit: 20 ticks of 1.05x playback (`dMedia` 1050ms per
  /// 1000ms wall tick) with `catchingUp: true` credit back exactly what the
  /// speed-up drained from the backlog (50ms/tick, the same amount `ahead`
  /// falls by), so `backlogMs` itself never moves and `delayMs` drops by
  /// precisely the accumulated credit.
  func testWave2ScenarioS5CatchUpCredit() {
    var tracker = LiveLatencyTracker()
    for t in stride(from: Int64(0), through: 10_000, by: 1_000) {
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: t, isPlaying: true, isBuffering: false),
        aheadMs: 30_000
      )
    }
    XCTAssertEqual(tracker.backlogMs, 30_000)

    var nowMs: Int64 = 10_000
    var positionMs: Int64 = 10_000
    for k in 1...20 {
      nowMs += 1_000
      positionMs += 1_050
      let ahead: Int64 = 30_000 - 50 * Int64(k)
      tracker.sample(
        LiveLatencySample(
          nowMs: nowMs,
          positionMs: positionMs,
          isPlaying: true,
          isBuffering: false,
          catchingUp: true
        ),
        aheadMs: ahead
      )
    }
    XCTAssertEqual(tracker.driftMs, 0)
    XCTAssertEqual(tracker.creditedMs, 1_000)
    XCTAssertEqual(tracker.backlogMs, 30_000, "credited exactly offsets the falling ahead figure")
    XCTAssertEqual(tracker.delayMs, 29_000)
  }

  /// The same S5 sequence with `catchingUp` left at its default `false`:
  /// nothing is ever credited, and delay reads the full (uncredited) backlog
  /// figure instead.
  func testWave2ScenarioS5WithoutCatchingUpFlagCreditsNothing() {
    var tracker = LiveLatencyTracker()
    for t in stride(from: Int64(0), through: 10_000, by: 1_000) {
      tracker.sample(
        LiveLatencySample(nowMs: t, positionMs: t, isPlaying: true, isBuffering: false),
        aheadMs: 30_000
      )
    }
    var nowMs: Int64 = 10_000
    var positionMs: Int64 = 10_000
    for k in 1...20 {
      nowMs += 1_000
      positionMs += 1_050
      let ahead: Int64 = 30_000 - 50 * Int64(k)
      tracker.sample(
        LiveLatencySample(nowMs: nowMs, positionMs: positionMs, isPlaying: true, isBuffering: false),
        aheadMs: ahead
      )
    }
    XCTAssertEqual(tracker.creditedMs, 0)
    XCTAssertEqual(tracker.delayMs, 30_000)
  }
}
