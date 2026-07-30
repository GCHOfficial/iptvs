import UIKit

/// The stream-info card (resolution / frame rate / dynamic range / codecs, plus
/// the live programme synopsis), toggled by the info button. Port of Android's
/// `InfoPanel.kt`, which mirrors the Windows overlay's panel.
///
/// Every field it can show is decided in `Core` by
/// `PlayerChromeState.infoRows()` / `infoSynopsis` — including the rule that an
/// unavailable field is *omitted* rather than shown as "unknown". This view
/// lays those out and nothing else.
///
/// **Most of it is empty today, by design.** Resolution comes from
/// `AVPlayerItem.presentationSize`, which the controller already feeds in, but
/// frame rate, dynamic range and the codec rows are step 9's colorimetry/format
/// read. The panel renders whatever exists and hides itself when that is
/// nothing (`infoPanelIsEmpty`), so step 9 lights it up with no change here.
///
/// Conforms to ``PlayerTapAbsorbing`` for the same reason `ListMenuView` does:
/// a tap on the panel is not a tap *outside* it, and must not peel it away
/// (docs/player.md, on the Windows/embedded overlay: "the panel itself absorbs
/// taps so it isn't re-closed by its own hit").
final class InfoPanelView: UIView, PlayerTapAbsorbing {
  private let headerLabel = UILabel()
  private let rowsStack = UIStackView()
  private let synopsisLabel = UILabel()

  private var renderedRows: [PlayerInfoRow]?
  private var renderedSynopsis: String?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = PlayerColors.panel
    layer.cornerRadius = PlayerDimens.menuCorner
    layer.masksToBounds = true

    headerLabel.text = "Stream info"
    headerLabel.font = PlayerFonts.panelHeader
    headerLabel.textColor = PlayerColors.textLo

    rowsStack.axis = .vertical
    rowsStack.alignment = .fill
    rowsStack.spacing = 8

    synopsisLabel.font = PlayerFonts.epgMeta
    synopsisLabel.textColor = PlayerColors.textLo
    synopsisLabel.numberOfLines = 4

    let container = UIStackView(arrangedSubviews: [headerLabel, rowsStack, synopsisLabel])
    container.axis = .vertical
    container.alignment = .fill
    container.spacing = 8
    container.translatesAutoresizingMaskIntoConstraints = false
    container.isUserInteractionEnabled = false
    addSubview(container)

    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      widthAnchor.constraint(equalToConstant: PlayerDimens.infoPanelWidth),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("InfoPanelView is created in code, never from a nib")
  }

  /// Renders the panel for `state`, hiding it whenever it is closed or would be
  /// empty.
  func render(_ state: PlayerChromeState) {
    guard state.infoOpen, !state.infoPanelIsEmpty else {
      isHidden = true
      return
    }
    isHidden = false

    let rows = state.infoRows()
    let synopsis = state.infoSynopsis
    // Rebuild only on a real change: the 500 ms progress tick renders the whole
    // overlay, and tearing these views down twice a second would flicker.
    guard rows != renderedRows || synopsis != renderedSynopsis else { return }
    renderedRows = rows
    renderedSynopsis = synopsis

    for view in rowsStack.arrangedSubviews {
      rowsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for row in rows {
      rowsStack.addArrangedSubview(InfoPanelView.makeRow(row))
    }
    rowsStack.isHidden = rows.isEmpty

    synopsisLabel.text = synopsis
    synopsisLabel.isHidden = synopsis == nil
  }

  /// Label left, value right — the value takes what's left and wraps to at most
  /// two lines, matching the Kotlin row's `weight(1f, fill = false)` +
  /// `maxLines = 2`.
  private static func makeRow(_ row: PlayerInfoRow) -> UIView {
    let label = UILabel()
    label.text = row.label
    label.font = PlayerFonts.infoLabel
    label.textColor = PlayerColors.textLo
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.setContentHuggingPriority(.required, for: .horizontal)

    let value = UILabel()
    value.text = row.value
    value.font = PlayerFonts.infoValue
    value.textColor = PlayerColors.textHi
    value.textAlignment = .right
    value.numberOfLines = 2
    value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stack = UIStackView(arrangedSubviews: [label, value])
    stack.axis = .horizontal
    stack.alignment = .firstBaseline
    stack.spacing = 16
    stack.isUserInteractionEnabled = false
    return stack
  }
}
