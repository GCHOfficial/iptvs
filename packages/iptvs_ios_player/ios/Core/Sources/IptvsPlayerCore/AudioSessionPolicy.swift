import Foundation

/// Well-known audio-session client identifiers.
///
/// **Why identifiers at all, rather than a bare activate/deactivate pair.**
/// `AVAudioSession` is process-wide, and after the `iosManageAudioSession: false`
/// pin (docs/ios.md Constraint 1) *nothing else in the process activates it* —
/// mpv's `ao_audiounit` is explicitly told to keep its hands off, so Swift is now
/// the only owner. That makes several unrelated things depend on one shared
/// boolean: the presented AVPlayer controller, the embedded media_kit/mpv
/// fullscreen surface, and the muted live preview. They start and stop in any
/// order and can overlap (an `engineFailed` handoff literally has the AVPlayer
/// path tearing down while the mpv path spins up), so a naive
/// "activate on start / deactivate on stop" deactivates the session out from
/// under whoever is still playing.
///
/// A reference *set* keyed by client id makes acquire/release idempotent and
/// order-independent, which is the only shape that survives that overlap.
///
/// The `fullscreenPlayer` prefix is exactly that — a prefix. Each
/// `IptvsPlayerViewController` appends a unique suffix, because two controllers
/// briefly coexist when one `open` replaces another, and a shared id would let
/// the outgoing controller's teardown remove the incoming one's claim.
public enum AudioSessionClientId {
  /// The presented native AVPlayer surface (`IptvsPlayerViewController`).
  /// Used as a **prefix**; see the type doc.
  public static let fullscreenPlayer = "fullscreenPlayer"

  /// The embedded media_kit/libmpv fullscreen surface — the AVPlayer fallback
  /// engine, and the only engine for containers AVPlayer can't take. Claimed
  /// from Dart over the plugin's `acquireAudioSession` method.
  public static let embeddedPlayer = "embeddedPlayer"

  /// The live preview engine (`LivePreviewController`). Muted by default, but it
  /// still decodes and still holds a provider connection, and it must
  /// **release** on app pause while the fullscreen player keeps its claim — that
  /// asymmetry is what `UIBackgroundModes = [audio]` makes load-bearing
  /// (docs/ios.md "Other work required").
  public static let livePreview = "livePreview"
}

/// Reference-counted-by-identity set of audio-session claimants.
///
/// The two mutating operations return **whether the caller must act on the real
/// `AVAudioSession`**, so the UIKit layer never has to reason about ordering:
/// only an empty→non-empty transition activates, and only a non-empty→empty
/// transition deactivates. Everything in between is a no-op the caller can
/// ignore.
///
/// Pure and in `Core` on purpose: this arithmetic is the whole correctness
/// argument for "the mpv fallback engine does not silence the AVPlayer engine",
/// and it is testable in milliseconds with no device.
public struct AudioSessionClients: Equatable, Sendable {
  private var ids: Set<String> = []

  public init() {}

  public var count: Int { ids.count }
  public var isEmpty: Bool { ids.isEmpty }

  public func contains(_ id: String) -> Bool { ids.contains(id) }

  /// Registers `id` as needing the audio session.
  ///
  /// - Returns: `true` only when this is the *first* live claim, i.e. when the
  ///   caller must actually activate `AVAudioSession`. Re-acquiring an id
  ///   already held returns `false` — acquire is idempotent by design, because
  ///   `viewDidAppear` runs again after a Picture-in-Picture restore re-presents
  ///   the controller.
  @discardableResult
  public mutating func acquire(_ id: String) -> Bool {
    let wasEmpty = ids.isEmpty
    let inserted = ids.insert(id).inserted
    return wasEmpty && inserted
  }

  /// Drops `id`'s claim.
  ///
  /// - Returns: `true` only when the *last* claim went away, i.e. when the
  ///   caller must deactivate `AVAudioSession`. Releasing an id that was never
  ///   held returns `false`, so a double teardown (a controller's `finish`
  ///   followed by its `deinit`) can never deactivate a session another client
  ///   is still using.
  @discardableResult
  public mutating func release(_ id: String) -> Bool {
    guard ids.remove(id) != nil else { return false }
    return ids.isEmpty
  }

  /// Drops every claim — the process is tearing down, or a hard reset is
  /// wanted. Returns `true` when that actually left the session unclaimed.
  @discardableResult
  public mutating func releaseAll() -> Bool {
    guard !ids.isEmpty else { return false }
    ids.removeAll()
    return true
  }
}

/// An `AVAudioSession` event, reduced to the three shapes that need a decision.
///
/// Foundation-only spelling of `AVAudioSession.InterruptionType` plus the one
/// route change that matters, so the policy below is testable without AVFoundation.
public enum AudioInterruption: Equatable, Sendable {
  /// `AVAudioSession.InterruptionType.began` — a call, Siri, another app.
  case began

  /// `.ended`. `shouldResume` is `AVAudioSession.InterruptionOptions.shouldResume`
  /// — the system's opinion on whether resuming is welcome. It is **not**
  /// advisory: resuming when it is absent is how an app starts talking over a
  /// phone call.
  case ended(shouldResume: Bool)

  /// `AVAudioSession.routeChangeNotification` with reason
  /// `.oldDeviceUnavailable` — headphones unplugged, Bluetooth walked away.
  case outputDeviceLost
}

/// What the player should do about an ``AudioInterruption``.
public enum AudioInterruptionReaction: Equatable, Sendable {
  case pause
  case resume
  case ignore
}

/// The interruption policy.
///
/// - Parameter wasPlaying: whether *this* player was playing when the
///   interruption began. It gates `resume` because the app must only restore
///   what the interruption took away: resuming a player the user had
///   deliberately paused would make an incoming call double as a play button.
///
/// `outputDeviceLost` pauses unconditionally, and deliberately does not consult
/// `wasPlaying`: pausing an already-paused player is free, and the failure this
/// prevents — a stream continuing out of the phone's speaker on a bus after the
/// headphones were unplugged — is not.
public func audioInterruptionReaction(
  _ event: AudioInterruption,
  wasPlaying: Bool
) -> AudioInterruptionReaction {
  switch event {
  case .began:
    return wasPlaying ? .pause : .ignore
  case .ended(let shouldResume):
    guard shouldResume, wasPlaying else { return .ignore }
    return .resume
  case .outputDeviceLost:
    return .pause
  }
}
