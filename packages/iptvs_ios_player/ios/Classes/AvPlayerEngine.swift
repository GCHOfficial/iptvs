import AVFoundation
import Foundation
import UIKit

/// The `UIView` the video is rendered into.
///
/// `layerClass` rather than a manually inserted sublayer: the `AVPlayerLayer`
/// *is* the view's backing layer, so it resizes with the view automatically. A
/// hand-added sublayer needs its `frame` re-synced in `layoutSubviews` on every
/// bounds change (rotation, safe-area change, the split-second layout pass right
/// after presentation), and forgetting one of those leaves the video stretched or
/// clipped in a way that only shows on a device in the wrong orientation.
///
/// Step 7 (PiP) reads `playerLayer` from here — `AVPictureInPictureController`
/// is constructed from an `AVPlayerLayer`, not from an `AVPlayer`.
final class PlayerLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }

  /// Safe by construction: `layerClass` above guarantees the backing layer's
  /// type.
  var playerLayer: AVPlayerLayer {
    // swiftlint:disable:next force_cast
    layer as! AVPlayerLayer
  }
}

/// AVFoundation playback for the native iOS player — the counterpart of
/// Android's `ExoPlayerEngine` (`android/app/src/main/kotlin/.../player/`), and
/// deliberately the same shape: a thin engine that owns the decoder and reports
/// engine-agnostic state through **mutable callback properties**, so the host
/// (`IptvsPlayerViewController`) can rebind them. Kotlin's `PlaybackEngine`
/// keeps `onUnsupportedVideo`/`onRecoverableError` as `var`s for exactly this
/// reason.
///
/// Deliberately *not* here, and staying that way: the audio session
/// (`IosAudioSession`, which is process-wide and outlives any one engine), the
/// PiP controller (`IosPipController`, which is built from the *layer*, not the
/// player), and the live reconnect watchdog (which lives in the view controller
/// alongside the `LiveReconnectWatchdog`/`ReconnectPolicy` it drives, mirroring
/// `HdrPlayerActivity.pollLiveReconnect` rather than the Dart watchdogs).
///
/// Colorimetry, codec and media-selection reads **do** live here, because they
/// are per-`AVPlayerItem` facts and this type owns the item. They stay thin on
/// purpose: every read hands raw FourCCs and colour tags to `Core`
/// (`IosStreamFormat` → ``iosStreamInfo(format:edrHeadroom:)``), which owns the
/// whole interpretation table and is covered by `swift test`. This type still
/// makes no judgements.
final class AvPlayerEngine {
  /// Undocumented but universally used `AVURLAsset` option for per-request HTTP
  /// headers. It is load-bearing here rather than a nicety: Stalker/MAG portals
  /// reject a stream request without the portal's `User-Agent`/`Referer`, so
  /// without it every MAG channel routed to AVPlayer would 403. The public
  /// alternative is an `AVAssetResourceLoaderDelegate` that re-implements HLS
  /// fetching by hand, which would forfeit the hardware/EDR path this engine
  /// exists for. The usual objection — App Review — does not apply: iOS ships
  /// through AltStore sideloading and never goes through review (docs/ios.md
  /// "Why not the App Store").
  private static let httpHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

  /// How often position/duration are sampled. Android's `HdrPlayerActivity`
  /// ticker runs at 500 ms and drives both the scrubber and the reconnect
  /// watchdog; matching it here means step 4's scrubber and step 8's watchdog
  /// both already have the cadence they need.
  private static let progressInterval = CMTime(seconds: 0.5, preferredTimescale: 600)

  let player = AVPlayer()

  // MARK: - Callbacks (rebindable by the host, like Kotlin's PlaybackEngine)

  /// A playback-state transition. `message` is a short machine code or nil —
  /// never human-readable error text, which can embed the credential-bearing
  /// stream URL.
  var onStateEvent: ((PlaybackStateEvent, String?) -> Void)?

  /// Fired on every progress tick (0.5 Hz-resolution position/duration).
  var onProgressTick: (() -> Void)?

