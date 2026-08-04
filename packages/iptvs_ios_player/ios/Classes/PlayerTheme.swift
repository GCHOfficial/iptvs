import UIKit

/// Design tokens for the native iOS player's control overlay — the port of
/// Android's `PlayerTheme.kt` (`android/app/src/main/kotlin/.../player/`).
///
/// **The colour values mirror `lib/theme.dart`'s `AppColors` exactly**, which is
/// what keeps the iOS overlay, the Android Compose overlay, the Windows GDI
/// overlay and the Linux Lua overlay reading as one app rather than four
/// lookalikes. `lib/theme.dart` is the single source of truth; every other
/// surface is a copy that has to be re-synced by hand when it moves.
///
/// **Known drift, deliberately not propagated here:** `PlayerTheme.kt` still
/// carries `PanelHi = 0xFF1E212B` and `Line = 0xFF262A36`, which `AppColors`
/// has since moved to `0xFF272B36` / `0xFF353B49`. This file follows
/// `lib/theme.dart`, not the stale Kotlin copy, so iOS is correct and Android is
/// the one that needs a catch-up edit (out of scope for this file's owner).
enum PlayerColors {
  // MARK: Tokens mirrored from lib/theme.dart `AppColors`

  /// App background / scrim base.
  static let ink = PlayerColors.rgb(0x0E_0F13)
  /// Cards / surfaces — the menu and info-panel background.
  static let panel = PlayerColors.rgb(0x16_181F)
  /// Hover / focus lift — badge chips and the pressed menu row.
  static let panelHi = PlayerColors.rgb(0x27_2B36)
  /// Hairlines / borders.
  static let line = PlayerColors.rgb(0x35_3B49)
  static let textHi = PlayerColors.rgb(0xF2_F4F8)
  static let textLo = PlayerColors.rgb(0x9A_A3B2)
  /// Brand / progress fill.
  static let accent = PlayerColors.rgb(0x7B_6CF6)
  /// "On air" signal — the LIVE pill.
  static let live = PlayerColors.rgb(0xFF_4D6D)

  // MARK: Overlay-only tints derived from the tokens above
  // (identical to the Kotlin overlay's derived set).

  /// Translucent chip behind every control button.
  static let buttonBackground = UIColor.white.withAlphaComponent(0.2)
  /// A pressed control. UIKit has no focus state to mirror Compose's
  /// `ButtonBgFocused` — there is no D-pad on iOS — so the accent fill is spent
  /// on touch-down feedback instead, which is the equivalent affordance here.
  static let buttonBackgroundPressed = accent
  static let scrimTop = UIColor.black.withAlphaComponent(0.8)
  static let scrimBottom = UIColor.black.withAlphaComponent(0.9)
  /// Unfilled slider/progress track, and the greyed LIVE pill once behind the
  /// edge.
  static let trackInactive = UIColor.white.withAlphaComponent(0.3)

  private static func rgb(_ value: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}

/// Shared geometry, ported from Kotlin `PlayerDimens` so the two overlays lay
/// out at the same rhythm.
enum PlayerDimens {
  static let buttonSize: CGFloat = 44
  static let buttonCorner: CGFloat = 10
  static let badgeCorner: CGFloat = 6
  static let menuCorner: CGFloat = 14
  static let menuWidth: CGFloat = 240
  static let menuMaxHeight: CGFloat = 320
  static let infoPanelWidth: CGFloat = 260
  static let edgePadding: CGFloat = 24
  static let controlSpacing: CGFloat = 8
  static let trackHeight: CGFloat = 4
  static let scrubberHeight: CGFloat = 28
  static let thumbSize: CGFloat = 14
  /// How far a scrim's gradient extends past the bar it backs, so the fade
  /// finishes clear of the chrome instead of ending on it.
  static let scrimFade: CGFloat = 24

