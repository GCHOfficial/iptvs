import XCTest

@testable import IptvsPlayerCore

/// Pins the arithmetic that keeps the process-wide `AVAudioSession` correct now
/// that Swift is its only owner (`iosManageAudioSession: false` at both
/// `PlayerConfiguration` sites — docs/ios.md Constraint 1).
///
/// The failure this suite exists to prevent is silent: a session deactivated
/// while something is still playing produces *no error anywhere*, just no sound.
///
/// Every `acquire`/`release` result is hoisted into a local before it is
/// asserted, matching `HostVisibilityTests`: both are `mutating`, and calling a
/// mutating method inside an `XCTAssert*` autoclosure is needless risk in files
/// no local toolchain can compile.
final class AudioSessionPolicyTests: XCTestCase {

  // MARK: - Activation edges

  func testFirstAcquireActivatesAndLastReleaseDeactivates() {
    var clients = AudioSessionClients()
    let activate = clients.acquire(AudioSessionClientId.embeddedPlayer)
    let deactivate = clients.release(AudioSessionClientId.embeddedPlayer)
    XCTAssertTrue(activate, "the first claim is what activates the session")
    XCTAssertTrue(deactivate, "the last release is what deactivates it")
    XCTAssertTrue(clients.isEmpty)
  }

  func testSecondAcquireDoesNotReactivate() {
    var clients = AudioSessionClients()
    _ = clients.acquire(AudioSessionClientId.fullscreenPlayer)
    let second = clients.acquire(AudioSessionClientId.livePreview)
    XCTAssertFalse(second, "the session is already active; re-activating it is churn")
    XCTAssertEqual(clients.count, 2)
  }

  /// `viewDidAppear` runs again after a Picture-in-Picture restore re-presents
  /// the controller, so the same client acquires twice with no release between.
  func testAcquireIsIdempotentForTheSameClient() {
    var clients = AudioSessionClients()
    let first = clients.acquire(AudioSessionClientId.fullscreenPlayer)
    let repeated = clients.acquire(AudioSessionClientId.fullscreenPlayer)
    XCTAssertTrue(first)
    XCTAssertFalse(repeated)
    XCTAssertEqual(clients.count, 1)

    let released = clients.release(AudioSessionClientId.fullscreenPlayer)
    XCTAssertTrue(
      released,
      "a doubly-acquired client still holds exactly one claim — this is a set, not a counter"
    )
  }

  /// The controller runs its teardown from `finish`/`forceClose`/
  /// `reportEngineFailed` *and* belt-and-braces from `deinit`.
  func testReleasingAnUnheldClientNeverDeactivates() {
    var clients = AudioSessionClients()
    _ = clients.acquire(AudioSessionClientId.embeddedPlayer)
    let strayRelease = clients.release(AudioSessionClientId.fullscreenPlayer)
    XCTAssertFalse(
      strayRelease,
      "a stale teardown must not deactivate a session another client is using"
    )
    XCTAssertEqual(clients.count, 1)
  }

  /// The `engineFailed` handoff: the AVPlayer controller tears down while the
  /// embedded mpv surface is spinning up, in whichever order the two happen to
  /// land. Neither ordering may leave the session deactivated with a live
  /// client, or produce a spurious second activation.
  func testHandoffOverlapNeverDropsTheSession() {
    var clients = AudioSessionClients()
    let avPlayerClaim = clients.acquire(AudioSessionClientId.fullscreenPlayer)
    // mpv comes up before AVPlayer has finished going down.
    let mpvClaim = clients.acquire(AudioSessionClientId.embeddedPlayer)
    let avPlayerTeardown = clients.release(AudioSessionClientId.fullscreenPlayer)
    let remaining = clients.count
    let mpvStillHeld = clients.contains(AudioSessionClientId.embeddedPlayer)
    let mpvTeardown = clients.release(AudioSessionClientId.embeddedPlayer)

    XCTAssertTrue(avPlayerClaim)
    XCTAssertFalse(mpvClaim)
    XCTAssertFalse(
      avPlayerTeardown,
      "mpv is still playing — deactivating here is exactly the silent bug"
    )
    XCTAssertEqual(remaining, 1)
    XCTAssertTrue(mpvStillHeld)
    XCTAssertTrue(mpvTeardown)
  }

