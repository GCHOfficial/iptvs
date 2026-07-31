import Foundation

/// What the live watchdog wants done on this tick.
public enum LiveReconnectAction: Equatable, Sendable {
  /// Playback is fine (or this isn't live): clear the stall clock, the attempt
  /// counter and the "Reconnecting…" chip.
  case healthy

  /// Stalled/dropped, but either the stall threshold or the attempt-scaled
  /// backoff has not elapsed yet. Nothing to do but keep the chip as it is.
  case wait

  /// Reload the source now.
  case reconnect
}

/// The live auto-reconnect watchdog's whole decision, as a pure value.
///
/// **iOS is Kotlin-shaped here, not Dart-shaped.** `IptvsPlayerViewController`
/// owns playback out of process with no live channel back to Dart for playback
/// state — exactly like `HdrPlayerActivity` — so the watchdog lives in Swift and
/// this is the direct port of `HdrPlayerActivity.pollLiveReconnect` /
/// `reconnectLive(force:)` (`android/app/src/main/kotlin/.../HdrPlayerActivity.kt`),
/// down to which field is reset where. The *timing* comes from
/// ``ReconnectPolicy``, which all four platforms share; this type only owns the
/// bookkeeping around it.
///
/// Everything that makes the watchdog testable is here rather than in the view
/// controller: `swift test` can drive a whole drop → backoff → recovery sequence
/// with a synthetic clock, where the UIKit half can only be read.
///
/// One deliberate divergence from Kotlin, recorded because it looks like an
/// omission: the healthy branch resets ``attempts`` but **not**
/// ``lastReconnectMs``. That is Android's behaviour too, and it is what stops a
/// stream that recovers for two seconds and drops again from reconnecting with
/// no gap at all.
public struct LiveReconnectWatchdog: Equatable, Sendable {
  /// How long Swift waits for Dart's `resolveAgain` reply before falling back to
  /// the locator it already holds.
  ///
  /// The reply is a method-channel round trip into a Dart route that may have
  /// popped, or into a `resolveAgain` callback that never completes — and a
  /// completion that never fires would stall the reconnect **forever**, which is
  /// the one failure mode this whole path exists to rule out. So the timeout is
  /// a liveness backstop, not a latency budget: it is deliberately longer than a
  /// healthy provider resolve (`kHttpReadTimeout` is 20s, but a live re-resolve
  /// that takes anywhere near that has already lost the race with the next
  /// attempt) and matches the 10s the codebase already uses for "a channel round
  /// trip that should have answered by now" (`_tryOpenNativeHdrPlayer`'s open
  /// timeout, `kIosFallbackSurfaceAfter`).
  ///
  /// On expiry the reload proceeds with the *original* locator, mirroring Dart's
  /// `_freshLiveStream` falling back to `widget.stream` when `resolveAgain` is
  /// unwired or throws. A late reply is discarded, not applied to a reload that
  /// has already happened.
  public static let resolveTimeoutMs: Int64 = 10_000

  /// Provider-declared liveness, never inferred (CLAUDE.md: "Liveness is
  /// provider metadata"). A VOD watchdog is inert: every entry point short-
  /// circuits to ``LiveReconnectAction/healthy``.
  public let isLive: Bool

  /// Reconnect attempts made so far. Feeds `ReconnectPolicy.minGapMs`, and is
  /// reset by a healthy poll.
  public private(set) var attempts: Int = 0

  /// When the current stall started, or `0` when not stalled.
  public private(set) var stalledSinceMs: Int64 = 0

  /// When the last reconnect was issued, or `0` when none has been.
  public private(set) var lastReconnectMs: Int64 = 0

  public init(isLive: Bool) {
    self.isLive = isLive
  }

