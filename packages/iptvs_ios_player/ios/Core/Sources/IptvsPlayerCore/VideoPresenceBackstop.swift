import Foundation

/// What the item itself says about whether it *has* a video track at all.
///
/// Three-valued on purpose. The naive detector for docs/ios.md's second
/// `engineFailed` shape — "playing, but `presentationSize == .zero`" — is a
/// two-valued reading of a three-valued world, and that is exactly why it
/// misfires: it cannot tell "a video stream that is not rendering" from
/// "legitimately audio-only content", and `selectIosEngine` rule 3 routes
/// `m4a`/`mp3`/`aac` to AVPlayer *on purpose*. Firing there would bounce
/// perfectly good audio onto mpv and pin it in `IosEngineMemo` for the rest of
/// the session — losing AirPlay and lock-screen transport on precisely the
/// content whose only output is audio.
///
/// So the backstop below requires **positive evidence that video was
/// promised**, and ``unknown`` is an absence rather than a vote — the same rule
/// `decideIosFallbackAction` applies to its native opinions, and the same reason:
/// manufacturing a decision out of a fact nobody stated is how you get a
/// confident wrong answer.
public enum DeclaredVideoEvidence: Equatable, Sendable {
  /// Nothing readable yet, or nothing this platform can read for this container
  /// (an HLS *media* playlist exposes neither `AVPlayerItemTrack.assetTrack` nor
  /// `AVURLAsset.variants`). Never fires — a missed detection is a black screen
  /// with audio, a false one is a working stream permanently downgraded.
  case unknown

  /// The item declares a video track (a progressive asset track whose format
  /// description is `kCMMediaType_Video`) or the HLS ladder declares video
  /// attributes on at least one variant.
  case present

  /// The item declares tracks, and none of them is video — genuinely audio-only
  /// content. Structurally excluded from firing.
  case absent
}

/// What the video-presence backstop wants done on this tick.
public enum VideoPresenceAction: Equatable, Sendable {
  /// Inside the grace window, settled, suppressed, or presenting a picture.
  case wait

  /// **The stream promised video and AVPlayer never put a picture on screen.**
  /// The `engineFailed` cross-language handoff: Dart marks the content mpv-only
  /// and reopens it on the embedded libmpv surface, which decodes containers and
  /// codecs AVFoundation refuses (docs/ios.md "engineFailed is a cross-language
  /// handoff").
  case handOffEngine
}

/// docs/ios.md's **second** `engineFailed` detection shape: an item that reaches
/// `.readyToPlay`, starts producing playback, and then renders **no picture at
/// all** — the black-screen-with-audio failure.
///
/// The realistic trigger on this app's providers is a container AVFoundation
/// parses and partly decodes: an HLS ladder whose video codec AVPlayer cannot
/// handle (MPEG-2 video in TS-in-HLS is the classic IPTV case) but whose audio
/// it can. AVPlayer plays the audio, `timeControlStatus` reaches `.playing`, and
/// nothing anywhere in the plugin ever notices — which is why this type exists.
///
/// ## Why this is a third window, not an extension of either watchdog
///
/// `PlaybackStartBackstop` cannot cover it: an audio-only-rendering item **does**
/// reach `.playing`, so `hasEverStarted` latches, the backstop disarms, and its
/// whole window is over. `LiveReconnectWatchdog` cannot cover it either: it acts
/// only on `isBuffering || ended`, and this failure is *healthy* playback — full
/// buffer, moving timebase, no error. The three windows are disjoint by
/// construction, each keyed on a fact rather than on a threshold comparison:
///
/// | Window | Condition | Owner |
/// |---|---|---|
/// | Before the current load produces playback | `hasStarted == false` | ``PlaybackStartBackstop`` |
/// | Playing, but stalled or ended | `hasStarted && (isBuffering \|\| ended)` | ``LiveReconnectWatchdog`` |
/// | Playing and healthy, with no picture | `hasStarted && !isBuffering && !ended` | this type |
///
/// The middle and bottom rows are complementary on one boolean, so at most one
/// can act on any tick — the same shape as the existing start-backstop/reconnect
/// exclusion, extended by one axis rather than layered on top of it. The top row
/// is excluded because this backstop is only *armed* at the current load's first
/// frame, which is the same instant `PlaybackStartBackstop.markStarted()` disarms
/// it.
///
/// ## Why the arming is per-load and per-item, not engine-lifetime
///
/// The opposite of ``PlaybackStartBackstop``, deliberately. There, keying on the
/// engine-lifetime `hasEverStarted` is what stops a failed live *reconnect* from
/// being misread as an unplayable container. Here the question is about the item
/// currently on screen — "is this load showing a picture" — so a reload gets a
/// fresh window, and a load that once showed a picture is settled for good
/// (``markPicture`` semantics, applied inside ``poll``): losing video mid-stream
/// is a drop, which is the reconnect watchdog's business, not an engine handoff.
public struct VideoPresenceBackstop: Equatable, Sendable {
  /// How long a playing item may render nothing before the handoff fires,
  /// measured from **the current load's first frame** (not from the load).
  ///
  /// 10s, the codebase's existing "a playback round trip that should have
  /// answered by now" unit — the same figure as ``PlaybackStartBackstop/timeoutMs``,
  /// `LiveReconnectWatchdog.resolveTimeoutMs` and Dart's `kIosFallbackSurfaceAfter`.
  /// Reusing it is not laziness: together with the start backstop it makes one
  /// statement — *within ~10s of playback beginning, or of the load if it never
  /// begins, a stream that cannot put a picture on screen has handed off.*
  ///
  /// It is deliberately long for what it measures. Video and audio start
  /// together on any healthy item, so a picture that is going to appear has
  /// appeared within a second or two; the remaining margin buys tolerance for a
  /// stream that opens on an audio-only segment (an ad pod, a discontinuity)
  /// before its video resumes. The asymmetry is the usual one for this platform:
  /// waiting too long costs black seconds on a stream that was going to be handed
  /// off anyway, firing too early costs a working stream its engine for the
  /// session.
  public static let timeoutMs: Int64 = 10_000

