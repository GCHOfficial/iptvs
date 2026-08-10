import 'package:flutter/material.dart';

import '../theme.dart';
import 'routed_focus_node.dart';

/// Outer vertical padding a [FocusableCard] adds around itself (top and
/// bottom), so adjacent cards never share a border. Exported because a grid
/// laying these out has to subtract it from its own main-axis spacing —
/// otherwise the vertical gutter is `spacing + 2 * this` while the horizontal
/// one is just `spacing`, and the lattice reads visibly lopsided.
const double kFocusableCardVerticalPadding = 4.0;

/// Width of the inset a [FocusableCard]'s border reserves on every side, in
/// **every** state.
///
/// The focus ring itself is drawn as a `foregroundDecoration` (painted *over*
/// the child) rather than as the box's own border, so gaining focus cannot
/// change the child's constraints. It used to: the ring was a
/// `Border.all(width: _focused ? 2 : 1)` on the [AnimatedContainer]'s
/// `decoration`, and a `BoxDecoration`'s border is exactly what insets a
/// `Container`'s child — so focusing a tile narrowed everything inside it by
/// 2 logical px, through ~7 interpolated fractional widths as the 120 ms
/// animation ran.
///
/// That was invisible for text, and expensive for artwork. A poster sized from
/// its own constraints feeds that width to `imageCacheSize`, so every frame of
/// the animation minted a *different* `memCacheWidth` — a different
/// `ResizeImage` cache key, i.e. a cache miss, a fresh asynchronous resolve
/// and a re-decode, with the `placeholder` showing in between. Walking the
/// media grid with a D-pad or Tab therefore made each poster visibly reload
/// even though the image had been decoded and cached seconds earlier, and
/// reload a second time on the way back out. Grids reserve this constant
/// rather than assuming a resting width (see `MediaGridMetrics.tileBorder`).
const double kFocusableCardBorderWidth = 2.0;

/// A card that behaves well under mouse, touch, and a TV remote's D-pad:
/// - shows a clear accent focus ring when focused (not just a hover tint),
/// - activates on OK/Enter/Select/Space (via [ActivateIntent]) as well as tap,
/// - scrolls itself to the middle of the viewport when it gains focus, so
///   arrowing through a lazy [ListView] keeps the focused row on screen.
class FocusableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  /// Optional long-press handler (touch only). Used on phones to open a
  /// preview before committing to fullscreen; null on TV/desktop.
  final VoidCallback? onLongPress;
  final bool autofocus;
  final bool scrollOnFocus;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;
  final String? debugLabel;
  final String? semanticsLabel;
  final bool? selected;

  /// Optional external focus node, so a parent can move focus to this card
  /// programmatically (e.g. land on a specific row after returning from a
  /// pushed route).
  final FocusNode? focusNode;

  const FocusableCard({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.scrollOnFocus = true,
    this.focusNode,
    this.onKeyEvent,
    this.debugLabel,
    this.semanticsLabel,
    this.selected,
  });

  @override
  State<FocusableCard> createState() => _FocusableCardState();
}

class _FocusableCardState extends State<FocusableCard> {
  /// Focused fill: an accent-tinted lift rather than the neutral
  /// [AppColors.panelHi] hover tint, following the EPG grid's selected cell
  /// (`_ProgrammeCell._selectedFill`). These tiles get as small as ~176 px in a
  /// 10-column TV grid viewed from across the room, where a 1-step-lighter grey
  /// plus a hairline ring reads as "nothing is selected". Hover deliberately
  /// keeps the neutral tint so the two states stay distinguishable on desktop.
  static final Color _focusedFill = Color.alphaBlend(
    AppColors.accent.withValues(alpha: 0.22),
    AppColors.panel,
  );

  bool _focused = false;
  late final FocusNode _ownedFocusNode = RoutedFocusNode(
    widget.debugLabel ?? 'FocusableCard',
  );

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _ownedFocusNode;

  /// Drawn from **`hasFocus`**, not `onShowFocusHighlight`.
  /// `FocusableActionDetector` gates that callback on
  /// `FocusManager.highlightMode == traditional`, and the mode starts as
  /// `touch` on Android: a cold start into Movies autofocused the first tile
  /// and drew **no ring at all** until some key was pressed — same for any TV
  /// box whose remote also emits pointer events. The live tab never had the bug
  /// because it paints its cursor from `hasFocus` (docs/tv-navigation.md,
  /// "Drawing the cursor"); this matches it.
  ///
  /// Safe on touch: [InkWell] here sets `canRequestFocus: false` and nothing
  /// requests focus on tap, so tapping a card never focuses it. An explicit
  /// `autofocus: true` does show its ring on a phone — deliberately, exactly
  /// like the live list's resting cursor row.
  void _onFocusChange(bool value) {
    if (mounted) setState(() => _focused = value);
    if (!value || !widget.scrollOnFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Scrollable.maybeOf(context) != null) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: appMotion(context, const Duration(milliseconds: 220)),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _ownedFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: kFocusableCardVerticalPadding,
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: widget.onKeyEvent,
        child: FocusableActionDetector(
          autofocus: widget.autofocus,
          focusNode: _effectiveFocusNode,
          mouseCursor: SystemMouseCursors.click,
          onFocusChange: _onFocusChange,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: Semantics(
            label: widget.semanticsLabel,
            button: true,
            selected: widget.selected,
            onTap: widget.onTap,
            child: ExcludeSemantics(
              excluding: widget.semanticsLabel != null,
              child: AnimatedContainer(
                duration: appMotion(context, const Duration(milliseconds: 120)),
                decoration: BoxDecoration(
                  color: _focused ? _focusedFill : AppColors.panel,
                  borderRadius: BorderRadius.circular(AppRadius.tile),
                  // Transparent and fixed-width: this border exists only to
                  // reserve the ring's space, so the child's constraints are
                  // identical focused and unfocused. See
                  // [kFocusableCardBorderWidth] for what animating it cost.
                  border: Border.all(
                    color: const Color(0x00000000),
                    width: kFocusableCardBorderWidth,
                  ),
                ),
                // The visible ring, painted over the child rather than beside
                // it — `foregroundDecoration` contributes no padding, so its
                // width is free to animate.
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.tile),
                  border: Border.all(
                    color: _focused ? AppColors.accent : AppColors.line,
                    width: _focused ? 2 : 1,
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    canRequestFocus: false,
                    borderRadius: BorderRadius.circular(AppRadius.tile),
                    hoverColor: AppColors.panelHi,
                    onTap: widget.onTap,
                    onLongPress: widget.onLongPress,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
