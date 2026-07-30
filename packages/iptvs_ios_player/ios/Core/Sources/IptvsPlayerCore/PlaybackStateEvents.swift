import Foundation

/// The playback-state transitions the native iOS player reports to Dart on the
/// shared `nativePlayback` method.
///
/// These are the same five facts every other platform's watchdog consumes, under
/// the same names: Android reads them off `PlayerUiState.isBuffering`/`ended`
/// inside `HdrPlayerActivity.pollLiveReconnect`, the Linux native session
/// surfaces them as `LinuxNativePlaybackSignal.dropped`/`stalled`/`resumed`, and
/// the Windows/embedded path derives them from media_kit's
/// `buffering`/`completed`/`error` streams. Naming them identically here keeps a
/// reader moving between the four implementations from having to re-learn a
/// vocabulary.
///
/// **Who acts on them is a per-platform decision, and iOS follows Kotlin, not
/// Dart.** Because `IptvsPlayerViewController` owns playback out of process (no
/// live channel back to Dart for playback state, exactly like
/// `HdrPlayerActivity`), the live auto-reconnect watchdog lives in Swift and
/// consumes these events *internally*. Emitting them to Dart as well is
/// deliberate but secondary: it puts native playback state into the same
/// user-exportable diagnostics log as every other platform's, which is the only
/// way a bug report from a sideloaded device can say what the player was doing.
/// Dart's `nativePlayback` switch handles the events it needs
/// (`engineFailed`, `hostVisibility`) and ignores the rest, so adding them is
/// forward-compatible in both directions.
public enum PlaybackStateEvent: String, Equatable, CaseIterable, Sendable {
  /// First frame is up — `AVPlayer.timeControlStatus` reached `.playing`.
  /// Also the gate that keeps *initial* buffering out of the stall watchdog,
  /// the same role `_markLinuxNativeStarted` plays on Linux: an item is
  /// `isPlaybackBufferEmpty == true` before it has loaded anything, and
  /// reporting that as a stall would start the reconnect clock on every open.
  case started

  /// Buffer ran dry after playback had started.
  case stalled

  /// Buffer recovered (`isPlaybackLikelyToKeepUp`).
  case resumed

  /// Clean end of stream. Live treats this as a drop; VOD completing is a
  /// legitimate end (`shouldReconnectOnCompleted` in
  /// `lib/player/player_screen.dart` pins that split for the Dart paths).
  case ended

  /// Hard failure while playing — a network drop, not a container problem.
  case dropped
}

extension PlaybackEventPayload {
  /// Periodic position/duration tick. Not a state *transition*, so it is kept
  /// off `PlaybackStateEvent`.
  public static let progressEvent = "progress"

  public static let positionKey = "positionMs"
  public static let durationKey = "durationMs"
  public static let messageKey = "message"

  /// A playback-state transition.
  ///
  /// `message` is optional and, when present, must be a **short machine code**
  /// — never an `Error`'s `localizedDescription`. `AVError` and its
  /// `NSUnderlyingError` routinely interpolate the failing URL, and provider
  /// URLs carry credentials in the query string *and* the path segments
  /// (CLAUDE.md: "Secrets must never reach logs, on-screen errors, or exported
  /// diagnostics"). Dart redacts what it logs, but the first defence is not
  /// putting a URL on the channel at all. Use ``errorCode(domain:code:)``.
  public static func playbackState(
    _ event: PlaybackStateEvent,
    positionMs: Int64,
    durationMs: Int64,
    message: String? = nil
  ) -> [String: Any] {
    var payload: [String: Any] = [
      eventKey: event.rawValue,
      positionKey: normalizedMs(positionMs),
      durationKey: normalizedMs(durationMs),
    ]
    if let message { payload[messageKey] = message }
    return payload
  }

  /// Periodic progress tick while the native controller owns playback.
  public static func progress(
    positionMs: Int64,
    durationMs: Int64,
    playing: Bool,
    buffering: Bool
  ) -> [String: Any] {
    [
      eventKey: progressEvent,
      positionKey: normalizedMs(positionMs),
      durationKey: normalizedMs(durationMs),
      "playing": playing,
      "buffering": buffering,
    ]
  }

  /// A credential-free identifier for an `NSError`, for the `message` field.
  ///
  /// Domain and code only, deliberately: they are enough to tell an
  /// `AVFoundationErrorDomain` decode failure from a `NSURLErrorDomain`
  /// timeout when reading an exported diagnostics log, and neither can carry a
  /// URL. The human-readable description cannot make that promise.
  public static func errorCode(domain: String, code: Int) -> String {
    "\(domain):\(code)"
  }

  /// Milliseconds as Dart should see them: never negative.
  ///
  /// AVFoundation reports an unknown or unbounded duration as
  /// `CMTime.indefinite` and a not-yet-known position as `CMTime.invalid`;
  /// converting either yields a NaN or negative seconds value. The callers
  /// map those to `0`, and this clamps anything that slips through, so Dart's
  /// `durationMs > 0` guard in the `nativeClosed` handler stays the single
  /// meaning of "no useful duration" across Android and iOS alike.
  public static func normalizedMs(_ value: Int64) -> Int {
    value <= 0 ? 0 : Int(value)
  }
}