  /// The periodic tick (500 ms, matching Android's progress ticker).
  ///
  /// `ended` picks the faster `ReconnectPolicy.endedReconnectMs` threshold: a
  /// clean end-of-stream on live is a **drop**, not an end
  /// (``shouldReconnectOnCompleted(isLive:)``), and there is nothing to wait for
  /// the way there is with a buffer that might refill.
  ///
  /// `nowMs` must be a positive wall-clock instant. `0` is the "not stalled"
  /// sentinel for ``stalledSinceMs``, exactly as it is for Kotlin's
  /// `stalledSinceMs`, so a caller passing a zero clock would re-prime the stall
  /// on every tick. Every real caller uses epoch milliseconds.
  public mutating func poll(
    isBuffering: Bool,
    ended: Bool,
    nowMs: Int64
  ) -> LiveReconnectAction {
    guard isLive else { return .healthy }
    guard isBuffering || ended else {
      stalledSinceMs = 0
      attempts = 0
      return .healthy
    }
    if stalledSinceMs == 0 { stalledSinceMs = nowMs }
    let threshold = ended ? ReconnectPolicy.endedReconnectMs : ReconnectPolicy.stallReconnectMs
    guard nowMs - stalledSinceMs >= threshold else { return .wait }
    return attempt(force: false, nowMs: nowMs)
  }

  /// A hard player error while playing — the direct port of Android wiring
  /// `onRecoverableError` to `reconnectLive(force = true)`. Skips the stall
  /// threshold, but is still rate-limited by `ReconnectPolicy.minGapMs`, so a
  /// stream erroring in a tight loop can't become a `create_link` storm.
  public mutating func forceReconnect(nowMs: Int64) -> LiveReconnectAction {
    guard isLive else { return .healthy }
    return attempt(force: true, nowMs: nowMs)
  }

  private mutating func attempt(force: Bool, nowMs: Int64) -> LiveReconnectAction {
    let minGap = ReconnectPolicy.minGapMs(priorAttempts: attempts, force: force)
    if lastReconnectMs != 0, nowMs - lastReconnectMs < minGap { return .wait }
    attempts += 1
    lastReconnectMs = nowMs
    // Restart the stall clock from the attempt, so the *next* threshold is
    // measured from the reload rather than from the original drop.
    stalledSinceMs = nowMs
    return .reconnect
  }
}

/// Whether a clean end-of-stream should be treated as a drop worth reconnecting.
///
/// The same split every other platform encodes — Dart's
/// `shouldReconnectOnCompleted` (`lib/player/player_screen.dart`, pinned by
/// `test/reconnect_policy_test.dart`), Android's `uiState.ended` branch inside
/// `pollLiveReconnect`, Linux's `end-file` reason mapping: **live treats a clean
/// EOF as a drop; VOD completing is a legitimate end of playback.** A live IPTV
/// stream does not end — a server that closes the connection has dropped it.
public func shouldReconnectOnCompleted(isLive: Bool) -> Bool { isLive }

/// A re-resolved live locator, parsed from Dart's `resolveAgain` reply.
///
/// The Dart half is the `resolveAgain` branch of `_handleNativeHdrMethodCall`
/// (`lib/player/player_screen.dart`), which answers
/// `{'url': …, 'headers': …}` from `_freshLiveStream()`. **Why the round trip
/// exists at all:** Stalker `create_link` URLs carry single-use `play_token`s,
/// so after a portal-side kill the URL this controller is holding is permanently
/// dead and reloading it can never succeed (docs/player.md "Live reloads
/// re-resolve"). Android's native watchdog has no equivalent step and reloads
/// the URL ExoPlayer just failed on.
///
/// Parsed here rather than at the call site so the failure shapes are pinned by
/// `swift test`: **every** unusable reply — a `FlutterError`, the
/// `FlutterMethodNotImplemented` sentinel, `nil` from a Dart route that has
/// already unmounted, a map with a blank `url` — must come back as `nil` so the
/// caller falls back to the locator it already holds rather than loading an
/// empty string.
public struct FreshLocator: Equatable, Sendable {
  public let url: String
  public let headers: [String: String]

  public init(url: String, headers: [String: String] = [:]) {
    self.url = url
    self.headers = headers
  }

  public init?(reply: Any?) {
    guard let map = reply as? [AnyHashable: Any] else { return nil }
    guard let url = PlayerOpenRequest.nonBlankString(map["url"]) else { return nil }
    self.url = url
    // Same header hygiene as `open`: blank keys/values dropped, non-strings
    // stringified. A reload that silently lost the MAG `User-Agent` would 403 on
    // every Stalker portal.
    headers = PlayerOpenRequest.parseHeaders(map["headers"])
  }
}