  /// The item reached `.readyToPlay`. The host uses this to apply a VOD resume
  /// seek, which is only meaningful once the item can accept one.
  var onReadyToPlay: (() -> Void)?

  /// A hard failure **before anything ever played** — the signature of AVPlayer
  /// having accepted a URL whose container it cannot actually handle. The host
  /// turns this into the `engineFailed` cross-language handoff so Dart reopens
  /// the same content on the embedded mpv surface (docs/ios.md "engineFailed is
  /// a cross-language handoff"). A failure *after* playback started is a network
  /// drop instead and arrives as `.dropped`.
  var onFatalError: ((String) -> Void)?

  // MARK: - State

  /// True once the **current item** has actually produced playback. This is the
  /// iOS counterpart of Linux's `_linuxNativeStarted` gate, and it exists for the
  /// same reason: an `AVPlayerItem` reports `isPlaybackBufferEmpty == true`
  /// before it has loaded anything, so reporting that as a stall would start the
  /// reconnect clock on every single open.
  ///
  /// Reset by every ``load(url:headers:subtitles:)``, because it gates per-item
  /// reads (`readStreamFormat`, which must wait for the *new* item's tracks).
  private(set) var hasStarted = false

  /// True once AVPlayer has produced playback at **any** point in this engine's
  /// life — and never cleared, not even by a reload.
  ///
  /// The discriminator the whole failure taxonomy hangs off. "AVPlayer can play
  /// this container" is a fact about the content, and a reload does not
  /// un-prove it, so per-item ``hasStarted`` is the wrong thing to ask:
  ///
  /// - a failure with this **false** is an unplayable container → `onFatalError`
  ///   → the `engineFailed` handoff to mpv;
  /// - a failure with this **true** is a network drop → `.dropped` → the live
  ///   reconnect watchdog (or, for VOD, the terminal error surface).
  ///
  /// Keying the split on `hasStarted` instead would misread every failed live
  /// reconnect as an unplayable container and permanently downgrade a working
  /// HDR channel to tone-mapped SDR, because `_handleIosEngineFailed` writes
  /// the content id into `IosEngineMemo` for the rest of the session.
  private(set) var hasEverStarted = false

  /// Whether the buffer is currently empty (post-start). Step 8's watchdog reads
  /// this the way `HdrPlayerActivity.pollLiveReconnect` reads
  /// `PlayerUiState.isBuffering`.
  private(set) var isBuffering = true

  /// Set once the stream ends cleanly. Live treats this as a drop; VOD
  /// completing is a legitimate end.
  private(set) var hasEnded = false

  /// Cached answer for ``declaredVideoEvidence``, reset by every load.
  ///
  /// `.unknown` doubles as "not answered yet", which is why only a *conclusive*
  /// read is stored: an early tick on an item whose tracks/variants have not
  /// loaded must not freeze the answer.
  private var videoEvidence: DeclaredVideoEvidence = .unknown

  private var itemObservations: [NSKeyValueObservation] = []
  private var playerObservations: [NSKeyValueObservation] = []
  private var notificationTokens: [NSObjectProtocol] = []
  private var timeObserver: Any?
  private var released = false

  init() {
    // Counted here rather than at the property initialiser so the increment and
    // the matching decrement in `release()` sit in the same file, one screen
    // apart (docs/player.md "Debug resource counters + lifecycle soak").
    IosDebugCounters.increment(.avPlayers)
    observePlayer()
    addProgressObserver()
  }

  deinit {
    // Belt and braces: `release()` is idempotent and the host calls it on every
    // exit path, but a periodic time observer that outlives its player is the
    // classic AVFoundation leak, so never rely on that alone.
    release()
  }

  // MARK: - Transport

