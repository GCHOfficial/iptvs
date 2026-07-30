import Foundation

/// Debug-only lifecycle counters for the native iOS player — the Swift
/// counterpart of Dart's `ResourceCounters`, Kotlin's `DebugCounters` and the
/// C++ `windowsSurfaces`/`windowsOverlays` ints (docs/player.md "Debug resource
/// counters + lifecycle soak").
///
/// **The invariant is the whole point: every counter must be back to zero once
/// an open/close cycle has settled.** `integration_test/player_soak_test.dart`
/// asserts exactly that over 100 cycles on real hardware, merging this map into
/// `ResourceCounters.snapshot()` through the `debugCounters` method on
/// `iptvs/native_hdr_player`.
///
/// `iosTimeObservers` earns a counter of its own rather than folding into
/// `iosAvPlayers`, and the reason is specific to AVFoundation: a periodic time
/// observer added with `AVPlayer.addPeriodicTimeObserver` **retains the
/// `AVPlayer` for the observer's lifetime**. Forget the matching
/// `removeTimeObserver` and the player never deallocates — the classic leak on
/// this platform, and one that otherwise shows up only as "memory grows",
/// never as an obviously-linked counter mismatch.
///
/// Release builds compile to nothing: every entry point is `#if DEBUG`, and
/// `snapshot()` returns an empty map, matching the Android/Windows contract that
/// a release native side simply omits its keys.
enum IosDebugCounter: String, CaseIterable {
  /// `AVPlayer` instances (`AvPlayerEngine` init ↔ its idempotent `release()`).
  case avPlayers = "iosAvPlayers"

  /// Presented `IptvsPlayerViewController`s (init ↔ deinit). Stays at 1 for the
  /// whole of a Picture-in-Picture session, which is correct — the plugin holds
  /// a deliberate strong reference so the layer can keep feeding the PiP window.
  case playerControllers = "iosPlayerControllers"

  /// `AVPictureInPictureController`s (`IosPipController` init ↔ deinit).
  case pipControllers = "iosPipControllers"

  /// Live periodic time observers. See the type doc.
  case timeObservers = "iosTimeObservers"

  /// Live `AVAudioSession` claimants — mirrors `AudioSessionClients.count`
  /// rather than being incremented per call, so a set that never empties is
  /// visible as a nonzero settled count instead of as silence.
  case audioClients = "iosAudioClients"
}

enum IosDebugCounters {
  #if DEBUG
    /// A plain lock rather than main-thread confinement (the C++ counters'
    /// approach): `AvPlayerEngine.deinit` and `IosPipController.deinit` are not
    /// guaranteed to run on the main queue, and a torn count would be worse than
    /// useless — it would make the soak assert fail intermittently on a
    /// perfectly balanced build.
    private static let lock = NSLock()
    private static var counts: [IosDebugCounter: Int] = [:]
  #endif

  static func increment(_ counter: IosDebugCounter) {
    #if DEBUG
      lock.lock()
      counts[counter, default: 0] += 1
      lock.unlock()
    #endif
  }

  static func decrement(_ counter: IosDebugCounter) {
    #if DEBUG
      lock.lock()
      counts[counter, default: 0] -= 1
      lock.unlock()
    #endif
  }

  /// Sets an absolute count. Used for ``IosDebugCounter/audioClients``, which is
  /// a *set size* rather than a create/destroy pair — deriving it from the set
  /// keeps the counter honest even if an acquire/release pair is ever missed.
  static func set(_ counter: IosDebugCounter, _ value: Int) {
    #if DEBUG
      lock.lock()
      counts[counter] = value
      lock.unlock()
    #endif
  }

  /// The `debugCounters` reply. Every key is present (even at zero) in debug so
  /// the soak reports a missing counter as `0` rather than as an absent key it
  /// would silently skip; empty in release.
  static func snapshot() -> [String: Int] {
    #if DEBUG
      lock.lock()
      defer { lock.unlock() }
      var result: [String: Int] = [:]
      for counter in IosDebugCounter.allCases {
        result[counter.rawValue] = counts[counter] ?? 0
      }
      return result
    #else
      return [:]
    #endif
  }
}
