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
/// **Deliberately two modes, not Android's four.** Kotlin's `AspectMode` also
/// offers `16:9` and `4:3`, which the Compose/ExoPlayer host implements by
/// resizing its `PlayerView`. The iOS video surface is an `AVPlayerLayer` whose
/// only sizing knob is `videoGravity` (`resizeAspect` / `resizeAspectFill` /
/// `resize`), so a forced 16:9 or 4:3 would need a hand-computed layer transform
/// against the presentation size and a re-layout on every rotation — new
/// geometry code with no way to verify it short of a device. Fit and Fill are
/// the two modes that map onto `videoGravity` exactly. Recorded here rather than
/// silently dropped; see docs/ios.md "Known parity gaps".
public enum PlayerAspectMode: String, Equatable, CaseIterable, Sendable {
  case fit
  case fill

  public var label: String {
    switch self {
    case .fit: return "Fit"
    case .fill: return "Fill"
    }
  }

  public func next() -> PlayerAspectMode {
    switch self {
    case .fit: return .fill
    case .fill: return .fit
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
/// - `isTv` and the clock badge (Android TV only; tvOS is out of scope —
///   docs/ios.md).
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

  public var positionMs: Int64 = 0
  public var durationMs: Int64 = 0
  public var muted: Bool = false
  public var speed: Double = 1.0
  public var aspect: PlayerAspectMode = .fit

  /// True while at the live edge; false once the viewer has paused and fallen
  /// behind. Greys the LIVE badge and reveals the go-to-live button, exactly as
  /// on Android and Windows.
  public var liveSynced: Bool = true

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
  /// open. Port of Kotlin `PlayerUiState.pinned`.
  public var pinned: Bool { menu != .none || infoOpen }

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

  // MARK: - Derived labels

  public var resolutionBadge: String? {
    BadgeFormatting.resolutionBadge(width: videoWidth, height: videoHeight)
  }
  public var hdrBadge: String? { BadgeFormatting.hdrBadge(dynamicRange: dynamicRange) }
  public var fpsBadge: String? { BadgeFormatting.fpsBadge(fps: fps) }
  public var sourceBadge: String? { BadgeFormatting.sourceBadge(name: sourceName) }
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

  static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