  /// Replaces the current item. Used both for the initial open and for a live
  /// reload (reconnect / "Go to live"), which is why it resets the start/stall
  /// bookkeeping — the same call `HdrPlayerActivity.reconnectLive` makes into
  /// `engine.load(url, subtitles)`.
  ///
  /// `subtitles` (external sidecar tracks) are accepted and currently ignored:
  /// composing them onto an `AVURLAsset` needs an `AVMutableComposition`, which
  /// belongs with the track-selection menu in step 5. Taking them in the
  /// signature now keeps that a one-file change.
  func load(url: String, headers: [String: String], subtitles: [PlayerSubtitleSpec] = []) {
    guard !released else { return }
    _ = subtitles
    guard let assetURL = URL(string: url) else {
      onFatalError?("invalid-url")
      return
    }

    teardownItemObservers()
    hasStarted = false
    isBuffering = true
    hasEnded = false
    // Per-item, like `hasStarted`: a reload builds a whole new `AVPlayerItem`,
    // and "does this item declare video" is a fact about *that* item.
    videoEvidence = .unknown

    var options: [String: Any] = [:]
    if !headers.isEmpty { options[AvPlayerEngine.httpHeaderFieldsKey] = headers }
    let asset = AVURLAsset(url: assetURL, options: options.isEmpty ? nil : options)
    let item = AVPlayerItem(asset: asset)
    observeItem(item)
    player.replaceCurrentItem(with: item)
    player.play()
  }

  func play() {
    guard !released else { return }
    player.play()
  }

  func pause() {
    guard !released else { return }
    player.pause()
  }

  var isPlaying: Bool {
    player.timeControlStatus == .playing
  }

