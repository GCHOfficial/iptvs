import UIKit

/// One row of a list-menu: label on the left, a check on the right when
/// selected.
///
/// A `UIControl` subclass rather than a `UIButton`, because a button with a
/// left-aligned title *and* a trailing image needs the `titleEdgeInsets` /
/// `imageEdgeInsets` pair that iOS 15 deprecated (or a `UIButton.Configuration`
/// that re-lays itself out on its own schedule). A `UIControl` hosting a stack
/// view gets the same touch semantics — including exclusion from the player's
/// root tap recogniser, which filters `UIControl` — with layout that reads as
/// what it is.
final class PlayerMenuRowView: UIControl {
  let optionId: String
  private let onTap: (String) -> Void
  private let label = UILabel()
  private let check = UIImageView()

  init(option: PlayerTrackOption, selected: Bool, onTap: @escaping (String) -> Void) {
    optionId = option.id
    self.onTap = onTap
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    label.text = option.label
    label.numberOfLines = 1
    label.font = selected ? PlayerFonts.menuRowSelected : PlayerFonts.menuRow
    label.textColor = selected ? PlayerColors.accent : PlayerColors.textHi

    check.tintColor = PlayerColors.accent
    check.contentMode = .scaleAspectFit
    check.image = UIImage(
      systemName: "checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    // Always laid out, only visible when selected: the fixed 18pt trailing
    // column keeps every row's label starting and ending at the same x, so the
    // list doesn't reflow as the selection moves.
    check.alpha = selected ? 1 : 0

    let row = UIStackView(arrangedSubviews: [label, check])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    // The stack and its children must not swallow the touch — the row itself is
    // the control.
    row.isUserInteractionEnabled = false
    addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
      check.widthAnchor.constraint(equalToConstant: 18),
      check.heightAnchor.constraint(equalToConstant: 18),
      // Comfortable touch target even for a single-line row.
      heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])

    accessibilityLabel = option.label
    accessibilityTraits = selected ? [.button, .selected] : [.button]
    isAccessibilityElement = true

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerMenuRowView is created in code, never from a nib")
  }

  override var isHighlighted: Bool {
    didSet {
      backgroundColor = isHighlighted ? PlayerColors.panelHi : .clear
    }
  }

  @objc private func handleTap() {
    onTap(optionId)
  }
}

/// The one reusable vertical list-menu (audio / subtitles / speed), mirroring
/// the Windows overlay's single-menu model and Android's `ListMenu.kt`.
///
/// Which menu is open, what it contains and what is selected are all decided by
/// `PlayerChromeState.menuContent()` in `Core` — this view renders a
/// ``PlayerMenuContent`` and reports the chosen id back. It holds no policy of
/// its own, which is why there is nothing here for a test to reach.
///
/// Conforms to ``PlayerTapAbsorbing``: a tap inside an open menu is not a "tap
/// outside", so the root tap recogniser must not treat it as one rung of the
/// Back ladder.
final class ListMenuView: UIView, PlayerTapAbsorbing {
  /// Called with the selected option's id. The controller applies it and closes
  /// the menu — closing here would make the view own a ladder rung.
  var onSelect: ((String) -> Void)?

  private let headerLabel = UILabel()
  private let scrollView = UIScrollView()
  private let rowsStack = UIStackView()
  /// Last rendered content, so an unchanged render (the 500 ms progress tick)
  /// does not rebuild the rows and cancel a touch mid-press.
  private var renderedContent: PlayerMenuContent?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = PlayerColors.panel
    layer.cornerRadius = PlayerDimens.menuCorner
    layer.masksToBounds = true

    headerLabel.font = PlayerFonts.panelHeader
    headerLabel.textColor = PlayerColors.textLo
    headerLabel.translatesAutoresizingMaskIntoConstraints = false

    rowsStack.axis = .vertical
    rowsStack.alignment = .fill
    rowsStack.spacing = 0
    rowsStack.translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.addSubview(rowsStack)

    addSubview(headerLabel)
    addSubview(scrollView)

    // Self-sizing scroll view: the stack drives the content layout guide, and
    // the low-priority height match lets the scroll view adopt that height
    // until the max-height cap wins. Without the cap a 30-track audio menu
    // would grow past the top of the screen.
    let contentHeight = rowsStack.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
    contentHeight.priority = UILayoutPriority(250)

    NSLayoutConstraint.activate([
      headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

      scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: PlayerDimens.menuMaxHeight),

      rowsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      rowsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      contentHeight,

      widthAnchor.constraint(equalToConstant: PlayerDimens.menuWidth),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("ListMenuView is created in code, never from a nib")
  }

  /// Renders `content`, or hides the menu entirely when nil (no menu open).
  func render(_ content: PlayerMenuContent?) {
    guard let content else {
      isHidden = true
      renderedContent = nil
      return
    }
    isHidden = false
    guard content != renderedContent else { return }
    renderedContent = content

    headerLabel.text = content.header
    for view in rowsStack.arrangedSubviews {
      rowsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for option in content.options {
      let row = PlayerMenuRowView(
        option: option,
        selected: option.id == content.selectedId,
        onTap: { [weak self] id in self?.onSelect?(id) }
      )
      rowsStack.addArrangedSubview(row)
    }
    // A menu with no options at all (defensive — the buttons that open one are
    // gated on there being a choice) would otherwise render as a bare header.
    scrollView.isHidden = content.options.isEmpty
  }
}
