import UIKit

/// Everything the overlay can ask the player to do. One enum + one closure
/// instead of a fourteen-method delegate protocol: the view makes no decisions,
/// so every case is a bare "the user pressed this".
enum PlayerControlsAction {
  /// The **X**. An explicit Exit that skips the Back ladder entirely, matching
  /// every other platform's on-screen back control (docs/player.md, Windows:
  /// "the on-screen back-*arrow* button still exits directly").
  case close
  case playPause
  case seekBy(Int64)
  case seekToFraction(Double)
  case toggleMute
  case toggleFavorite
  case goLive
  case cycleAspect
  case enterPictureInPicture
  case toggleMenu(PlayerMenu)
  case toggleInfo
  case selectMenuOption(String)
}

/// The native player's control overlay — the port of Android's `ControlsOverlay`
/// + `TopBar` + `BottomBar` + `TransportControls` + `RightCluster`
/// (`.../player/PlayerControls.kt`), and the direct counterpart of the Windows
/// GDI overlay's two bars.
///
/// **Two structural invariants, both load-bearing and both inherited from step
/// 3:**
///
/// 1. **Scrim full-bleed, controls inset to the safe area.** The gradient runs
///    to the physical edge — under the notch/Dynamic Island and the home
///    indicator — because that is the only way it reads over video that itself
///    reaches the edge. Every *control* lives inside `safeContainer`, which is
///    pinned to `safeAreaLayoutGuide`. This is the same split as the Compose
///    overlay's `safeDrawingPadding()` groups and the Windows overlay's bar
///    insets; new chrome goes inside `safeContainer`, never against `bounds`.
/// 2. **The view holds no policy.** Which buttons exist, what the badges read,
///    which menu is open and what "behind the live edge" means are all
///    `PlayerChromeState` in `Core`, where `swift test` can reach them. This
///    file lays views out and forwards taps.
///
/// The "Reconnecting…" chip is deliberately outside the visibility gate: a
/// stream that dropped while the chrome was hidden must still say so.
final class PlayerControlsView: UIView {
  var onAction: ((PlayerControlsAction) -> Void)?

  // MARK: Scrim + containers

  private let topScrim = PlayerGradientView(colors: [PlayerColors.scrimTop, .clear])
  private let bottomScrim = PlayerGradientView(colors: [.clear, PlayerColors.scrimBottom])
  private let safeContainer = UIView()

  // MARK: Top bar

  private let topBar = UIStackView()
  private let titleRow = UIStackView()
  private let compactBadgeRow = UIStackView()
  private let badgesStack = UIStackView()
  private let titleLabel = UILabel()
  private lazy var closeButton = PlayerIconButton(
    systemName: "xmark",
    accessibilityLabel: "Close player",
    fallbackTitle: "Close"
  ) { [weak self] in self?.onAction?(.close) }
  private let sourceBadge = PlayerBadgeLabel()
  private let liveBadge = PlayerBadgeLabel(font: PlayerFonts.livePill)
  private let resolutionBadge = PlayerBadgeLabel()
  private let hdrBadge = PlayerBadgeLabel()
  private let fpsBadge = PlayerBadgeLabel()

  // MARK: Bottom bar

  private let bottomBar = UIStackView()
  private let scrubberRow = UIStackView()
  private let positionLabel = UILabel()
  private let durationLabel = UILabel()
  private let scrubber = PlayerScrubberView()

  private let epgStrip = UIStackView()
  private let epgTitleRow = UIStackView()
  private let epgTitleLabel = UILabel()
  private let epgRangeLabel = UILabel()
  private let epgProgress = PlayerProgressBarView()
  private let epgNextLabel = UILabel()

  private let primaryRow = UIStackView()
  private let secondaryRow = UIStackView()
  private let transportStack = UIStackView()
  private let clusterStack = UIStackView()

