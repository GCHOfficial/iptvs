import Foundation

/// A selectable row in one of the player's list-menus (audio / subtitles /
/// speed). Port of Android's `TrackOption` (`.../player/PlayerUiState.kt`).
public struct PlayerTrackOption: Equatable, Sendable {
  public let id: String
  public let label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

/// Which list-menu, if any, is currently open. Port of Android's `PlayerMenu`,
/// which itself mirrors the Windows overlay's single-menu model: at most one
/// menu is open at a time, so this is an enum rather than a set of flags.
public enum PlayerMenu: String, Equatable, CaseIterable, Sendable {
  case none
  case audio
  case subtitles
  case speed
}

/// Aspect/zoom modes cycled by the aspect button.
///
/// **Three modes, not the other surfaces' five.** Kotlin's `AspectMode` also
/// offers `16:9` and `4:3`, which the Compose/ExoPlayer host implements by
/// resizing its `PlayerView`. The iOS video surface is an `AVPlayerLayer` whose
/// only sizing knob is `videoGravity`, so a forced 16:9 or 4:3 would need a
/// hand-computed layer transform against the presentation size and a re-layout
/// on every rotation — new geometry code with no way to verify it short of a
/// device. Recorded here rather than silently dropped; see docs/ios.md
/// "Known parity gaps".
///
/// The rule for inclusion is whether a mode maps onto `videoGravity` exactly,
/// and all three of these do: `resizeAspect`, `resizeAspectFill`, `resize`.
/// [stretch] is the last of them and is **not** a duplicate of [fill] —
/// `fill` crops to fill while keeping the picture's shape, `stretch` distorts
/// to fill and keeps every pixel. On a tall handset that difference is a fifth
/// of the frame or more, which is why a viewer asking to fill the screen may
/// mean either one.
public enum PlayerAspectMode: String, Equatable, CaseIterable, Sendable {
  case fit
  case fill
  case stretch

  public var label: String {
    switch self {
    case .fit: return "Fit"
    case .fill: return "Fill"
    case .stretch: return "Stretch"
    }
  }

