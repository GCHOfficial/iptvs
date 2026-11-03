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
    this.autofocus = false,
  });

  final IconData icon;

  /// Short, visible name. Also the tooltip in icon-only form unless
  /// [tooltip] gives a longer one.
  final String label;

  /// Longer description, shown on hover in either form.
  final String? tooltip;

  final VoidCallback? onPressed;

  /// Takes focus when its route first builds.
  ///
  /// Honoured by **both** forms, which is the point: this widget's contract is
  /// that the breakpoint changes how an action looks and never where focus
  /// goes, and an autofocus that only existed above the breakpoint would
  /// silently drop a screen's D-pad entry point on a phone. Screens that use
  /// it set it on exactly one action — autofocus is a race between whoever
  /// mounts first, not a preference several widgets can hold.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (!isWideLayout(MediaQuery.sizeOf(context))) {
      return IconButton(
        autofocus: autofocus,
        tooltip: tooltip ?? label,
        icon: Icon(icon),
        onPressed: onPressed,
      );
    }
    final button = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton.icon(
        autofocus: autofocus,
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, maxLines: 1, softWrap: false),
      ),
    );
    final hint = tooltip;
    return hint == null ? button : Tooltip(message: hint, child: button);
  }
}
