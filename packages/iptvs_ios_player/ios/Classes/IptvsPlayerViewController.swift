import AVFoundation
import Flutter
import UIKit

/// The native iOS player surface — the direct analogue of Android's
/// `HdrPlayerActivity` (`android/app/src/main/kotlin/.../HdrPlayerActivity.kt`).
///
/// A **presented** `UIViewController` owning an `AVPlayerLayer` on its own view
/// hierarchy, deliberately outside Flutter's compositor. Every platform in this
/// repo that needed real HDR ended up taking video out of the host UI
/// compositor — Android's separate Activity, Windows' native HWND, Linux's
/// standalone mpv process — and the composited path is the SDR tier everywhere.
/// See docs/ios.md "Native player" for the full decision record, including the
/// rejected `UiKitView` platform-view design and why stock
/// `AVPlayerViewController` chrome was turned down.
///
/// Presentation invariants, all from docs/ios.md and each load-bearing:
///
/// - `.overFullScreen`, never `.fullScreen`. `.fullScreen` removes the
///   presenting `FlutterViewController` from the hierarchy, which Flutter
///   reports as an `AppLifecycleState` transition — and this codebase has real
///   consumers of that (the preview-stop observer, the update-flow prompt gate,
///   the cloud-sync timers). Opening the player must read like a route push,
///   not a backgrounding.
/// - `isModalInPresentation = true` — no interactive swipe-to-dismiss. Exit is
///   always an explicit command, matching every other platform.
/// - `animated: false` on present and dismiss, matching the zero-duration
///   player routes everywhere else.
/// - Immersive: status bar and home indicator hidden, idle timer disabled while
///   presented.
/// - Scrim full-bleed, controls inset to `safeAreaLayoutGuide` — the same split
///   as the Android Compose overlay's `safeDrawingPadding()` groups. Only
///   video and scrim may run under the notch.
///
/// **Step 3 scope.** This is the presentation, the engine, and the
/// `nativeClosed` round-trip. Chrome is an X button and nothing else; the
/// attachment points for steps 4–8 are marked with `MARK:` sections below.
final class IptvsPlayerViewController: UIViewController {
  private let request: PlayerOpenRequest
  private weak var channel: FlutterMethodChannel?
  private let engine = AvPlayerEngine()

  private let videoView = PlayerLayerView()
  private let scrimView = UIView()
  private let controlsContainer = UIView()
  private let closeButton = UIButton(type: .system)

  // MARK: Chrome state
  //
  // Step 4 lifts these into `PlayerUiState.swift` (the port of Kotlin's
  // `PlayerUiState`). They are named after their Kotlin counterparts so that
  // move is mechanical. `menuOpen`/`infoOpen` exist here only as the inputs
  // `nextPlayerBackAction` needs; nothing sets them yet.
  private var controlsVisible = true
  private var menuOpen = false
  private var infoOpen = false
  private var isFavorite: Bool

  /// Whether this controller has already run its exit path. Every exit route —
  /// the X button, a Dart-side `close`, the debug soak timer — funnels through
  /// `finish`, and it must be idempotent because `viewDidDisappear` can arrive
  /// after one of them has already fired.
  private var finishing = false

  /// Set by step 7 immediately before dismissing for Picture-in-Picture, so the
  /// disappearance does not clear the idle timer or look like an exit. Android
  /// carries the same flag shape (`HdrPlayerActivity.onStop` skips its pause
  /// when `inPip`).
  var dismissedForPictureInPicture = false

  /// Backing store for `IptvsPipStateProviding`. Registered with the plugin on
  /// `viewDidLoad` so `hostVisibility`/`engineFailed` payloads carry a *real*
  /// `pipActive` rather than the "unknown" a plugin with no controller reports.
  /// Truthful today: no PiP controller exists yet, so PiP genuinely cannot be
  /// running. Step 7 drives this from the
  /// `AVPictureInPictureControllerDelegate` did-start/did-stop callbacks and
  /// calls `IptvsIosPlayerPlugin.current?.pictureInPictureStateChanged()` from
  /// both.
  private(set) var pictureInPictureActive = false

