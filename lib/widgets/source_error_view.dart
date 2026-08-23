import 'package:flutter/material.dart';

import '../theme.dart';

/// The "couldn't load this" body, with a retry the D-pad can actually reach.
///
/// **The retry autofocuses.** This is the same rule the delete-confirmation
/// dialog follows, and it exists because the live tab's body is a *selection
/// model* rather than a focus tree: its rows are not focus targets, and when a
/// load fails there are no rows at all. Nothing in the error body was focusable
/// on arrival, so on a television the button was visible, was the only action on
/// screen, and could not be pressed — the first OK went nowhere and there was
/// nothing to arrow towards. The failure is silent from the app's side and total
/// from the user's: a source that fails to load is exactly when they cannot
/// route around it.
///
/// Autofocus is safe here because this body only mounts on a failed load, which
/// replaces the list wholesale — whatever focus the body held is already gone,
/// so there is nothing to steal it from.
class SourceErrorView extends StatelessWidget {
  const SourceErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  /// Complete, already-composed message — headline plus whatever the source
  /// reported. Callers word their own, so this makes no assumptions about it.
  final String message;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textLo),
            ),
            const SizedBox(height: 16),
            FilledButton(
              autofocus: true,
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