  private lazy var playPauseButton = PlayerIconButton(
    systemName: "play.fill",
    accessibilityLabel: "Play",
    fallbackTitle: "Play"
  ) { [weak self] in self?.onAction?(.playPause) }
  private lazy var back10Button = PlayerIconButton(
    systemName: "gobackward.10",
    accessibilityLabel: "Back 10 seconds",
    fallbackTitle: "-10"
  ) { [weak self] in self?.onAction?(.seekBy(-10_000)) }
  private lazy var forward10Button = PlayerIconButton(
    systemName: "goforward.10",
    accessibilityLabel: "Forward 10 seconds",
    fallbackTitle: "+10"
  ) { [weak self] in self?.onAction?(.seekBy(10_000)) }
  private lazy var muteButton = PlayerIconButton(
    systemName: "speaker.wave.2.fill",
    accessibilityLabel: "Mute",
    fallbackTitle: "Mute"
  ) { [weak self] in self?.onAction?(.toggleMute) }
  private lazy var goLiveButton = PlayerTextButton(
    title: "LIVE",
    accessibilityLabel: "Go to live"
  ) { [weak self] in self?.onAction?(.goLive) }
  private lazy var favoriteButton = PlayerIconButton(
    systemName: "star",
    accessibilityLabel: "Add to favorites",
    fallbackTitle: "Fav"
  ) { [weak self] in self?.onAction?(.toggleFavorite) }
  private lazy var speedButton = PlayerTextButton(
    title: "1×",
    accessibilityLabel: "Playback speed"
  ) { [weak self] in self?.onAction?(.toggleMenu(.speed)) }
  private lazy var audioButton = PlayerIconButton(
    systemName: "waveform",
    accessibilityLabel: "Audio track",
    fallbackTitle: "Audio"
  ) { [weak self] in self?.onAction?(.toggleMenu(.audio)) }
  private lazy var subtitlesButton = PlayerIconButton(
    systemName: "captions.bubble",
    accessibilityLabel: "Subtitles",
    fallbackTitle: "CC"
  ) { [weak self] in self?.onAction?(.toggleMenu(.subtitles)) }
  private lazy var aspectButton = PlayerTextButton(
    title: PlayerAspectMode.fit.label,
    accessibilityLabel: "Aspect ratio"
  ) { [weak self] in self?.onAction?(.cycleAspect) }
  private lazy var pipButton = PlayerIconButton(
    systemName: "pip.enter",
    accessibilityLabel: "Picture in picture",
    fallbackTitle: "PiP"
  ) { [weak self] in self?.onAction?(.enterPictureInPicture) }
  private lazy var infoButton = PlayerIconButton(
    systemName: "info.circle",
    accessibilityLabel: "Stream info",
    fallbackTitle: "Info"
  ) { [weak self] in self?.onAction?(.toggleInfo) }

  // MARK: Panels + notices

  private let listMenu = ListMenuView()
  private let infoPanel = InfoPanelView()
  private let reconnectChip = UIView()

  /// Nil until the first layout pass, so whichever arrangement the real width
  /// calls for is applied once rather than assumed.
  private var isCompact: Bool?

