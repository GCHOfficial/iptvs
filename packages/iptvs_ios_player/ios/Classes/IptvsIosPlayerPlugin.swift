import Flutter
import UIKit

/// Lets `IptvsPlayerViewController` tell the plugin whether Picture-in-Picture
/// is currently running, without the plugin importing AVKit or holding a
/// reference to the controller's internals.
///
/// **While no conforming object is registered the plugin reports PiP as
/// *unknown*, never as `false`.** That is deliberate and load-bearing: Dart
/// treats an absent `pipActive` as "no opinion" but an explicit `false` as an
/// authoritative "PiP is off", which clears a veto. A plugin build with no PiP
/// controller in it must not clear a veto it cannot actually evaluate. It is
/// self-consistent, because the view controller is the only thing that creates
/// PiP in the first place: no controller, no PiP.
public protocol IptvsPipStateProviding: AnyObject {
  var isPictureInPictureActive: Bool { get }
}

/// Registers the shared `iptvs/native_hdr_player` method channel (the same
/// channel name Android's `HdrPlayerActivity` already uses) and owns the
/// process-wide **host visibility** reporting that Dart's AVPlayer→mpv runtime
/// fallback depends on.
///
/// Why the plugin — not the (future) view controller — owns this: the fallback
/// can outlive the controller. `engineFailed` is emitted *after*
/// `IptvsPlayerViewController` has torn down AVPlayer and dismissed itself, and
/// Dart may then wait an arbitrarily long time for a safe moment to open
/// libmpv. Something that survives the controller has to keep answering "is the
/// app on screen yet?", and the plugin is the only such object.
///
/// See docs/ios.md "engineFailed is a cross-language handoff" and
/// `decideIosFallbackAction` in `lib/player/player_screen.dart` for the Dart
/// half of the contract. The player surface itself is
/// `IptvsPlayerViewController`, which this plugin presents on `open` and
/// forwards transport calls to.
public class IptvsIosPlayerPlugin: NSObject, FlutterPlugin {
  /// The live plugin instance, so `IptvsPlayerViewController` can register
  /// itself as the PiP state provider and emit `engineFailed` through the one
  /// channel Dart is listening on. Weak: the registrar owns the plugin.
  public private(set) static weak var current: IptvsIosPlayerPlugin?

  private var channel: FlutterMethodChannel?
  private var visibilityTracker = HostVisibilityTracker()

  /// Set by `IptvsPlayerViewController` on `viewDidLoad` and cleared
  /// automatically when it deallocates (weak). See `IptvsPipStateProviding`
  /// for why `nil` means *unknown* rather than *not in PiP*.
  public weak var pipStateProvider: IptvsPipStateProviding?

  /// The presented player, while one exists.
  ///
  /// **Weak on purpose:** UIKit retains a presented view controller for as long
  /// as it is presented, and nothing should keep it alive past its dismissal —
  /// a strong reference here would leak an `AVPlayer` per open, which the
  /// `debugCounters` soak (docs/player.md "Debug resource counters + lifecycle
  /// soak") is specifically built to catch.
  ///
  /// It stays weak. Picture-in-Picture, which dismisses the controller while its
  /// `AVPlayerLayer` keeps feeding the PiP window, is handled by the *separate*
  /// strong hold below rather than by promoting this one — so the exceptional
  /// lifetime is scoped to the exceptional case, and every ordinary open still
  /// deallocates on dismissal.
  private weak var activeController: IptvsPlayerViewController?