  public func next() -> PlayerAspectMode {
    switch self {
    case .fit: return .fill
    case .fill: return .stretch
    case .stretch: return .fit
    }
  }
}

/// Sentinel id for the "Off" subtitle option. Port of Kotlin `SUBTITLE_OFF_ID`.
public let playerSubtitleOffId = "off"

/// Playback speeds offered in the speed menu (VOD only). Port of Kotlin
/// `SPEED_OPTIONS`, same values in the same order.
public let playerSpeedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

/// Stable option id for a speed value. Kotlin uses `Float.toString()`; Swift's
/// `String(Double)` produces the same `"0.5"` / `"1.0"` shapes, and
/// `Double(id)` parses them back, which is what the menu's select callback does.
public func playerSpeedId(_ value: Double) -> String {
  String(value)
}

/// Menu-row and button label for a speed, e.g. `"1×"` / `"0.75×"`. Port of
/// Kotlin `speedOptionLabel`/`PlayerUiState.speedLabel` (which agree).
public func playerSpeedOptionLabel(_ value: Double) -> String {
  "\(BadgeFormatting.trimmedDecimal(value))×"
}

/// Channel-count label for the info panel's Audio row. Port of Kotlin
/// `channelsLabel` (`InfoPanel.kt`), including the empty string for unknown.
public func playerAudioChannelsLabel(_ channels: Int) -> String {
  switch channels {
  case ..<1: return ""
  case 1: return "Mono"
  case 2: return "Stereo"
  case 6: return "5.1"
  case 8: return "7.1"
  default: return "\(channels)ch"
  }
}

/// Wall-clock `HH:mm` for EPG programme start/stop labels. Port of Kotlin
/// `clockHm`.
///
/// `en_US_POSIX` by default rather than the device locale: the format string is
/// a fixed pattern, and a non-POSIX locale can re-interpret it (localised
/// digits, or a 12-hour override on a device set to 12-hour time, which would
/// silently drop the AM/PM marker this pattern has no field for). The time zone
/// *is* the device's, because the EPG epochs are absolute instants that must
/// read as the viewer's local clock. Both are injectable so the tests are
/// deterministic.
public func playerClockHm(
  ms: Int64,
  timeZone: TimeZone = .current,
  locale: Locale = Locale(identifier: "en_US_POSIX")
) -> String {
  let formatter = DateFormatter()
  formatter.locale = locale
  formatter.timeZone = timeZone
  formatter.dateFormat = "HH:mm"
  return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/// `"20:00 – 20:45"` for the live strip's current-programme time range.
public func playerEpgRangeLabel(
  _ entry: PlayerEpgEntry,
  timeZone: TimeZone = .current,
  locale: Locale = Locale(identifier: "en_US_POSIX")
) -> String {
  let start = playerClockHm(ms: entry.startMs, timeZone: timeZone, locale: locale)
  let stop = playerClockHm(ms: entry.stopMs, timeZone: timeZone, locale: locale)
  return "\(start) – \(stop)"
}

/// `"Next · 20:45 – 21:30 · Programme"`. Port of Kotlin `LiveEpgStrip`'s next
/// line, separators included.
public func playerEpgNextLabel(
  _ entry: PlayerEpgEntry,
  timeZone: TimeZone = .current,
  locale: Locale = Locale(identifier: "en_US_POSIX")
) -> String {
  "Next · \(playerEpgRangeLabel(entry, timeZone: timeZone, locale: locale)) · \(entry.title)"
}

/// One label/value row of the stream-info panel.
public struct PlayerInfoRow: Equatable, Sendable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

/// The header + options + current selection for whichever list-menu is open.
public struct PlayerMenuContent: Equatable, Sendable {
  public let menu: PlayerMenu
  public let header: String
  public let options: [PlayerTrackOption]
  public let selectedId: String?

  public init(menu: PlayerMenu, header: String, options: [PlayerTrackOption], selectedId: String?) {
    self.menu = menu
    self.header = header
    self.options = options
    self.selectedId = selectedId
  }
}

/// Auto-hide policy for the control overlay. Port of Kotlin `HIDE_DELAY_VOD` /
/// `HIDE_DELAY_LIVE` and the `LaunchedEffect` guard in `PlayerControls.kt`.
///
/// Live gets the longer delay because its bar carries the EPG strip, which is
/// something the viewer reads rather than operates.
public enum PlayerAutoHide {
  public static let vodDelayMs: Int = 3500
  public static let liveDelayMs: Int = 4500

  public static func delayMs(isLive: Bool) -> Int {
    isLive ? liveDelayMs : vodDelayMs
  }

  /// Controls auto-hide only while they are up, nothing is *pinned* (an open
  /// menu or info panel), and playback is actually running. A paused player
  /// keeps its chrome — hiding it would leave a still frame with no affordance
  /// to resume.
  public static func shouldSchedule(controlsVisible: Bool, pinned: Bool, isPlaying: Bool) -> Bool {
    controlsVisible && !pinned && isPlaying
  }
}

/// The two messages the native terminal error surface can show.
///
/// **Fixed strings, never an `NSError`'s `localizedDescription`.** `AVError` and
/// its `NSUnderlyingError` routinely interpolate the failing URL, and provider
/// URLs carry credentials in the query string *and* in path segments (CLAUDE.md:
/// "Secrets must never reach logs, on-screen errors, or exported diagnostics").
/// A constant has nothing to leak; the machine-readable half of the failure goes
/// to Dart's diagnostics log as a `domain:code` through
/// ``PlaybackEventPayload/errorCode(domain:code:)`` instead.
///
/// Phrased to match the Dart overlay's existing voice ("Couldn't create the
/// video surface.", "Couldn't restart playback on this device.").
public enum PlayerErrorMessages {
  /// Playback was running and stopped hard. VOD only — live reconnects.
  public static let playbackStopped = "Playback stopped and couldn't be resumed."

  /// The stream never started and there is no way to hand it to the fallback
  /// engine.
  public static let cannotPlay = "Couldn't play this stream."
}

/// Everything the iOS player chrome renders from — the port of Android's
/// `PlayerUiState` (`android/app/src/main/kotlin/.../player/PlayerUiState.kt`),
/// minus the D-pad/TV-only pieces iOS has no counterpart for.
///
/// **A value type in `Core`, not an observable object.** Compose's `PlayerUiState`
/// is a `@Stable` class of `mutableStateOf` fields because recomposition is
/// driven by per-field observation; UIKit has no such machinery, so the iOS
/// split is different by necessity and better by accident: this struct holds the
/// state *and every derived label/visibility rule*, `swift test` covers all of
/// it on the CI host with no simulator, and `Classes/PlayerUiState.swift` is a
/// ~40-line observable box around it whose only job is "one mutation → one
/// render". Everything a reviewer would want to assert about the chrome —
/// which buttons appear, what a badge reads, which menu is open — is decided
/// here.
///
/// Deliberately absent versus Kotlin:
///
/// - `isTv` (Android TV only; tvOS is out of scope — docs/ios.md). The **clock
///   badge is not** absent, despite being TV-gated on Android: this controller
///   hides the status bar (`prefersStatusBarHidden`), and the same phone reaches
///   the Flutter overlay on mpv-routed channels — which shows an `HH:mm` badge
///   unconditionally — so gating it here would mean the *same device* showing a
///   clock on a Stalker channel and not on an HLS one. It is rendered straight
///   from the `nowMs` the view is already handed, so it needs no state field.
/// - `volume` (the volume *slider* is dropped on iOS: the hardware buttons and
///   the AirPlay route picker cover it — docs/ios.md "Plugin-package layout").
///   `muted` stays, since a mute toggle has no hardware equivalent.
/// - `inPip` (step 7 owns PiP; the controller dismisses itself for PiP rather
///   than rendering a chrome-less variant of this overlay).
/// - `videoUnsupported` (Android's DV-P5-on-non-DV-hardware notice). iOS has no
///   audio-plays-but-no-picture state: an unplayable container is
///   `engineFailed`, a whole cross-language handoff, not an in-place notice.
///
/// `supportsPip` is live as of step 7 — driven from
/// ``shouldOfferPictureInPicture(isSupported:isPossible:)``, which is why the
/// button stays hidden on a Simulator and on audio-only content.
///
/// Fields the later steps fill in are present and inert: `dynamicRange`,
/// `videoCodec`, `audioCodec`, `audioChannels`, `fps` (step 9),
/// `audioTracks`/`subtitleTracks` (step 9's media-selection read),
/// `reconnecting` (step 8). Each one's chrome is already written and simply
/// renders nothing until its step lands.
public struct PlayerChromeState: Equatable, Sendable {
  // MARK: Presentation

  public var title: String = ""
  public var sourceName: String?
  public var isLive: Bool = false
  public var epgNow: PlayerEpgEntry?
  public var epgNext: PlayerEpgEntry?

  // MARK: Playback

  public var isPlaying: Bool = false
  public var isBuffering: Bool = true
  public var ended: Bool = false

  /// True while step 8's live reconnect watchdog is re-establishing a dropped
  /// stream. Drives the centred "Reconnecting…" chip, which is deliberately
  /// **not** gated on `controlsVisible` — a stream that dropped while the
  /// chrome was hidden must still say so.
  public var reconnecting: Bool = false

  /// A **terminal** playback failure this controller cannot recover from on its
  /// own, or `nil` for the normal case.
  ///
  /// The native counterpart of Dart's `PlayerErrorOverlay`
  /// (`lib/player/player_overlay.dart`), and deliberately no more elaborate than
  /// it: a message plus Back and Retry. It exists because two paths otherwise
  /// dead-end on this platform, both VOD-only by construction —
  ///
  /// 1. a hard `AVPlayerItem` failure **mid-film** (``PlaybackDropOutcome``):
  ///    live reloads through the reconnect watchdog, but the watchdog is inert
  ///    for VOD, so nothing at all happened and the viewer was left with a
  ///    stopped picture under working chrome;
  /// 2. a load that never starts and cannot be handed to the fallback engine —
  ///    either because the plugin channel Dart listens on is gone, or because
  ///    the stream already played once so ``PlaybackStartAction/surfaceError``
  ///    applies rather than a handoff.
  ///
  /// Never carries error text from AVFoundation: `AVError` userInfo embeds the
  /// failing URL, which carries provider credentials. See ``PlayerErrorMessages``.
  public var errorMessage: String?

  public var positionMs: Int64 = 0
  public var durationMs: Int64 = 0
  public var muted: Bool = false
  public var speed: Double = 1.0
  /// Fill, matching every other surface (Dart `_aspectModeIndex`, Kotlin
  /// `AspectMode.Fill`). Crops to fill rather than letterboxing — identical to
  /// fit whenever the picture and the screen share a shape.
  public var aspect: PlayerAspectMode = .fill

  /// True while at the live edge; false once the viewer has fallen behind.
  /// Greys the LIVE badge and reveals the go-to-live button, exactly as on
  /// Android and Windows.
  ///
  /// Two independent rules can clear it: the **pause rule** (unchanged,
  /// immediate — the controller sets this `false` directly the instant
  /// playback pauses) and the **latched drift rule** in
  /// ``applyLiveLatency(driftMs:delayMs:aheadMs:)`` (accumulated drift
  /// reaching ``kLiveDriftWarnMs``). Both are **latched**: once false, only
  /// ``resetLiveLatency()`` — called at a load, a reconnect, "Go to live", a
  /// zap settle, or an engine swap — sets it back to true. This hysteresis is
  /// mandatory, not a nicety: the go-to-live chip removes itself while
  /// focused and hands focus to play/pause, so it must never flicker around a
  /// threshold a sample could cross and re-cross.
  ///
  /// **Wave 2 deliberately keys this on `driftMs`, never `delayMs`**
  /// (`live-latency-wave2-contract.md` "The Go to live latch"): `delayMs`
  /// includes a connect-time backlog the provider handed over before the
  /// first frame, and on iOS there is no way to trim it — a reconnect just
  /// re-receives the same backlog from the provider, and ExoPlayer's
  /// catch-up speed-up has no AVPlayer equivalent either. Offering "Go to
  /// live" for a number this controller cannot reduce would be a button that
  /// lies; the backlog is still **shown**, just not **latched on**.
  public var liveSynced: Bool = true

  /// Accumulated live drift in ms, from ``LiveLatencyTracker/driftMs`` —
  /// delay added *after* this stream's first frame, excluding any
  /// connect-time backlog. Feeds only the latch rule in
  /// ``applyLiveLatency(driftMs:delayMs:aheadMs:)``; no label reads it
  /// directly any more (wave 2 moved the badge/info-row display to
  /// ``liveDelayMs``), but it stays a stored field because it's a true
  /// accumulator the latch needs on every sample, not something derivable
  /// from what's displayed.
  public var liveDriftMs: Int64 = 0

  /// Accumulated live **delay** in ms, from ``LiveLatencyTracker/delayMs`` —
  /// drift plus the lower-bound connect-time backlog, minus anything
  /// credited back (`live-latency-wave2-contract.md` (a)). `0` until the
  /// controller's first post-baseline sample. Drives ``liveDelayBadgeLabel``
  /// and ``liveDelayInfoValue`` — never read directly by a view.
  public var liveDelayMs: Int64 = 0

  /// Buffered-ahead cushion in ms at the last latency sample, or `-1` when
  /// unknown (matches ``LiveLatencyTracker``'s sibling convention — `aheadMs`
  /// is engine-read, not tracker-derived, so it lives here rather than on the
  /// tracker itself).
  public var liveAheadMs: Int64 = -1

  // MARK: Favorite
  //
  // The Dart host owns the favorites store: it seeds these through the `open`
  // payload and reads `isFavorite` back on `nativeClosed`. There is no live
  // channel from the controller to Dart, so the toggle is local until exit —
  // same contract as Android's Intent extra + `RESULT_FAVORITE` (docs/player.md
  // "Live favorite star").

  public var canFavorite: Bool = false
  public var isFavorite: Bool = false

  // MARK: Tracks

  public var audioTracks: [PlayerTrackOption] = []
  public var selectedAudioId: String?
  public var subtitleTracks: [PlayerTrackOption] = []
  public var selectedSubtitleId: String? = playerSubtitleOffId

  // MARK: Stream info

  public var videoWidth: Int = 0
  public var videoHeight: Int = 0
  public var fps: Double = 0
  /// Already-formatted label, e.g. `"HDR10 · PQ"` — produced by
  /// ``dynamicRangeLabel(gamma:primaries:matrix:hdr10Plus:)``, never assembled
  /// in the view layer.
  public var dynamicRange: String = ""
  public var videoCodec: String = ""
  public var audioCodec: String = ""
  public var audioChannels: Int = 0

  // MARK: Chrome

  public var menu: PlayerMenu = .none
  public var infoOpen: Bool = false
  public var controlsVisible: Bool = true
  public var supportsPip: Bool = false

  /// True while `AVRoutePickerView`'s system route sheet is on screen.
  ///
  /// Its only job is to pin the chrome: the sheet is presented by AVKit, not by
  /// this overlay, so none of the interaction that keeps it up passes through
  /// `pokeControls`. Without this the auto-hide timer runs to completion behind
  /// the sheet and the viewer dismisses it onto a bare picture — the same
  /// "a pinned overlay never auto-hides" rule the open-menu case already has
  /// (docs/player.md). Set from `AVRoutePickerViewDelegate`'s will-begin/did-end
  /// pair.
  ///
  /// Deliberately **not** cleared by ``setControlsVisible(_:)`` the way `menu`
  /// and `infoOpen` are: those are this overlay's own chrome, while this one
  /// mirrors a system presentation whose lifetime only AVKit knows.
  public var routePickerPresenting: Bool = false

  public init() {}

  /// Seeds the presentation half from the `open` payload. Everything else keeps
  /// its default until the engine reports it.
  public init(request: PlayerOpenRequest) {
    self.init()
    title = request.title
    sourceName = request.sourceName
    isLive = request.isLive
    epgNow = request.epgNow
    epgNext = request.epgNext
    canFavorite = request.canFavorite
    isFavorite = request.isFavorite
  }

  // MARK: - Derived visibility

  /// Controls must stay pinned (no auto-hide) while a menu or the info panel is
  /// open. Port of Kotlin `PlayerUiState.pinned`, plus one iOS-only rung:
  /// the AirPlay route sheet, which Android has no counterpart for.
  public var pinned: Bool { menu != .none || infoOpen || routePickerPresenting }

  /// Audio button only when there's a real choice to make.
  public var showAudioButton: Bool { audioTracks.count > 1 }

  /// Subtitle button only when there's at least one real track to enable — an
  /// "Off"-only list is not a choice.
  public var showSubtitleButton: Bool { subtitleTracks.contains { $0.id != playerSubtitleOffId } }

  /// Speed and ±10s are VOD-only.
  public var showSpeedButton: Bool { !isLive }
  public var showSkipButtons: Bool { !isLive }

  /// **Live = no seek bar.** Keyed on the provider-declared `isLive` and
  /// nothing else — never on duration or on seekable ranges (CLAUDE.md:
  /// "Liveness is provider metadata, not inferred"; docs/ios.md records this as
  /// the fourth reason stock `AVPlayerViewController` was rejected, since its
  /// `requiresLinearPlayback` infers scrubbability from the item).
  public var showScrubber: Bool { !isLive }

  /// The live EPG strip sits where the VOD scrubber would be.
  public var showLiveEpgStrip: Bool { isLive && epgNow != nil }

  /// Go-to-live appears only once behind the edge, pairing with the greyed LIVE
  /// badge.
  public var showGoLiveButton: Bool { isLive && !liveSynced }

  public var showFavoriteButton: Bool { canFavorite }
  public var showPictureInPictureButton: Bool { supportsPip }
  public var showLiveBadge: Bool { isLive }

  /// The terminal error surface. Like the reconnect chip it renders outside the
  /// `controlsVisible` gate — an error that only appeared if you happened to tap
  /// first would be indistinguishable from the hang it exists to replace.
  public var showErrorOverlay: Bool { errorMessage != nil }

  /// "Reconnecting…" **and** a terminal error are mutually exclusive: the chip
  /// promises a retry is in progress, which a terminal error contradicts. The
  /// error wins, so a live reconnect that ends in a surfaced failure does not
  /// leave a spinner running behind it.
  public var showReconnectChip: Bool { reconnecting && errorMessage == nil }

  // MARK: - Derived labels

  public var resolutionBadge: String? {
    BadgeFormatting.resolutionBadge(width: videoWidth, height: videoHeight)
  }
  public var hdrBadge: String? { BadgeFormatting.hdrBadge(dynamicRange: dynamicRange) }
  public var fpsBadge: String? { BadgeFormatting.fpsBadge(fps: fps) }
  public var sourceBadge: String? { BadgeFormatting.sourceBadge(name: sourceName) }

  /// The LIVE badge's text — `"LIVE"` at the edge, `"LIVE -m:ss"` once behind
  /// by ``kLiveDriftWarnMs`` or more. Replaces the plain `"LIVE"` constant the
  /// view used to draw; ``showLiveBadge`` still decides whether to draw it at
  /// all. **Wave 2: reads ``liveDelayMs``, not ``liveDriftMs``**
  /// (`live-latency-wave2-contract.md` (a) — "the badge ... use[s] delayMs"),
  /// so a connect-time backlog the viewer never saw added to the stream is
  /// still shown here, even though it never latches ``liveSynced`` false (see
  /// that property's doc).
  public var liveDelayBadgeLabel: String {
    LiveLatencyFormatting.liveDelayBadgeLabel(driftMs: liveDelayMs)
  }

  /// The stream-info panel's "Live delay" row value, or `nil` for VOD (the row
  /// doesn't exist off live content at all — see ``infoRows()``). Wave 2:
  /// reads ``liveDelayMs``, same reasoning as ``liveDelayBadgeLabel``.
  public var liveDelayInfoValue: String? {
    guard isLive else { return nil }
    return LiveLatencyFormatting.liveDelayInfoValue(driftMs: liveDelayMs, aheadMs: liveAheadMs)
  }

  public var speedLabel: String { playerSpeedOptionLabel(speed) }
  public var aspectLabel: String { aspect.label }
  public var positionLabel: String { BadgeFormatting.formatTime(ms: positionMs) }
  public var durationLabel: String { BadgeFormatting.formatTime(ms: durationMs) }

  /// Scrubber fill, clamped to `0...1`. `0` when the duration isn't known yet,
  /// which is also every live item (`CMTime.indefinite` normalises to `0`).
  public var progressFraction: Double {
    guard durationMs > 0 else { return 0 }
    return min(max(Double(positionMs) / Double(durationMs), 0), 1)
  }

  /// Elapsed fraction of the current live programme at `nowMs`, or `0` with no
  /// EPG. Port of Kotlin `EpgEntry.progressAt` at the call site.
  public func liveProgrammeProgress(nowMs: Int64) -> Double {
    guard let epgNow else { return 0 }
    return epgNow.progress(at: nowMs)
  }

  // MARK: - Derived content

  /// The open menu's header/options/selection, or nil when none is open.
  /// The speed menu's options are synthesised from ``playerSpeedOptions`` here
  /// rather than stored, exactly as Kotlin's `PlayerMenusLayer` does.
  public func menuContent() -> PlayerMenuContent? {
    switch menu {
    case .none:
      return nil
    case .audio:
      return PlayerMenuContent(
        menu: .audio,
        header: "Audio",
        options: audioTracks,
        selectedId: selectedAudioId
      )
    case .subtitles:
      return PlayerMenuContent(
        menu: .subtitles,
        header: "Subtitles",
        options: subtitleTracks,
        selectedId: selectedSubtitleId
      )
    case .speed:
      return PlayerMenuContent(
        menu: .speed,
        header: "Playback speed",
        options: playerSpeedOptions.map {
          PlayerTrackOption(id: playerSpeedId($0), label: playerSpeedOptionLabel($0))
        },
        selectedId: playerSpeedId(speed)
      )
    }
  }

  /// Stream-info rows, omitting everything not yet known. Port of Kotlin
  /// `InfoPanel`'s `buildList`, same labels in the same order — an empty result
  /// means the panel renders nothing but its header.
  public func infoRows() -> [PlayerInfoRow] {
    var rows: [PlayerInfoRow] = []
    if videoWidth > 0, videoHeight > 0 {
      rows.append(PlayerInfoRow(label: "Resolution", value: "\(videoWidth) × \(videoHeight)"))
    }
    if fps > 0 {
      rows.append(
        PlayerInfoRow(label: "Frame rate", value: "\(BadgeFormatting.trimmedDecimal(fps)) fps")
      )
    }
    if !PlayerChromeState.isBlank(dynamicRange) {
      rows.append(PlayerInfoRow(label: "Dynamic range", value: dynamicRange))
    }
    if !PlayerChromeState.isBlank(videoCodec) {
      rows.append(PlayerInfoRow(label: "Video", value: videoCodec))
    }
    if !PlayerChromeState.isBlank(audioCodec) {
      let channels = playerAudioChannelsLabel(audioChannels)
      let value = channels.isEmpty ? audioCodec : "\(audioCodec) · \(channels)"
      rows.append(PlayerInfoRow(label: "Audio", value: value))
    }
    // Live only (`live-latency-contract.md`), and — unlike every row above —
    // not gated on "known yet": `0` drift with an unknown buffer is still a
    // real, displayable answer ("at the live edge"), not an absent one. This
    // codebase has no existing buffer/network-related row to sit after, so it
    // lands at the end.
    if isLive, let value = liveDelayInfoValue {
      rows.append(PlayerInfoRow(label: "Live delay", value: value))
    }
    return rows
  }

  /// Live programme synopsis shown under the info rows, or nil. VOD never has
  /// one (there is no EPG), matching Kotlin's `state.isLive &&` guard.
  public var infoSynopsis: String? {
    guard isLive, let synopsis = epgNow?.description, !PlayerChromeState.isBlank(synopsis) else {
      return nil
    }
    return synopsis
  }

  /// True when the info panel would render nothing at all — no rows and no
  /// synopsis. Kotlin returns early from the composable in that case; the iOS
  /// view uses this to stay hidden rather than showing an empty card.
  public var infoPanelIsEmpty: Bool { infoRows().isEmpty && infoSynopsis == nil }

  // MARK: - Mutations
  //
  // Pure, so the ladder and the toggle semantics are pinned by `swift test`
  // rather than living inside a UIKit action handler where nothing can reach
  // them.

  /// Toggles `target` open, closing whatever other menu was open. Opening a
  /// menu deliberately does **not** close the info panel — the Back/tap ladder
  /// peels menu *then* info, and collapsing both at once would swallow a rung.
  public mutating func toggleMenu(_ target: PlayerMenu) {
    guard target != .none else {
      menu = .none
      return
    }
    menu = (menu == target) ? .none : target
  }

  public mutating func toggleInfo() {
    infoOpen.toggle()
  }

  /// Hiding the controls closes the menu and info panel with them — they are
  /// chrome, and leaving them armed would make the next reveal pop up a panel
  /// the viewer never asked for. Port of Kotlin's `LaunchedEffect
  /// (state.controlsVisible)` cleanup.
  public mutating func setControlsVisible(_ visible: Bool) {
    controlsVisible = visible
    if !visible {
      menu = .none
      infoOpen = false
    }
  }

  public mutating func cycleAspect() {
    aspect = aspect.next()
  }

  /// Folds in one latency sample. Stores the raw figures for the
  /// badge/info-row formatters and, once **drift** (not delay — see
  /// ``liveSynced``'s doc) reaches ``kLiveDriftWarnMs``, latches
  /// ``liveSynced`` false — **only** false: a lower later reading (which
  /// should not occur, since drift only grows between resets, but the rule
  /// holds regardless) must never resync a viewer the pause rule or an
  /// earlier sample already desynced. Call on every surface tick while live;
  /// harmless, if pointless, to call for VOD.
  ///
  /// `driftMs` is ``LiveLatencyTracker/driftMs`` (feeds the latch only);
  /// `delayMs` is ``LiveLatencyTracker/delayMs`` (feeds the two labels only;
  /// `live-latency-wave2-contract.md` (a)). The caller always has both, since
  /// both are plain reads off the same tracker instance after one
  /// `sample(_:aheadMs:)` call.
  public mutating func applyLiveLatency(driftMs: Int64, delayMs: Int64, aheadMs: Int64) {
    liveDriftMs = driftMs
    liveDelayMs = delayMs
    liveAheadMs = aheadMs
    if driftMs >= kLiveDriftWarnMs { liveSynced = false }
  }

  /// Clears accumulated drift/delay and the desync latch — called at every
  /// wave-1 reset point (load, reconnect, "Go to live", zap settle, engine
  /// swap; see ``LiveLatencyResetReason``). The **only** place ``liveSynced``
  /// is set back to `true` once the drift rule has cleared it; the pause
  /// rule's direct `false` is set by the controller elsewhere and is
  /// unaffected by this being absent from that path, by design.
  public mutating func resetLiveLatency() {
    liveDriftMs = 0
    liveDelayMs = 0
    liveAheadMs = -1
    liveSynced = true
  }

  static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
