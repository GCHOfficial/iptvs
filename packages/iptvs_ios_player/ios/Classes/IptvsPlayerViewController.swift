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
/// **Scope so far.** Steps 3–7: the presentation, the engine, the
/// `nativeClosed` round-trip, the full control overlay (`PlayerControlsView` +
/// `ListMenuView` + `InfoPanelView`, all rendering from one
/// `PlayerChromeState`), the audio session with Now Playing and the system
/// remote transport (`IosAudioSession`), and Picture-in-Picture
/// (`IosPipController`). The controller itself holds no chrome policy — it
/// translates overlay actions into engine calls and state edits, and every
/// decision it appears to make (the ladder, auto-hide, which control exists,
/// what the lock screen says, what a PiP stop means) is a `Core` function
/// `swift test` already covers.
///
/// Step 6 is the one that makes an install audible: without an activated
/// `.playback` session the process sits in `soloAmbient` and there is no sound
/// at all on a phone with the ring switch on silent, however good the chrome
/// looks. `IosAudioSession` is now the process's *only* owner of
/// `AVAudioSession` — `iosManageAudioSession: false` at both Dart
/// `PlayerConfiguration` sites means mpv no longer touches it either, so the
/// **fallback engine depends on this class as well** (docs/ios.md Constraint 1).
///
/// Steps 8 and 9 complete it: the live reconnect watchdog with its `resolveAgain`
/// round trip into Dart, and the colorimetry/stream-info read plus the
/// audio/subtitle media selection. Both follow the same rule as everything
/// above them — the decision lives in `Core` (`LiveReconnectWatchdog`,
/// `iosStreamInfo`), this class only applies it — so the parts that can be
/// tested without a device are.
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

  /// Redraws the chrome so the top bar's clock badge stays honest.
  ///
  /// Needed because every other render trigger is a *playback* event: the
  /// progress tick fires off the timebase, so a **paused** player renders
  /// nothing at all — and a paused player is exactly the case where the chrome
  /// is pinned up indefinitely (`PlayerAutoHide.shouldSchedule` refuses to
  /// schedule while paused), so a frozen clock would sit on screen for as long
  /// as the viewer left it there.
  ///
  /// 10s to match the Android overlay's clock `LaunchedEffect`, which ticks at
  /// the same rate for the same reason: an `HH:mm` badge only ever needs
  /// minute-granularity, so anything faster is churn.
  private var clockTicker: Timer?
  private static let clockTickInterval: TimeInterval = 10

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
  ///
  /// Driven from the `AVPictureInPictureControllerDelegate` did-start/did-stop
  /// callbacks, and forced to `false` synchronously when a teardown stops PiP —
  /// `reportEngineFailed` must not ship a snapshot claiming PiP is running when
  /// it has just been stopped, because Dart reads that snapshot as authoritative
  /// and would veto its own fallback on it (docs/ios.md "Stop PiP before
  /// emitting `engineFailed`").
  private(set) var pictureInPictureActive = false

  /// Picture-in-Picture, or nil when the device cannot do it at all — which is
  /// **every Simulator**. A nil here keeps `supportsPip` false, the button
  /// hidden and `.enterPictureInPicture` unreachable, so a simulator run
  /// exercises everything else exactly as a device would.
  private var pipController: IosPipController?

  /// True between `restoreUserInterfaceForPictureInPictureStop` and the
  /// following `didStop`. It is the difference between "the user tapped restore"
  /// (re-present, keep playing) and "the user closed the PiP window" (finish, so
  /// the Dart route pops instead of dead-ending on a black screen).
  private var restoringFromPictureInPicture = false

  /// Lock-screen / Control-Centre transport. Enabled on `viewDidAppear`,
  /// disabled on every exit path — `MPRemoteCommandCenter` is a process-wide
  /// singleton, so a target left wired outlives this controller.
  private let nowPlaying = IosNowPlayingCenter()

  /// This controller's audio-session claim.
  ///
  /// **Per-instance, not the bare constant.** Two controllers coexist for a
  /// moment when one `open` replaces another (`presentPlayer` force-closes the
  /// old one and presents the new one from its dismissal completion), and with a
  /// shared id the outgoing controller's teardown would drop the incoming one's
  /// claim and deactivate the session under it.
  private let audioClientId =
    "\(AudioSessionClientId.fullscreenPlayer)#\(UUID().uuidString)"

  private var soakAutoCloseTimer: Timer?
  private var pendingResumeMs: Int64?
  private var lastEmittedProgressSecond: Int64 = -1

  // MARK: Live reconnect watchdog (step 8)

  /// The pure decision half, in `Core`. This class supplies the clock and the
  /// engine facts and does what it is told.
  private var watchdog: LiveReconnectWatchdog

  /// The "this load never produced a frame" backstop — docs/ios.md's third
  /// `engineFailed` detection shape, and the one thing that keeps a VOD open
  /// from hanging forever behind chrome on a black screen.
  ///
  /// Polled from the **same ticker** as `watchdog`, immediately before it, so
  /// the two decisions are evaluated in a fixed order on one instant. They can
  /// never both act: `PlaybackStartBackstop` owns the window before AVPlayer has
  /// ever produced a frame and `LiveReconnectWatchdog` owns everything after,
  /// split by `AvPlayerEngine.hasEverStarted` rather than by comparing their
  /// thresholds. See `PlaybackStartBackstop`'s type doc for the full argument.
  private var startBackstop: PlaybackStartBackstop

  /// The "this load plays but shows nothing" backstop — docs/ios.md's *second*
  /// `engineFailed` detection shape, and the one the other two structurally
  /// cannot see.
  ///
  /// An item rendering no picture still reaches `.playing`, so `hasEverStarted`
  /// latches, `startBackstop` disarms, and `watchdog` sees a full buffer and a
  /// moving timebase — healthy, by every signal either of them reads. This one
  /// owns the remaining window: **started, healthy, and no picture**, which is
  /// complementary to the reconnect watchdog's `isBuffering || ended` on one
  /// boolean, so at most one of the three can act on any tick. See
  /// `VideoPresenceBackstop`'s type doc for the full argument.
  private var videoBackstop = VideoPresenceBackstop()

  /// The 500 ms watchdog tick, mirroring Android's progress-ticker cadence.
  ///
  /// **A `Timer`, deliberately not `AvPlayerEngine.onProgressTick`**, even though
  /// that already runs at 500 ms and is where Android's equivalent lives.
  /// `AVPlayer.addPeriodicTimeObserver` fires against the *timebase*: when
  /// playback stalls or the item fails, the timebase stops and the callback
  /// stops with it — precisely the condition the watchdog exists to notice. A
  /// watchdog that can only run while playback is healthy is not a watchdog.
  ///
  /// Runs for **VOD as well as live** now that it also drives `startBackstop`;
  /// on VOD it stops itself the moment that backstop disarms, so an ordinary
  /// film does not carry a 2 Hz no-op timer for two hours.
  private var reconnectTicker: Timer?

  /// True from a hard `.dropped` until the engine reports playing again.
  ///
  /// The engine's own `isBuffering` does **not** cover a drop (an `AVPlayerItem`
  /// that failed mid-playback stops reporting buffer state entirely), and the
  /// chrome's copy is overwritten from the engine on every progress tick, so
  /// neither can carry this. Kotlin gets it for free because ExoPlayer sits in
  /// `STATE_BUFFERING`/`STATE_IDLE` after an error.
  private var liveDropped = false

  /// Guards against a second reload starting while a `resolveAgain` round trip
  /// is still in flight — otherwise the watchdog's 500 ms tick, a "Go to live"
  /// press and a Retry from the error surface could each ask the portal for a
  /// locator at the same time, which on a single-connection account is exactly
  /// the `create_link` storm the backoff exists to prevent. Shared by all three
  /// for that reason, despite the `live` in the name.
  private var liveReloadInFlight = false

  /// Monotonic token for the in-flight `resolveAgain`, so the reply and the
  /// timeout race for one settlement and the loser is discarded — the same
  /// idiom as `ChannelHandlerOwner`'s owner token and the repo's generation
  /// guards.
  private var resolveSequence = 0
  private var resolveTimer: Timer?
  private var pendingResolveCompletion: ((FreshLocator) -> Void)?

  // MARK: Stream info (step 9)

  /// Latched once the item has told us something real. Colorimetry, codecs and
  /// the track lists are properties of the item, not of the moment, so they are
  /// read until they answer and then left alone rather than re-derived twice a
  /// second — the same "derive once, then freeze" shape Android's fps
  /// measurement uses.
  private var streamInfoResolved = false
  private var streamInfoAttempts = 0

  /// ~10s of ticks after the first frame. A stream that has not described itself
  /// by then never will (audio-only, or a provider HLS ladder with no usable
  /// attributes), and retrying forever would touch AVFoundation's loadable
  /// properties on the main thread twice a second for the whole session.
  private static let streamInfoMaxAttempts = 20

  init(request: PlayerOpenRequest, channel: FlutterMethodChannel?) {
    self.request = request
    self.channel = channel
    // Provider-declared liveness, never inferred — a VOD watchdog is inert by
    // construction rather than by a guard someone can forget.
    watchdog = LiveReconnectWatchdog(isLive: request.isLive)
    startBackstop = PlaybackStartBackstop(isLive: request.isLive)
    uiState = PlayerUiState(PlayerChromeState(request: request))
    super.init(nibName: nil, bundle: nil)
    IosDebugCounters.increment(.playerControllers)
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
    clockTicker?.invalidate()
    // A repeating `Timer` is retained by the run loop, not by this object, so an
    // un-invalidated one keeps firing (against a nil `weak self`) for the rest of
    // the process. Every exit path already stops it; this is the backstop for a
    // controller torn down some other way.
    stopLiveWatchdog()
    engine.release()
    // Belt and braces. Every exit path already runs `releasePlaybackServices`,
    // but a controller that is deallocated some other way must not leave the
    // process-wide audio session activated for a player that no longer exists.
    // Safe because the claim id is per-instance: releasing an id nobody holds is
    // a no-op, so this can never deactivate a *newer* controller's session
    // (`AudioSessionPolicyTests.testPrefixedControllerIdsAreIndependentClaims`).
    IosAudioSession.shared.release(audioClientId)
    IosDebugCounters.decrement(.playerControllers)
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
    // After `buildViewHierarchy`, which is what puts the `AVPlayer` on the
    // layer: `AVPictureInPictureController(playerLayer:)` needs a layer that
    // already has a player.
    setUpPictureInPicture()

    if request.resumeMs > 0 && !request.isLive {
      pendingResumeMs = request.resumeMs
    }
    // Arms the start backstop and the ticker as well as loading — every load in
    // this class goes through here so no path can start a stream without a clock
    // bounding it. Started here rather than in `viewDidAppear`, and never
    // stopped on disappearance: playback deliberately outlives visibility on
    // this platform (Picture-in-Picture, and background audio, which PiP
    // requires anyway), and a stream that drops while the app is in PiP must
    // still reconnect. Android can tie its ticker to `onStart`/`onStop` because
    // it pauses playback there; this controller does not.
    startPlayback(url: request.url, headers: request.headers)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Without this the screen sleeps mid-film; without the matching clear in
    // `viewDidDisappear` it stays awake for the rest of the process. Neither
    // failure is observable in the Simulator.
    UIApplication.shared.isIdleTimerDisabled = true
    // Idempotent on purpose: this runs again when a Picture-in-Picture restore
    // re-presents the controller.
    acquirePlaybackServices()
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
    startClockTicker()
  }

  /// See ``clockTicker``. `.common` run-loop mode for the same reason the
  /// watchdog ticker uses it: a menu being scrolled must not stop the clock.
  private func startClockTicker() {
    guard clockTicker == nil, !finishing else { return }
    let ticker = Timer(
      timeInterval: IptvsPlayerViewController.clockTickInterval,
      repeats: true
    ) { [weak self] _ in
      // Nothing to repaint when the chrome is down, and nothing on screen at all
      // while this controller is dismissed for Picture-in-Picture.
      guard let self, self.uiState.value.controlsVisible else { return }
      guard !self.dismissedForPictureInPicture else { return }
      // A pure repaint — no state mutation, so this cannot re-arm the auto-hide
      // clock (`syncAutoHide` keys on the (visible, pinned, playing) triple,
      // which none of this touches).
      self.render(self.uiState.value)
    }
    RunLoop.main.add(ticker, forMode: .common)
    clockTicker = ticker
  }

  private func stopClockTicker() {
    clockTicker?.invalidate()
    clockTicker = nil
  }

  // MARK: - Audio session, Now Playing, remote transport

  /// Claims the audio session and wires the system transport.
  ///
  /// **This is what makes the app audible.** Before it the process sits in the
  /// default `soloAmbient` category: muted by the ring switch, silent the
  /// instant the app leaves the foreground. `IosAudioSession` is the process's
  /// only owner of `AVAudioSession` now that `iosManageAudioSession: false`
  /// stops mpv touching it (docs/ios.md Constraint 1).
  ///
  /// Idempotent — the claim is a set membership, and `IosNowPlayingCenter.enable`
  /// guards on its own flag — because `viewDidAppear` runs again after a
  /// Picture-in-Picture restore.
  private func acquirePlaybackServices() {
    IosAudioSession.shared.acquire(audioClientId)
    IosAudioSession.shared.isPlayingProvider = { [weak self] in
      self?.engine.isPlaying ?? false
    }
    IosAudioSession.shared.onInterruption = { [weak self] reaction in
      self?.handleAudioInterruption(reaction)
    }

    nowPlaying.onPlay = { [weak self] in self?.resumeFromRemote() }
    nowPlaying.onPause = { [weak self] in self?.pauseFromRemote() }
    nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePlayPause() }
    nowPlaying.onSkip = { [weak self] deltaMs in self?.seekBy(deltaMs) }
    nowPlaying.onSeek = { [weak self] positionMs in
      guard let self, !self.request.isLive else { return }
      self.engine.seek(toMs: positionMs)
      self.refreshNowPlaying()
    }
    nowPlaying.enable(policy: remoteCommandPolicy(isLive: request.isLive))
    refreshNowPlaying()
  }

  /// Drops the claim and unwires the transport. Runs on **every** exit path —
  /// `finish`, `forceClose`, `reportEngineFailed` — because a claim left behind
  /// keeps the session activated for a player that no longer exists, and a
  /// remote-command target left behind keeps a dead closure wired to the user's
  /// headphone button for the rest of the process.
  private func releasePlaybackServices() {
    // Clear the callbacks before releasing so a late notification can't reach a
    // controller that is already tearing down. The closures capture `self`
    // weakly, so this is hygiene rather than a leak fix.
    IosAudioSession.shared.onInterruption = nil
    IosAudioSession.shared.isPlayingProvider = nil
    IosAudioSession.shared.release(audioClientId)
    nowPlaying.disable()
  }

  /// Publishes the current state to the lock screen / Control Centre.
  ///
  /// Called on transitions (start, play/pause, seek, reload) plus a slow
  /// periodic correction — deliberately **not** on every progress tick: the
  /// system extrapolates the elapsed time from the reported playback rate
  /// between updates, so a 2 Hz rewrite is pure churn.
  private func refreshNowPlaying() {
    let state = uiState.value
    nowPlaying.update(
      nowPlayingSnapshot(
        title: state.title,
        sourceName: state.sourceName,
        isLive: state.isLive,
        positionMs: engine.positionMs,
        durationMs: engine.durationMs,
        isPlaying: engine.isPlaying,
        speed: state.speed
      )
    )
  }

  /// A phone call, Siri, or a yanked pair of headphones.
  ///
  /// The decision itself is `audioInterruptionReaction` in `Core` (pinned by
  /// `AudioSessionPolicyTests`); this only applies it, and routes through the
  /// same chrome updates a button press would so the play/pause icon can't
  /// disagree with the engine.
  private func handleAudioInterruption(_ reaction: AudioInterruptionReaction) {
    switch reaction {
    case .pause:
      guard engine.isPlaying else { return }
      pauseFromRemote()
    case .resume:
      guard !engine.isPlaying else { return }
      resumeFromRemote()
    case .ignore:
      break
    }
  }

  /// Play/pause arriving from outside the overlay (lock screen, headphone
  /// button, an interruption ending). Same state edits as `togglePlayPause`,
  /// minus the chrome poke — there is no on-screen interaction to keep the
  /// controls up for, and the controller may not even be presented (PiP).
  private func resumeFromRemote() {
    engine.play()
    applyPlaybackSpeed()
    uiState.value.isPlaying = true
    refreshNowPlaying()
  }

  private func pauseFromRemote() {
    engine.pause()
    uiState.batch { state in
      state.isPlaying = false
      if state.isLive { state.liveSynced = false }
    }
    refreshNowPlaying()
  }

  // MARK: - Picture-in-Picture

  /// Builds the PiP controller, or leaves it nil where PiP does not exist.
  ///
  /// The nil case is not exceptional: it is every Simulator, and it must stay
  /// completely inert rather than fail — `supportsPip` stays false,
  /// `showPictureInPictureButton` keeps the button hidden, and the
  /// `.enterPictureInPicture` action is unreachable.
  ///
  /// PiP additionally needs `UIBackgroundModes = [audio]`
  /// (`ios/Runner/Info.plist`) and an activated `.playback` session; without
  /// either, `startPictureInPicture()` reports through `pipFailedToStart`
  /// instead of throwing — which is why that callback simply undoes the
  /// speculative bookkeeping and leaves playback exactly where it was.
  private func setUpPictureInPicture() {
    guard let controller = IosPipController(playerLayer: videoView.playerLayer) else { return }
    controller.delegate = self
    pipController = controller
    // `isPictureInPicturePossible` is false until an item with a video track is
    // ready, so the button appears a beat after playback starts rather than at
    // present time. The KVO observation is seeded with `.initial`, so this call
    // is only the belt-and-braces first value.
    syncPictureInPictureAvailability(controller.isPossible)
  }

  private func syncPictureInPictureAvailability(_ possible: Bool) {
    let supported = pipController != nil && IosPipController.isSupported
    uiState.value.supportsPip = shouldOfferPictureInPicture(
      isSupported: supported,
      isPossible: possible
    )
  }

  /// Stops PiP as part of a teardown and settles `pictureInPictureActive`
  /// **synchronously**.
  ///
  /// The synchronous part is the contract: `didStopPictureInPicture` arrives on
  /// a later runloop turn, and `reportEngineFailed` ships
  /// `currentHostVisibility()` on its payload immediately after calling this. A
  /// stale `pipActive: true` there is read by Dart as an authoritative veto and
  /// would defer the mpv fallback for no reason (docs/ios.md "Stop PiP before
  /// emitting `engineFailed`, not after").
  private func stopPictureInPictureForTeardown() {
    pipController?.stop()
    guard pictureInPictureActive else { return }
    pictureInPictureActive = false
    IptvsIosPlayerPlugin.current?.pictureInPictureStateChanged()
  }

  /// Drops the plugin's PiP-lifetime strong reference to this controller.
  ///
  /// **Deferred by one runloop turn on purpose.** That reference is frequently
  /// the *only* thing keeping this object alive — the plugin's `activeController`
  /// is weak and UIKit released it when the controller dismissed itself for PiP
  /// — so dropping it from inside one of this object's own methods would
  /// deallocate `self` mid-call. The async block's own capture of `self` is what
  /// bridges the gap.
  private func releasePictureInPictureRetain() {
    guard let plugin = IptvsIosPlayerPlugin.current else { return }
    DispatchQueue.main.async {
      plugin.releasePictureInPictureRetain(self)
    }
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
    applyToChrome(event)
    // Every one of these moves the reported playback rate, which is what the
    // lock screen extrapolates its elapsed time from — a stall that isn't
    // reported leaves the system counting forward through dead air.
    refreshNowPlaying()
    emit(
      PlaybackEventPayload.playbackState(
        event,
        positionMs: engine.positionMs,
        durationMs: engine.durationMs,
        message: message
      )
    )

    // The live reconnect watchdog's edge-triggered half; the level-triggered
    // half is `pollWatchdogs` on the 500 ms ticker.
    switch event {
    case .started:
      liveDropped = false
      // The handover between the two watchdogs, in one place: the start backstop
      // disarms for this load and the reconnect watchdog latches "AVPlayer can
      // play this". Both are also derived from `engine.hasEverStarted` on every
      // tick, so this is the prompt edge rather than the only path.
      startBackstop.markStarted()
      watchdog.markStarted()
      // …and the third window opens on the same edge. From here on the question
      // stops being "did this load start" and becomes "is it showing anything".
      videoBackstop.markStarted(nowMs: IptvsPlayerViewController.nowMs())
    case .resumed:
      liveDropped = false
    case .dropped:
      liveDropped = true
      switch playbackDropOutcome(isLive: request.isLive) {
      case .reconnect:
        // A hard player error while playing. Forced, so it skips the 8s stall
        // threshold — but `ReconnectPolicy.minGapMs` still rate-limits it, so a
        // stream erroring in a tight loop cannot become a `create_link` storm.
        // Direct port of Android wiring `onRecoverableError` to
        // `reconnectLive(force = true)`.
        if watchdog.forceReconnect(nowMs: IptvsPlayerViewController.nowMs()) == .reconnect {
          startLiveReload(showsReconnecting: true)
        }
      case .surfaceError:
        // VOD. Nothing else in this controller would ever act on it — the
        // reconnect watchdog is inert for VOD by construction — so without this
        // a mid-film failure left a stopped picture under working chrome and no
        // way forward but backing out.
        surfaceTerminalError(PlayerErrorMessages.playbackStopped)
      }
    case .ended:
      // **A clean server-side EOF on live is a drop, not an end**
      // (`shouldReconnectOnCompleted`) — live IPTV does not end, so a server
      // closing the connection has dropped it. Nothing forced here: the poll's
      // `ended` branch picks the faster `endedReconnectMs` threshold on its own,
      // which keeps a single decision point for *when*. A VOD `.ended` reaches a
      // watchdog constructed with `isLive: false` and is inert.
      break
    case .stalled:
      break
    }
  }

  // MARK: - Watchdogs (start backstop + live reconnect)

  private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  /// The **only** place a stream is handed to the engine.
  ///
  /// Every load — the initial open, a reconnect reload, "Go to live", a Retry
  /// from the error surface — arms the start backstop and (re-)starts the
  /// ticker, so there is no way to begin playback without a clock bounding it.
  /// That is the property that closes the original hole: the missing detector
  /// was missing precisely because nothing owned "a load that never became
  /// playback".
  private func startPlayback(url: String, headers: [String: String]) {
    startBackstop.markLoaded(nowMs: IptvsPlayerViewController.nowMs())
    // The mirror of the line above: the two backstops are always in opposite
    // states, because the video-presence window only opens at the first frame —
    // the same instant `startBackstop` closes.
    videoBackstop.markLoaded()
    startWatchdogTicker()
    engine.load(url: url, headers: headers, subtitles: request.subtitles)
  }

  private func startWatchdogTicker() {
    guard reconnectTicker == nil, !finishing else { return }
    // `.common` run-loop mode rather than `Timer.scheduledTimer`'s default:
    // scrolling an open track menu puts the main run loop in tracking mode, and
    // a watchdog that stops ticking while the user is scrolling is a watchdog
    // with a hole in it.
    let ticker = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.pollWatchdogs()
    }
    RunLoop.main.add(ticker, forMode: .common)
    reconnectTicker = ticker
  }

  private func stopWatchdogTicker() {
    reconnectTicker?.invalidate()
    reconnectTicker = nil
  }

  private func stopLiveWatchdog() {
    stopWatchdogTicker()
    resolveTimer?.invalidate()
    resolveTimer = nil
    pendingResolveCompletion = nil
    liveReloadInFlight = false
  }

  /// The level-triggered half of all three watchdogs, port of
  /// `HdrPlayerActivity.pollLiveReconnect` with the two backstops around it.
  ///
  /// Reads engine facts rather than chrome fields: `handleProgressTick`
  /// overwrites `PlayerChromeState.isBuffering` from the engine twice a second,
  /// so a chrome-derived watchdog would be reading its own echo.
  ///
  /// **Order is load-bearing, and it is an exclusion rather than a priority.**
  /// The backstop is asked first, but that alone would still be a race — a live
  /// stream that never starts looks stalled from the first tick, so
  /// `ReconnectPolicy.stallReconnectMs` (8s) would fire a reload before the
  /// backstop's 10s ever elapsed and AVPlayer would retry, forever, a container
  /// it has already proved it cannot play. What actually makes this
  /// deterministic is that `LiveReconnectWatchdog.poll` reports `.healthy` while
  /// `hasEverStarted` is false: the two own disjoint windows either side of that
  /// one monotonic fact, so at most one of them can act on any tick and the 8s
  /// and 10s figures never compete.
  ///
  /// `VideoPresenceBackstop` sits between them on the same construction — armed
  /// only at the current load's first frame (so it cannot overlap the start
  /// backstop) and acting only on `!isBuffering && !ended` (the complement of the
  /// reconnect watchdog's trigger). Three deciders, three disjoint windows, at
  /// most one action per tick, each boundary a boolean fact rather than a
  /// threshold comparison. Its position in the sequence is documentation, not the
  /// safety property.
  private func pollWatchdogs() {
    guard !finishing else { return }
    let nowMs = IptvsPlayerViewController.nowMs()
    let hasEverStarted = engine.hasEverStarted

    switch startBackstop.poll(hasEverStarted: hasEverStarted, nowMs: nowMs) {
    case .handOffEngine:
      // Nothing has ever played: the container is one AVFoundation accepted and
      // then could not decode. Hand it to mpv rather than retrying the engine
      // that already failed — `reportEngineFailed` tears down and dismisses, so
      // return immediately.
      reportEngineFailed(reason: PlaybackStartBackstop.engineFailedReason)
      return
    case .surfaceError:
      // A reload of a stream that *did* play never came back, and only VOD gets
      // here (live is the reconnect watchdog's, which is still retrying). No
      // handoff: the container is proven, so switching engines would downgrade a
      // working stream over what is really a network failure.
      surfaceTerminalError(PlayerErrorMessages.playbackStopped)
      return
    case .wait:
      break
    }

    // The second detection shape, in the window neither of the other two can
    // see. `reportEngineFailed` tears down and dismisses, so return immediately.
    if pollVideoPresence(nowMs: nowMs) { return }

    // VOD has nothing else on this ticker: the reconnect watchdog is inert for
    // VOD by construction, so don't even poll it. Once *both* backstops have
    // settled — first frame plus a picture, a fired decision, or the
    // video-presence give-up — stop the ticker rather than run it at 2 Hz for
    // the length of a film; a later Retry re-arms both through `startPlayback`.
    guard request.isLive else {
      if !startBackstop.isArmed, !videoBackstop.isArmed { stopWatchdogTicker() }
      return
    }

    switch watchdog.poll(
      hasEverStarted: hasEverStarted,
      isBuffering: engine.isBuffering || liveDropped,
      ended: engine.hasEnded,
      nowMs: nowMs
    ) {
    case .healthy:
      // Clearing the chip here rather than on `.started` is deliberate: the
      // engine reports `.started` the instant the timebase moves, which on a
      // half-recovered stream can precede the buffer actually holding.
      if uiState.value.reconnecting { uiState.value.reconnecting = false }
    case .wait:
      break
    case .reconnect:
      startLiveReload(showsReconnecting: true)
    }
  }

  /// docs/ios.md's **second** `engineFailed` detection shape: playback is
  /// healthy, the stream promised video, and nothing has ever appeared on the
  /// layer. Returns `true` when it fired, in which case the controller is already
  /// tearing down and the caller must stop touching it.
  ///
  /// The `isArmed` guard is not just an optimisation: it keeps the AVFoundation
  /// reads below off the ticker for the whole of a normal film, since the window
  /// settles as soon as a picture appears.
  private func pollVideoPresence(nowMs: Int64) -> Bool {
    guard videoBackstop.isArmed else { return false }
    let action = videoBackstop.poll(
      // Per-item, not `hasEverStarted`: the question is whether *this* item is
      // producing playback, which is exactly the boundary `startBackstop` uses.
      isPlaying: engine.hasStarted,
      isBuffering: engine.isBuffering || liveDropped,
      ended: engine.hasEnded,
      evidence: engine.declaredVideoEvidence,
      isPresentingVideo: isPresentingVideo,
      isSuppressed: isPictureSuppressed,
      nowMs: nowMs
    )
    guard action == .handOffEngine else { return false }
    reportEngineFailed(reason: VideoPresenceBackstop.engineFailedReason)
    return true
  }

  /// Any sign that a real picture exists, from the two independent facts iOS
  /// offers — **either one settles the window**, because the failure being
  /// detected is "never rendered", not "stopped rendering".
  ///
  /// `presentationSize` is a property of the *item* and `isReadyForDisplay` a
  /// property of the *layer*; requiring both to say "nothing" is what keeps a
  /// stream that renders in some way the other read misses from being handed off.
  private var isPresentingVideo: Bool {
    engine.presentationSize != .zero || videoView.playerLayer.isReadyForDisplay
  }

  /// The picture is legitimately somewhere other than this layer.
  ///
  /// Each of these makes a working video stream look picture-less from here, and
  /// handing off in any of them would be actively harmful — mpv has neither PiP
  /// nor AirPlay, so the "fix" would remove the very feature in use. Suppression
  /// only blocks firing; it never extends the window, so a load that spends its
  /// whole evaluation window suppressed gives up unjudged instead of firing the
  /// moment the user comes back.
  private var isPictureSuppressed: Bool {
    if pictureInPictureActive || dismissedForPictureInPicture { return true }
    if engine.isExternalPlaybackActive { return true }
    // A backgrounded app is not decoding video (background *audio* is the mode
    // this app declares). `nil` — no plugin to ask — reads as "active", the same
    // absence-is-not-a-veto rule `decideIosFallbackAction` applies to its own
    // native opinions.
    return !(IptvsIosPlayerPlugin.current?.currentHostVisibility().appActive ?? true)
  }

  /// Reloads the live stream **through a fresh locator**.
  ///
  /// This is the step Android's native watchdog does not have. Stalker
  /// `create_link` URLs carry single-use `play_token`s, so after a portal-side
  /// kill the URL this controller is holding is permanently dead and reloading
  /// it can never succeed — `HdrPlayerActivity.reconnectLive` retries exactly
  /// that URL, which is why a portal kill on Android needs the user to back out
  /// and re-enter the channel (docs/player.md "Live auto-reconnect").
  private func startLiveReload(showsReconnecting: Bool) {
    guard request.isLive, !finishing, !liveReloadInFlight else { return }
    liveReloadInFlight = true
    if showsReconnecting { uiState.value.reconnecting = true }
    resolveFreshLocator { [weak self] locator in
      guard let self else { return }
      self.liveReloadInFlight = false
      guard !self.finishing else { return }
      self.liveDropped = false
      self.load(url: locator.url, headers: locator.headers)
    }
  }

  /// Asks Dart for a freshly resolved live locator, **with a timeout**.
  ///
  /// The timeout is the whole reason this isn't a bare `invokeMethod`: the reply
  /// comes from a Dart route that may have popped, or from a `resolveAgain`
  /// callback that never completes, and a completion that never fires would
  /// leave the reconnect stalled forever behind `liveReloadInFlight`. On expiry
  /// the reload proceeds with the locator this controller already holds —
  /// mirroring `_freshLiveStream` falling back to `widget.stream` when
  /// `resolveAgain` is unwired or throws, so the *worst* case here is Android's
  /// current behaviour rather than a dead player.
  ///
  /// Reply and timeout race for one settlement through `resolveSequence`; the
  /// loser is discarded rather than applied to a reload that already happened.
  private func resolveFreshLocator(_ completion: @escaping (FreshLocator) -> Void) {
    guard let channel else {
      completion(currentLocatorFallback())
      return
    }
    resolveSequence &+= 1
    let token = resolveSequence
    pendingResolveCompletion = completion

    resolveTimer?.invalidate()
    let timer = Timer(
      timeInterval: TimeInterval(LiveReconnectWatchdog.resolveTimeoutMs) / 1000,
      repeats: false
    ) { [weak self] _ in
      self?.settleResolve(token: token, locator: nil)
    }
    RunLoop.main.add(timer, forMode: .common)
    resolveTimer = timer

    // `ChannelHandlerOwner`'s wrapper propagates the Dart return value straight
    // back here; a superseded owner answers nothing, which lands on the timeout.
    channel.invokeMethod("resolveAgain", arguments: nil) { [weak self] reply in
      self?.settleResolve(token: token, locator: FreshLocator(reply: reply))
    }
  }

  private func settleResolve(token: Int, locator: FreshLocator?) {
    guard token == resolveSequence else { return }
    // Consume the token so the losing path becomes a no-op.
    resolveSequence &+= 1
    resolveTimer?.invalidate()
    resolveTimer = nil
    let completion = pendingResolveCompletion
    pendingResolveCompletion = nil
    completion?(locator ?? currentLocatorFallback())
  }

  /// The locator to reload when Dart can't supply a fresh one — the `open`
  /// payload's, exactly as Dart falls back to `widget.stream` rather than to
  /// anything it re-resolved since.
  private func currentLocatorFallback() -> FreshLocator {
    FreshLocator(url: request.url, headers: request.headers)
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
        // Playback is the only thing that clears a surfaced terminal error: a
        // Retry that actually worked must not leave the overlay sitting over
        // moving video.
        state.errorMessage = nil
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
    let size = engine.presentationSize
    // Colorimetry, codecs and the track lists, read until the item answers and
    // then latched (see `streamInfoResolved`). Folded into the same `batch` as
    // the tick below so a resolve costs one render, not two.
    let streamInfo = resolveStreamInfoIfNeeded()
    uiState.batch { state in
      state.positionMs = positionMs
      state.durationMs = durationMs
      state.isPlaying = playing
      state.isBuffering = buffering
      state.videoWidth = Int(size.width)
      state.videoHeight = Int(size.height)
      if let streamInfo { streamInfo.apply(to: &state) }
    }

    let second = positionMs / 1_000
    guard second != lastEmittedProgressSecond else { return }
    lastEmittedProgressSecond = second
    // Slow correction for the lock screen's extrapolated clock. Every 5s rather
    // than every tick: the system already advances the elapsed time itself from
    // the reported rate, and rewriting `nowPlayingInfo` at 2 Hz is churn with a
    // visible cost (the Control Centre scrubber jitters).
    if second % 5 == 0 { refreshNowPlaying() }
    emit(
      PlaybackEventPayload.progress(
        positionMs: positionMs,
        durationMs: durationMs,
        playing: playing,
        buffering: buffering
      )
    )
  }

  // MARK: - Stream info + media selection

  /// One resolved read of everything the item can say about itself.
  private struct StreamInfoUpdate {
    let info: IosStreamInfo
    let audioTracks: [PlayerTrackOption]
    let selectedAudioId: String?
    let subtitleTracks: [PlayerTrackOption]
    let selectedSubtitleId: String?

    func apply(to state: inout PlayerChromeState) {
      state.fps = info.fps
      state.dynamicRange = info.dynamicRange
      state.videoCodec = info.videoCodec
      state.audioCodec = info.audioCodec
      state.audioChannels = info.audioChannels
      state.audioTracks = audioTracks
      state.selectedAudioId = selectedAudioId
      state.subtitleTracks = subtitleTracks
      state.selectedSubtitleId = selectedSubtitleId
    }
  }

  /// Reads colorimetry/codecs/tracks until the item answers, then latches.
  ///
  /// Gated on `engine.hasStarted` before the attempt budget is even touched:
  /// AVFoundation's synchronous property accessors are views of asynchronously
  /// loaded state, and touching them before the asset is loaded can block the
  /// main thread. After the first frame every read here is a cache hit.
  ///
  /// **Dart stays the label authority in spirit.** Nothing here assembles a
  /// string: the raw tags go to `Core`'s ``iosStreamInfo(format:edrHeadroom:)``,
  /// which routes through the very
  /// ``dynamicRangeLabel(gamma:primaries:matrix:hdr10Plus:)`` port that
  /// `DynamicRangeLabelTests` pins byte-identical to
  /// `test/dynamic_range_test.dart`.
  private func resolveStreamInfoIfNeeded() -> StreamInfoUpdate? {
    guard !streamInfoResolved, engine.hasStarted else { return nil }
    guard streamInfoAttempts < IptvsPlayerViewController.streamInfoMaxAttempts else { return nil }
    streamInfoAttempts += 1

    let format = engine.readStreamFormat()
    let audioTracks = engine.mediaOptions(for: .audible)
    let subtitleTracks = iosSubtitleMenuOptions(tracks: engine.mediaOptions(for: .legible))
    // Nothing at all yet — try again next tick rather than latching a blank
    // readout that would then never be corrected.
    guard !format.isEmpty || !audioTracks.isEmpty || !subtitleTracks.isEmpty else { return nil }
    streamInfoResolved = true

    return StreamInfoUpdate(
      info: iosStreamInfo(format: format, edrHeadroom: displayEdrHeadroom()),
      audioTracks: audioTracks,
      selectedAudioId: engine.selectedMediaOptionId(for: .audible),
      subtitleTracks: subtitleTracks,
      // AVFoundation's automatic selection is left in place rather than forced
      // off: on iOS the "Closed Captions + SDH" accessibility setting is what
      // drives it, and overriding a system accessibility preference to match the
      // other platforms' subtitles-off default would be the wrong trade. Whatever
      // it picked is simply reported, so the menu's tick is honest.
      selectedSubtitleId: engine.selectedMediaOptionId(for: .legible) ?? playerSubtitleOffId
    )
  }

  /// The display's EDR capability, or nil when the platform can't say.
  ///
  /// Feeds the honesty gate in ``iosDynamicRangeForDisplay(sourceLabel:edrHeadroom:)``
  /// — see there for why iOS gates the badge on the display where Android and
  /// Windows don't, and why `nil` must read as "no opinion" rather than "SDR".
  /// `potentialEDRHeadroom` (the display's capability), never
  /// `currentEDRHeadroom` (which varies with brightness and ambient light and
  /// legitimately reads 1.0 on a genuinely HDR panel).
  private func displayEdrHeadroom() -> Double? {
    guard #available(iOS 16.0, *) else { return nil }
    // Scene-scoped rather than `UIScreen.main`: on an iPad with an external
    // display the player's own window is the one whose capability matters.
    let screen = view.window?.windowScene?.screen ?? UIScreen.main
    return Double(screen.potentialEDRHeadroom)
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
    // A reload builds a whole new `AVPlayerItem`, so the latched stream info and
    // the media-selection indices (which are per-item by construction — see
    // `iosMediaOptionId(index:)`) have to be re-derived. The *rendered* values
    // are left in place until the new read lands: a live reconnect returns to the
    // same channel, so clearing them would only make the badges flicker.
    streamInfoResolved = false
    streamInfoAttempts = 0
    startPlayback(url: url, headers: headers)
    refreshNowPlaying()
  }

  /// Presentation metadata pushed from Dart through the plugin's
  /// `setControlState` — the iOS counterpart of the same call the Windows GDI
  /// overlay is driven by (`_syncWindowsNativeControlState`).
  ///
  /// **Deliberately narrow: presentation only.** Position, duration, playing
  /// state and track lists are *not* read, and that is a correctness rule rather
  /// than laziness — while a native engine owns playback Dart's embedded
  /// `_player` is idle and reports zeros (docs/player.md: `_persistPlaybackPosition`
  /// is a no-op for exactly this reason), so honouring them here would rewrite
  /// the lock screen with a stopped player's state mid-film. This controller's
  /// own `AvPlayerEngine` is the only authority on those.
  func applyControlState(_ map: [AnyHashable: Any]) {
    uiState.batch { state in
      if let title = PlayerOpenRequest.string(map["title"]) { state.title = title }
      if map.index(forKey: "sourceName") != nil {
        state.sourceName = PlayerOpenRequest.nonBlankString(map["sourceName"])
      }
      if let canFavorite = map["canFavorite"] as? Bool { state.canFavorite = canFavorite }
      if let isFavorite = map["isFavorite"] as? Bool { state.isFavorite = isFavorite }
      if let liveSynced = map["liveSynced"] as? Bool, state.isLive { state.liveSynced = liveSynced }
      if let reconnecting = map["reconnecting"] as? Bool { state.reconnecting = reconnecting }
      if let now = PlayerOpenRequest.parseEpg(
        map,
        titleKey: "epgNowTitle",
        startKey: "epgNowStartMs",
        stopKey: "epgNowStopMs",
        descriptionKey: "epgNowDesc"
      ) {
        state.epgNow = now
      }
      if let next = PlayerOpenRequest.parseEpg(
        map,
        titleKey: "epgNextTitle",
        startKey: "epgNextStartMs",
        stopKey: "epgNextStopMs",
        descriptionKey: nil
      ) {
        state.epgNext = next
      }
    }
    refreshNowPlaying()
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
      // Unreachable unless `supportsPip` is true, which needs both a real device
      // and an item with a ready video track — see `shouldOfferPictureInPicture`.
      pipController?.start()
    case .retry:
      retryAfterTerminalError()
    case .toggleMenu(let menu):
      uiState.batch { $0.toggleMenu(menu) }
    case .toggleInfo:
      uiState.batch { $0.toggleInfo() }
    case .selectMenuOption(let id):
      selectMenuOption(id)
    case .routePickerWillPresent:
      // Pins the chrome for the sheet's lifetime — see
      // `PlayerChromeState.routePickerPresenting`. The `pokeControls()` above
      // already re-armed the timer; this state change immediately re-evaluates
      // `syncAutoHide` with `pinned == true`, which cancels it.
      uiState.batch { $0.routePickerPresenting = true }
    case .routePickerDidDismiss:
      // Unpinning is what re-arms the clock, via the same `syncAutoHide` edge —
      // so the chrome gets a full auto-hide interval after the sheet closes
      // rather than vanishing immediately.
      uiState.batch { $0.routePickerPresenting = false }
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
    refreshNowPlaying()
  }

  private func seekBy(_ deltaMs: Int64) {
    // Belt and braces behind `showSkipButtons`: live is never seekable here.
    // The remote transport agrees by construction — `remoteCommandPolicy`
    // disables the skip commands for live off the same predicate.
    guard !request.isLive else { return }
    engine.seek(toMs: max(0, engine.positionMs + deltaMs))
    refreshNowPlaying()
  }

  private func seekToFraction(_ fraction: Double) {
    guard !request.isLive else { return }
    let duration = engine.durationMs
    guard duration > 0 else { return }
    engine.seek(toMs: Int64(Double(duration) * min(max(fraction, 0), 1)))
    refreshNowPlaying()
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
      // `AVPlayerItem.select(_:in:)` against the `.audible` group. The id is an
      // index into `group.options` (`iosMediaOptionId(index:)`), which is why the
      // list and the selection are always read from the same item.
      let selected = engine.selectMediaOption(id: id, for: .audible)
      uiState.batch { state in
        // Optimistic, like the speed menu: `currentMediaSelection` does not
        // update synchronously, so reading it back here would render the *old*
        // tick. A refused selection leaves the tick where it was instead.
        if selected { state.selectedAudioId = id }
        state.menu = .none
      }
    case .subtitles:
      // Same, against `.legible`. The `playerSubtitleOffId` sentinel falls
      // through `iosMediaOptionIndex` as nil and becomes `select(nil, in:)`.
      //
      // External sidecar tracks (`request.subtitles`) are still not composed in:
      // that needs an `AVMutableComposition` around the `AVURLAsset`, which
      // AVFoundation cannot build for an HLS asset at all — so a sidecar `.srt`
      // on an AVPlayer-routed stream has no home on this engine. Only the
      // stream's own in-band/HLS subtitle renditions appear here.
      let selected = engine.selectMediaOption(id: id, for: .legible)
      uiState.batch { state in
        if selected { state.selectedSubtitleId = id }
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
  /// fresh one.
  ///
  /// When the stream exposes no window — which is most live IPTV — the only way
  /// to the edge is a reload, and that reload goes through the **`resolveAgain`
  /// round trip**, not through the URL this controller is holding: a Stalker
  /// `play_token` is single-use, so re-opening it can never succeed after a
  /// portal-side kill (docs/player.md "Live reloads re-resolve"). It is the same
  /// call the reconnect watchdog makes, minus the "Reconnecting…" chip — this is
  /// a deliberate user action, not a recovery.
  private func goToLive() {
    guard request.isLive else { return }
    if let edgeMs = liveEdgeMs() {
      engine.seek(toMs: edgeMs)
    } else {
      startLiveReload(showsReconnecting: false)
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

  // MARK: Terminal error surface

  /// Puts the native error/Retry overlay on screen.
  ///
  /// **Deliberately minimal, and deliberately a mirror rather than a new
  /// design:** `PlayerErrorOverlay` (`lib/player/player_overlay.dart`) is a
  /// scrim, a message and Back + Retry, and this is the same three things. Every
  /// richer idea (a reason code on screen, an engine picker, a countdown)
  /// either leaks something — `AVError` userInfo embeds the credential-bearing
  /// stream URL — or duplicates a decision the engine-selection rules already
  /// own.
  ///
  /// Reached only where nothing else can act: a VOD hard failure (live
  /// reconnects instead), a VOD reload that never came back, and an
  /// `engineFailed` that has no channel to hand off through. It is never a
  /// substitute for the mpv handoff, which is always preferred when the failure
  /// is a container problem.
  private func surfaceTerminalError(_ message: String) {
    guard !finishing else { return }
    uiState.batch { state in
      state.errorMessage = message
      // The chip promises a retry is under way, which this contradicts.
      state.reconnecting = false
      state.isPlaying = false
      state.isBuffering = false
      // The overlay renders outside the visibility gate, but the chrome carries
      // the X and the title, so bring it up rather than leaving the viewer with
      // a card floating over nothing.
      state.setControlsVisible(true)
    }
    refreshNowPlaying()
  }

  /// Retry from the error surface.
  ///
  /// Goes through the same `resolveAgain` round trip a live reload does rather
  /// than replaying `request.url`, for the reason that round trip exists at all:
  /// a Stalker `create_link` token is single-use, so retrying the held locator
  /// after a portal-side kill can never succeed. For VOD the Dart side leaves
  /// `resolveAgain` unwired (only live channels pass it —
  /// `channel_list_screen.dart`), so `_freshLiveStream` answers with the
  /// original stream, which is exactly what a VOD retry wants; the round trip
  /// costs one method call and needs no VOD-specific branch here.
  ///
  /// `startPlayback` re-arms the start backstop, so a retry that hangs surfaces
  /// this same overlay again after ``PlaybackStartBackstop/timeoutMs`` instead of
  /// replacing one silent hang with another.
  private func retryAfterTerminalError() {
    // Shares `liveReloadInFlight` with the reconnect watchdog rather than
    // running its own resolve: two overlapping `resolveAgain` round trips would
    // leave the first completion orphaned (the second overwrites
    // `pendingResolveCompletion`) and the flag stuck true, deadlocking every
    // later reload.
    guard !finishing, uiState.value.errorMessage != nil, !liveReloadInFlight else { return }
    liveReloadInFlight = true
    uiState.batch { state in
      state.errorMessage = nil
      state.isBuffering = true
      state.ended = false
    }
    resolveFreshLocator { [weak self] locator in
      guard let self else { return }
      self.liveReloadInFlight = false
      guard !self.finishing else { return }
      self.liveDropped = false
      self.load(url: locator.url, headers: locator.headers)
    }
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
    stopClockTicker()
    stopLiveWatchdog()
    // PiP first, then the engine — a PiP window left running over a released
    // `AVPlayer` is a black floating rectangle the user cannot dismiss from the
    // app.
    stopPictureInPictureForTeardown()
    releasePlaybackServices()
    engine.release()
    UIApplication.shared.isIdleTimerDisabled = false
    releasePictureInPictureRetain()

    let channel = self.channel
    dismissThen {
      // `dismissalEmitsNativeClosed(.exit)` — this is the one dismissal that
      // pops the Dart route.
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
    stopClockTicker()
    stopLiveWatchdog()
    stopPictureInPictureForTeardown()
    releasePlaybackServices()
    engine.release()
    // Unconditional now that PiP has just been stopped above: the previous
    // `!dismissedForPictureInPicture` guard existed only because nothing could
    // stop PiP yet, and it would leave the screen awake for the rest of the
    // process on a close-while-in-PiP.
    UIApplication.shared.isIdleTimerDisabled = false
    releasePictureInPictureRetain()
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
  ///
  /// All three of docs/ios.md's detection shapes arrive here, distinguishable
  /// downstream **only by `reason`** — which is why that stays a short machine
  /// code rather than error text:
  ///
  /// 1. a hard `AVPlayerItem.status == .failed` before anything played, via
  ///    `AvPlayerEngine.onFatalError` (`item-failed`, `failed-to-play-to-end`,
  ///    `invalid-url`, or `domain:code`);
  /// 2. **ready but no picture** — healthy playback, video declared, nothing ever
  ///    rendered — via `VideoPresenceBackstop` (`no-video-picture`);
  /// 3. **never started within 10s** via `PlaybackStartBackstop`
  ///    (`no-first-start`).
  ///
  /// Shape 2 was specified and deliberately left unbuilt for a while, because the
  /// obvious detector ("playing but `presentationSize == .zero`") misfires on
  /// legitimately audio-only content, which `selectIosEngine` rule 3 routes here
  /// on purpose (`m4a`, `mp3`, `aac`, and radio channels served as audio-only
  /// HLS). It is safe now only because it requires **positive evidence that video
  /// was promised** (`AvPlayerEngine.declaredVideoEvidence`) rather than inferring
  /// failure from an absent picture; see that property and
  /// `VideoPresenceBackstop`'s type doc.
  private func reportEngineFailed(reason: String) {
    guard !finishing else { return }
    // **Handing off is only possible while there is somewhere to hand off to.**
    // The emit below goes through the plugin's channel; with the plugin
    // deallocated or the channel gone it would vanish silently — after this
    // method had already dismissed the only surface the user had — leaving the
    // Dart route on a black screen with nothing left to recover it. That is the
    // exact dead end the whole fallback contract exists to rule out, so fail
    // closed onto the local error surface instead: the controller stays
    // presented (playback is already dead either way) and Back/Retry still work.
    guard IptvsIosPlayerPlugin.current != nil, channel != nil else {
      surfaceTerminalError(PlayerErrorMessages.cannotPlay)
      return
    }
    finishing = true

    let positionMs = request.isLive ? 0 : engine.positionMs
    let pipWasActive = pictureInPictureActive

    // Contractual ordering: stop PiP **before** the engine teardown, and settle
    // `pictureInPictureActive` synchronously — the emit below ships
    // `currentHostVisibility()`, and a stale `pipActive: true` there is an
    // authoritative veto Dart would defer its whole fallback on.
    stopPictureInPictureForTeardown()

    soakAutoCloseTimer?.invalidate()
    soakAutoCloseTimer = nil
    autoHideTimer?.invalidate()
    autoHideTimer = nil
    stopClockTicker()
    // Stops the ticker *and* drops any in-flight `resolveAgain` completion: the
    // Dart route survives an `engineFailed` (it has to host the mpv surface),
    // so a late reply must not reach a controller that is already dismissing.
    stopLiveWatchdog()
    // The audio session goes back to the pool here rather than being held for
    // the successor: Dart reopens on the embedded media_kit surface, which
    // claims it under its own client id (`AudioSessionClientId.embeddedPlayer`).
    // Overlapping claims are exactly what the client set exists to survive.
    releasePlaybackServices()
    engine.release()
    UIApplication.shared.isIdleTimerDisabled = false
    releasePictureInPictureRetain()

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

// MARK: - IosPipControllerDelegate

/// The Picture-in-Picture lifecycle. Three things here are contractual rather
/// than incidental, and each has a matching `Core` function so the rule is
/// pinned even though **none of these callbacks can ever fire in a Simulator**
/// (`isPictureInPictureSupported()` is false there, so no PiP controller exists
/// and the button is never shown):
///
/// 1. **PiP never sends `nativeClosed`** (``dismissalEmitsNativeClosed``). The
///    controller dismisses itself so the `AVPlayerLayer` can keep feeding the
///    PiP window; the Dart route must survive completely untouched, or the
///    restore control would have nothing to return to.
/// 2. **Something must retain the controller across that dismissal.** The
///    plugin's `activeController` is weak *by design* (a strong one would leak an
///    `AVPlayer` per open), so a separate strong hold is taken for exactly the
///    duration of PiP.
/// 3. **A PiP window closed without a restore must `finish()`**
///    (``pipStopOutcome(restoreRequested:)``). Otherwise the app is left with a
///    dismissed controller, a live `AVPlayer` and a Dart route on a black
///    screen — a dead end only a force-quit escapes.
extension IptvsPlayerViewController: IosPipControllerDelegate {
  func pipWillStart() {
    // Both of these must land *before* the dismissal in `pipDidStart`: the flag
    // so `viewDidDisappear` reads the disappearance as PiP rather than an exit,
    // and the retain so the dismissal isn't this object's last release.
    dismissedForPictureInPicture = true
    IptvsIosPlayerPlugin.current?.retainForPictureInPicture(self)
  }

  func pipDidStart() {
    pictureInPictureActive = true
    IptvsIosPlayerPlugin.current?.pictureInPictureStateChanged()
    guard presentingViewController != nil else { return }
    // Deliberately no `nativeClosed` here — see the extension doc.
    dismiss(animated: false)
  }

  func pipRestoreUserInterface(completion: @escaping (Bool) -> Void) {
    restoringFromPictureInPicture = true
    dismissedForPictureInPicture = false

    if presentingViewController != nil {
      completion(true)
      return
    }
    guard let host = IptvsIosPlayerPlugin.topViewController(), host !== self else {
      // Nothing to present from. Telling AVKit the restore failed would leave
      // the user with a dismissed player and a live engine, so exit properly
      // instead: `finish()` pops the Dart route back to the channel list.
      completion(false)
      finish()
      return
    }
    host.present(self, animated: false) { completion(true) }
  }

  func pipDidStop(restoreRequested: Bool) {
    pictureInPictureActive = false
    IptvsIosPlayerPlugin.current?.pictureInPictureStateChanged()

    // `restoringFromPictureInPicture` is redundant with the controller's own
    // record and kept as belt and braces: mistaking a restore for a close would
    // tear down playback the user just asked to come back to.
    let restored = restoreRequested || restoringFromPictureInPicture
    restoringFromPictureInPicture = false
    dismissedForPictureInPicture = false

    switch pipStopOutcome(restoreRequested: restored) {
    case .restoreHost:
      // Presented again (or about to be) — UIKit owns the lifetime once more.
      releasePictureInPictureRetain()
    case .finishPlayback:
      // Drops the retain itself, after `nativeClosed` has been delivered.
      finish()
    }
  }

  func pipFailedToStart(_ error: Error) {
    // Not fatal: the controller is still presented and still playing. Undo the
    // speculative bookkeeping `pipWillStart` did and carry on.
    dismissedForPictureInPicture = false
    pictureInPictureActive = false
    releasePictureInPictureRetain()
    IptvsIosPlayerPlugin.current?.pictureInPictureStateChanged()
  }

  func pipPossibleChanged(_ possible: Bool) {
    syncPictureInPictureAvailability(possible)
  }
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
