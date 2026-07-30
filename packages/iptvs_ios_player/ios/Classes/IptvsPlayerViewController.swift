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
/// **Scope so far.** Steps 3–5: the presentation, the engine, the
/// `nativeClosed` round-trip, and the full control overlay
/// (`PlayerControlsView` + `ListMenuView` + `InfoPanelView`, all rendering from
/// one `PlayerChromeState`). The controller itself holds no chrome policy — it
/// translates overlay actions into engine calls and state edits, and every
/// decision it appears to make (the ladder, auto-hide, which control exists) is
/// a `Core` function `swift test` already covers.
///
/// **Still to attach**, each marked with a `MARK: Step N attaches here` at the
/// exact call site: the audio session and Now Playing (6), Picture-in-Picture
/// (7), the live reconnect watchdog and the `resolveAgain` round trip (8), and
/// colorimetry/stream-info plus the audio/subtitle track lists (9). The chrome
/// for all four is written and inert — the PiP button, the "Reconnecting…"
/// chip, the HDR/fps badges, the info panel and the two track menus render
/// nothing until their step supplies the state.
final class IptvsPlayerViewController: UIViewController {
  private let request: PlayerOpenRequest
  private weak var channel: FlutterMethodChannel?
  private let engine = AvPlayerEngine()

  private let videoView = PlayerLayerView()
  private let controlsView = PlayerControlsView()

  // MARK: Chrome state
  //
  // The whole overlay renders from one `PlayerChromeState` (in `Core`, where
  // `swift test` can reach every derived rule), held in the `PlayerUiState` box
  // so that one mutation means one render. `handleBack`/`videoTapped` read
  // `menu`/`infoOpen`/`controlsVisible` straight off it, which is what makes the
  // Back ladder live rather than inert.
  private let uiState: PlayerUiState

  /// Fires the auto-hide. Re-armed on every interaction and on every change to
  /// the (visible, pinned, playing) triple — never on a plain progress tick,
  /// which would re-arm it twice a second and mean it never fired at all.
  private var autoHideTimer: Timer?
  private var autoHideKey: AutoHideKey?

  private struct AutoHideKey: Equatable {
    let controlsVisible: Bool
    let pinned: Bool
    let isPlaying: Bool
  }

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
    uiState = PlayerUiState(PlayerChromeState(request: request))
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    isModalInPresentation = true
    // Required for `prefersStatusBarHidden` to be honoured: `.overFullScreen`
    // is not a "fullscreen" presentation as far as status-bar appearance is
    // concerned, so without this the bar keeps whatever the Flutter view
    // controller last asked for.
    modalPresentationCapturesStatusBarAppearance = true
    uiState.onChange = { [weak self] state in
      self?.render(state)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("IptvsPlayerViewController is created in code, never from a nib")
  }