  // MARK: - Construction

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    buildHierarchy()
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerControlsView is created in code, never from a nib")
  }

  private func buildHierarchy() {
    addSubview(topScrim)
    addSubview(bottomScrim)
    addSubview(safeContainer)

    topScrim.translatesAutoresizingMaskIntoConstraints = false
    bottomScrim.translatesAutoresizingMaskIntoConstraints = false
    safeContainer.translatesAutoresizingMaskIntoConstraints = false

    buildTopBar()
    buildBottomBar()
    buildPanels()
    buildReconnectChip()

    NSLayoutConstraint.activate([
      // Full-bleed scrim: to the physical edges, deliberately not the safe area.
      topScrim.topAnchor.constraint(equalTo: topAnchor),
      topScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
      topScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
      topScrim.heightAnchor.constraint(equalToConstant: PlayerDimens.topScrimHeight),

      bottomScrim.bottomAnchor.constraint(equalTo: bottomAnchor),
      bottomScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomScrim.heightAnchor.constraint(equalToConstant: PlayerDimens.bottomScrimHeight),

      // Controls: never under the notch, never under the home indicator.
      safeContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      safeContainer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      safeContainer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      safeContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
    ])
  }

  private func buildTopBar() {
    titleLabel.font = PlayerFonts.title
    titleLabel.textColor = PlayerColors.textHi
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    // The title is what gives way when the bar is narrow — the badges carry
    // information that can't be inferred from anywhere else on screen.
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    badgesStack.axis = .horizontal
    badgesStack.alignment = .center
    badgesStack.spacing = PlayerDimens.controlSpacing
    for badge in [sourceBadge, liveBadge, resolutionBadge, hdrBadge, fpsBadge] {
      badgesStack.addArrangedSubview(badge)
    }

    titleRow.axis = .horizontal
    titleRow.alignment = .center
    titleRow.spacing = 14
    titleRow.addArrangedSubview(closeButton)
    titleRow.addArrangedSubview(titleLabel)
    // `badgesStack` joins here in the wide arrangement and moves to
    // `compactBadgeRow` below the breakpoint — see `applyCompactLayout`.
    titleRow.addArrangedSubview(badgesStack)

    compactBadgeRow.axis = .horizontal
    compactBadgeRow.alignment = .center
    compactBadgeRow.spacing = PlayerDimens.controlSpacing
    compactBadgeRow.addArrangedSubview(PlayerControlsView.flexibleSpacer())
    compactBadgeRow.isHidden = true

    topBar.axis = .vertical
    topBar.alignment = .fill
    topBar.spacing = 6
    topBar.translatesAutoresizingMaskIntoConstraints = false
    topBar.addArrangedSubview(titleRow)
    topBar.addArrangedSubview(compactBadgeRow)
    safeContainer.addSubview(topBar)

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: safeContainer.topAnchor, constant: 12),
      topBar.leadingAnchor.constraint(
        equalTo: safeContainer.leadingAnchor,
        constant: PlayerDimens.edgePadding
      ),
      topBar.trailingAnchor.constraint(
        equalTo: safeContainer.trailingAnchor,
        constant: -PlayerDimens.edgePadding
      ),
    ])
  }

  private func buildBottomBar() {
    // --- VOD scrubber ---------------------------------------------------
    for label in [positionLabel, durationLabel] {
      label.font = PlayerFonts.time
      label.numberOfLines = 1
    }
    positionLabel.textColor = PlayerColors.textHi
    durationLabel.textColor = PlayerColors.textLo
    positionLabel.text = "0:00"
    durationLabel.text = "0:00"

    scrubber.onScrub = { [weak self] fraction in
      self?.onAction?(.seekToFraction(fraction))
    }

    scrubberRow.axis = .horizontal
    scrubberRow.alignment = .center
    scrubberRow.spacing = 8
    scrubberRow.addArrangedSubview(positionLabel)
    scrubberRow.addArrangedSubview(scrubber)
    scrubberRow.addArrangedSubview(durationLabel)
    NSLayoutConstraint.activate([
      positionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
      scrubber.heightAnchor.constraint(equalToConstant: PlayerDimens.scrubberHeight),
    ])

    // --- Live EPG strip (sits where the scrubber would be) ---------------
    epgTitleLabel.font = PlayerFonts.epgTitle
    epgTitleLabel.textColor = PlayerColors.textHi
    epgTitleLabel.numberOfLines = 1
    epgTitleLabel.lineBreakMode = .byTruncatingTail
    epgTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    epgRangeLabel.font = PlayerFonts.epgMeta
    epgRangeLabel.textColor = PlayerColors.textLo
    epgRangeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    epgNextLabel.font = PlayerFonts.epgMeta
    epgNextLabel.textColor = PlayerColors.textLo
    epgNextLabel.numberOfLines = 1
    epgNextLabel.lineBreakMode = .byTruncatingTail

    epgTitleRow.axis = .horizontal
    epgTitleRow.alignment = .center
    epgTitleRow.spacing = 8
    epgTitleRow.addArrangedSubview(epgTitleLabel)
    epgTitleRow.addArrangedSubview(epgRangeLabel)

    epgStrip.axis = .vertical
    epgStrip.alignment = .fill
    epgStrip.spacing = 6
    epgStrip.addArrangedSubview(epgTitleRow)
    epgStrip.addArrangedSubview(epgProgress)
    epgStrip.addArrangedSubview(epgNextLabel)
    epgProgress.heightAnchor.constraint(equalToConstant: PlayerDimens.trackHeight).isActive = true

    // --- Transport + right cluster ---------------------------------------
    transportStack.axis = .horizontal
    transportStack.alignment = .center
    transportStack.spacing = PlayerDimens.controlSpacing
    for button in [playPauseButton, back10Button, forward10Button, muteButton] {
      transportStack.addArrangedSubview(button)
    }

    clusterStack.axis = .horizontal
    clusterStack.alignment = .center
    clusterStack.spacing = PlayerDimens.controlSpacing
    // Order mirrors Kotlin's `RightCluster`: go-live, favorite, speed, audio,
    // subtitles, aspect, PiP, info.
    clusterStack.addArrangedSubview(goLiveButton)
    clusterStack.addArrangedSubview(favoriteButton)
    clusterStack.addArrangedSubview(speedButton)
    clusterStack.addArrangedSubview(audioButton)
    clusterStack.addArrangedSubview(subtitlesButton)
    clusterStack.addArrangedSubview(aspectButton)
    clusterStack.addArrangedSubview(pipButton)
    clusterStack.addArrangedSubview(infoButton)

    primaryRow.axis = .horizontal
    primaryRow.alignment = .center
    primaryRow.spacing = PlayerDimens.controlSpacing
    primaryRow.addArrangedSubview(transportStack)
    primaryRow.addArrangedSubview(PlayerControlsView.flexibleSpacer())
    // `clusterStack` joins here in the wide arrangement; below the breakpoint it
    // moves to `secondaryRow` — see `applyCompactLayout`.
    primaryRow.addArrangedSubview(clusterStack)

    secondaryRow.axis = .horizontal
    secondaryRow.alignment = .center
    secondaryRow.spacing = PlayerDimens.controlSpacing
    secondaryRow.addArrangedSubview(PlayerControlsView.flexibleSpacer())
    secondaryRow.isHidden = true

    bottomBar.axis = .vertical
    bottomBar.alignment = .fill
    bottomBar.spacing = 12
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addArrangedSubview(scrubberRow)
    bottomBar.addArrangedSubview(epgStrip)
    bottomBar.addArrangedSubview(primaryRow)
    bottomBar.addArrangedSubview(secondaryRow)
    safeContainer.addSubview(bottomBar)

    NSLayoutConstraint.activate([
      bottomBar.leadingAnchor.constraint(
        equalTo: safeContainer.leadingAnchor,
        constant: PlayerDimens.edgePadding
      ),
      bottomBar.trailingAnchor.constraint(
        equalTo: safeContainer.trailingAnchor,
        constant: -PlayerDimens.edgePadding
      ),
      bottomBar.bottomAnchor.constraint(equalTo: safeContainer.bottomAnchor, constant: -18),
    ])
  }

  private func buildPanels() {
    safeContainer.addSubview(listMenu)
    safeContainer.addSubview(infoPanel)
    listMenu.isHidden = true
    infoPanel.isHidden = true
    listMenu.onSelect = { [weak self] id in
      self?.onAction?(.selectMenuOption(id))
    }

    // Both "stay off the other bar" constraints are 999, not required: on a
    // short landscape phone a tall info panel or a long track list genuinely
    // cannot fit between the bars, and a *required* constraint there would make
    // the layout unsatisfiable — UIKit then drops one of its choosing and logs a
    // wall of constraint output. At 999 the panel is allowed to overlap the bar
    // slightly instead, which is a visible cosmetic compromise rather than an
    // arbitrary broken layout.
    let menuTop = listMenu.topAnchor.constraint(
      greaterThanOrEqualTo: safeContainer.topAnchor,
      constant: 8
    )
    menuTop.priority = UILayoutPriority(999)
    let infoBottom = infoPanel.bottomAnchor.constraint(
      lessThanOrEqualTo: bottomBar.topAnchor,
      constant: -12
    )
    infoBottom.priority = UILayoutPriority(999)

    NSLayoutConstraint.activate([
      // Anchored above the bottom bar's right cluster, the way Kotlin aligns it
      // BottomEnd with a 96dp bottom padding — expressed here against the bar
      // itself so a taller live bar (EPG strip) pushes the menu up with it.
      listMenu.trailingAnchor.constraint(
        equalTo: safeContainer.trailingAnchor,
        constant: -PlayerDimens.edgePadding
      ),
      listMenu.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),
      menuTop,

      infoPanel.trailingAnchor.constraint(
        equalTo: safeContainer.trailingAnchor,
        constant: -PlayerDimens.edgePadding
      ),
      infoPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
      infoBottom,
    ])
  }

  private func buildReconnectChip() {
    reconnectChip.translatesAutoresizingMaskIntoConstraints = false
    reconnectChip.backgroundColor = PlayerColors.panel
    reconnectChip.layer.cornerRadius = PlayerDimens.menuCorner
    reconnectChip.layer.masksToBounds = true
    reconnectChip.isHidden = true
    // Not a control: it must never eat a tap that would otherwise reveal the
    // chrome.
    reconnectChip.isUserInteractionEnabled = false

    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.color = PlayerColors.accent
    spinner.startAnimating()

    let label = UILabel()
    label.text = "Reconnecting…"
    label.font = PlayerFonts.notice
    label.textColor = PlayerColors.textHi

    let row = UIStackView(arrangedSubviews: [spinner, label])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    reconnectChip.addSubview(row)
    // Added last so it sits above the bars, and outside `safeContainer` so it
    // survives the chrome being hidden.
    addSubview(reconnectChip)

    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: reconnectChip.topAnchor, constant: 14),
      row.bottomAnchor.constraint(equalTo: reconnectChip.bottomAnchor, constant: -14),
      row.leadingAnchor.constraint(equalTo: reconnectChip.leadingAnchor, constant: 20),
      row.trailingAnchor.constraint(equalTo: reconnectChip.trailingAnchor, constant: -20),
      reconnectChip.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
      reconnectChip.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
    ])
  }

  private static func flexibleSpacer() -> UIView {
    let spacer = UIView()
    spacer.isUserInteractionEnabled = false
    spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
    return spacer
  }

  // MARK: - Responsive arrangement

  /// Below `PlayerDimens.compactWidth` (phone portrait) the badge cluster and
  /// the right-hand button cluster each wrap onto their own row, exactly as the
  /// Compose overlay's `BoxWithConstraints` branches do.
  ///
  /// Reparenting two stacks is cheaper and far less fragile than maintaining two
  /// parallel constraint sets, and `UIStackView.addArrangedSubview` handles the
  /// removal from the old parent. Doing it from `layoutSubviews` is safe because
  /// `isCompact` gates it: the extra layout pass it triggers cannot flip the
  /// flag back.
  override func layoutSubviews() {
    super.layoutSubviews()
    let compact = bounds.width < PlayerDimens.compactWidth
    guard compact != isCompact else { return }
    isCompact = compact
    applyCompactLayout(compact)
  }

  private func applyCompactLayout(_ compact: Bool) {
    if compact {
      if badgesStack.superview !== compactBadgeRow {
        compactBadgeRow.insertArrangedSubview(badgesStack, at: 0)
      }
      compactBadgeRow.isHidden = false
      if clusterStack.superview !== secondaryRow {
        secondaryRow.insertArrangedSubview(clusterStack, at: 0)
      }
      secondaryRow.isHidden = false
    } else {
      if badgesStack.superview !== titleRow {
        titleRow.addArrangedSubview(badgesStack)
      }
      compactBadgeRow.isHidden = true
      if clusterStack.superview !== primaryRow {
        primaryRow.addArrangedSubview(clusterStack)
      }
      secondaryRow.isHidden = true
    }
  }

  // MARK: - Render

  /// Applies `state` to every control. Idempotent and cheap enough to run on
  /// each 500 ms progress tick — the state box already filters out no-op
  /// changes, and the sub-views that would otherwise churn (menu rows, info
  /// rows, SF symbols) each guard on their own last-rendered value.
  ///
  /// - Parameter nowMs: wall-clock epoch for the live EPG progress bar. Passed
  ///   in rather than read here so the clock stays a controller concern and the
  ///   view has no hidden time dependency.
  func render(_ state: PlayerChromeState, nowMs: Int64) {
    reconnectChip.isHidden = !state.reconnecting

    let visible = state.controlsVisible
    topScrim.isHidden = !visible
    bottomScrim.isHidden = !visible
    safeContainer.isHidden = !visible
    guard visible else { return }

    renderTopBar(state)
    renderProgress(state, nowMs: nowMs)
    renderTransport(state)
    renderCluster(state)

    listMenu.render(state.menuContent())
    infoPanel.render(state)
  }

  private func renderTopBar(_ state: PlayerChromeState) {
    titleLabel.text = state.title
    sourceBadge.apply(state.sourceBadge)
    resolutionBadge.apply(state.resolutionBadge)
    hdrBadge.apply(state.hdrBadge)
    hdrBadge.backgroundColor = PlayerColors.accent
    fpsBadge.apply(state.fpsBadge)

    liveBadge.isHidden = !state.showLiveBadge
    if state.showLiveBadge {
      liveBadge.text = "LIVE"
      // Red at the live edge, grey once behind — the pairing with the go-to-live
      // button that every other overlay uses.
      liveBadge.backgroundColor = state.liveSynced ? PlayerColors.live : PlayerColors.trackInactive
      liveBadge.textColor = state.liveSynced ? .white : PlayerColors.textLo
    }
  }

  private func renderProgress(_ state: PlayerChromeState, nowMs: Int64) {
    scrubberRow.isHidden = !state.showScrubber
    if state.showScrubber {
      positionLabel.text = state.positionLabel
      durationLabel.text = state.durationLabel
      // Never fight the finger: while a drag is in flight the thumb follows the
      // touch, not the (pre-seek) player position.
      if !scrubber.isTracking {
        scrubber.progress = state.progressFraction
      }
    }

    epgStrip.isHidden = !state.showLiveEpgStrip
    guard state.showLiveEpgStrip, let now = state.epgNow else { return }
    epgTitleLabel.text = now.title
    epgRangeLabel.text = playerEpgRangeLabel(now)
    epgProgress.progress = state.liveProgrammeProgress(nowMs: nowMs)
    if let next = state.epgNext {
      epgNextLabel.text = playerEpgNextLabel(next)
      epgNextLabel.isHidden = false
    } else {
      epgNextLabel.isHidden = true
    }
  }

  private func renderTransport(_ state: PlayerChromeState) {
    playPauseButton.setSymbol(
      state.isPlaying ? "pause.fill" : "play.fill",
      fallbackTitle: state.isPlaying ? "Pause" : "Play"
    )
    playPauseButton.accessibilityLabel = state.isPlaying ? "Pause" : "Play"

    back10Button.isHidden = !state.showSkipButtons
    forward10Button.isHidden = !state.showSkipButtons

    muteButton.setSymbol(
      state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
      fallbackTitle: state.muted ? "Unmute" : "Mute"
    )
    muteButton.accessibilityLabel = state.muted ? "Unmute" : "Mute"
  }

  private func renderCluster(_ state: PlayerChromeState) {
    goLiveButton.isHidden = !state.showGoLiveButton

    favoriteButton.isHidden = !state.showFavoriteButton
    if state.showFavoriteButton {
      favoriteButton.setSymbol(
        state.isFavorite ? "star.fill" : "star",
        fallbackTitle: state.isFavorite ? "Unfav" : "Fav"
      )
      favoriteButton.accessibilityLabel =
        state.isFavorite ? "Remove from favorites" : "Add to favorites"
    }

    speedButton.isHidden = !state.showSpeedButton
    if state.showSpeedButton {
      speedButton.setLabel(state.speedLabel)
    }

    // Empty until step 9 reads the item's media-selection groups; the state's
    // own rules keep both buttons hidden until there is a real choice.
    audioButton.isHidden = !state.showAudioButton
    subtitlesButton.isHidden = !state.showSubtitleButton

    aspectButton.setLabel(state.aspectLabel)
    // Step 7 flips `supportsPip` once an `AVPictureInPictureController` exists.
    pipButton.isHidden = !state.showPictureInPictureButton
  }
}

