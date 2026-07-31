import Foundation

/// The lock-screen / Control Centre "now playing" description, in
/// Foundation-only terms.
///
/// The `MPNowPlayingInfoCenter` dictionary itself is built in
/// `Classes/IosAudioSession.swift`, from this. The split exists because the
/// *rules* — what a live stream reports, when a duration is meaningful, what
/// the rate is while paused — are the part that can be wrong, and they are the
/// part `swift test` can reach. The MediaPlayer key names are the part that
/// cannot be tested off-device anyway.
///
/// iOS has no counterpart on the other platforms: Android's native player has
/// no `MediaSession` (it is a fullscreen Activity, not a background service),
/// and Windows/Linux have no lock screen. This is genuinely new surface, which
/// is another reason its rules are pinned rather than inlined.
public struct NowPlayingSnapshot: Equatable, Sendable {
  /// What the lock screen shows on the first line. Never empty when anything is
  /// known — see ``nowPlayingSnapshot(title:sourceName:isLive:positionMs:durationMs:isPlaying:speed:)``.
  public let title: String

  /// Second line. Nil when there is nothing to say that the title doesn't
  /// already say.
  public let artist: String?

  public let isLive: Bool

  /// Nil for live and for a not-yet-known duration. A live HLS item's duration
  /// is `CMTime.indefinite`, which `AvPlayerEngine` normalises to `0`.
  public let durationSeconds: Double?

  /// Nil for live: with `MPNowPlayingInfoPropertyIsLiveStream` set, the system
  /// hides the scrubber, and feeding it a position it will not draw only
  /// invites it to draw one.
  public let elapsedSeconds: Double?

  /// `0` while paused, otherwise the playback speed. The system extrapolates
  /// the elapsed time from this between updates, which is why a paused player
  /// must report exactly `0` rather than its last speed.
  public let playbackRate: Double

  public init(
    title: String,
    artist: String?,
    isLive: Bool,
    durationSeconds: Double?,
    elapsedSeconds: Double?,
    playbackRate: Double
  ) {
    self.title = title
    self.artist = artist
    self.isLive = isLive
    self.durationSeconds = durationSeconds
    self.elapsedSeconds = elapsedSeconds
    self.playbackRate = playbackRate
  }
}

/// Builds the ``NowPlayingSnapshot`` for the current playback state.
///
/// Rules worth stating, each of which is a test:
///
/// - **A blank title falls back to the source name**, so a channel whose EPG
///   title never arrived still shows *something* on the lock screen rather than
///   an empty row with a stray subtitle underneath it.
/// - **The artist line is dropped when it would duplicate the title**, which is
///   exactly what the fallback above produces.
/// - **Live reports neither duration nor elapsed**, and is flagged as a live
///   stream. This is the same "liveness is provider metadata, not inferred"
///   rule the rest of the app follows (CLAUDE.md) — keyed on `isLive`, never on
///   whether a duration happened to be readable.
/// - **A non-positive duration is "unknown", not zero.** `AvPlayerEngine`
///   collapses every non-numeric `CMTime` to `0`, so `0` here means "no useful
///   duration" and must not become a zero-length progress bar.
public func nowPlayingSnapshot(
  title: String,
  sourceName: String?,
  isLive: Bool,
  positionMs: Int64,
  durationMs: Int64,
  isPlaying: Bool,
  speed: Double
) -> NowPlayingSnapshot {
  let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
  let trimmedSource = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
  let source = (trimmedSource?.isEmpty ?? true) ? nil : trimmedSource

  let displayTitle = trimmedTitle.isEmpty ? (source ?? "") : trimmedTitle
  let artist = (source == displayTitle) ? nil : source

  let duration: Double? = (isLive || durationMs <= 0) ? nil : Double(durationMs) / 1000
  let elapsed: Double? = isLive ? nil : Double(max(0, positionMs)) / 1000

  return NowPlayingSnapshot(
    title: displayTitle,
    artist: artist,
    isLive: isLive,
    durationSeconds: duration,
    elapsedSeconds: elapsed,
    playbackRate: isPlaying ? speed : 0
  )
}

/// Which `MPRemoteCommandCenter` commands are enabled.
///
/// Enabling a command the player cannot honour is not cosmetic on iOS: the
/// system draws the lock-screen and Control-Centre transport from this, and a
/// live channel offering a scrub bar or a ±10s pair would be offering seeks
/// that silently do nothing (the controller refuses them — `seekBy`/
/// `seekToFraction` both `guard !request.isLive`).
public struct RemoteCommandPolicy: Equatable, Sendable {
  public let play: Bool
  public let pause: Bool
  public let togglePlayPause: Bool
  public let skipForward: Bool
  public let skipBackward: Bool
  public let changePlaybackPosition: Bool

  /// Skip interval offered to the system, in seconds. Matches the overlay's own
  /// ±10s buttons (`PlayerControlsView`'s `gobackward.10`/`goforward.10`), so
  /// the two transports agree.
  public let skipIntervalSeconds: Double

  public init(
    play: Bool,
    pause: Bool,
    togglePlayPause: Bool,
    skipForward: Bool,
    skipBackward: Bool,
    changePlaybackPosition: Bool,
    skipIntervalSeconds: Double
  ) {
    self.play = play
    self.pause = pause
    self.togglePlayPause = togglePlayPause
    self.skipForward = skipForward
    self.skipBackward = skipBackward
    self.changePlaybackPosition = changePlaybackPosition
    self.skipIntervalSeconds = skipIntervalSeconds
  }
}

/// The command set for a stream.
///
/// Deliberately the same `!isLive` predicate `PlayerChromeState.showSkipButtons`
/// and `.showScrubber` use, so the remote transport and the on-screen transport
/// can never disagree about what this stream supports. `PlayerChromeStateTests`
/// and `NowPlayingPolicyTests` both assert that pairing.
public func remoteCommandPolicy(isLive: Bool) -> RemoteCommandPolicy {
  RemoteCommandPolicy(
    play: true,
    pause: true,
    togglePlayPause: true,
    skipForward: !isLive,
    skipBackward: !isLive,
    changePlaybackPosition: !isLive,
    skipIntervalSeconds: 10
  )
}
