import XCTest

@testable import IptvsPlayerCore

/// Pins the PiP rules that cannot be exercised anywhere but a physical device —
/// `AVPictureInPictureController.isPictureInPictureSupported()` is `false` on
/// every Simulator, so *none* of the delegate callbacks these decisions sit
/// behind will ever fire in CI or in a simulator run.
///
/// That is precisely why they are pure functions here rather than `if`s inside
/// the delegate methods.
final class PictureInPicturePolicyTests: XCTestCase {

  // MARK: - Offering the button

  func testPipIsOfferedOnlyWhenSupportedAndPossible() {
    XCTAssertTrue(shouldOfferPictureInPicture(isSupported: true, isPossible: true))
    XCTAssertFalse(
      shouldOfferPictureInPicture(isSupported: false, isPossible: true),
      "the Simulator answers false here, and the whole PiP path must stay inert rather than fail"
    )
    XCTAssertFalse(
      shouldOfferPictureInPicture(isSupported: true, isPossible: false),
      "audio-only, or an item whose video track isn't ready yet"
    )
    XCTAssertFalse(shouldOfferPictureInPicture(isSupported: false, isPossible: false))
  }

  // MARK: - What each dismissal tells Dart

  /// The contract in one assertion: **PiP must not send `nativeClosed`.** The
  /// controller dismisses itself so the layer can feed the PiP window, and Dart's
  /// `_finishNativePlayback` would pop the route out from under it.
  func testOnlyAnExitDismissalPopsTheDartRoute() {
    XCTAssertTrue(dismissalEmitsNativeClosed(.exit))
    XCTAssertFalse(
      dismissalEmitsNativeClosed(.pictureInPicture),
      "the Dart route has to survive PiP completely untouched"
    )
    XCTAssertFalse(
      dismissalEmitsNativeClosed(.engineFailed),
      "engineFailed is sent instead of nativeClosed — the route hosts the mpv surface next"
    )
  }

  // MARK: - Stopping PiP

  func testRestoreControlBringsTheHostBack() {
    XCTAssertEqual(pipStopOutcome(restoreRequested: true), .restoreHost)
  }

  /// A PiP window closed with its X calls no restore handler. Without this
  /// branch the app is left with a dismissed controller and a Dart route on a
  /// black screen — a dead end only a force-quit escapes.
  func testClosingThePipWindowFinishesPlaybackRatherThanDeadEnding() {
    XCTAssertEqual(pipStopOutcome(restoreRequested: false), .finishPlayback)
  }
}
