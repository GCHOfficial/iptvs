import AVFoundation
import Foundation
import MediaPlayer

/// The process's **only** owner of `AVAudioSession`.
///
/// This is step 6, and it is the step that makes an install audible at all.
/// Before it, the app sits in the default `soloAmbient` category: video plays,
/// nothing comes out of a phone with the ring switch on silent, and nothing at
/// all comes out once the app is backgrounded. Neither is a player.
///
/// **Why Swift owns it exclusively.** mpv's `ao_audiounit` driver
/// unconditionally calls `AVAudioSession.setActive:` YES/NO on init and dispose,
/// and the session is process-wide — so every mpv engine teardown used to
/// clobber AVPlayer's session state (background audio, lock-screen controls).
/// `media_kit` is git-pinned to the commit that adds `iosManageAudioSession`, and
/// both Dart `PlayerConfiguration` sites set it to `false` (docs/ios.md
/// Constraint 1, docs/player.md iOS). The consequence is easy to miss and is
/// stated here because it is the whole design: **mpv no longer activates the
/// session, so the mpv path now depends on this class too.** An mpv-routed
/// stream is silent unless something acquires a claim here on its behalf.
///
/// Claims are keyed by client id (``AudioSessionClients``), so acquire/release
/// is idempotent and order-independent. That matters because the AVPlayer→mpv
/// `engineFailed` handoff genuinely overlaps: the presented controller is
/// tearing down while the embedded surface is opening, in either order.
///
/// Not thread-safe, and deliberately not made so — every entry point is a
/// main-queue UIKit callback, a method-channel handler (main queue by
/// contract), or an `AVAudioSession` notification, all of which are delivered on
/// the main thread.
final class IosAudioSession {
  static let shared = IosAudioSession()

  /// The player's response to an interruption or a lost output route. Set by
  /// `IptvsPlayerViewController` while it is presented and cleared on teardown;
  /// captured weakly by its owner, so a leaked closure can't keep a controller
  /// alive.
  ///
  /// A single slot rather than a broadcast list because there is exactly one
  /// AVFoundation client in this process. The mpv path reacts to interruptions
  /// inside libmpv/media_kit and is not represented here.
  var onInterruption: ((AudioInterruptionReaction) -> Void)?

  /// Whether the interrupted player was playing — supplied by the same owner,
  /// since only it knows. Absent (or answering `false`) makes an interruption
  /// end a no-op, which is the safe direction.
  var isPlayingProvider: (() -> Bool)?

  private var clients = AudioSessionClients()
  private var observing = false
  private(set) var isActive = false

  private init() {}

  // MARK: - Category

