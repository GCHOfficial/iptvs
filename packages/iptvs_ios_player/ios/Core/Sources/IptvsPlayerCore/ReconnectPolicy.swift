import Foundation

/// Pure timing policy for the live auto-reconnect watchdog — iOS's copy of the
/// same policy Android's `HdrPlayerActivity` (Kotlin `ReconnectPolicy`) and
/// Windows/Linux (Dart `reconnectMinGapMs` in `lib/player/player_screen.dart`)
/// already run. All three must produce numerically identical results for the
/// same inputs so live playback backs off the same way regardless of engine.
/// Kept free of UIKit/AVFoundation imports so it's covered by plain `swift
/// test` rather than an on-device/simulator run. See docs/player.md "Live
/// auto-reconnect".
public enum ReconnectPolicy {
  /// Buffering/dropped this long before a non-forced reconnect fires.
  /// Mirrors Android's `ReconnectPolicy.STALL_RECONNECT_MS` and Dart's
  /// `kReconnectStallMs`.
  public static let stallReconnectMs: Int64 = 8_000

  /// A live drop (ended) is faster to retry than a stall. Mirrors Android's
  /// `ReconnectPolicy.ENDED_RECONNECT_MS`. Dart has no separate constant for
  /// this today — its embedded/Windows watchdog treats every live drop
  /// through the same stall-based `reconnectMinGapMs` path.
  public static let endedReconnectMs: Int64 = 2_000

  /// Cap on the attempt-scaled backoff between repeated reconnect attempts.
  /// Mirrors Android's `ReconnectPolicy.MAX_BACKOFF_MS` and Dart's
  /// `kReconnectMaxBackoffMs`.
  public static let maxBackoffMs: Int64 = 30_000

  /// Minimum gap (ms) required since the last reconnect attempt before the
  /// *next* one may fire. `priorAttempts` is the number of reconnect attempts
  /// already made (0 before the first). A forced reconnect (hard player
  /// error) always uses the base stall threshold instead of scaling with the
  /// attempt count. Mirrors Android's `ReconnectPolicy.minGapMs` and Dart's
  /// `reconnectMinGapMs` exactly — same clamp, same base unit.
  public static func minGapMs(priorAttempts: Int, force: Bool) -> Int64 {
    if force { return stallReconnectMs }
    let scaled = Int64(priorAttempts + 1) * stallReconnectMs
    return min(scaled, maxBackoffMs)
  }
}
