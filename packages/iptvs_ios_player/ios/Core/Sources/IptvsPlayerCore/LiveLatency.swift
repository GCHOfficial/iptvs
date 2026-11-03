import Foundation

/// Drift threshold (ms) past which a live stream reads as "behind live" rather
/// than at the edge. Shared across every surface implementing the wave-1
/// live-latency contract (`live-latency-contract.md`, the design document
/// handed to all four platforms at once): Android, Windows/Linux (computed in
/// Dart), and this one. Also the threshold ``PlayerChromeState/liveSynced``
/// latches false at, alongside the pre-existing pause rule.
public let kLiveDriftWarnMs: Int64 = 30_000

/// One tick's engine facts, fed into ``LiveLatencyTracker/sample(_:aheadMs:)``.
///
/// `isPlaying` only matters for establishing the baseline (see that type's
/// doc); once a baseline exists, drift accumulates from `nowMs`/`positionMs`
/// alone regardless of play state — a paused or stalled stream still falls
/// behind, which is the entire point of this contract.
public struct LiveLatencySample: Equatable, Sendable {
  public let nowMs: Int64
  public let positionMs: Int64
  public let isPlaying: Bool
  public let isBuffering: Bool

  /// Wave 2 (`live-latency-wave2-contract.md` (a)): true while the caller is
  /// deliberately running media time faster than wall time to shrink a
  /// backlog (ExoPlayer's 1.05x catch-up). A sample flagged `catchingUp`
  /// that isn't also a discontinuity earns **catch-up credit**
  /// (`max(0, dMedia - dWall)`), added to ``LiveLatencyTracker/creditedMs``.
  /// Defaults `false` so every wave-1 call site keeps compiling and keeps its
  /// old behaviour unchanged. **This controller never sets it true** — iOS has
  /// no catch-up speed-up (`live-latency-wave2-contract.md` (e) is
  /// ExoPlayer-only) — but the tracker implements the full shared contract
  /// regardless, since `LiveLatencyTests` pins it directly against the
  /// contract's parity scenarios.
  public let catchingUp: Bool

  public init(
    nowMs: Int64,
    positionMs: Int64,
    isPlaying: Bool,
    isBuffering: Bool,
    catchingUp: Bool = false
  ) {
    self.nowMs = nowMs
    self.positionMs = positionMs
    self.isPlaying = isPlaying
    self.isBuffering = isBuffering
    self.catchingUp = catchingUp
  }
}