  /// Below this width the top bar's badges and the bottom bar's right cluster
  /// each wrap onto their own row. Same 560 breakpoint the Compose overlay
  /// uses, so a phone in portrait behaves identically on both platforms.
  static let compactWidth: CGFloat = 560
}

/// Typography.
///
/// **System font (SF), not Inter** — the one deliberate visual divergence from
/// the other overlays, all of which bundle Inter (Android `res/font`, Linux
/// `linux/mpv/fonts/`). Shipping Inter here would mean adding a
/// `resource_bundles` entry to `iptvs_ios_player.podspec` plus runtime
/// `CTFontManagerRegisterFontsForURL` registration — a build-configuration
/// change outside this step's file ownership, for a difference measured in
/// letterform detail on a phone-sized bar. Recorded so it reads as a decision
/// rather than an oversight; the swap is a two-line change in
/// ``PlayerFonts`` if the podspec ever carries the font.
enum PlayerFonts {
  static let title = UIFont.systemFont(ofSize: 18, weight: .bold)
  static let badge = UIFont.systemFont(ofSize: 11, weight: .bold)
  static let livePill = UIFont.systemFont(ofSize: 12, weight: .bold)
  static let button = UIFont.systemFont(ofSize: 14, weight: .semibold)
  static let time = UIFont.systemFont(ofSize: 13, weight: .regular)
  static let epgTitle = UIFont.systemFont(ofSize: 14, weight: .semibold)
  static let epgMeta = UIFont.systemFont(ofSize: 12, weight: .regular)
  static let panelHeader = UIFont.systemFont(ofSize: 12, weight: .semibold)
  static let menuRow = UIFont.systemFont(ofSize: 14, weight: .regular)
  static let menuRowSelected = UIFont.systemFont(ofSize: 14, weight: .semibold)
  static let infoLabel = UIFont.systemFont(ofSize: 13, weight: .semibold)
  static let infoValue = UIFont.systemFont(ofSize: 13, weight: .bold)
  static let notice = UIFont.systemFont(ofSize: 15, weight: .semibold)
}

/// A view that hit-tests as *chrome* rather than as exposed video.
///
/// The player's root tap recogniser drives the touch half of the Back ladder
/// (docs/tv-navigation.md: tap outside peels menu → info; tap on exposed video
/// toggles the chrome). A tap *inside* an open menu or the info panel is not a
/// tap outside it, so those views declare themselves here and
/// `IptvsPlayerViewController`'s gesture delegate walks the touched view's
/// ancestors looking for this protocol — the same reason the Windows/Linux
/// overlays make their info panel absorb its own taps (docs/player.md: "the
/// panel itself absorbs taps so it isn't re-closed by its own hit").
protocol PlayerTapAbsorbing: AnyObject {}

// MARK: - Small shared primitives

/// A `UIView` whose backing layer is a `CAGradientLayer`, so the scrim resizes
/// with the view instead of needing its frame re-synced on every layout pass
/// (rotation, safe-area change, the pass right after presentation). Same
/// reasoning as `PlayerLayerView`'s `layerClass` override in `AvPlayerEngine`.
final class PlayerGradientView: UIView {
  override class var layerClass: AnyClass { CAGradientLayer.self }

  private var gradientLayer: CAGradientLayer {
    // swiftlint:disable:next force_cast
    layer as! CAGradientLayer
  }

  init(colors: [UIColor]) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    gradientLayer.colors = colors.map { $0.cgColor }
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerGradientView is created in code, never from a nib")
  }
}

/// A rounded chip label — the badge primitive (Kotlin `Badge`/`LiveBadge`).
///
/// A `UILabel` subclass with insets rather than a container view + label: one
/// view, one intrinsic size, and it collapses correctly when hidden inside a
/// `UIStackView`.
final class PlayerBadgeLabel: UILabel {
  private let textInsets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)

  init(font: UIFont = PlayerFonts.badge) {
    super.init(frame: .zero)
    self.font = font
    textColor = PlayerColors.textHi
    backgroundColor = PlayerColors.panelHi
    layer.cornerRadius = PlayerDimens.badgeCorner
    layer.masksToBounds = true
    numberOfLines = 1
    // Badges are short and fixed-width; the title beside them is what gives way
    // when the bar is narrow.
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerBadgeLabel is created in code, never from a nib")
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: textInsets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + textInsets.left + textInsets.right,
      height: size.height + textInsets.top + textInsets.bottom
    )
  }

  /// Sets the text and hides the badge entirely when there is nothing to show —
  /// the `state.xBadge == nil` case, which must collapse rather than render an
  /// empty chip.
  func apply(_ value: String?) {
    text = value
    isHidden = value == nil
    invalidateIntrinsicContentSize()
  }
}

/// Square icon button with the translucent chip background.
///
/// A hand-rolled `UIButton` subclass rather than `UIButton.Configuration`: the
/// configuration API re-derives the background on its own schedule, and this
/// button's only states are normal and pressed. `UIButton` also means the root
/// tap recogniser's delegate excludes it for free (`touch.view is UIControl`),
/// which is the difference between working controls and controls that read as
/// dead.
final class PlayerIconButton: UIButton {
  private let action: () -> Void

