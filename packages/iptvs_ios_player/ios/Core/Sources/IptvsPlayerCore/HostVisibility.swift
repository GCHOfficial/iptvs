import Foundation

/// What the *host* (the iOS application process, and the PiP controller if one
/// exists) can say about whether anything of the Flutter route is on screen.
///
/// This exists because of a deliberate conflict in the iOS player design.
/// `IptvsPlayerViewController` is presented `.overFullScreen` rather than
/// `.fullScreen` **specifically so that opening it does not remove the
/// `FlutterViewController` and therefore fires no Flutter `AppLifecycleState`
/// transition** (docs/ios.md "Native player" — the preview-stop observer, the
/// update flow and the cloud-sync timers are real downstream consumers that
/// must not fire just because the player opened). But Dart's AVPlayer→mpv
/// runtime fallback (`engineFailed`) needs to know whether it may open libmpv
/// *right now*, and it was inferring that from exactly the lifecycle state the
/// presentation style is designed not to move.
///
/// So Swift states the facts instead of letting Dart infer them:
/// `UIApplication.shared.applicationState == .active` and
/// `AVPictureInPictureController.isPictureInPictureActive` are both directly
/// readable here, and neither depends on any UIKit→`AppLifecycleState` mapping
/// being what anyone assumed. Dart's `decideIosFallbackAction`
/// (`lib/player/player_screen.dart`) combines them with its own lifecycle read
/// and vetoes on any one of the three.
///
/// Foundation-only on purpose: it holds no `UIApplication`/`AVKit` types, only
/// the two booleans read off them, so it compiles and tests under plain
/// `swift test` on the CI host with no simulator.
public struct HostVisibility: Equatable, Sendable {
  /// `UIApplication.shared.applicationState == .active`.
  public let appActive: Bool

  /// `AVPictureInPictureController.isPictureInPictureActive`, or `nil` when
  /// nothing in the process is in a position to answer — no player view
  /// controller has been presented yet, so no PiP controller exists.
  ///
  /// **`nil` is an absence, not a `false`.** Dart treats a missing `pipActive`
  /// key as "no opinion" rather than "PiP is off", and the payload builders
  /// below omit the key entirely for `nil` so that distinction survives the
  /// method channel. Reporting a confident `false` from a layer that cannot
  /// actually see PiP would be the one way to reintroduce the bug this whole
  /// contract exists to close.
  public let pipActive: Bool?

  public init(appActive: Bool, pipActive: Bool?) {
    self.appActive = appActive
    self.pipActive = pipActive
  }
}

/// Emit-on-change filter for `hostVisibility` events.
///
/// `UIApplication` foreground/background notifications and PiP delegate
/// callbacks both fire more often than the state actually changes (and can
/// fire in pairs), and Dart re-evaluates its deferral on every one. Collapsing
/// repeats keeps the method channel — and the user-exportable diagnostics log
/// Dart writes from it — quiet without adding any state Dart has to trust.
///
/// Deliberately *not* an optimisation Dart depends on: Dart's gate is
/// idempotent and also polls, so a duplicate event is harmless and a dropped
/// one is recovered. This only stops the channel chattering.
public struct HostVisibilityTracker {
  private var last: HostVisibility?

  public init() {}

  /// Records `visibility` and returns it only when it differs from the last
  /// value recorded — i.e. only when there is something new to tell Dart.
  public mutating func changeToEmit(_ visibility: HostVisibility) -> HostVisibility? {
    if last == visibility { return nil }
    last = visibility
    return visibility
  }

  /// Drops the memo so the next update always emits. Call when the Dart side
  /// may have been replaced (a new `PlayerScreen` route claimed the channel),
  /// since the new owner has never seen any of these events.
  public mutating func reset() {
    last = nil
  }
}

/// Builders for the `nativePlayback` method-call payloads the iOS player sends
/// to Dart over the shared `iptvs/native_hdr_player` channel.
///
/// Centralised and pure so the key names cannot drift from the ones
/// `_handleNativeHdrMethodCall` / `_handleIosEngineFailed` /
/// `_handleIosHostVisibility` parse in `lib/player/player_screen.dart`, and so
/// that drift is caught by `swift test` in seconds rather than by an iOS
/// device silently ignoring an event.
public enum PlaybackEventPayload {
  public static let method = "nativePlayback"
  public static let eventKey = "event"
  public static let engineFailedEvent = "engineFailed"
  public static let hostVisibilityEvent = "hostVisibility"

  /// AVPlayer could not play this container after all. Sent **instead of**
  /// `nativeClosed`, because the Dart route must survive to host the embedded
  /// mpv surface (docs/player.md "MethodChannel handler ownership").
  ///
  /// - `reason`: a short diagnostic string. Dart redacts it before logging
  ///   because `AVError`/`NSUnderlyingError` descriptions routinely embed the
  ///   failing URL, which carries provider credentials — but keep it short and
  ///   avoid interpolating the URL deliberately.
  /// - `positionMs`: last known playback position, `0` for live or unknown.
  ///   Dart reuses it as the embedded resume point for VOD.
  /// - `pipWasActive`: whether PiP was running when the failure was detected.
  ///   Diagnostic only — the gating fact is `visibility.pipActive`, read
  ///   *after* the teardown.
  public static func engineFailed(
    reason: String?,
    positionMs: Int,
    pipWasActive: Bool,
    visibility: HostVisibility
  ) -> [String: Any] {
    var payload: [String: Any] = [
      eventKey: engineFailedEvent,
      "positionMs": positionMs,
      "pipWasActive": pipWasActive,
    ]
    if let reason { payload["reason"] = reason }
    merge(visibility, into: &payload)
    return payload
  }

  /// The host application state or PiP state changed. This is the wake signal
  /// for a fallback Dart has deferred, and its whole value is that it does not
  /// route through Flutter's lifecycle plumbing — so it still arrives if
  /// presenting `.overFullScreen`, dismissing it, or entering/leaving PiP turns
  /// out to deliver no `AppLifecycleState` transition at all.
  ///
  /// Send it unconditionally on every real change, not only while a fallback is
  /// pending: Swift has no idea whether Dart is currently waiting, and Dart
  /// ignores events it doesn't need.
  public static func hostVisibility(_ visibility: HostVisibility) -> [String: Any] {
    var payload: [String: Any] = [eventKey: hostVisibilityEvent]
    merge(visibility, into: &payload)
    return payload
  }

  private static func merge(_ visibility: HostVisibility, into payload: inout [String: Any]) {
    payload["appActive"] = visibility.appActive
    // Omitted, never `false`, when unknown — see `HostVisibility.pipActive`.
    if let pipActive = visibility.pipActive { payload["pipActive"] = pipActive }
  }
}
