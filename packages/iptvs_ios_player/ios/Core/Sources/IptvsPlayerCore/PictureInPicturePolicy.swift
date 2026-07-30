import Foundation

/// Whether the PiP button should be offered.
///
/// Two facts, both read off `AVPictureInPictureController` and neither
/// guessable:
///
/// - `isSupported`: `AVPictureInPictureController.isPictureInPictureSupported()`.
///   **False on every Simulator**, which is why the whole PiP path has to be
///   inert rather than fatal when it is false — a simulator run must exercise
///   everything else normally.
/// - `isPossible`: `isPictureInPicturePossible`, KVO-observed. False until an
///   item with a video track is ready, and false forever for audio-only. This
///   is the reason the button appears a beat after playback starts rather than
///   at present time.
///
/// Deliberately **not** gated on `isLive`. PiP works for live HLS, and this app's
/// primary content is live — gating it out would remove the feature from the
/// case it exists for.
public func shouldOfferPictureInPicture(isSupported: Bool, isPossible: Bool) -> Bool {
  isSupported && isPossible
}

/// Why `IptvsPlayerViewController` is going away.
///
/// The three cases send **three different things to Dart**, and confusing any
/// two of them breaks the route:
///
/// - `exit` → `nativeClosed`, which pops the Dart route (and carries the VOD
///   position and the favorite state).
/// - `pictureInPicture` → **nothing**. The controller dismisses itself so the
///   `AVPlayerLayer` can feed the PiP window, while the plugin holds a strong
///   reference to keep it alive. The Dart route must survive completely
///   untouched: a `nativeClosed` here would pop the route out from under a PiP
///   window that is still playing, and the user's restore button would then have
///   nothing to return to.
/// - `engineFailed` → `engineFailed` *instead of* `nativeClosed`, because Dart
///   keeps the route alive to host the embedded mpv surface
///   (docs/ios.md "engineFailed is a cross-language handoff").
public enum PlayerDismissal: Equatable, Sendable {
  case exit
  case pictureInPicture
  case engineFailed
}

/// Whether this dismissal is the one that tells Dart to pop its route.
public func dismissalEmitsNativeClosed(_ kind: PlayerDismissal) -> Bool {
  kind == .exit
}

/// What to do when Picture-in-Picture stops.
public enum PipStopOutcome: Equatable, Sendable {
  /// The user tapped the PiP window's *restore* control: re-present the player
  /// over the Flutter host and hand control back to it.
  case restoreHost

  /// The PiP window was closed outright — no restore was requested, so nothing
  /// of this playback is on screen any more and nothing ever will be.
  case finishPlayback
}

/// The PiP stop decision.
///
/// - Parameter restoreRequested: whether
///   `restoreUserInterfaceForPictureInPictureStopWithCompletionHandler` was
///   called before the stop. AVKit calls it *only* for the restore control, not
///   for the close button.
///
/// **The `finishPlayback` branch is the one that matters.** A PiP window closed
/// with the X leaves the app with a dismissed controller, a live `AVPlayer`, and
/// a Dart route sitting on a black `PlayerScreen` with no native surface behind
/// it — a dead end the user can only escape by force-quitting. Running the
/// ordinary `finish()` path instead sends `nativeClosed`, which pops the route
/// back to the channel list exactly as the X button in the overlay would.
public func pipStopOutcome(restoreRequested: Bool) -> PipStopOutcome {
  restoreRequested ? .restoreHost : .finishPlayback
}
