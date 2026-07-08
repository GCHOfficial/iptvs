import 'package:flutter/material.dart';

import '../theme.dart';
import 'routed_focus_node.dart';

/// A text field that behaves under a TV remote's D-pad as well as touch/mouse.
///
/// The problem it solves: a normal [TextField] traps D-pad focus — once it's
/// focused, the embedded editor consumes the arrow keys for caret movement, so
/// you can't navigate away, and Back tends to do nothing useful. That makes the
/// search box / credential fields a dead end on Android TV.
///
/// This wraps the field in an **edit-mode cell** (the same "OK to edit" model the
/// player sliders use): in traversal it's a single focusable cell that arrows
/// pass over freely. Pressing OK/Select (or tapping) enters edit mode — the inner
/// field takes focus and the keyboard opens; pressing the IME action (Done/Search)
/// or Back exits edit mode and returns focus to the cell so navigation resumes.
/// The inner field is removed from traversal ([ExcludeFocus]) unless editing, so
/// it can never become a trap.
///
/// Matches the channel list's search box height by default (`height: 40` there
/// is redundant with this but kept explicit at that call site).
const double kTvTextFieldHeight = 40.0;

class TvTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final double? height;
  final FocusNode? cellFocusNode;

  /// Optional persistent label rendered above the field. Preferred over a
  /// floating label for credential forms (it stays visible once text is entered).
  final String? label;

  const TvTextField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.autofocus = false,
    this.textInputAction,
    this.height,
    this.label,
    this.cellFocusNode,
  });

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  final FocusNode _cellFocus = RoutedFocusNode('TvTextField.cell');
  final FocusNode _fieldFocus = RoutedFocusNode('TvTextField.field');
  final FocusNode _toggleFocus = RoutedFocusNode('TvTextField.toggle');
  bool _editing = false;
  bool _cellFocused = false;
  bool _toggleFocused = false;
  late bool _obscured = widget.obscureText;

  FocusNode get _effectiveCellFocus => widget.cellFocusNode ?? _cellFocus;

  @override
  void initState() {
    super.initState();
    _fieldFocus.addListener(_onFieldFocusChange);
  }

  @override
  void dispose() {
    _fieldFocus.removeListener(_onFieldFocusChange);
    if (widget.cellFocusNode == null) {
      _cellFocus.dispose();
    }
    _fieldFocus.dispose();
    _toggleFocus.dispose();
    super.dispose();
  }

  void _onFieldFocusChange() {
    // The editor lost focus (tapped elsewhere, keyboard dismissed) — leave edit
    // mode so the cell is back to a plain navigable stop.
    if (!_fieldFocus.hasFocus && _editing && mounted) {
      setState(() => _editing = false);
    }
  }

  void _enterEdit() {
    if (_editing) return;
    setState(() => _editing = true);
    // Request the inner field after the ExcludeFocus barrier lifts this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _fieldFocus.requestFocus();
    });
  }

  void _exitEdit({bool refocusCell = true}) {
    if (!_editing) return;
    setState(() => _editing = false);
    _fieldFocus.unfocus();
    if (refocusCell) _effectiveCellFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final highlighted = _editing || _cellFocused;
    final cell = _buildCell(highlighted);
    if (widget.label == null) return cell;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            widget.label!,
            style: const TextStyle(
              color: AppColors.textLo,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        cell,
      ],
    );
  }

  Widget _buildCell(bool highlighted) {
    // While editing, swallow Back to leave edit mode instead of popping the route.
    // PopScope (not BackButtonListener) is the Navigator-compatible mechanism —
    // this app uses Navigator, not a Router, so BackButtonListener would throw.
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _editing) _exitEdit();
      },
      child: Container(
        height: widget.height ?? kTvTextFieldHeight,
        // Vertically centers the Row within a fixed-height cell.
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: highlighted ? AppColors.panelHi : AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(
            color: highlighted ? AppColors.accent : AppColors.line,
            width: highlighted ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _buildEntryCell()),
            // The show/hide toggle lives *outside* the entry cell's
            // edit-mode barrier below, as its own always-focusable stop —
            // not nested inside it. Nested there it would be unreachable by
            // D-pad: entering edit mode hands focus straight to the
            // TextField, and arrow keys are then consumed by the editor for
            // caret movement (that's the whole reason this widget exists),
            // so a sibling icon inside the same barrier could never be
            // navigated to on a TV remote.
            if (widget.obscureText) _buildVisibilityToggle(),
            if (widget.suffixIcon != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: IgnorePointer(
                  ignoring: !_editing,
                  child: ExcludeFocus(
                    excluding: !_editing,
                    child: IconTheme.merge(
                      data: const IconThemeData(color: AppColors.textLo),
                      child: widget.suffixIcon!,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The "OK to edit" prefix-icon + text field portion — a single focusable
  /// stop until [_enterEdit] hands focus to the inner [TextField].
  Widget _buildEntryCell() {
    return FocusableActionDetector(
      focusNode: _effectiveCellFocus,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.text,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _cellFocused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _enterEdit();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _enterEdit,
        // Until editing, the inner field neither takes focus (ExcludeFocus) nor
        // pointer events (IgnorePointer) — so a tap falls through to the cell's
        // onTap → _enterEdit instead of being swallowed by the (unfocusable)
        // field. Once editing, both barriers lift so caret/selection work.
        child: IgnorePointer(
          ignoring: !_editing,
          child: ExcludeFocus(
            excluding: !_editing,
            // Icons live OUTSIDE the InputDecoration, in a manually centered
            // Row. Inside the decorator their 48dp minimum makes it taller
            // than the text line, and the InputDecorator's dense-layout
            // vertical centering differs between Android and Windows — the
            // recurring "hint sits high on Android" bug. With no icons the
            // decorator collapses to the text line and the Row centers
            // everything identically on every platform.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (widget.prefixIcon != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: IconTheme.merge(
                      data: const IconThemeData(color: AppColors.textLo),
                      child: widget.prefixIcon!,
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _fieldFocus,
                      obscureText: _obscured,
                      onChanged: widget.onChanged,
                      textInputAction: widget.textInputAction,
                      onSubmitted: (value) {
                        _exitEdit();
                        widget.onSubmitted?.call(value);
                      },
                      // A *collapsed* decoration removes the InputDecorator's
                      // layout entirely (no fill, borders, or padding — the
                      // cell supplies all of that), so the field is exactly
                      // the text line and the Row's centering is
                      // platform-independent. Any non-collapsed decoration
                      // re-engages the decorator's own vertical placement,
                      // which differs between Android and Windows — the
                      // recurring hint-misalignment bug.
                      //
                      // Every border slot must be InputBorder.none
                      // explicitly: applyDefaults fills any null slot from
                      // the app theme's OutlineInputBorders, and the
                      // decorator prefers enabled/focusedBorder over
                      // `border` — which painted a second rounded box
                      // inside the cell.
                      decoration: InputDecoration(
                        isCollapsed: true,
                        contentPadding: EdgeInsets.zero,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        hintText: widget.hintText,
                        hintStyle: const TextStyle(color: AppColors.textLo),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Password/credential fields get a built-in show/hide toggle — without it
  /// there's no way to spot a typo on a device with no physical keyboard to
  /// arrow back over masked characters. Always focusable/tappable (not
  /// gated by edit mode) with its own accent focus ring, matching how every
  /// other D-pad-navigable control in the app signals focus.
  Widget _buildVisibilityToggle() {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: FocusableActionDetector(
        focusNode: _toggleFocus,
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (mounted) setState(() => _toggleFocused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              setState(() => _obscured = !_obscured);
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: () => setState(() => _obscured = !_obscured),
          child: Tooltip(
            message: _obscured ? 'Show' : 'Hide',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _toggleFocused ? AppColors.panelHi : null,
                border: _toggleFocused
                    ? Border.all(color: AppColors.accent, width: 2)
                    : null,
              ),
              child: Icon(
                _obscured ? Icons.visibility_off : Icons.visibility,
                size: 20,
                color: _toggleFocused ? AppColors.accent : AppColors.textLo,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