/// Tracks delay accumulated behind the live edge since the current stream's
/// first frame — the pure half of the wave-1 live-latency contract.
///
/// **Why "nothing ever subtracts from drift" is the whole design.** Live
/// MPEG-TS arrives at roughly realtime; every rebuffer or pause adds its own
/// duration to how far behind live the viewer is, permanently, because the
/// decoder has no way to "catch up" on a live feed the way it can seek ahead
/// on VOD. A viewer who drifted 90s through rebuffering is 90s behind live
/// until an explicit reset (a reconnect, "Go to live", a fresh load) puts them
/// back at the edge — which is exactly the bug this contract exists to fix
/// (`liveSynced` used to go false only on a user pause, so a drifted viewer
/// still saw a green LIVE pill).
///
/// **Baseline.** Before the first sample where the engine is playing *and*
/// media time has advanced since the previous sample, drift is defined as `0`
/// — there is nothing to measure before the stream has ever progressed, and a
/// stream stuck pre-roll must not accumulate drift it hasn't earned.
///
/// **After baseline**, every sample compares wall-clock elapsed (`dWall`)
/// against media-time elapsed (`dMedia`) since the previous sample:
/// - A **discontinuity** (`dMedia < -500` or `dMedia > dWall + 2000` — a seek,
///   a reload landing on a different position, a bad PTS jump) keeps the
///   accumulated drift but re-baselines the wall/media reference points
///   without adding this tick's delta to drift, and counts toward
///   ``discontinuities``.
/// - Otherwise `driftMs += max(0, dWall - dMedia)`. There is deliberately **no
///   cap** on `dWall`: a long gap with no media progress — a pause, a stall,
///   the app backgrounded — **is** real lag.
///
/// **Stalls** (transitions into `isBuffering`) and the wall time spent
/// buffering are counted for attribution only in an exported diagnostics line
/// — they do not themselves move ``driftMs`` beyond what the ordinary
/// per-sample delta above already captures (a stall is just a period where
/// `dMedia` stays near zero while `dWall` keeps advancing).
///
/// ``reset()`` must be the only way ``driftMs`` ever goes back to zero, and
/// the caller is responsible for logging a reset line
/// (``LiveLatencyLogging/resetLine(reason:driftMs:stalls:)``) **before**
/// calling it if `driftMs >= LiveLatencyLogging.resetLogMinDriftMs` — the
/// contract requires the about-to-be-discarded figure to survive in the
/// diagnostics log, but only once it's worth printing.
///
/// **Wave 2** (`live-latency-wave2-contract.md` (a)) extends this with the
/// **backlog** a provider can hand over *before* the first frame — a
/// connect-time cushion of already-stale data that `driftMs` alone can't see,
/// since drift only measures delay added *after* baseline. ``aheadMs`` (media
/// buffered ahead of the playhead) is a lower bound on that backlog, so every
/// baselined sample folds `aheadMs + creditedMs - driftMs` into a running
/// maximum, ``backlogMs``. ``delayMs`` — `max(0, backlogMs + driftMs -
/// creditedMs)` — is the number every surface now shows the viewer; it can
/// never double-count a pause (a provider queuing data during a pause raises
/// `ahead` *with* `drift`, leaving the sum unmoved) and stays honest after a
/// verified in-cache skip followed by a refill, because the credit from that
/// skip is subtracted back out once the backlog it exposed rebuilds.
/// ``creditedMs`` is delay deliberately removed: either a measured jump after
/// a verified skip (``credit(_:)``) or, while a sample reports
/// ``LiveLatencySample/catchingUp``, the per-tick gain from running media
/// time faster than wall time. Nothing else ever reduces it.
public struct LiveLatencyTracker: Equatable, Sendable {
  public private(set) var driftMs: Int64 = 0

  /// Delay deliberately credited back — see the type doc. Grows only through
  /// ``credit(_:)`` and the catch-up-credit branch of ``sample(_:aheadMs:)``;
  /// nothing else moves it, and ``reset()`` is the only way it returns to
  /// zero.
  public private(set) var creditedMs: Int64 = 0

  /// Running maximum of `aheadMs + creditedMs - driftMs` over every baselined
  /// sample (a sample taken where ``aheadMs`` was unknown, i.e. negative, is
  /// skipped rather than folded in as zero — see the type doc). Starts at `0`
  /// and only rises, which is what makes it safe to read at any time rather
  /// than only after a full session.
  public private(set) var backlogMs: Int64 = 0

  public private(set) var hasBaseline: Bool = false
  public private(set) var stalls: Int = 0
  public private(set) var stalledMs: Int64 = 0
  public private(set) var discontinuities: Int = 0

  private var lastWallMs: Int64 = 0
  private var lastPositionMs: Int64 = 0

  /// The previous tick's position, tracked even before a baseline exists —
  /// baseline formation itself needs "did media time advance since the last
  /// sample", which requires having seen one.
  private var previousPositionMs: Int64?

  private var wasBuffering = false
  private var stallStartedMs: Int64 = 0

  public init() {}

  /// `max(0, backlogMs + driftMs - creditedMs)` — the lower-bound delay figure
  /// every surface displays and diagnostics logs in wave 2
  /// (`live-latency-wave2-contract.md` (a)). Derived rather than stored: it is
  /// a pure function of the three accumulators above, recomputed fresh on
  /// every read so it can never drift out of sync with them.
  public var delayMs: Int64 {
    max(0, backlogMs + driftMs - creditedMs)
  }