  deinit {
    soakAutoCloseTimer?.invalidate()
    autoHideTimer?.invalidate()
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
    // Video is full-bleed: it may run under the notch/Dynamic Island, which is
    // the whole point of not letterboxing away from the cutout (Android sets
    // LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES for the same reason).
    videoView.translatesAutoresizingMaskIntoConstraints = false
    videoView.playerLayer.player = engine.player
    videoView.playerLayer.videoGravity = .resizeAspect
    view.addSubview(videoView)

    // The overlay is *also* full-bleed, and owns the scrim/controls split
    // internally: its gradient scrim reaches the physical edges while every
    // control lives inside its `safeAreaLayoutGuide`. Step 3's plain dim band +
    // lone X are gone; the split they existed to establish is unchanged.
    controlsView.onAction = { [weak self] action in
      self?.handle(action)
    }
    view.addSubview(controlsView)

    NSLayoutConstraint.activate([
      videoView.topAnchor.constraint(equalTo: view.topAnchor),
      videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      controlsView.topAnchor.constraint(equalTo: view.topAnchor),
      controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
    // Both of these matter, and now more than ever: without them a tap
    // recogniser on the ancestor view swallows or cancels the *whole overlay's*
    // button tracking, and every control reads as dead — a failure that looks
    // like broken wiring rather than a gesture-arena problem. See the delegate
    // at the bottom of this file for the other half.
    tap.cancelsTouchesInView = false
    tap.delegate = self
    view.addGestureRecognizer(tap)

    // Paint the seeded state before the first frame, so the bar is populated
    // (title, LIVE pill, favorite star) rather than appearing a tick later.
    render(uiState.value)
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
    applyToChrome(event)
    emit(
      PlaybackEventPayload.playbackState(
        event,
        positionMs: engine.positionMs,
        durationMs: engine.durationMs,
        message: message
      )
    )
  }

  /// Folds an engine state transition into the chrome. One `batch` per event, so
  /// a transition that moves several fields still renders once.
  private func applyToChrome(_ event: PlaybackStateEvent) {
    uiState.batch { state in
      switch event {
      case .started:
        state.isPlaying = true
        state.isBuffering = false
        state.ended = false
        // A fresh start is by definition at the live edge — this is what clears
        // the greyed LIVE pill and the go-to-live button after a reload.
        if state.isLive { state.liveSynced = true }
      case .stalled:
        state.isBuffering = true
      case .resumed:
        state.isBuffering = false
      case .ended:
        state.ended = true
        state.isPlaying = false
      case .dropped:
        state.isPlaying = false
      }
    }
  }

  private func handleProgressTick() {
    // The scrubber, its time labels and the live EPG progress bar all redraw off
    // this tick, which is why the engine samples at 500 ms (Android's ticker
    // cadence) rather than at the 1 Hz the Dart emit below uses. `PlayerUiState`
    // diffs, so a tick that moves nothing costs one struct comparison and no
    // layout at all.
    let positionMs = engine.positionMs
    let durationMs = engine.durationMs
    let playing = engine.isPlaying
    let buffering = engine.isBuffering
    // `presentationSize` is `.zero` until the first frame decodes, and
    // `resolutionBadge` is nil for a zero size, so the badge simply appears when
    // the picture does.
    //
    // MARK: Step 9 attaches here.
    //
    // `fps`, `dynamicRange`, `videoCodec`, `audioCodec`/`audioChannels` are the
    // remaining `PlayerChromeState` stream-info fields, and everything that
    // renders them — the HDR and fps badges, the whole info panel — is already
    // written and simply shows nothing while they are empty. Feed them from the
    // item's track format descriptions here (or from a `readyToPlay` one-shot,
    // since they don't change mid-item), and build the label itself with
    // `dynamicRangeLabel(gamma:primaries:matrix:)` from Core rather than
    // assembling a string, so the iOS badge text agrees with the Android,
    // Windows and Linux ones by construction. Note HDR10+ is permanently
    // absent on this platform (docs/ios.md "Known parity gaps").
    let size = engine.presentationSize
    uiState.batch { state in
      state.positionMs = positionMs
      state.durationMs = durationMs
      state.isPlaying = playing
      state.isBuffering = buffering
      state.videoWidth = Int(size.width)
      state.videoHeight = Int(size.height)
    }

    let second = positionMs / 1_000
    guard second != lastEmittedProgressSecond else { return }
    lastEmittedProgressSecond = second
    emit(
      PlaybackEventPayload.progress(
        positionMs: positionMs,
        durationMs: durationMs,
        playing: playing,
        buffering: buffering
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

  // MARK: - Chrome

  /// The single render entry point. Every state change funnels here through
  /// `PlayerUiState.onChange`, so there is exactly one place that turns state
  /// into pixels and exactly one place that re-evaluates the auto-hide clock.
  private func render(_ state: PlayerChromeState) {
    // Wall clock read here rather than inside the view: the EPG progress bar is
    // the only thing that needs it, and a view with a hidden time dependency is
    // a view that can't be reasoned about from its inputs.
    controlsView.render(state, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    syncAutoHide(state)
  }

  // MARK: Overlay actions

  private func handle(_ action: PlayerControlsAction) {
    // Every control press is an interaction, exactly as Kotlin's `onInteract()`
    // runs on every button: it re-arms the auto-hide clock and, if the chrome
    // was on its way out, keeps it up.
    pokeControls()

    switch action {
    case .close:
      // Parity with every other platform: the visible close control is an
      // explicit Exit and skips the peel ladder (docs/player.md — "the
      // on-screen back-*arrow* button still exits directly"; docs/tv-navigation
      // .md — "The overlay's **X** is a dedicated Exit control that skips the
      // ladder entirely").
      finish()
    case .playPause:
      togglePlayPause()
    case .seekBy(let deltaMs):
      seekBy(deltaMs)
    case .seekToFraction(let fraction):
      seekToFraction(fraction)
    case .toggleMute:
      toggleMute()
    case .toggleFavorite:
      // Local-only, reported back on `nativeClosed` — the controller has no
      // live channel to the Dart favorites store (docs/player.md "Live favorite
      // star").
      uiState.value.isFavorite.toggle()
    case .goLive:
      goToLive()
    case .cycleAspect:
      cycleAspect()
    case .enterPictureInPicture:
      // MARK: Step 7 attaches here — `pictureInPictureController?
      // .startPictureInPicture()`. The button is hidden until that step sets
      // `supportsPip`, so this case is unreachable today.
      break
    case .toggleMenu(let menu):
      uiState.batch { $0.toggleMenu(menu) }
    case .toggleInfo:
      uiState.batch { $0.toggleInfo() }
    case .selectMenuOption(let id):
      selectMenuOption(id)
    }
  }

  private func togglePlayPause() {
    if engine.isPlaying {
      engine.pause()
      uiState.batch { state in
        state.isPlaying = false
        // Pausing live drops you behind the edge: grey the LIVE pill and reveal
        // go-to-live, matching the Android and Windows overlays.
        if state.isLive { state.liveSynced = false }
      }
    } else {
      engine.play()
      applyPlaybackSpeed()
      uiState.value.isPlaying = true
    }
  }

  private func seekBy(_ deltaMs: Int64) {
    // Belt and braces behind `showSkipButtons`: live is never seekable here.
    guard !request.isLive else { return }
    engine.seek(toMs: max(0, engine.positionMs + deltaMs))
  }

  private func seekToFraction(_ fraction: Double) {
    guard !request.isLive else { return }
    let duration = engine.durationMs
    guard duration > 0 else { return }
    engine.seek(toMs: Int64(Double(duration) * min(max(fraction, 0), 1)))
  }

  private func toggleMute() {
    let muted = !uiState.value.muted
    // No volume slider on iOS — the hardware buttons and the AirPlay route
    // picker own volume (docs/ios.md). Mute has no hardware equivalent, so it
    // stays.
    engine.player.isMuted = muted
    uiState.value.muted = muted
  }

  private func cycleAspect() {
    uiState.batch { $0.cycleAspect() }
    videoView.playerLayer.videoGravity =
      uiState.value.aspect == .fill ? .resizeAspectFill : .resizeAspect
  }

  /// Applies the chosen speed to the player. VOD only, and only while already
  /// playing — writing `rate` on a paused player *starts* it, which would turn
  /// "pick a speed" into "pick a speed and resume".
  private func applyPlaybackSpeed() {
    guard !request.isLive else { return }
    let speed = Float(uiState.value.speed)
    guard speed != 1, engine.player.rate != 0 else { return }
    engine.player.rate = speed
  }

  private func selectMenuOption(_ id: String) {
    switch uiState.value.menu {
    case .speed:
      guard let speed = Double(id) else { return }
      uiState.batch { state in
        state.speed = speed
        state.menu = .none
      }
      applyPlaybackSpeed()
    case .audio:
      // MARK: Step 9 attaches here — `AVPlayerItem.select(_:in:)` against the
      // `.audible` media-selection group. The menu, its rows and this callback
      // are complete; nothing populates `audioTracks` yet, so
      // `showAudioButton` keeps the button hidden and this case is unreachable
      // today. The option ids must be whatever key that step uses to find the
      // `AVMediaSelectionOption` again.
      uiState.batch { state in
        state.selectedAudioId = id
        state.menu = .none
      }
    case .subtitles:
      // MARK: Step 9 attaches here too — the `.legible` group, plus the
      // `playerSubtitleOffId` sentinel mapping to `select(nil, in:)`. External
      // sidecar tracks (`request.subtitles`) additionally need an
      // `AVMutableComposition`, which is why `AvPlayerEngine.load` already
      // takes them and ignores them.
      uiState.batch { state in
        state.selectedSubtitleId = id
        state.menu = .none
      }
    case .none:
      break
    }
  }

  /// Jump back to the live edge.
  ///
  /// Prefers a seek to the end of the item's seekable window: it keeps the
  /// current connection and the current locator, where a reload would need a
  /// fresh one. Falls back to reloading the URL this controller holds.
  ///
  /// MARK: Step 8 attaches here — that fallback must become the `resolveAgain`
  /// round trip into Dart *before* the reload. A Stalker `play_token` is
  /// single-use, so re-opening the URL this controller is holding can never
  /// succeed after a portal-side kill (docs/player.md "Live reloads
  /// re-resolve"). The same call is what the reconnect watchdog will make.
  private func goToLive() {
    guard request.isLive else { return }
    if let edgeMs = liveEdgeMs() {
      engine.seek(toMs: edgeMs)
    } else {
      load(url: request.url, headers: request.headers)
    }
    uiState.value.liveSynced = true
  }

  /// End of the item's last seekable range, in ms, or nil when the stream
  /// exposes no window (a non-seekable live feed).
  private func liveEdgeMs() -> Int64? {
    guard let item = engine.player.currentItem else { return nil }
    guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
    let ms = AvPlayerEngine.milliseconds(from: CMTimeRangeGetEnd(range))
    return ms > 0 ? ms : nil
  }

  // MARK: Tap ladder

  /// A tap on the scrim or the exposed video.
  ///
  /// **This is the iOS Back ladder** (docs/tv-navigation.md, Back-ladder
  /// section): with no hardware Back, touch is the ladder's input — a tap
  /// outside the chrome peels menu → info exactly as Back does elsewhere, and a
  /// tap with the chrome hidden reveals it rather than exiting. `playerTapAction`
  /// is defined in Core *as* `nextPlayerBackAction` with its terminal rung
  /// swapped, so the two can never disagree about rung order.
  @objc private func videoTapped() {
    let state = uiState.value
    switch playerTapAction(
      menuOpen: state.menu != .none,
      infoOpen: state.infoOpen,
      controlsVisible: state.controlsVisible
    ) {
    case .closeMenu:
      uiState.batch { $0.menu = .none }
    case .closeInfo:
      uiState.batch { $0.infoOpen = false }
    case .hideControls:
      uiState.batch { $0.setControlsVisible(false) }
    case .showControls:
      pokeControls()
    }
  }

  /// The Back ladder proper, kept for any Back-*equivalent* input this
  /// controller grows (a Dart-driven close-with-peel, a hardware keyboard's
  /// Escape on an iPad). Kept here rather than inline in a handler for the same
  /// reason Android keeps it in `PlayerBackPolicy`: one press must never be
  /// interpreted once by a control and again by the screen.
  func handleBack() {
    let state = uiState.value
    switch nextPlayerBackAction(
      menuOpen: state.menu != .none,
      infoOpen: state.infoOpen,
      controlsVisible: state.controlsVisible
    ) {
    case .closeMenu:
      uiState.batch { $0.menu = .none }
    case .closeInfo:
      uiState.batch { $0.infoOpen = false }
    case .hideControls:
      uiState.batch { $0.setControlsVisible(false) }
    case .exit:
      finish()
    }
  }

  // MARK: Auto-hide

  /// Re-arms the auto-hide clock whenever the (visible, pinned, playing) triple
  /// changes — and *only* then.
  ///
  /// The subtlety worth stating: `render` runs on every progress tick, so
  /// re-arming unconditionally from here would push the deadline out twice a
  /// second and the controls would never hide at all. Kotlin gets this for free
  /// from `LaunchedEffect`'s key list; this is the same key list, compared by
  /// hand.
  private func syncAutoHide(_ state: PlayerChromeState) {
    let key = AutoHideKey(
      controlsVisible: state.controlsVisible,
      pinned: state.pinned,
      isPlaying: state.isPlaying
    )
    guard key != autoHideKey else { return }
    autoHideKey = key
    armAutoHide(state)
  }

  private func armAutoHide(_ state: PlayerChromeState) {
    autoHideTimer?.invalidate()
    autoHideTimer = nil
    guard
      PlayerAutoHide.shouldSchedule(
        controlsVisible: state.controlsVisible,
        pinned: state.pinned,
        isPlaying: state.isPlaying
      )
    else { return }
    // Block form, not target/action: a `Timer` retains its target, and this one
    // outlives nothing.
    autoHideTimer = Timer.scheduledTimer(
      withTimeInterval: TimeInterval(PlayerAutoHide.delayMs(isLive: state.isLive)) / 1000,
      repeats: false
    ) { [weak self] _ in
      self?.uiState.batch { $0.setControlsVisible(false) }
    }
  }

  /// Interaction: show the chrome and restart its clock. The forced re-arm is
  /// why this exists separately from `syncAutoHide` — tapping a button while
  /// the controls are already up changes none of the three keys, but must still
  /// buy another few seconds.
  private func pokeControls() {
    uiState.batch { $0.setControlsVisible(true) }
    armAutoHide(uiState.value)
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
    autoHideTimer?.invalidate()
    autoHideTimer = nil
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
    autoHideTimer?.invalidate()
    autoHideTimer = nil
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
      map["favorite"] = uiState.value.isFavorite
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
    autoHideTimer?.invalidate()
    autoHideTimer = nil
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
  /// Decides what counts as a tap on *exposed video or scrim* — the only thing
  /// the tap ladder should act on.
  ///
  /// Two exclusions, and both are load-bearing:
  ///
  /// - **`UIControl`.** Every button and the scrubber are `UIControl`s. Without
  ///   this the root recogniser competes with their own tracking and they read
  ///   as dead — the classic version of this bug, and the reason
  ///   `cancelsTouchesInView = false` alone is not enough.
  /// - **``PlayerTapAbsorbing``** (the list menu and the info panel). A tap
  ///   *inside* an open panel is not a tap outside it, and treating it as one
  ///   would let the panel dismiss itself on its own hit — exactly the case the
  ///   Windows/embedded overlay calls out ("the panel itself absorbs taps so it
  ///   isn't re-closed by its own hit", docs/player.md).
  ///
  /// Walks ancestors rather than testing `touch.view` alone, because the hit
  /// view is often a decorative subview: a label inside a menu row, or the
  /// stack view inside the info panel. Stops at the controller's own view so
  /// the walk is bounded.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    var node = touch.view
    while let current = node, current !== view {
      if current is UIControl { return false }
      if current is PlayerTapAbsorbing { return false }
      node = current.superview
    }
    return true
  }
}
