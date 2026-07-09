import 'package:flutter/material.dart';

import '../theme.dart';

/// Focusable star toggle used in the per-item surfaces (live preview panel,
/// phone preview sheet, media details sheet). On TV it's reached by D-pad (e.g.
/// Up from the top channel into the preview panel); OK/Enter toggles it.
class FavoriteButton extends StatelessWidget {
  final bool favorite;
  final VoidCallback onPressed;

  /// Optional routed focus node + D-pad key handler, so the live preview panel
  /// can slot the star into its contained Up/Down/Left/Right navigation.
  final FocusNode? focusNode;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  const FavoriteButton({
    super.key,
    required this.favorite,
    required this.onPressed,
    this.focusNode,
    this.onKeyEvent,
  });

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
      focusNode: focusNode,
      icon: Icon(
        favorite ? Icons.star_rounded : Icons.star_outline_rounded,
        color: favorite ? AppColors.accent : AppColors.textLo,
      ),
      onPressed: onPressed,
    );
    if (onKeyEvent == null) return button;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: onKeyEvent,
      child: button,
    );
  }
}

/// Non-interactive favorited marker for list/grid tiles (no focus stop).
class FavoriteBadge extends StatelessWidget {
  final double size;

  const FavoriteBadge({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.star_rounded, size: size, color: AppColors.accent);
  }
}