  /// Clears every accumulated figure back to a fresh tracker's values —
  /// including ``creditedMs`` and ``backlogMs`` (wave 2's reset clears them
  /// too, per `live-latency-wave2-contract.md` (a): "Reset ... clears
  /// `creditedMs` and `backlogMs` too").
  public mutating func reset() {
    self = LiveLatencyTracker()
  }

  /// Credits back a measured delay reduction — the mpv in-cache-skip path's
  /// verified jump (`live-latency-wave2-contract.md` (b) step 2: "call
  /// `tracker.credit(P2 - P)`"). Negative input is clamped to `0`; credit only
  /// ever grows. **Unused on iOS in wave 2** — there is no mpv surface here to
  /// skip on — but implemented so the type matches the shared contract and so
  /// `LiveLatencyTests` can pin the S4 parity scenario directly.
  public mutating func credit(_ ms: Int64) {
    creditedMs += max(0, ms)
  }

  /// Folds in one tick. Safe — and required — to call on every surface tick
  /// (~0.5–1s) regardless of play/buffer state; see the type doc for why a
  /// paused or stalled sample must still be fed in rather than skipped.
  ///
  /// `aheadMs` is the engine-read buffered-ahead cushion at this same tick —
  /// kept as a parameter here rather than a field of `LiveLatencySample`
  /// because, as in wave 1, it is engine-read and not tracker-derived; wave 2
  /// is the first thing that needs it *inside* the tracker, to fold into
  /// ``backlogMs``. A negative value (unknown) skips only the backlog fold —
  /// drift/discontinuity/stall accounting are unaffected.
  public mutating func sample(_ sample: LiveLatencySample, aheadMs: Int64) {
    defer { updateStallAccounting(sample) }

    guard hasBaseline else {
      if sample.isPlaying, let previous = previousPositionMs, sample.positionMs > previous {
        hasBaseline = true
        lastWallMs = sample.nowMs
        lastPositionMs = sample.positionMs
      }
      previousPositionMs = sample.positionMs
      return
    }

    let dWall = sample.nowMs - lastWallMs
    let dMedia = sample.positionMs - lastPositionMs
    lastWallMs = sample.nowMs
    lastPositionMs = sample.positionMs
    previousPositionMs = sample.positionMs

    if dMedia < -500 || dMedia > dWall + 2_000 {
      discontinuities += 1
    } else {
      driftMs += max(0, dWall - dMedia)
      // Catch-up credit (`live-latency-wave2-contract.md` (a)): only while
      // the caller reports `catchingUp` and only on a non-discontinuity tick,
      // where `dMedia` is a trustworthy measure of how much media time this
      // tick actually consumed.
      if sample.catchingUp {
        creditedMs += max(0, dMedia - dWall)
      }
    }

    // Backlog folds in on every baselined sample, discontinuities included —
    // the contract's "every baselined sample" has no carve-out for one, and a
    // discontinuity sample's `aheadMs`/`creditedMs`/`driftMs` are just as real
    // a reading as any other tick's.
    if aheadMs >= 0 {
      let candidate = aheadMs + creditedMs - driftMs
      if candidate > backlogMs { backlogMs = candidate }
    }
  }

  private mutating func updateStallAccounting(_ sample: LiveLatencySample) {
    if sample.isBuffering {
      if !wasBuffering {
        stalls += 1
        stallStartedMs = sample.nowMs
      }
    } else if wasBuffering {
      stalledMs += max(0, sample.nowMs - stallStartedMs)
    }
    wasBuffering = sample.isBuffering
  }
}

/// User-facing strings for live delay — identical wording required on every
/// surface (`live-latency-contract.md` "What the user sees"), down to the
/// ASCII hyphen-minus in the badge. Free functions in an enum namespace,
/// matching ``BadgeFormatting``'s shape: nothing here needs a
/// `PlayerChromeState` instance, only the raw millisecond figures it stores.
public enum LiveLatencyFormatting {
  /// `m:ss`, or `h:mm:ss` past an hour. Floors to whole seconds. A negative
  /// input — which should not occur, since drift only ever grows or resets to
  /// zero — reads as `"0:00"` rather than propagating a negative label.
  public static func fmtDelay(_ ms: Int64) -> String {
    let totalSeconds = max(0, ms) / 1_000
    if totalSeconds < 3_600 {
      return "\(totalSeconds / 60):\(pad2(totalSeconds % 60))"
    }
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    return "\(hours):\(pad2(minutes)):\(pad2(seconds))"
  }