  /// - Parameters:
  ///   - systemName: an SF Symbol name.
  ///   - fallbackTitle: rendered as text if the symbol is missing on this iOS
  ///     version. A nil `UIImage(systemName:)` otherwise produces an invisible
  ///     but tappable button — a failure that looks like a layout bug and hides
  ///     for a whole release. Failing *visibly* is the point.
  init(
    systemName: String,
    accessibilityLabel: String,
    fallbackTitle: String,
    action: @escaping () -> Void
  ) {
    self.action = action
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    tintColor = PlayerColors.textHi
    backgroundColor = PlayerColors.buttonBackground
    layer.cornerRadius = PlayerDimens.buttonCorner
    layer.masksToBounds = true
    self.accessibilityLabel = accessibilityLabel
    setSymbol(systemName, fallbackTitle: fallbackTitle)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: PlayerDimens.buttonSize),
      heightAnchor.constraint(equalToConstant: PlayerDimens.buttonSize),
    ])
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerIconButton is created in code, never from a nib")
  }

  private var currentSymbol: String?

  /// Swaps the glyph in place (play ↔ pause, star ↔ star.fill, speaker ↔ muted).
  ///
  /// A no-op when the symbol hasn't changed: the whole overlay re-renders on
  /// every progress tick, and re-setting an identical image twice a second
  /// churns image decoding and can interrupt the button's own touch feedback.
  func setSymbol(_ systemName: String, fallbackTitle: String) {
    guard systemName != currentSymbol else { return }
    currentSymbol = systemName
    let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    if let image = UIImage(systemName: systemName, withConfiguration: configuration) {
      setImage(image, for: .normal)
      setTitle(nil, for: .normal)
    } else {
      setImage(nil, for: .normal)
      titleLabel?.font = PlayerFonts.button
      setTitleColor(PlayerColors.textHi, for: .normal)
      setTitle(fallbackTitle, for: .normal)
    }
  }

  override var isHighlighted: Bool {
    didSet {
      backgroundColor =
        isHighlighted ? PlayerColors.buttonBackgroundPressed : PlayerColors.buttonBackground
    }
  }

  @objc private func handleTap() {
    action()
  }
}

/// Text-labelled control button (aspect mode, speed, "LIVE"). Port of Kotlin
/// `TextControlButton`.
final class PlayerTextButton: UIButton {
  private let action: () -> Void
  private let horizontalPadding: CGFloat = 28

  init(title: String, accessibilityLabel: String, action: @escaping () -> Void) {
    self.action = action
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = PlayerColors.buttonBackground
    layer.cornerRadius = PlayerDimens.buttonCorner
    layer.masksToBounds = true
    titleLabel?.font = PlayerFonts.button
    setTitleColor(PlayerColors.textHi, for: .normal)
    setTitle(title, for: .normal)
    self.accessibilityLabel = accessibilityLabel
    heightAnchor.constraint(equalToConstant: PlayerDimens.buttonSize).isActive = true
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerTextButton is created in code, never from a nib")
  }

  /// Horizontal padding added here rather than through `contentEdgeInsets`,
  /// which is deprecated from iOS 15 and would warn on every build.
  override var intrinsicContentSize: CGSize {
    let base = super.intrinsicContentSize
    return CGSize(width: base.width + horizontalPadding, height: PlayerDimens.buttonSize)
  }

  func setLabel(_ title: String) {
    guard title != self.title(for: .normal) else { return }
    setTitle(title, for: .normal)
    invalidateIntrinsicContentSize()
  }

  override var isHighlighted: Bool {
    didSet {
      backgroundColor =
        isHighlighted ? PlayerColors.buttonBackgroundPressed : PlayerColors.buttonBackground
    }
  }

  @objc private func handleTap() {
    action()
  }
}

/// A thin track with an accent fill — the VOD scrubber's bar and the live EPG
/// programme-progress bar. Non-interactive; ``PlayerScrubberView`` wraps one to
/// add touch.
final class PlayerProgressBarView: UIView {
  /// Clamped to `0...1` on write, so no caller can overfill the bar.
  var progress: Double = 0 {
    didSet {
      progress = min(max(progress, 0), 1)
      setNeedsLayout()
    }
  }

  private let track = UIView()
  private let fill = UIView()

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    track.backgroundColor = PlayerColors.trackInactive
    fill.backgroundColor = PlayerColors.accent
    for view in [track, fill] {
      view.layer.cornerRadius = PlayerDimens.trackHeight / 2
      view.layer.masksToBounds = true
      addSubview(view)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerProgressBarView is created in code, never from a nib")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: PlayerDimens.trackHeight)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    track.frame = bounds
    fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(progress), height: bounds.height)
  }
}