  private var soakAutoCloseTimer: Timer?
  private var pendingResumeMs: Int64?
  private var lastEmittedProgressSecond: Int64 = -1

  init(request: PlayerOpenRequest, channel: FlutterMethodChannel?) {
    self.request = request
    self.channel = channel
    isFavorite = request.isFavorite
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    isModalInPresentation = true
    // Required for `prefersStatusBarHidden` to be honoured: `.overFullScreen`
    // is not a "fullscreen" presentation as far as status-bar appearance is
    // concerned, so without this the bar keeps whatever the Flutter view
    // controller last asked for.
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) {
    fatalError("IptvsPlayerViewController is created in code, never from a nib")
  }

  deinit {
    soakAutoCloseTimer?.invalidate()
    engine.release()
  }

  // MARK: - Immersive presentation

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

  override func viewDidLoad() {
    super.viewDidLoad()
    // First act, per docs/ios.md: until this lands, every host-visibility
    // payload reports PiP as *unknown* instead of the real state.
    IptvsIosPlayerPlugin.current?.pipStateProvider = self

    view.backgroundColor = .black
    buildViewHierarchy()
    bindEngine()

    if request.resumeMs > 0 && !request.isLive {
      pendingResumeMs = request.resumeMs
    }
    engine.load(url: request.url, headers: request.headers, subtitles: request.subtitles)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Without this the screen sleeps mid-film; without the matching clear in
    // `viewDidDisappear` it stays awake for the rest of the process. Neither
    // failure is observable in the Simulator.
    UIApplication.shared.isIdleTimerDisabled = true
    scheduleSoakAutoCloseIfRequested()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // A PiP dismissal is not an exit — the layer is still feeding the PiP
    // window and the screen must stay awake (step 7).
    guard !dismissedForPictureInPicture else { return }
    UIApplication.shared.isIdleTimerDisabled = false
  }

  // MARK: - View hierarchy

  private func buildViewHierarchy() {
    // Video and scrim are full-bleed: video may run under the notch/Dynamic
    // Island, which is the whole point of not letterboxing away from the
    // cutout (Android sets LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES for the
    // same reason).
    videoView.translatesAutoresizingMaskIntoConstraints = false
    videoView.playerLayer.player = engine.player
    videoView.playerLayer.videoGravity = .resizeAspect
    view.addSubview(videoView)

    // The scrim is full-bleed *horizontally and to the physical top edge* —
    // deliberately not inset by the safe area, so it runs under the status bar
    // and notch the way the Compose overlay's full-bleed scrim and the Windows
    // GDI overlay's bars do. It is a plain top band here because step 3 has only
    // one control; step 4 replaces it with the top+bottom gradient pair that
    // backs the real bars. What must not change is the split: scrim full-bleed,
    // controls inside `safeAreaLayoutGuide`.
    scrimView.translatesAutoresizingMaskIntoConstraints = false
    scrimView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    scrimView.isUserInteractionEnabled = false
    view.addSubview(scrimView)

    // Controls, by contrast, are inset to the safe area — no control may ever
    // sit under the cutout or the home indicator.
    controlsContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controlsContainer)

    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = .white
    closeButton.accessibilityLabel = "Close player"
    closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    controlsContainer.addSubview(closeButton)

