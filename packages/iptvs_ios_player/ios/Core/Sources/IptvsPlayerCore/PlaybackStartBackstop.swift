import Foundation

/// What the start backstop wants done once a load has failed to produce
/// playback within ``PlaybackStartBackstop/timeoutMs``.
public enum PlaybackStartAction: Equatable, Sendable {
  /// Still inside the window, already playing, or disarmed. Nothing to do.
  case wait

  /// **AVPlayer has never produced a frame for this content.** That is the
  /// fingerprint of a container AVFoundation accepted the URL for and then could
  /// not actually play, so the honest recovery is the cross-language handoff:
  /// emit `engineFailed` and let Dart reopen on the embedded libmpv surface
  /// (docs/ios.md "engineFailed is a cross-language handoff").
  case handOffEngine

  /// **A reload of a stream that demonstrably played never came back.** Switching
  /// engines would be the wrong answer here twice over: the container is proven
  /// playable, and `_handleIosEngineFailed` writes the content id into
  /// `IosEngineMemo`, so a handoff would permanently downgrade a working
  /// HDR channel to tone-mapped SDR for the rest of the session over what is
  /// really a network problem. Tell the viewer instead.
  case surfaceError
}

/// The third `engineFailed` detection shape docs/ios.md specifies —
/// **"never started within ~10s of open"** — plus the bound that stops a
/// *reload* of an already-proven stream from hanging silently.
///
/// The other two shapes are edge-triggered facts `AvPlayerEngine` already
/// reports (`AVPlayerItem.status == .failed`, and ready-but-no-video-track).
/// This one is the absence of a fact, so it needs a clock, and the clock is
/// polled from the same 500 ms ticker the live reconnect watchdog runs on
/// rather than from its own `Timer`: one ticker means the two decisions are
/// evaluated in a fixed order on the same instant instead of racing two
/// independent timers.
///
/// ## Why this and `LiveReconnectWatchdog` can never fight
///
/// A live stream that never starts looks exactly like a stalled one to
/// `LiveReconnectWatchdog`: `AVPlayerItem.isPlaybackBufferEmpty` is `true`
/// before anything has loaded, so the stall clock would start at open and
/// `ReconnectPolicy.stallReconnectMs` (8s) would fire a reload **before** this
/// backstop's 10s ever elapsed — retrying, forever, the one engine that has
/// already demonstrated it cannot play the container.
///
/// The fix is **not** to tune 8s against 10s. It is that the two watchdogs own
/// *disjoint* windows, separated by a single monotonic boolean:
///
/// - **Before AVPlayer has ever produced a frame** (`hasEverStarted == false`)
///   this backstop owns the window outright, and `LiveReconnectWatchdog.poll`
///   returns `.healthy` no matter how empty the buffer looks.
/// - **After the first frame** the backstop is disarmed for that load and the
///   reconnect watchdog owns everything, including reloads that never come
///   back — which is what keeps a genuine network drop on AVPlayer instead of
///   downgrading it to mpv.
///
/// So the numbers never compete: on any given tick at most one of the two can
/// return a non-`wait` action, and which one is decided by a fact, not by a
/// threshold comparison.
public struct PlaybackStartBackstop: Equatable, Sendable {
  /// How long a load may go without producing playback.
  ///
  /// 10s, deliberately the same figure as `LiveReconnectWatchdog.resolveTimeoutMs`
  /// and Dart's `kIosFallbackSurfaceAfter` — the codebase's existing unit for
  /// "a playback round trip that should have answered by now". It is well clear
  /// of `ReconnectPolicy.stallReconnectMs` (8s), but that margin is *not* what
  /// makes the ordering safe; see the type doc.
  public static let timeoutMs: Int64 = 10_000

  /// The `reason` shipped on the resulting `engineFailed` payload.
  ///
  /// A short machine code, never error text: `AVError`/`NSUnderlyingError`
  /// descriptions routinely interpolate the failing URL, and provider URLs carry
  /// credentials in the query string *and* the path segments (CLAUDE.md:
  /// "Secrets must never reach logs, on-screen errors, or exported
  /// diagnostics"). It is also distinguishable from the other two shapes'
  /// codes (`item-failed`, `failed-to-play-to-end`, `invalid-url`, and
  /// `domain:code`) in an exported diagnostics log, which is the only way a
  /// sideloaded device can report which detector fired.
  public static let engineFailedReason = "no-first-start"

  /// Provider-declared liveness, never inferred. Live reloads are the reconnect
  /// watchdog's business — it is already retrying them on the shared backoff
  /// schedule and showing "Reconnecting…", so a terminal error over the top of
  /// that would contradict it.
  public let isLive: Bool

  /// When the current load started, or `0` when disarmed. `0` is the "not
  /// armed" sentinel, so ``markLoaded(nowMs:)`` clamps to 1 — a caller with a
  /// zero clock would otherwise arm into a permanently disarmed state.
  public private(set) var armedAtMs: Int64 = 0

  public init(isLive: Bool) {
    self.isLive = isLive
  }

  public var isArmed: Bool { armedAtMs != 0 }

  /// Arms the clock. Called on **every** load — the initial open, a live
  /// reconnect reload, "Go to live", and a Retry from the error surface — so no
  /// load can hang unbounded, whichever of them started it.
  public mutating func markLoaded(nowMs: Int64) {
    armedAtMs = max(nowMs, 1)
  }

  /// First frame of the current load. Disarms until the next one.
  public mutating func markStarted() {
    armedAtMs = 0
  }

  /// The periodic tick.
  ///
  /// - Parameter hasEverStarted: whether AVPlayer has produced a frame at any
  ///   point in this controller's life — **not** whether the *current* item has.
  ///   That distinction is the whole discriminator: per-item state resets on
  ///   every reload, so keying on it would make every failed reconnect look like
  ///   an unplayable container and hand a working HDR channel to mpv.
  ///
  /// Fires at most once per load: the action disarms the clock, so a caller that
  /// cannot act immediately does not get a repeat on the next tick.
  public mutating func poll(hasEverStarted: Bool, nowMs: Int64) -> PlaybackStartAction {
    guard armedAtMs != 0, nowMs - armedAtMs >= PlaybackStartBackstop.timeoutMs else {
      return .wait
    }
    armedAtMs = 0
    guard hasEverStarted else { return .handOffEngine }
    return isLive ? .wait : .surfaceError
  }
}

/// What a hard player error means once playback has already started.
///
/// The companion of ``shouldReconnectOnCompleted(isLive:)``, and the same split
/// every platform encodes: **live reloads, VOD does not.** Stated as a function
/// rather than an inline `if` because the VOD half used to have no branch at all
/// — a mid-film `AVPlayerItem` failure left the controller with a stopped
/// picture, no watchdog (the reconnect one is inert for VOD by construction) and
/// no error surface, i.e. a dead end only backing out escaped.
public enum PlaybackDropOutcome: Equatable, Sendable {
  /// Reload the source through the live reconnect watchdog.
  case reconnect

  /// Nothing will retry this on its own — put the terminal error surface on
  /// screen so the viewer can retry or exit.
  case surfaceError
}

public func playbackDropOutcome(isLive: Bool) -> PlaybackDropOutcome {
  isLive ? .reconnect : .surfaceError
}