  /// The compact LIVE badge: `"LIVE"` at the edge, `"LIVE -m:ss"` once behind.
  /// **ASCII hyphen-minus (`-`), never U+2212** — the same reason every other
  /// cross-surface label in this codebase avoids it: GDI/ASS fonts on the
  /// Windows and Linux renderers that print this identical string don't all
  /// carry the Unicode minus glyph.
  public static func liveDelayBadgeLabel(driftMs: Int64) -> String {
    driftMs < kLiveDriftWarnMs ? "LIVE" : "LIVE -\(fmtDelay(driftMs))"
  }

  /// The stream-info panel's "Live delay" row value: the delay, plus the
  /// buffered-ahead cushion when it's known. `aheadMs < 0` (unknown engine
  /// read) omits the buffer clause entirely rather than printing a bogus `0s`.
  ///
  /// `aheadMs` rounds to the nearest second, half away from zero (`500ms` →
  /// `1s`, matching the contract's parity vectors) — `Double.rounded()`'s
  /// default rounding rule.
  public static func liveDelayInfoValue(driftMs: Int64, aheadMs: Int64) -> String {
    let delay = fmtDelay(driftMs)
    guard aheadMs >= 0 else { return delay }
    let aheadSeconds = (Double(aheadMs) / 1_000).rounded()
    return "\(delay) · buffer \(Int(aheadSeconds))s"
  }

  private static func pad2(_ n: Int64) -> String {
    n < 10 ? "0\(n)" : "\(n)"
  }
}

/// Reset reasons for the "live latency reset" diagnostics line — the exact
/// vocabulary `live-latency-contract.md` specifies, shared verbatim with the
/// other three platforms so a diagnostics line reads the same wherever it came
/// from.
///
/// **Not every reason is reachable from this controller.** iOS has no zap
/// input yet (docs/ios.md "Live zapping" — "Only iOS's zap input remains
/// outstanding"), so ``zap`` is unused here until that lands. And iOS never
/// adopts another engine's already-running playback the way Android's
/// `SharedEngine` does: its AVPlayer↔mpv switch is a whole cross-language
/// `engineFailed` handoff that tears this controller down rather than an
/// in-place engine swap, so there is no "claimed a running surface" moment —
/// ``claim`` is likewise unused here. Both cases are defined regardless, for
/// parity with the shared vocabulary and so a future zap/adoption feature has
/// nothing left to add to this enum.
public enum LiveLatencyResetReason: String, Equatable, Sendable {
  case load
  case reconnect
  case zap
  case golive
  case engine
  case claim
}

/// Exportable diagnostics-log line builders — credential-free by construction,
/// since every argument is a count or a millisecond figure, never a URL or a
/// channel name. Mirrors ``BadgeFormatting``'s free-function shape; the caller
/// owns sending the resulting string through the host's existing log relay.
public enum LiveLatencyLogging {
  /// Minimum gap between periodic lines in one session.
  public static let periodicIntervalMs: Int64 = 60_000
  /// Buffered-ahead depth (ms) that alone justifies a periodic line, even with
  /// no meaningful drift.
  public static let aheadLogThresholdMs: Int64 = 30_000
  /// Drift (ms) that alone justifies a periodic line, even with a healthy
  /// buffer.
  public static let delayLogThresholdMs: Int64 = 5_000
  /// Drift (ms) a reset must have measured before ``resetLine`` is worth
  /// printing. Below this a reset is noise — a healthy stream resets with a
  /// few tens of milliseconds of jitter on nearly every reconnect/zap, and an
  /// export full of `drift=29ms` lines buries the resets that matter. Parity
  /// constant with Dart's `kLiveLatencyResetLogMinDriftMs` and Kotlin's
  /// `LiveLatency.RESET_LOG_MIN_DRIFT_MS`.
  public static let resetLogMinDriftMs: Int64 = 1_000

