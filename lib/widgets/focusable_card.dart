import 'package:flutter/material.dart';

import '../theme.dart';

/// A card that behaves well under mouse, touch, and a TV remote's D-pad:
/// - shows a clear accent focus ring when focused (not just a hover tint),
/// - activates on OK/Enter/Select/Space (via [ActivateIntent]) as well as tap,
/// - scrolls itself to the middle of the viewport when it gains focus, so
///   arrowing through a lazy [ListView] keeps the focused row on screen.
class FocusableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool autofocus;
  final bool scrollOnFocus;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;
  final String? debugLabel;

  /// Optional external focus node, so a parent can move focus to this card
  /// programmatically (e.g. land on a specific row after returning from a
  /// pushed route).
  final FocusNode? focusNode;

  const FocusableCard({
    super.key,
    required this.child,
    required this.onTap,
    this.autofocus = false,
    this.scrollOnFocus = true,
    this.focusNode,
    this.onKeyEvent,
    this.debugLabel,
  });

  @override
  State<FocusableCard> createState() => _FocusableCardState();
}

class _FocusableCardState extends State<FocusableCard> {
  bool _focused = false;
  late final FocusNode _ownedFocusNode = FocusNode(
    debugLabel: widget.debugLabel ?? 'FocusableCard',
  );

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _ownedFocusNode;

  void _onHighlight(bool value) {
    if (mounted) setState(() => _focused = value);
    if (!value || !widget.scrollOnFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Scrollable.maybeOf(context) != null) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: widget.onKeyEvent,
        child: FocusableActionDetector(
          autofocus: widget.autofocus,
          focusNode: _effectiveFocusNode,
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: _onHighlight,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: _focused ? AppColors.panelHi : AppColors.panel,
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
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
