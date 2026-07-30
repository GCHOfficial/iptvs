import Flutter
import UIKit

/// Lets `IptvsPlayerViewController` (not yet written) tell the plugin whether
/// Picture-in-Picture is currently running, without the plugin importing AVKit
/// or holding a reference to the controller's internals.
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
/// half of the contract. No AVFoundation is touched here yet — the player
/// surface itself lands with `IptvsPlayerViewController`.
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

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "iptvs/native_hdr_player",
      binaryMessenger: registrar.messenger()
    )
    let instance = IptvsIosPlayerPlugin()
    instance.channel = channel
    instance.startObservingHostVisibility()
    IptvsIosPlayerPlugin.current = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      // No engine wired up yet — always report "did not open" rather than
      // silently pretending to play. Dart falls through to the embedded
      // media_kit surface (`_tryOpenNativeHdrPlayer` returning false).
      result(false)
    case "close":
      result(true)
    case "debugCounters":
      // Shape matches the Android/Windows `debugCounters` reply
      // (`ResourceCounters.snapshot()`): an empty map until real lifecycle
      // resources exist to count.
      result([:])
    default:
      result(FlutterMethodNotImplemented)
    }
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