  /// The **PiP-lifetime strong hold**, and the whole reason `activeController`
  /// can stay weak.
  ///
  /// Entering PiP dismisses `IptvsPlayerViewController` — UIKit then releases
  /// it, and with only a weak reference left it would deallocate mid-session,
  /// taking the `AVPlayer` feeding the PiP window with it. This holds it for
  /// exactly as long as PiP is running: set on `willStart`, cleared on `didStop`
  /// (or on the failure path, or by whichever teardown runs first).
  ///
  /// Never assigned outside that window, so an ordinary open/close cycle still
  /// settles `iosPlayerControllers` back to zero.
  private var pictureInPictureRetainedController: IptvsPlayerViewController?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "iptvs/native_hdr_player",
      binaryMessenger: registrar.messenger()
    )
    let instance = IptvsIosPlayerPlugin()
    instance.channel = channel
    instance.startObservingHostVisibility()
    // Category only — no activation. `setCategory` does not interrupt other
    // apps; only `setActive(true)` does, and that is per-client
    // (`IosAudioSession`). It buys one concrete thing on its own, and it is the
    // thing a tester would never diagnose: `.playback` is not muted by the ring
    // switch, where the default `soloAmbient` is. That matters *specifically*
    // for the mpv fallback, which no longer touches the session itself
    // (`iosManageAudioSession: false`) and, until Dart claims a client, has
    // nothing else setting a category for it.
    //
    // **Verify on device:** the claim that a launch-time `setCategory` leaves
    // other apps' audio alone is Apple's documented behaviour but is untestable
    // here. If launching iptvs turns out to stop a playing podcast, move this
    // call into `IosAudioSession.activate()` only — the cost is that an
    // mpv-routed stream goes silent again on a phone with the ring switch on,
    // until the Dart-side `acquireAudioSession` wiring lands.
    IosAudioSession.shared.configureCategory()
    IptvsIosPlayerPlugin.current = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      // A payload that cannot describe a playable stream is answered `false`,
      // not as a channel error: Dart treats both identically (fall through to
      // the embedded media_kit surface), and `false` keeps a routing decision
      // out of the diagnostics log as if it were a fault.
      guard let request = PlayerOpenRequest(arguments: call.arguments) else {
        result(false)
        return
      }
      presentPlayer(request, result: result)

    case "close":
      guard let controller = activeController else {
        result(true)
        return
      }
      controller.forceClose { result(true) }

    case "play":
      activeController?.play()
      result(activeController != nil)

    case "pause":
      activeController?.pause()
      result(activeController != nil)

    case "seekTo":
      guard let controller = activeController,
        let positionMs = PlayerOpenRequest.int64(argument(call, "positionMs"))
      else {
        result(false)
        return
      }
      controller.seek(toMs: positionMs)
      result(true)

    case "load":
      // The live reload the reconnect watchdog and "Go to live" both use. The
      // watchdog itself lives in the controller (step 8) and re-resolves through
      // Dart's inbound `resolveAgain`; this entry point is for a Dart-side
      // caller that already has a fresh URL.
      guard let controller = activeController,
        let url = PlayerOpenRequest.nonBlankString(argument(call, "url"))
      else {
        result(false)
        return
      }
      controller.load(
        url: url,
        headers: PlayerOpenRequest.parseHeaders(argument(call, "headers"))
      )
      result(true)

    case "setControlState":
      // Presentation metadata push, the same call the Windows GDI overlay is
      // driven by. The controller reads *only* the presentation half — see
      // `IptvsPlayerViewController.applyControlState` for why position/duration/
      // playing state are deliberately ignored.
      guard let controller = activeController,
        let map = call.arguments as? [AnyHashable: Any]
      else {
        result(false)
        return
      }
      controller.applyControlState(map)
      result(true)

    case "acquireAudioSession":
      // The mpv/media_kit half of the audio session.
      //
      // `iosManageAudioSession: false` means mpv no longer activates
      // `AVAudioSession` itself (docs/ios.md Constraint 1), so an mpv-routed
      // stream — every extension-less Stalker locator, every raw `.ts` — is
      // **silent** until something claims a session on its behalf. That claim
      // comes through here, keyed by client id so it survives overlapping with
      // the AVPlayer controller's own claim during an `engineFailed` handoff.
      guard let clientId = PlayerOpenRequest.nonBlankString(argument(call, "client")) else {
        result(false)
        return
      }
      IosAudioSession.shared.acquire(clientId)
      result(true)

    case "releaseAudioSession":
      guard let clientId = PlayerOpenRequest.nonBlankString(argument(call, "client")) else {
        result(false)
        return
      }
      IosAudioSession.shared.release(clientId)
      result(true)

    case "debugCounters":
      // Shape matches the Android/Windows `debugCounters` reply
      // (`ResourceCounters.snapshot()`): `iosAvPlayers`,
      // `iosPlayerControllers`, `iosPipControllers`, `iosTimeObservers`,
      // `iosAudioClients`, all `#if DEBUG` and empty in release. Every one must
      // settle back to zero after an open/close cycle — see docs/player.md
      // "Debug resource counters + lifecycle soak".
      result(IosDebugCounters.snapshot())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func argument(_ call: FlutterMethodCall, _ key: String) -> Any? {
    (call.arguments as? [AnyHashable: Any])?[key]
  }

  /// Presents the native player over whatever is currently on screen.
  ///
  /// An already-active controller is torn down **first, and the new one is
  /// presented from its dismissal completion**. UIKit rejects a `present` issued
  /// while a dismissal is still in flight ("Attempt to present … while a
  /// presentation is in progress"), and the failure mode is a silently missing
  /// player rather than an error Dart can react to. Dart pushes one player route
  /// at a time, so this path is defensive — but "defensive" here means the
  /// difference between a recoverable stale controller and a dead black screen.
  private func presentPlayer(_ request: PlayerOpenRequest, result: @escaping FlutterResult) {
    let present: () -> Void = { [weak self] in
      guard let self else {
        result(false)
        return
      }
      // Resolved *after* any dismissal above: the top view controller changes
      // when a presentation is undone.
      guard let host = IptvsIosPlayerPlugin.topViewController() else {
        result(false)
        return
      }
      // A new `open` means a new Dart `PlayerScreen` owns the channel, and it
      // has seen none of the host-visibility events the previous owner did.
      self.visibilityTracker.reset()

      let controller = IptvsPlayerViewController(request: request, channel: self.channel)
      self.activeController = controller
      host.present(controller, animated: false) { [weak self] in
        // The controller registered itself as the PiP state provider during
        // `viewDidLoad`, so this first snapshot carries a real `pipActive`
        // rather than "unknown".
        self?.publishHostVisibility()
      }
      result(true)
    }

    if let existing = activeController {
      existing.forceClose { present() }
    } else {
      present()
    }
  }

  /// The view controller to present from: the frontmost presented controller of
  /// the active window scene, which is normally the `FlutterViewController`.
  ///
  /// Read off `connectedScenes` rather than the deprecated
  /// `UIApplication.keyWindow` because this app runs a `UISceneDelegate`
  /// (`ios/Runner/Info.plist` declares a `UIApplicationSceneManifest`, and
  /// `SceneDelegate.swift` subclasses `FlutterSceneDelegate`), so the
  /// application-level window accessors are not the source of truth.
  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    let keyWindow = scene?.keyWindow ?? scene?.windows.first(where: { $0.isKeyWindow })
    let window = keyWindow ?? scene?.windows.first
    guard var controller = window?.rootViewController else { return nil }
    while let presented = controller.presentedViewController {
      controller = presented
    }
    return controller
  }

  // MARK: - Host visibility

  /// The authoritative answer to "can anything of the Flutter route be on
  /// screen right now?", read straight off UIKit rather than inferred from a
  /// Flutter lifecycle state that the `.overFullScreen` presentation style is
  /// specifically designed not to move.
  public func currentHostVisibility() -> HostVisibility {
    HostVisibility(
      appActive: UIApplication.shared.applicationState == .active,
      pipActive: pipStateProvider?.isPictureInPictureActive
    )
  }

  /// Emits `nativePlayback`/`hostVisibility` when — and only when — the state
  /// actually changed. Dart's gate is idempotent and also polls, so a dropped
  /// or duplicated event costs nothing; this just keeps the channel and the
  /// user-exportable diagnostics log quiet.
  public func publishHostVisibility() {
    guard let change = visibilityTracker.changeToEmit(currentHostVisibility()) else { return }
    channel?.invokeMethod(
      PlaybackEventPayload.method,
      arguments: PlaybackEventPayload.hostVisibility(change)
    )
  }

  /// `IptvsPlayerViewController` calls this after it has detected an
  /// unplayable container, torn down its `AVPlayer`, stopped PiP and dismissed
  /// itself — **instead of** `nativeClosed`, which would pop the Dart route
  /// that has to survive to host the embedded mpv surface.
  ///
  /// The current host snapshot rides on the payload, so Dart's very first
  /// evaluation already has the authoritative facts.
  public func emitEngineFailed(reason: String?, positionMs: Int, pipWasActive: Bool) {
    let visibility = currentHostVisibility()
    channel?.invokeMethod(
      PlaybackEventPayload.method,
      arguments: PlaybackEventPayload.engineFailed(
        reason: reason,
        positionMs: positionMs,
        pipWasActive: pipWasActive,
        visibility: visibility
      )
    )
    // Record (don't emit) the snapshot we just shipped, so the next genuine
    // change still fires while an identical one stays quiet.
    _ = visibilityTracker.changeToEmit(visibility)
  }

  /// Call whenever PiP starts or stops (the
  /// `AVPictureInPictureControllerDelegate` did-start/did-stop callbacks). The
  /// app-state half is observed here; PiP is not observable from the plugin.
  public func pictureInPictureStateChanged() {
    publishHostVisibility()
  }

  // MARK: - Picture-in-Picture lifetime

  /// Takes the PiP-lifetime strong hold. Called from
  /// `pictureInPictureControllerWillStartPictureInPicture`, i.e. **before** the
  /// controller dismisses itself — after the dismissal there may be nothing left
  /// holding it.
  func retainForPictureInPicture(_ controller: IptvsPlayerViewController) {
    pictureInPictureRetainedController = controller
  }

  /// Drops the hold — **identity-checked**, the same discipline
  /// `ChannelHandlerOwner.release(token)` uses on the Dart side: a controller
  /// that has been superseded must not clear a newer one's hold. Without the
  /// check, a late PiP teardown from an outgoing player would deallocate the
  /// incoming one mid-PiP.
  func releasePictureInPictureRetain(_ controller: IptvsPlayerViewController) {
    guard pictureInPictureRetainedController === controller else { return }
    pictureInPictureRetainedController = nil
  }

  private func startObservingHostVisibility() {
    let center = NotificationCenter.default
    // `didBecomeActive` is the wake signal that matters; the other three are
    // what let Dart *engage* a deferral promptly instead of finding out a
    // second later on its poll.
    for name in [
      UIApplication.didBecomeActiveNotification,
      UIApplication.willResignActiveNotification,
      UIApplication.didEnterBackgroundNotification,
      UIApplication.willEnterForegroundNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(hostVisibilityNotification(_:)),
        name: name,
        object: nil
      )
    }
  }

  @objc private func hostVisibilityNotification(_ notification: Notification) {
    // `willResignActive`/`willEnterForeground` fire *before*
    // `UIApplication.applicationState` settles, so re-read on the next runloop
    // turn rather than shipping a stale value. Both notifications are delivered
    // on the main thread, so this stays main-thread-confined.
    DispatchQueue.main.async { [weak self] in
      self?.publishHostVisibility()
    }
  }
}