/// The VOD seek bar.
///
/// A `UIControl` subclass, which matters twice over: it gets touch tracking
/// without a gesture recogniser that would compete with the player's root tap
/// recogniser, and the root recogniser's delegate excludes `UIControl` touches,
/// so dragging the scrubber can never be mistaken for a tap on the video.
///
/// No D-pad "OK to edit" mode, unlike the Compose `SlimSlider` — there is no
/// remote on iOS, so the whole focus/edit apparatus that exists to stop a TV
/// slider trapping the D-pad has nothing to protect against here.
final class PlayerScrubberView: UIControl {
  var onScrub: ((Double) -> Void)?

  var progress: Double {
    get { bar.progress }
    set {
      bar.progress = newValue
      setNeedsLayout()
    }
  }

  private let bar = PlayerProgressBarView()
  private let thumb = UIView()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    // Both are decoration; the control itself is the hit target, so
    // `touch.view` stays a `UIControl` for the root recogniser's delegate.
    bar.isUserInteractionEnabled = false
    thumb.isUserInteractionEnabled = false
    thumb.backgroundColor = PlayerColors.accent
    thumb.layer.cornerRadius = PlayerDimens.thumbSize / 2
    addSubview(bar)
    addSubview(thumb)
    isAccessibilityElement = true
    accessibilityTraits = .adjustable
    accessibilityLabel = "Seek"
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerScrubberView is created in code, never from a nib")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: PlayerDimens.scrubberHeight)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let trackY = (bounds.height - PlayerDimens.trackHeight) / 2
    bar.frame = CGRect(
      x: 0,
      y: trackY,
      width: bounds.width,
      height: PlayerDimens.trackHeight
    )
    let travel = max(bounds.width - PlayerDimens.thumbSize, 0)
    thumb.frame = CGRect(
      x: travel * CGFloat(progress),
      y: (bounds.height - PlayerDimens.thumbSize) / 2,
      width: PlayerDimens.thumbSize,
      height: PlayerDimens.thumbSize
    )
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    apply(touch)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    apply(touch)
    return true
  }

  private func apply(_ touch: UITouch) {
    guard bounds.width > 0 else { return }
    let fraction = min(max(Double(touch.location(in: self).x / bounds.width), 0), 1)
    progress = fraction
    onScrub?(fraction)
  }

  // MARK: Accessibility

  override func accessibilityIncrement() {
    nudge(by: 0.05)
  }

  override func accessibilityDecrement() {
    nudge(by: -0.05)
  }

  private func nudge(by delta: Double) {
    let target = min(max(progress + delta, 0), 1)
    progress = target
    onScrub?(target)
  }
}
