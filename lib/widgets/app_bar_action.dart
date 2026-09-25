import 'package:flutter/material.dart';

import '../theme.dart';

/// An AppBar action that names itself when there is room to.
///
/// Icon-only actions ("Sources", "Diagnostics", "Cloud sync", …) were not
/// self-explanatory — a remote has no hover, so the tooltip that names them
/// never shows on a television, which is exactly where the icons were least
/// familiar. On the wide layout ([isWideLayout]: every TV, and any window
/// wide enough for the two-pane browse UI) the action is an icon + text
/// button; below it, where a phone's AppBar has no room for words, it stays
/// an [IconButton] with [label] as its tooltip.
///
/// Both forms are a single focus target in the same place, so D-pad traversal
/// through the AppBar is unchanged across the breakpoint.
class AppBarAction extends StatelessWidget {
  const AppBarAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;

  /// Short, visible name. Also the tooltip in icon-only form unless
  /// [tooltip] gives a longer one.
  final String label;

  /// Longer description, shown on hover in either form.
  final String? tooltip;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (!isWideLayout(MediaQuery.sizeOf(context))) {
      return IconButton(
        tooltip: tooltip ?? label,
        icon: Icon(icon),
        onPressed: onPressed,
      );
    }
    final button = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, maxLines: 1, softWrap: false),
      ),
    );
    final hint = tooltip;
    return hint == null ? button : Tooltip(message: hint, child: button);
  }
}