  /// When evaluation stops for the current load, measured from the same anchor.
  ///
  /// Two jobs. It bounds the 2 Hz ticker — VOD stops its ticker once nothing on
  /// it can still act, and without a give-up an item whose evidence never
  /// resolves to ``DeclaredVideoEvidence/present`` would keep the timer (and its
  /// AVFoundation reads) alive for the length of a film. And it keeps the
  /// semantics honest: this shape is "the load never had a picture", so a stream
  /// that has been playing for half a minute is out of scope no matter what it
  /// renders afterwards.
  public static let giveUpMs: Int64 = 30_000

  /// The `reason` shipped on the resulting `engineFailed` payload.
  ///
  /// A coarse machine code, never error text — `AVError` descriptions interpolate
  /// the failing URL and provider URLs carry credentials in the query string
  /// *and* the path segments (CLAUDE.md: "Secrets must never reach logs,
  /// on-screen errors, or exported diagnostics"). Distinct from every other
  /// shape's code (`no-first-start`, `item-failed`, `failed-to-play-to-end`,
  /// `invalid-url`, `domain:code`), because an exported diagnostics log is the
  /// only way a sideloaded device can report *which* detector fired.
  ///
  /// Spelled "picture", not "track": the detector's evidence is that a *declared*
  /// video track produced no rendered frame, which is a strictly narrower — and
  /// more accurate — claim than "there is no video track".
  public static let engineFailedReason = "no-video-picture"

  /// When the current load produced its first frame, or `0` when this backstop is
  /// not evaluating (before the first frame, after a picture appeared, after it
  /// fired, or past ``giveUpMs``).
  ///
  /// `0` is the "not armed" sentinel, so ``markStarted(nowMs:)`` clamps to 1 —
  /// the same clamp, for the same reason, as `PlaybackStartBackstop.markLoaded`.
  public private(set) var armedAtMs: Int64 = 0

  public init() {}

  public var isArmed: Bool { armedAtMs != 0 }

  /// A new item is being loaded: stop evaluating until it produces a frame.
  ///
  /// Called from the same `startPlayback` prologue that arms
  /// ``PlaybackStartBackstop``, so the two are always in opposite states.
  public mutating func markLoaded() {
    armedAtMs = 0
  }

  /// The current load produced its first frame — the moment this backstop's
  /// window opens and ``PlaybackStartBackstop``'s closes.
  public mutating func markStarted(nowMs: Int64) {
    armedAtMs = max(nowMs, 1)
  }

  /// The periodic tick, evaluated on the same 500 ms ticker as the other two
  /// watchdogs so all three decisions are taken in a fixed order on one instant.
  ///
  /// - Parameters:
  ///   - isPlaying: whether the **current item** has produced playback
  ///     (`AvPlayerEngine.hasStarted`, per-item — *not* `hasEverStarted`).
  ///   - isBuffering: the engine's buffer-empty state. A stall belongs to
  ///     `LiveReconnectWatchdog`; a picture that hasn't arrived because nothing
  ///     has arrived is not this shape.
  ///   - ended: a clean EOF belongs to the reconnect watchdog (live) or is a
  ///     legitimate end (VOD).
  ///   - evidence: whether the item declares a video track at all. Only
  ///     ``DeclaredVideoEvidence/present`` can fire.
  ///   - isPresentingVideo: any sign of a real picture — a non-zero
  ///     `AVPlayerItem.presentationSize` *or* `AVPlayerLayer.isReadyForDisplay`.
  ///     Either one settles this load permanently, because the failure being
  ///     detected is "never rendered", not "stopped rendering".
  ///   - isSuppressed: the picture is legitimately not on this layer — PiP,
  ///     external playback (AirPlay), or a backgrounded app. Suppression only
  ///     blocks firing; it does not extend the window, so a stream that spends
  ///     its whole evaluation window suppressed simply gives up unjudged.
  ///
  /// Fires at most once per load: firing disarms, so a caller that cannot act
  /// immediately does not get the decision repeated on the next tick.
  public mutating func poll(
    isPlaying: Bool,
    isBuffering: Bool,
    ended: Bool,
    evidence: DeclaredVideoEvidence,
    isPresentingVideo: Bool,
    isSuppressed: Bool,
    nowMs: Int64
  ) -> VideoPresenceAction {
    guard armedAtMs != 0 else { return .wait }

    // A picture, at any point in the window, settles this load for good.
    if isPresentingVideo {
      armedAtMs = 0
      return .wait
    }

    // Out of scope: this shape is about a load that never had a picture.
    if nowMs - armedAtMs >= VideoPresenceBackstop.giveUpMs {
      armedAtMs = 0
      return .wait
    }

    guard nowMs - armedAtMs >= VideoPresenceBackstop.timeoutMs else { return .wait }
    guard evidence == .present else { return .wait }
    guard isPlaying, !isBuffering, !ended, !isSuppressed else { return .wait }

    armedAtMs = 0
    return .handOffEngine
  }
}
