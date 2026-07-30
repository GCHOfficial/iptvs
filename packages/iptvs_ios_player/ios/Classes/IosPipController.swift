import AVFoundation
import AVKit
import Foundation

/// What ``IosPipController`` tells its host about a Picture-in-Picture session.
///
/// A protocol rather than a bag of closures because the ordering between these
/// callbacks *is* the contract, and reading them in one place is the only way
/// that ordering stays reviewable. AVKit's real sequence, worth writing down
/// because two of the three failure modes come from getting it wrong:
///
/// 1. `willStart` → 2. `didStart` → (time passes) → 3. optional
///    `restoreUserInterface` → 4. `willStop` → 5. `didStop`
///
/// The restore callback fires **only** for the PiP window's restore control,
/// never for its close button — which is exactly what
/// ``pipStopOutcome(restoreRequested:)`` keys on.
protocol IosPipControllerDelegate: AnyObject {
  /// PiP is about to take over. The host must arrange to stay alive across its
  /// own dismissal *before* this returns.
  func pipWillStart()

  /// PiP is running. The host dismisses itself here — the `AVPlayerLayer` keeps
  /// feeding the PiP window regardless.
  func pipDidStart()

  /// The user asked to come back to the app. Re-present and call
  /// `completion(true)`; `completion(false)` tells AVKit the restore failed.
  func pipRestoreUserInterface(completion: @escaping (Bool) -> Void)

  /// PiP has ended. `restoreRequested` is whether ``pipRestoreUserInterface(completion:)``
  /// was called first — feed it to ``pipStopOutcome(restoreRequested:)``.
  func pipDidStop(restoreRequested: Bool)

  /// PiP could not start. Not fatal: the host stays exactly where it is.
  func pipFailedToStart(_ error: Error)

  /// `isPictureInPicturePossible` changed — the host uses it to show or hide the
  /// PiP button.
  func pipPossibleChanged(_ possible: Bool)
}

/// `AVPictureInPictureController` wrapper for the presented iOS player.
///
/// **Constructed only when PiP is genuinely available**, which is what keeps a
/// Simulator run normal: `AVPictureInPictureController.isPictureInPictureSupported()`
/// returns `false` on every Simulator, `init?` returns nil there, `supportsPip`
/// stays false, the button stays hidden, and the `.enterPictureInPicture` action
/// is unreachable. Nothing crashes, nothing hangs, and every other step is
/// exercised exactly as it would be on a device.
///
/// PiP additionally requires `UIBackgroundModes = [audio]` in
/// `ios/Runner/Info.plist` and an **activated** `.playback` audio session
/// (`IosAudioSession`); without either, `startPictureInPicture()` fails through
/// `pipFailedToStart` rather than throwing. That coupling is why steps 6 and 7
/// land together.
///
/// Automatic PiP on backgrounding (`canStartPictureInPictureAutomaticallyFromInline`)
/// is deliberately left off. With the audio background mode the fullscreen
/// player already keeps *playing* when the app is backgrounded (docs/ios.md:
/// "the fullscreen player *should* keep playing in the background"), so
/// auto-PiP would change the meaning of the home gesture rather than add a
/// capability, and it would fire the whole dismiss/retain dance on a path the
/// user never asked for. Recorded here so it reads as a decision, not an
/// oversight.
final class IosPipController: NSObject {
  weak var delegate: IosPipControllerDelegate?

  private let controller: AVPictureInPictureController
  private var possibleObservation: NSKeyValueObservation?
  private var restoreRequested = false

  var isActive: Bool { controller.isPictureInPictureActive }
  var isPossible: Bool { controller.isPictureInPicturePossible }

  /// Whether this device can do PiP at all. `false` on every Simulator.
  static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  /// - Returns: nil when PiP is unsupported on this device, or when AVKit
  ///   declines to build a controller for this layer.
  init?(playerLayer: AVPlayerLayer) {
    guard IosPipController.isSupported else { return nil }
    // Bound through an explicitly optional local rather than `guard let` on the
    // initialiser directly: `AVPictureInPictureController.init(playerLayer:)` is
    // failable in the SDKs this targets, but binding it this way compiles
    // whichever way that nullability is spelled — and there is no local Swift
    // toolchain here to find out the hard way.
    let candidate: AVPictureInPictureController? = AVPictureInPictureController(
      playerLayer: playerLayer
    )
    guard let candidate else { return nil }
    controller = candidate
    super.init()
    controller.delegate = self
    IosDebugCounters.increment(.pipControllers)

    possibleObservation = controller.observe(
      \.isPictureInPicturePossible,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let possible = controller.isPictureInPicturePossible
      // KVO can arrive off the main queue; every consumer here edits UI state.
      DispatchQueue.main.async { self?.delegate?.pipPossibleChanged(possible) }
    }
  }

  deinit {
    possibleObservation?.invalidate()
    controller.delegate = nil
    IosDebugCounters.decrement(.pipControllers)
  }

  /// Enters PiP. A no-op when it is already running or not currently possible —
  /// AVKit logs and ignores a start it cannot honour, so guarding here keeps the
  /// failure path meaningful (`pipFailedToStart` then means something real).
  func start() {
    guard !controller.isPictureInPictureActive, controller.isPictureInPicturePossible else {
      return
    }
    restoreRequested = false
    controller.startPictureInPicture()
  }

  /// Leaves PiP. Safe to call when it isn't running — every teardown path calls
  /// it unconditionally rather than testing first, because a *missed* stop
  /// leaves a PiP window playing over an app that has torn its player down.
  func stop() {
    guard controller.isPictureInPictureActive else { return }
    controller.stopPictureInPicture()
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension IosPipController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    restoreRequested = false
    delegate?.pipWillStart()
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    delegate?.pipDidStart()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    delegate?.pipFailedToStart(error)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    // Recorded *before* `didStop`, which is where the decision is taken. AVKit
    // calls this only for the restore control — never for the close button —
    // and that asymmetry is the entire signal.
    restoreRequested = true
    delegate?.pipRestoreUserInterface(completion: completionHandler)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    delegate?.pipDidStop(restoreRequested: restoreRequested)
    restoreRequested = false
  }
}