  /// The reverse ordering — AVPlayer gone before mpv arrives — legitimately
  /// bounces the session, and must report both edges so the real session
  /// follows.
  func testSequentialHandoffReportsBothEdges() {
    var clients = AudioSessionClients()
    let activate = clients.acquire(AudioSessionClientId.fullscreenPlayer)
    let deactivate = clients.release(AudioSessionClientId.fullscreenPlayer)
    let reactivate = clients.acquire(AudioSessionClientId.embeddedPlayer)
    XCTAssertTrue(activate)
    XCTAssertTrue(deactivate)
    XCTAssertTrue(reactivate)
  }

  /// Two controllers coexist for a moment when one `open` replaces another, so
  /// the controller's id carries a per-instance suffix. Distinct ids must be
  /// distinct claims even when they share a prefix.
  func testPrefixedControllerIdsAreIndependentClaims() {
    var clients = AudioSessionClients()
    let outgoing = "\(AudioSessionClientId.fullscreenPlayer)#A"
    let incoming = "\(AudioSessionClientId.fullscreenPlayer)#B"
    let outgoingClaim = clients.acquire(outgoing)
    let incomingClaim = clients.acquire(incoming)
    let outgoingTeardown = clients.release(outgoing)
    let incomingTeardown = clients.release(incoming)

    XCTAssertTrue(outgoingClaim)
    XCTAssertFalse(incomingClaim)
    XCTAssertFalse(
      outgoingTeardown,
      "the outgoing controller's teardown must not mute the incoming one"
    )
    XCTAssertTrue(incomingTeardown)
  }

  func testReleaseAllOnlyReportsWhenSomethingWasHeld() {
    var clients = AudioSessionClients()
    let emptyReset = clients.releaseAll()
    _ = clients.acquire(AudioSessionClientId.livePreview)
    _ = clients.acquire(AudioSessionClientId.embeddedPlayer)
    let populatedReset = clients.releaseAll()
    let settled = clients.isEmpty

    XCTAssertFalse(emptyReset)
    XCTAssertTrue(populatedReset)
    XCTAssertTrue(settled)
  }

  /// The preview drops its claim on app pause while the fullscreen player keeps
  /// its own — the asymmetry `UIBackgroundModes = [audio]` makes load-bearing
  /// (docs/ios.md: the fullscreen player *should* keep playing behind the
  /// launcher, the preview must not).
  func testPreviewReleaseOnPauseLeavesTheFullscreenPlayerAudible() {
    var clients = AudioSessionClients()
    _ = clients.acquire(AudioSessionClientId.fullscreenPlayer)
    _ = clients.acquire(AudioSessionClientId.livePreview)
    let previewTeardown = clients.release(AudioSessionClientId.livePreview)
    let fullscreenStillHeld = clients.contains(AudioSessionClientId.fullscreenPlayer)
    XCTAssertFalse(previewTeardown)
    XCTAssertTrue(fullscreenStillHeld)
  }

  // MARK: - Interruptions

  func testInterruptionBeganPausesOnlyWhenPlaying() {
    XCTAssertEqual(audioInterruptionReaction(.began, wasPlaying: true), .pause)
    XCTAssertEqual(audioInterruptionReaction(.began, wasPlaying: false), .ignore)
  }

  func testInterruptionEndResumesOnlyWhatItInterrupted() {
    XCTAssertEqual(
      audioInterruptionReaction(.ended(shouldResume: true), wasPlaying: true),
      .resume
    )
    XCTAssertEqual(
      audioInterruptionReaction(.ended(shouldResume: true), wasPlaying: false),
      .ignore,
      "a player the user had paused must not be started by a call ending"
    )
    XCTAssertEqual(
      audioInterruptionReaction(.ended(shouldResume: false), wasPlaying: true),
      .ignore,
      "without .shouldResume the system is saying not to — resuming talks over it"
    )
  }

  func testOutputDeviceLostAlwaysPauses() {
    XCTAssertEqual(audioInterruptionReaction(.outputDeviceLost, wasPlaying: true), .pause)
    XCTAssertEqual(
      audioInterruptionReaction(.outputDeviceLost, wasPlaying: false),
      .pause,
      "pausing an already-paused player is free; blasting a bus is not"
    )
  }
}
