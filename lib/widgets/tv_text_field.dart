import 'package:flutter/material.dart';

import '../theme.dart';

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
  final FocusNode _cellFocus = FocusNode(debugLabel: 'TvTextField.cell');
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'TvTextField.field');
  bool _editing = false;
  bool _cellFocused = false;

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
      child: FocusableActionDetector(
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
          onTap: _enterEdit,
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: highlighted ? AppColors.panelHi : AppColors.panel,
              borderRadius: BorderRadius.circular(AppRadius.tile),
              border: Border.all(
                color: highlighted ? AppColors.accent : AppColors.line,
                width: highlighted ? 2 : 1,
              ),
            ),
            // Until editing, the inner field neither takes focus (ExcludeFocus) nor
            // pointer events (IgnorePointer) — so a tap falls through to the cell's
            // onTap → _enterEdit instead of being swallowed by the (unfocusable)
            // field. Once editing, both barriers lift so caret/selection work.
            child: IgnorePointer(
              ignoring: !_editing,
              child: ExcludeFocus(
                excluding: !_editing,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _fieldFocus,
                  obscureText: widget.obscureText,
                  onChanged: widget.onChanged,
                  textInputAction: widget.textInputAction,
                  onSubmitted: (value) {
                    _exitEdit();
                    widget.onSubmitted?.call(value);
                  },
                  // The cell already supplies the background + focus ring, so strip
                  // the global InputDecorationTheme's fill and all borders.
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    hintText: widget.hintText,
                    prefixIcon: widget.prefixIcon,
                    suffixIcon: widget.suffixIcon,
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