    NSLayoutConstraint.activate([
      videoView.topAnchor.constraint(equalTo: view.topAnchor),
      videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      scrimView.topAnchor.constraint(equalTo: view.topAnchor),
      scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // Ends below the close button rather than covering the frame: a
      // full-screen dim during bring-up reads as "the video isn't rendering",
      // which is the one thing the first simulator run needs to be able to tell.
      scrimView.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: 60),

      controlsContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      controlsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      controlsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      closeButton.topAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: 8),
      closeButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 8),
      // 44pt is Apple's minimum comfortable hit target; the glyph itself is
      // much smaller.
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
    // Both of these matter: without them a tap recogniser on the ancestor view
    // swallows or cancels the close button's own touch tracking, and the button
    // reads as dead — a failure that looks like a broken exit path rather than
    // a gesture-arena problem.
    tap.cancelsTouchesInView = false
    tap.delegate = self
    view.addGestureRecognizer(tap)
  }

  // MARK: - Engine wiring

  private func bindEngine() {
    engine.onStateEvent = { [weak self] event, message in
      self?.handleStateEvent(event, message: message)
    }
    engine.onProgressTick = { [weak self] in
      self?.handleProgressTick()
    }
    engine.onReadyToPlay = { [weak self] in
      self?.applyPendingResume()
    }
    engine.onFatalError = { [weak self] reason in
      self?.reportEngineFailed(reason: reason)
    }
  }

  private func handleStateEvent(_ event: PlaybackStateEvent, message: String?) {
    // MARK: Step 8 attaches here.
    //
    // The live reconnect watchdog belongs in this method plus a 500 ms ticker,
    // mirroring `HdrPlayerActivity.pollLiveReconnect`/`reconnectLive` and
    // driving `ReconnectPolicy` (already in Core and tested). iOS is
    // Kotlin-shaped rather than Linux-shaped here because, exactly like the
    // Android Activity, this controller owns playback with no live channel back
    // to Dart for playback state. It additionally gets a `resolveAgain`
    // round-trip Android lacks — Stalker `create_link` tokens are single-use, so
    // reloading the URL this controller is holding can never succeed after a
    // portal-side kill (docs/player.md "Live auto-reconnect").
    emit(
      PlaybackEventPayload.playbackState(
        event,
        positionMs: engine.positionMs,
        durationMs: engine.durationMs,
        message: message
      )
    )
  }

  private func handleProgressTick() {
    // MARK: Step 4 attaches here — the scrubber and the live EPG progress strip
    // both redraw off this tick, which is why the engine samples at 500 ms
    // (Android's ticker cadence) rather than at the 1 Hz this emit uses.
    let positionMs = engine.positionMs
    let second = positionMs / 1_000
    guard second != lastEmittedProgressSecond else { return }
    lastEmittedProgressSecond = second
    emit(
      PlaybackEventPayload.progress(
        positionMs: positionMs,
        durationMs: engine.durationMs,
        playing: engine.isPlaying,
        buffering: engine.isBuffering
      )
    )
  }

  /// VOD resume, applied once the item can accept a seek. Android does the same
  /// thing right after `load` because ExoPlayer remembers a seek issued before
  /// it is ready; `AVPlayerItem` does not, so this waits for `.readyToPlay`.
  private func applyPendingResume() {
    guard let resumeMs = pendingResumeMs else { return }
    pendingResumeMs = nil
    let duration = engine.durationMs
    // Never resume past the end — that would land on a completed item and
    // immediately report `ended`.
    guard duration == 0 || resumeMs < duration else { return }
    engine.seek(toMs: resumeMs)
  }

  // MARK: - Dart-driven transport

  func play() { engine.play() }
  func pause() { engine.pause() }
  func seek(toMs positionMs: Int64) { engine.seek(toMs: positionMs) }

  /// Live reload — the same call the reconnect watchdog and "Go to live" make.
  func load(url: String, headers: [String: String]) {
    lastEmittedProgressSecond = -1
    engine.load(url: url, headers: headers, subtitles: request.subtitles)
  }

  // MARK: - Chrome (steps 4–5 attach here)
  //
  // Step 4 replaces `setControlsVisible` with the real `ControlsOverlay`
  // equivalent — top bar, badge cluster, live EPG strip, bottom transport bar,
  // scrubber, favorite star, go-to-live — plus the auto-hide timer that is
  // deliberately absent now (auto-hiding an X-button-only overlay would look
  // like a hung player). Step 5 adds the list menus and info panel, which set
  // `menuOpen`/`infoOpen` and thereby light up the Back ladder below.

  @objc private func videoTapped() {
    setControlsVisible(!controlsVisible)
  }

  @objc private func closeButtonTapped() {
    // Parity with every other platform: the visible back/close control is an
    // explicit Exit and skips the peel ladder (docs/player.md — "The on-screen
    // back-arrow button still exits directly").
    finish()
  }

  private func setControlsVisible(_ visible: Bool) {
    controlsVisible = visible
    controlsContainer.isHidden = !visible
    scrimView.isHidden = !visible
  }

  /// The Back ladder, for the gesture/remote paths step 4 wires up. Kept here
  /// (rather than inline in a gesture handler) for the same reason Android keeps
  /// it in `PlayerBackPolicy`: one press must never be interpreted once by a
  /// control and again by the screen. `nextPlayerBackAction` is in Core and
  /// already pinned by `PlayerBackPolicyTests`.
  func handleBack() {
    switch nextPlayerBackAction(
      menuOpen: menuOpen,
      infoOpen: infoOpen,
      controlsVisible: controlsVisible
    ) {
    case .closeMenu:
      menuOpen = false
    case .closeInfo:
      infoOpen = false
    case .hideControls:
      setControlsVisible(false)
    case .exit:
      finish()
    }
  }

  // MARK: - Exit

  /// Every exit path funnels through here, mirroring `HdrPlayerActivity.finish`:
  /// build the result payload *before* tearing the engine down (the position is
  /// read off it), dismiss, and only then tell Dart.
  ///
  /// `nativeClosed` is sent from the dismissal completion rather than before it,
  /// so Dart pops its route once the native surface is already gone — the same
  /// ordering Android gets for free, where `MainActivity.onActivityResult`
  /// relays the result after the Activity has finished. Sending it first would
  /// leave a frame with a popped route sitting under a still-presented player.
  func finish() {
    guard !finishing else { return }
    finishing = true

    let payload = closePayload()
    soakAutoCloseTimer?.invalidate()
    soakAutoCloseTimer = nil
    engine.release()
    if !dismissedForPictureInPicture {
      UIApplication.shared.isIdleTimerDisabled = false
    }

    let channel = self.channel
    dismissThen {
      channel?.invokeMethod("nativeClosed", arguments: payload)
    }
  }

  /// Dart-initiated teardown — `PlayerScreen._exitAndPop`'s `close` call, or a
  /// stale controller being replaced by a new `open`. Deliberately silent: Dart
  /// is already popping its own route, so echoing `nativeClosed` would be a
  /// second pop.
  func forceClose(completion: (() -> Void)? = nil) {
    guard !finishing else {
      completion?()
      return
    }
    finishing = true
    soakAutoCloseTimer?.invalidate()
    soakAutoCloseTimer = nil
    engine.release()
    if !dismissedForPictureInPicture {
      UIApplication.shared.isIdleTimerDisabled = false
    }
    dismissThen { completion?() }
  }

  /// Dismisses (when actually presented) and then runs `completion` — **always**.
  ///
  /// `dismiss(animated:completion:)` only invokes its completion when there is a
  /// presentation to undo. Every caller here uses the completion to deliver the
  /// one message Dart is waiting for (`nativeClosed`, or `engineFailed`), and a
  /// completion that silently never fires would strand the Dart route on a black
  /// surface with no way back — the exact dead-end the fallback contract exists
  /// to rule out. Step 7 makes the not-presented case real: PiP dismisses this
  /// controller while keeping it alive.
  private func dismissThen(_ completion: @escaping () -> Void) {
    guard presentingViewController != nil else {
      completion()
      return
    }
    dismiss(animated: false, completion: completion)
  }

  /// **Byte-identical to the map `MainActivity.onActivityResult` builds** for
  /// Android's `nativeClosed`, because `_handleNativeHdrMethodCall` parses one
  /// shape for both platforms:
  ///
  /// - position/duration only for VOD, and only when the duration is real
  ///   (`durationMs > 0`) — a live item's duration is `CMTime.indefinite`, which
  ///   `AvPlayerEngine` normalises to `0`;
  /// - `favorite` only when the star was shown at all (`canFavorite`), since the
  ///   controller owning a local toggle is the only channel this state has back
  ///   to the Dart favorites store;
  /// - `nil` rather than an empty map when there is nothing to report, matching
  ///   Kotlin's `if (map.isEmpty()) null else map`.
  private func closePayload() -> [String: Any]? {
    var map: [String: Any] = [:]
    if !request.isLive {
      let positionMs = engine.positionMs
      let durationMs = engine.durationMs
      if durationMs > 0 {
        map["positionMs"] = PlaybackEventPayload.normalizedMs(positionMs)
        map["durationMs"] = PlaybackEventPayload.normalizedMs(durationMs)
      }
    }
    if request.canFavorite {
      map["favorite"] = isFavorite
    }
    return map.isEmpty ? nil : map
  }

  // MARK: - engineFailed

  /// AVPlayer could not play this container after all — hand the stream back to
  /// Dart so it reopens on the embedded libmpv surface.
  ///
  /// **Ordering is contractual** (docs/ios.md): stop PiP, tear down the
  /// `AVPlayer`, dismiss, *then* emit — so the host-visibility snapshot riding
  /// on the payload describes post-teardown reality rather than a PiP window
  /// that is already going away. And it must be `engineFailed`, never
  /// `nativeClosed`: the Dart route has to survive to host the mpv surface, and
  /// `_finishNativePlayback` would pop it.
  private func reportEngineFailed(reason: String) {
    guard !finishing else { return }
    finishing = true

    let positionMs = request.isLive ? 0 : engine.positionMs
    let pipWasActive = pictureInPictureActive

    // MARK: Step 7 attaches here — `pictureInPictureController?.stopPictureInPicture()`
    // goes immediately below, before the engine teardown, and must leave
    // `pictureInPictureActive` false by the time the emit runs.

    soakAutoCloseTimer?.invalidate()
    soakAutoCloseTimer = nil
    engine.release()
    UIApplication.shared.isIdleTimerDisabled = false

    dismissThen {
      IptvsIosPlayerPlugin.current?.emitEngineFailed(
        reason: reason,
        positionMs: PlaybackEventPayload.normalizedMs(positionMs),
        pipWasActive: pipWasActive
      )
    }
  }

  // MARK: - Debug soak

  private func scheduleSoakAutoCloseIfRequested() {
    #if DEBUG
      guard soakAutoCloseTimer == nil, let soakMs = request.soakAutoCloseMs else { return }
      // Debug-only, and inert unless Dart sent the extra: lets
      // `integration_test/player_soak_test.dart` cycle the native surface
      // unattended, exactly as `EXTRA_SOAK_AUTOCLOSE_MS` does on Android.
      soakAutoCloseTimer = Timer.scheduledTimer(
        withTimeInterval: TimeInterval(soakMs) / 1_000,
        repeats: false
      ) { [weak self] _ in
        self?.finish()
      }
    #endif
  }

  // MARK: - Channel

  private func emit(_ payload: [String: Any]) {
    channel?.invokeMethod(PlaybackEventPayload.method, arguments: payload)
  }
}

// MARK: - IptvsPipStateProviding

extension IptvsPlayerViewController: IptvsPipStateProviding {
  var isPictureInPictureActive: Bool { pictureInPictureActive }
}

// MARK: - UIGestureRecognizerDelegate

extension IptvsPlayerViewController: UIGestureRecognizerDelegate {
  /// Let controls handle their own touches. Without this the tap-to-toggle
  /// recogniser competes with every button in the overlay.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    !(touch.view is UIControl)
  }
}