  /// Puts the process in `.playback` / `.moviePlayback` **without activating**.
  ///
  /// Called once at plugin registration, and again defensively before every
  /// activation. Setting the category alone does not interrupt other apps —
  /// only `setActive(true)` does — so this is cheap at launch, and it buys one
  /// concrete thing on its own: audio is no longer muted by the ring switch,
  /// which `soloAmbient` (the default) honours. That is the floor below which an
  /// mpv-routed stream with no Dart-side claim is inaudible for a reason no
  /// tester would guess.
  ///
  /// `.moviePlayback` is the mode Apple documents for video players; it is also
  /// what enables the enhanced audio routing AirPlay expects.
  func configureCategory() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .moviePlayback,
        options: []
      )
    } catch {
      logAudioSession("setCategory failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Claims

  /// Registers `clientId` as needing audio, activating the session if it is the
  /// first live claim.
  ///
  /// Safe to call repeatedly for the same id: `viewDidAppear` runs again after a
  /// Picture-in-Picture restore re-presents the controller.
  func acquire(_ clientId: String) {
    let shouldActivate = clients.acquire(clientId)
    IosDebugCounters.set(.audioClients, clients.count)
    startObservingIfNeeded()
    guard shouldActivate else { return }
    activate()
  }

  /// Drops `clientId`'s claim, deactivating only when it was the last one.
  func release(_ clientId: String) {
    let shouldDeactivate = clients.release(clientId)
    IosDebugCounters.set(.audioClients, clients.count)
    guard shouldDeactivate else { return }
    deactivate()
  }

  /// Hard reset. Not used on any normal path — kept for a plugin-level
  /// "everything is gone" call so a leaked claim can be cleared without
  /// restarting the app.
  func releaseAll() {
    let shouldDeactivate = clients.releaseAll()
    IosDebugCounters.set(.audioClients, clients.count)
    guard shouldDeactivate else { return }
    deactivate()
  }

  var hasClients: Bool { !clients.isEmpty }

  private func activate() {
    configureCategory()
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      isActive = true
    } catch {
      // Not fatal and deliberately not surfaced: another app can legitimately
      // refuse to yield (a phone call in progress), and the interruption
      // notification will bring us back when it ends.
      logAudioSession("setActive(true) failed: \(error.localizedDescription)")
    }
  }

  private func deactivate() {
    do {
      // `.notifyOthersOnDeactivation` is what lets whatever we interrupted
      // (music, a podcast) resume instead of staying dead until the user goes
      // and restarts it by hand.
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
      isActive = false
    } catch {
      // Routinely throws when audio is still being rendered by something the
      // session doesn't know about; harmless, and the next activation is
      // unaffected.
      logAudioSession("setActive(false) failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Interruptions and route changes

  private func startObservingIfNeeded() {
    guard !observing else { return }
    observing = true
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }

    switch type {
    case .began:
      dispatch(.began)
    case .ended:
      let optionsRaw =
        notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
      let shouldResume = options.contains(.shouldResume)
      // The system deactivated the session for the duration of the
      // interruption, so re-activate before asking anyone to resume — otherwise
      // `play()` succeeds and produces no sound.
      if shouldResume, hasClients { activate() }
      dispatch(.ended(shouldResume: shouldResume))
    @unknown default:
      break
    }
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
      reason == .oldDeviceUnavailable
    else { return }
    dispatch(.outputDeviceLost)
  }

  private func dispatch(_ event: AudioInterruption) {
    let wasPlaying = isPlayingProvider?() ?? false
    let reaction = audioInterruptionReaction(event, wasPlaying: wasPlaying)
    guard reaction != .ignore else { return }
    onInterruption?(reaction)
  }

  private func logAudioSession(_ message: String) {
    #if DEBUG
      // Session errors never embed a stream URL, so there is nothing to redact
      // here — but keep it debug-only anyway: the diagnostics log is
      // user-exportable and this is noise, not a fault the user can act on.
      print("[iptvs][audio-session] \(message)")
    #endif
  }
}

/// `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for the presented player.
///
/// This is genuinely new surface — no other platform in this repo has a lock
/// screen or a system transport — so the *rules* live in `Core`
/// (``nowPlayingSnapshot(title:sourceName:isLive:positionMs:durationMs:isPlaying:speed:)``,
/// ``remoteCommandPolicy(isLive:)``, both pinned by `swift test`) and this class
/// is the MediaPlayer key mapping and nothing else.
///
/// Ownership: one instance per `IptvsPlayerViewController`, enabled on
/// `viewDidAppear` and torn down on every exit path. `MPRemoteCommandCenter` is
/// a process-wide singleton whose targets are **not** cleared automatically, so
/// forgetting `disable()` leaves a dead closure wired to the user's headphone
/// button for the rest of the process.
final class IosNowPlayingCenter {
  var onPlay: (() -> Void)?
  var onPause: (() -> Void)?
  var onTogglePlayPause: (() -> Void)?
  /// Relative skip, in **milliseconds**, signed — matches the overlay's
  /// `.seekBy` action so both transports go through one code path.
  var onSkip: ((Int64) -> Void)?
  /// Absolute seek, in milliseconds.
  var onSeek: ((Int64) -> Void)?

  private var targets: [(MPRemoteCommand, Any)] = []
  private var enabled = false

  deinit {
    disable()
  }

  /// Wires the system transport for a stream. The caller publishes the first
  /// ``update(_:)`` itself, so the two stay independently callable.
  /// Idempotent — a Picture-in-Picture restore re-runs `viewDidAppear`.
  func enable(policy: RemoteCommandPolicy) {
    guard !enabled else { return }
    enabled = true

    let center = MPRemoteCommandCenter.shared()

    configure(center.playCommand, enabled: policy.play) { [weak self] _ in
      self?.onPlay?()
      return .success
    }
    configure(center.pauseCommand, enabled: policy.pause) { [weak self] _ in
      self?.onPause?()
      return .success
    }
    configure(center.togglePlayPauseCommand, enabled: policy.togglePlayPause) { [weak self] _ in
      self?.onTogglePlayPause?()
      return .success
    }

    center.skipForwardCommand.preferredIntervals = [NSNumber(value: policy.skipIntervalSeconds)]
    configure(center.skipForwardCommand, enabled: policy.skipForward) { [weak self] event in
      let seconds =
        (event as? MPSkipIntervalCommandEvent)?.interval ?? policy.skipIntervalSeconds
      self?.onSkip?(Int64(seconds * 1000))
      return .success
    }

    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: policy.skipIntervalSeconds)]
    configure(center.skipBackwardCommand, enabled: policy.skipBackward) { [weak self] event in
      let seconds =
        (event as? MPSkipIntervalCommandEvent)?.interval ?? policy.skipIntervalSeconds
      self?.onSkip?(Int64(-seconds * 1000))
      return .success
    }

    configure(
      center.changePlaybackPositionCommand,
      enabled: policy.changePlaybackPosition
    ) { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.onSeek?(Int64(max(0, event.positionTime) * 1000))
      return .success
    }
  }

  /// Publishes the current state. Cheap, but not free — call it on transitions
  /// (start, play/pause, seek, reload) rather than on every progress tick; the
  /// system extrapolates elapsed time from `playbackRate` in between.
  func update(_ snapshot: NowPlayingSnapshot) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: snapshot.title,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: snapshot.isLive,
      MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
    ]
    if let artist = snapshot.artist { info[MPMediaItemPropertyArtist] = artist }
    // Omitted rather than zeroed when unknown — a zero duration draws a
    // zero-length scrubber, which reads as a broken stream rather than an
    // unknown one.
    if let duration = snapshot.durationSeconds {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    if let elapsed = snapshot.elapsedSeconds {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// Removes every target this instance added and clears the Now Playing entry.
  /// Idempotent, and safe to call from `deinit`.
  func disable() {
    guard enabled else { return }
    enabled = false
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets.removeAll()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func configure(
    _ command: MPRemoteCommand,
    enabled: Bool,
    handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
  ) {
    command.isEnabled = enabled
    guard enabled else { return }
    targets.append((command, command.addTarget(handler: handler)))
  }
}