  /// Seeks to `positionMs`. Tolerance is zero so a VOD resume lands where the
  /// user actually stopped rather than at the nearest keyframe, which on a long
  /// film can be many seconds away.
  func seek(toMs positionMs: Int64, completion: ((Bool) -> Void)? = nil) {
    guard !released, player.currentItem != nil else {
      completion?(false)
      return
    }
    let target = CMTime(value: CMTimeValue(max(0, positionMs)), timescale: 1_000)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
      completion?(finished)
    }
  }

  /// Current position in ms, or `0` when not yet known.
  var positionMs: Int64 {
    AvPlayerEngine.milliseconds(from: player.currentTime())
  }

  /// Duration in ms, or `0` for live and anything not yet known. A live HLS
  /// item reports `CMTime.indefinite`, which is deliberately *not* numeric — see
  /// `milliseconds(from:)`.
  var durationMs: Int64 {
    guard let item = player.currentItem else { return 0 }
    return AvPlayerEngine.milliseconds(from: item.duration)
  }

  /// Natural video size, `.zero` until the first frame is decoded (and forever
  /// for an audio-only item). Step 4's resolution badge and step 7's PiP aspect
  /// ratio both read this.
  var presentationSize: CGSize {
    player.currentItem?.presentationSize ?? .zero
  }

  /// Whether AVPlayer is sending this item to an external device (AirPlay).
  ///
  /// Read only by ``IptvsPlayerViewController``'s video-presence backstop, as a
  /// *suppression*: during external playback the local `AVPlayerLayer` renders
  /// nothing and the item's presentation size can legitimately stay zero on a
  /// perfectly good video stream. Firing the mpv handoff there would move an
  /// AirPlaying stream onto an engine with no AirPlay at all (docs/ios.md "Known
  /// parity gaps").
  var isExternalPlaybackActive: Bool {
    player.isExternalPlaybackActive
  }

  /// **Whether the current item declares a video track at all** — the positive
  /// evidence `VideoPresenceBackstop` requires before it will ever hand off.
  ///
  /// This is what makes docs/ios.md's second detection shape shippable. The naive
  /// form of that detector — "playing, but `presentationSize == .zero`" —
  /// cannot distinguish a video stream that is not rendering from legitimately
  /// audio-only content, which `selectIosEngine` rule 3 routes to this engine on
  /// purpose (`m4a`, `mp3`, `aac`, and radio channels served as audio-only HLS).
  ///
  /// **Two sources, the same two `readStreamFormat` already has to use**, and no
  /// new AVFoundation spellings beyond them:
  ///
  /// 1. Progressive assets answer through `AVPlayerItemTrack.assetTrack` →
  ///    `formatDescriptions` → `CMFormatDescriptionGetMediaType`.
  /// 2. HLS does not — `assetTrack` is documented `nil` there — so the ladder's
  ///    `AVAssetVariant.videoAttributes` answers instead: a variant with video
  ///    has attributes, an audio-only rendition has `nil`.
  ///
  /// Anything neither source can answer (most importantly an HLS **media**
  /// playlist, which has no variants) stays ``DeclaredVideoEvidence/unknown`` and
  /// therefore never fires. That is a deliberate coverage gap in the safe
  /// direction: a missed detection is a black screen the user can back out of, a
  /// false one is a working stream pinned to the SDR/no-PiP/no-AirPlay engine for
  /// the rest of the session.
  ///
  /// Gated on ``hasStarted`` for the same reason ``readStreamFormat()`` is: these
  /// synchronous accessors are views of asynchronously loaded state and can block
  /// the main thread on an unloaded asset. After the first frame they are cache
  /// hits.
  var declaredVideoEvidence: DeclaredVideoEvidence {
    if videoEvidence != .unknown { return videoEvidence }
    guard !released, hasStarted, let item = player.currentItem else { return .unknown }
    let evidence = AvPlayerEngine.readVideoEvidence(item)
    videoEvidence = evidence
    return evidence
  }

  private static func readVideoEvidence(_ item: AVPlayerItem) -> DeclaredVideoEvidence {
    var sawFormatDescriptions = false
    for track in item.tracks {
      guard let assetTrack = track.assetTrack else { continue }
      let descriptions = assetTrack.formatDescriptions
        .compactMap { AvPlayerEngine.formatDescription($0) }
      guard !descriptions.isEmpty else { continue }
      sawFormatDescriptions = true
      if descriptions.contains(where: {
        CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video
      }) {
        return .present
      }
    }
    // Tracks that described themselves, none of them video: genuinely audio-only.
    if sawFormatDescriptions { return .absent }

    // The HLS route. `variants` is on `AVURLAsset`, not `AVAsset` — every item
    // this engine builds carries one, so a failed cast means `load` changed.
    guard let asset = item.asset as? AVURLAsset else { return .unknown }
    let variants = asset.variants
    guard !variants.isEmpty else { return .unknown }
    // `contains(where:)` spelled out rather than as a trailing closure: a
    // trailing closure immediately followed by `?` is exactly the shape Swift's
    // parser is unreliable about, and there is no local toolchain to find out.
    return variants.contains(where: { $0.videoAttributes != nil }) ? .present : .absent
  }

  /// Tears everything down. Idempotent, and safe to call from `deinit`.
  func release() {
    guard !released else { return }
    released = true
    teardownItemObservers()
    for observation in playerObservations { observation.invalidate() }
    playerObservations.removeAll()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
      IosDebugCounters.decrement(.timeObservers)
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    IosDebugCounters.decrement(.avPlayers)
  }

  // MARK: - Observation

  private func observePlayer() {
    playerObservations = [
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        let status = player.timeControlStatus
        DispatchQueue.main.async { self?.handleTimeControlStatus(status) }
      }
    ]
  }

  private func addProgressObserver() {
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: AvPlayerEngine.progressInterval,
      queue: .main
    ) { [weak self] _ in
      self?.onProgressTick?()
    }
    // A periodic time observer **retains its `AVPlayer`** until it is removed,
    // which is why this gets its own counter rather than folding into
    // `iosAvPlayers`: leak it and the player simply never deallocates, with
    // nothing else in the system to say so.
    IosDebugCounters.increment(.timeObservers)
  }

  private func observeItem(_ item: AVPlayerItem) {
    itemObservations = [
      item.observe(\.status, options: [.new]) { [weak self] item, _ in
        let status = item.status
        let error = item.error as NSError?
        DispatchQueue.main.async { self?.handleItemStatus(status, error: error) }
      },
      item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
        let empty = item.isPlaybackBufferEmpty
        DispatchQueue.main.async { self?.handleBufferEmpty(empty) }
      },
      item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
        let likely = item.isPlaybackLikelyToKeepUp
        DispatchQueue.main.async { self?.handleLikelyToKeepUp(likely) }
      },
    ]

    let center = NotificationCenter.default
    notificationTokens = [
      center.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification,
        object: item,
        queue: .main
      ) { [weak self] _ in
        self?.handleEndOfStream()
      },
      center.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification,
        object: item,
        queue: .main
      ) { [weak self] notification in
        // Global constant, not a member of `AVPlayerItem`: the two
        // notification *names* were renamed onto the class in Swift, this
        // userInfo key was not.
        let error =
          notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        self?.handleFailure(error, notification: true)
      },
    ]
  }

  private func teardownItemObservers() {
    for observation in itemObservations { observation.invalidate() }
    itemObservations.removeAll()
    let center = NotificationCenter.default
    for token in notificationTokens { center.removeObserver(token) }
    notificationTokens.removeAll()
  }

  // MARK: - State handling (main thread)

  private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
    guard !released, status == .playing, !hasStarted else { return }
    hasStarted = true
    // Never reset — see the property doc. This is the moment the host's start
    // backstop disarms and its live reconnect watchdog arms.
    hasEverStarted = true
    isBuffering = false
    onStateEvent?(.started, nil)
  }

  private func handleItemStatus(_ status: AVPlayerItem.Status, error: NSError?) {
    guard !released else { return }
    switch status {
    case .readyToPlay:
      onReadyToPlay?()
    case .failed:
      handleFailure(error, notification: false)
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  private func handleBufferEmpty(_ empty: Bool) {
    // Only meaningful after playback has actually started — see `hasStarted`.
    guard !released, hasStarted, empty, !isBuffering else { return }
    isBuffering = true
    onStateEvent?(.stalled, nil)
  }

  private func handleLikelyToKeepUp(_ likely: Bool) {
    guard !released, hasStarted, likely, isBuffering else { return }
    isBuffering = false
    onStateEvent?(.resumed, nil)
  }

  private func handleEndOfStream() {
    guard !released, !hasEnded else { return }
    hasEnded = true
    onStateEvent?(.ended, nil)
  }

  /// The one discriminator that matters in this file.
  ///
  /// A hard failure **before anything ever played** is the fingerprint of a
  /// container AVPlayer could not actually handle, and the honest response is to
  /// hand the stream to mpv (`engineFailed`). A failure **after** playback
  /// started is a network drop — the stream was demonstrably playable a moment
  /// ago — and switching engines for it would permanently downgrade a working
  /// HDR channel to tone-mapped SDR for the rest of the session, because
  /// `_handleIosEngineFailed` writes the content id into `IosEngineMemo`.
  ///
  /// **``hasEverStarted``, not ``hasStarted``.** A live reconnect reload builds a
  /// fresh `AVPlayerItem`, so the per-item flag is false again the instant the
  /// watchdog retries — and a portal that is simply down would have had every
  /// failed retry read as "unplayable container" and thrown a working channel at
  /// mpv on the *first* one. The engine-lifetime flag is what makes the two
  /// cases distinguishable at all.
  private func handleFailure(_ error: NSError?, notification: Bool) {
    guard !released else { return }
    let code = error.map { PlaybackEventPayload.errorCode(domain: $0.domain, code: $0.code) }
      ?? (notification ? "failed-to-play-to-end" : "item-failed")
    if hasEverStarted {
      onStateEvent?(.dropped, code)
    } else {
      onFatalError?(code)
    }
  }

  // MARK: - Stream format (colorimetry, codecs, frame rate)

  /// Collects whatever colorimetry/codec facts the current item exposes, for
  /// ``iosStreamInfo(format:edrHeadroom:)`` to turn into chrome fields.
  ///
  /// **Gated on ``hasStarted`` on purpose, and not only to avoid empty reads.**
  /// The accessors below (`AVAssetTrack.formatDescriptions`,
  /// `AVURLAsset.variants`) are synchronous views of properties AVFoundation
  /// loads asynchronously; on an unloaded asset they can block the calling
  /// thread, and this runs on the main queue from the progress tick. Once the
  /// first frame is up, the master playlist and track formats are already
  /// parsed, so every read here is a cache hit.
  ///
  /// **Two sources, because iOS has two.** Format descriptions are
  /// authoritative and are what a progressive MP4/fMP4 exposes; for HLS,
  /// `AVPlayerItemTrack.assetTrack` is documented as `nil`, so the variant
  /// attributes are the only route. HLS is the *common* AVPlayer path on iOS
  /// once Xtream defaults to `m3u8` (docs/ios.md "The `streamExtension` lever"),
  /// so the variant fallback is load-bearing rather than defensive.
  func readStreamFormat() -> IosStreamFormat {
    guard !released, hasStarted, let item = player.currentItem else { return IosStreamFormat() }
    var format = IosStreamFormat()
    readTrackFormats(item, into: &format)
    readVariantAttributes(item, into: &format)
    if format.declaredFrameRate <= 0 {
      // Read across *all* item tracks rather than picking the video one: with no
      // `assetTrack` there is nothing to test the media type against, and
      // `currentVideoFrameRate` is documented as 0 for a non-video track.
      format.measuredFrameRate = item.tracks
        .map { Double($0.currentVideoFrameRate) }
        .max() ?? 0
    }
    return format
  }

  private func readTrackFormats(_ item: AVPlayerItem, into format: inout IosStreamFormat) {
    for track in item.tracks {
      guard let assetTrack = track.assetTrack else { continue }
      guard
        let description = assetTrack.formatDescriptions
          .compactMap({ AvPlayerEngine.formatDescription($0) })
          .first
      else { continue }
      let subType = AvPlayerEngine.fourCCString(CMFormatDescriptionGetMediaSubType(description))
      switch CMFormatDescriptionGetMediaType(description) {
      case kCMMediaType_Video:
        format.videoCodecFourCC = format.videoCodecFourCC ?? subType
        format.transferFunction =
          format.transferFunction
          ?? AvPlayerEngine.stringExtension(
            description,
            kCMFormatDescriptionExtension_TransferFunction
          )
        format.colorPrimaries =
          format.colorPrimaries
          ?? AvPlayerEngine.stringExtension(
            description,
            kCMFormatDescriptionExtension_ColorPrimaries
          )
        format.yCbCrMatrix =
          format.yCbCrMatrix
          ?? AvPlayerEngine.stringExtension(
            description,
            kCMFormatDescriptionExtension_YCbCrMatrix
          )
        let nominal = Double(assetTrack.nominalFrameRate)
        if nominal > 0, format.declaredFrameRate <= 0 { format.declaredFrameRate = nominal }
      case kCMMediaType_Audio:
        format.audioCodecFourCC = format.audioCodecFourCC ?? subType
        if format.audioChannels <= 0,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        {
          format.audioChannels = Int(asbd.pointee.mChannelsPerFrame)
        }
      default:
        break
      }
    }
  }

  /// The HLS route. Fills only what the track read left empty.
  ///
  /// **`variants` lives on `AVURLAsset`, not on `AVAsset`** (`API_AVAILABLE(ios(15.0))`),
  /// which is why this starts with a cast rather than reading `item.asset`
  /// directly — the first build of this file got that wrong. No `#available`
  /// guard: the pod's deployment target is iOS 15.0 (`iptvs_ios_player.podspec`,
  /// `s.platform = :ios, '15.0'`), so the property is unconditionally available
  /// and a redundant check would itself be diagnosed. Every item this engine
  /// builds carries an `AVURLAsset` (`load` constructs one), so the cast failing
  /// means someone changed `load`, not that a stream is unusual.
  ///
  /// Picking *which* variant: prefer the one whose declared presentation size
  /// matches what the item is actually presenting, since ABR may have settled on
  /// any rung of the ladder; fall back to the largest, which is the rung whose
  /// colorimetry the provider advertises the stream by. Both are heuristics —
  /// AVFoundation exposes no "currently playing variant" — but the dynamic range
  /// is a property of the *ladder* on every real provider, not of the rung, so
  /// the fallback costs nothing in practice.
  ///
  /// Deliberately reads only four members — `videoAttributes`,
  /// `presentationSize`, `codecTypes`, `videoRange`. Two more that would have
  /// been useful (`VideoAttributes.nominalFrameRate`,
  /// `AudioAttributes.formatIDs`) are left alone because their exact iOS 15
  /// spellings could not be verified without a compiler, and both produce merely
  /// decorative facts: the frame rate has a live-measured fallback
  /// (`currentVideoFrameRate`, snapped by `iosResolvedFrameRate`) and the audio
  /// codec is one info-panel row. The HDR badge — the whole reason this second
  /// source exists — depends on neither.
  private func readVariantAttributes(_ item: AVPlayerItem, into format: inout IosStreamFormat) {
    guard format.videoCodecFourCC == nil || format.transferFunction == nil else { return }
    guard let asset = item.asset as? AVURLAsset else { return }
    let variants = asset.variants
    guard !variants.isEmpty else { return }
    let presented = item.presentationSize
    let matched = variants.first { variant in
      guard presented != .zero, let attributes = variant.videoAttributes else { return false }
      return attributes.presentationSize == presented
    }
    let chosen =
      matched
      ?? variants.max { lhs, rhs in
        AvPlayerEngine.variantArea(lhs) < AvPlayerEngine.variantArea(rhs)
      }
    guard let video = chosen?.videoAttributes else { return }

    if format.videoCodecFourCC == nil, let codec = video.codecTypes.first {
      format.videoCodecFourCC = AvPlayerEngine.fourCCString(codec)
    }
    guard format.transferFunction == nil else { return }

    // Compared against an explicitly typed local rather than matched with
    // leading-dot patterns in a `switch`: `AVVideoRange` is a string-backed
    // struct (`NS_TYPED_ENUM`), not an enum, so `.sdr` needs a base the compiler
    // can see — and "cannot infer contextual base in reference to member 'sdr'"
    // was the third error in the first build of this file. An annotated local
    // makes the base explicit whichever way the type is imported.
    let range: AVVideoRange = video.videoRange
    if range == .pq {
      format.transferFunction = "pq"
    } else if range == .hlg {
      format.transferFunction = "hlg"
    } else if range == .sdr {
      format.transferFunction = "sdr"
    }
    // A PQ/HLG rung is BT.2020 by definition. An SDR one is deliberately left
    // without primaries, so the label falls through to plain "SDR" instead of
    // claiming a wide gamut the manifest never declared.
    if format.colorPrimaries == nil, format.transferFunction != nil, range != .sdr {
      format.colorPrimaries = "bt.2020"
    }
  }

  private static func variantArea(_ variant: AVAssetVariant) -> Double {
    guard let size = variant.videoAttributes?.presentationSize else { return 0 }
    return Double(size.width * size.height)
  }

  /// A `CMFormatDescription` out of an untyped `formatDescriptions` entry.
  ///
  /// `AVAssetTrack.formatDescriptions` is documented as `[Any]` — the ObjC
  /// property is an untyped `NSArray *` — and **a conditional cast from `Any` to
  /// a CoreFoundation type does not compile**: Swift cannot express a failable
  /// downcast to a CF type and diagnoses `as?` as always-succeeding, which is
  /// what broke the first build of this file. The honest form is to do by hand
  /// exactly what `as?` could not: check the CF type id, then cast
  /// unconditionally. `CFGetTypeID` is total over any object, so an entry that
  /// is something else (or a boxed Swift value) returns nil rather than trapping
  /// — which is the safety an `as!` on its own would have thrown away.
  private static func formatDescription(_ entry: Any) -> CMFormatDescription? {
    let object = entry as AnyObject
    guard CFGetTypeID(object) == CMFormatDescriptionGetTypeID() else { return nil }
    return (entry as! CMFormatDescription)  // swiftlint:disable:this force_cast
  }

  /// A `CMFormatDescription` string extension (colour tags), or nil.
  private static func stringExtension(
    _ description: CMFormatDescription,
    _ key: CFString
  ) -> String? {
    guard let value = CMFormatDescriptionGetExtension(description, extensionKey: key) else {
      return nil
    }
    return value as? String
  }

  /// A FourCC as text (`0x68766331` → `"hvc1"`), or nil for the zero code.
  ///
  /// ISO-Latin-1 rather than ASCII: the encoding must be total over four
  /// arbitrary bytes, and an unrecognised codec tag returning `nil` from a
  /// failed decode would look identical to "no codec", which is a different
  /// fact.
  static func fourCCString(_ code: FourCharCode) -> String? {
    guard code != 0 else { return nil }
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xFF),
      UInt8((code >> 16) & 0xFF),
      UInt8((code >> 8) & 0xFF),
      UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .isoLatin1)
  }

  // MARK: - Media selection

  /// The selectable options in `characteristic`'s group, already labelled.
  ///
  /// Two filters, each removing a control that would appear to do nothing:
  /// options the device cannot actually play (audio), and forced-only subtitle
  /// tracks, which follow the audio selection automatically and are not a user
  /// choice. Ids stay indexed against the *unfiltered* `group.options`, so a
  /// filtered row still maps back to the right option.
  func mediaOptions(for characteristic: AVMediaCharacteristic) -> [PlayerTrackOption] {
    guard let group = mediaSelectionGroup(characteristic) else { return [] }
    let playable: Set<ObjectIdentifier>? =
      characteristic == .audible
      ? Set(
        AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
          .map { ObjectIdentifier($0) }
      )
      : nil

    var options: [PlayerTrackOption] = []
    for (index, option) in group.options.enumerated() {
      if let playable, !playable.contains(ObjectIdentifier(option)) { continue }
      if characteristic == .legible,
        option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
      {
        continue
      }
      options.append(
        PlayerTrackOption(
          id: iosMediaOptionId(index: index),
          label: iosMediaOptionLabel(
            displayName: option.displayName,
            languageTag: option.extendedLanguageTag,
            index: index
          )
        )
      )
    }
    return options
  }

  /// The id of whatever is currently selected in `characteristic`'s group, or
  /// nil when nothing is (which the subtitle menu renders as "Off").
  func selectedMediaOptionId(for characteristic: AVMediaCharacteristic) -> String? {
    guard let item = player.currentItem, let group = mediaSelectionGroup(characteristic) else {
      return nil
    }
    guard let selected = item.currentMediaSelection.selectedMediaOption(in: group) else {
      return nil
    }
    guard let index = group.options.firstIndex(of: selected) else { return nil }
    return iosMediaOptionId(index: index)
  }

  /// Selects an option by id; a nil id (or the `playerSubtitleOffId` sentinel)
  /// deselects, where the group allows it.
  @discardableResult
  func selectMediaOption(id: String?, for characteristic: AVMediaCharacteristic) -> Bool {
    guard let item = player.currentItem, let group = mediaSelectionGroup(characteristic) else {
      return false
    }
    guard let index = iosMediaOptionIndex(id: id) else {
      // A group that requires a selection keeps the one it has rather than
      // silently ignoring the call — `allowsEmptySelection` is false for audio
      // on essentially every stream, and true for subtitles on essentially all.
      guard group.allowsEmptySelection else { return false }
      item.select(nil, in: group)
      return true
    }
    guard index >= 0, index < group.options.count else { return false }
    item.select(group.options[index], in: group)
    return true
  }

  private func mediaSelectionGroup(
    _ characteristic: AVMediaCharacteristic
  ) -> AVMediaSelectionGroup? {
    guard !released, let item = player.currentItem else { return nil }
    return item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
  }

  // MARK: - Time conversion

  /// `CMTime` → ms, mapping every "unknown" spelling to `0`.
  ///
  /// A live HLS item's duration is `CMTime.indefinite` and a cold position is
  /// `CMTime.invalid`; both are non-numeric and `CMTimeGetSeconds` on them
  /// yields NaN. Collapsing all of those to `0` is what lets Dart keep using
  /// `durationMs > 0` as the single meaning of "no useful duration" across
  /// Android and iOS.
  static func milliseconds(from time: CMTime) -> Int64 {
    guard time.isNumeric else { return 0 }
    let seconds = time.seconds
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int64(seconds * 1_000)
  }
}