  /// Whether this tick's figures are worth a periodic export. The caller still
  /// owns the 60s cadence and the "only while live and playing" gate — this is
  /// only the content gate (`live-latency-contract.md`: "only if delayMs >=
  /// 5000 || aheadMs >= 30000"; wave 2 moved the gate from drift to delay).
  public static func shouldLogPeriodic(delayMs: Int64, aheadMs: Int64) -> Bool {
    delayMs >= delayLogThresholdMs || aheadMs >= aheadLogThresholdMs
  }

  /// `"live latency drift=<ms>ms ahead=<ms>ms stalls=<n> stalled=<ms>ms
  /// disc=<n> delay=<ms>ms backlog=<ms>ms credited=<ms>ms"`. Wave 2
  /// (`live-latency-wave2-contract.md` (a)) adds the three trailing fields
  /// after `drift=`'s existing group — the caller passes
  /// ``LiveLatencyTracker/delayMs``/``LiveLatencyTracker/backlogMs``/
  /// ``LiveLatencyTracker/creditedMs`` from the same tracker `driftMs`/
  /// `stalls`/`stalledMs`/`discontinuities` came from.
  public static func periodicLine(
    driftMs: Int64,
    aheadMs: Int64,
    stalls: Int,
    stalledMs: Int64,
    discontinuities: Int,
    delayMs: Int64,
    backlogMs: Int64,
    creditedMs: Int64
  ) -> String {
    "live latency drift=\(driftMs)ms ahead=\(aheadMs)ms stalls=\(stalls)"
      + " stalled=\(stalledMs)ms disc=\(discontinuities)"
      + " delay=\(delayMs)ms backlog=\(backlogMs)ms credited=\(creditedMs)ms"
  }

  /// Same content as ``periodicLine``, prefixed for the one-shot "just crossed
  /// the warn threshold this session" line. Wave 2: the crossing itself is now
  /// detected on `delayMs` (``crossedWarnThreshold``'s caller passes `delayMs`
  /// for both `previousDriftMs`/`currentDriftMs`), per
  /// `live-latency-wave2-contract.md` (a) — "The 'behind' crossing is now
  /// `delayMs >= kLiveDriftWarnMs`".
  public static func behindLine(
    driftMs: Int64,
    aheadMs: Int64,
    stalls: Int,
    stalledMs: Int64,
    discontinuities: Int,
    delayMs: Int64,
    backlogMs: Int64,
    creditedMs: Int64
  ) -> String {
    "live latency behind "
      + periodicLine(
        driftMs: driftMs,
        aheadMs: aheadMs,
        stalls: stalls,
        stalledMs: stalledMs,
        discontinuities: discontinuities,
        delayMs: delayMs,
        backlogMs: backlogMs,
        creditedMs: creditedMs
      )
  }

  /// `"live latency reset reason=<reason> drift=<ms>ms stalls=<n>"`. The
  /// caller only emits this when `driftMs >= resetLogMinDriftMs` — a reset
  /// with nothing meaningfully accumulated is not worth a diagnostics line.
  public static func resetLine(reason: LiveLatencyResetReason, driftMs: Int64, stalls: Int) -> String {
    "live latency reset reason=\(reason.rawValue) drift=\(driftMs)ms stalls=\(stalls)"
  }

  /// Whether a fresh crossing-detection edge fired: drift was below the warn
  /// threshold and this sample's is at or above it. The caller holds the
  /// "already logged this session" latch (cleared only by a reset) — this is
  /// only the pure edge test, pulled out so it's covered by `swift test`
  /// rather than living inline in `IptvsPlayerViewController`.
  public static func crossedWarnThreshold(previousDriftMs: Int64, currentDriftMs: Int64) -> Bool {
    previousDriftMs < kLiveDriftWarnMs && currentDriftMs >= kLiveDriftWarnMs
  }
}
