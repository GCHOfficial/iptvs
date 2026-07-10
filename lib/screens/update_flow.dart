import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../data/update_installer.dart';
import '../data/update_service.dart';
import '../data/update_store.dart';
import '../theme.dart';

/// The user's choice on the "Update available" dialog.
enum UpdateChoice { update, later, skip }

/// Runs a full update check → prompt → download → install cycle.
///
/// [manual] distinguishes the two entry points:
/// - `true` (the Sources "Check for updates" card): always prompts if a newer
///   release exists, and reports "up to date" / errors via a snackbar.
/// - `false` (the throttled startup check in [HomeShell]): silent unless a
///   *fresh* newer release exists (respects the skipped-version preference).
///
/// [service] / [store] are injectable for tests; production passes none.
Future<void> runUpdateCheck(
  BuildContext context, {
  required bool manual,
  UpdateService? service,
  UpdateStore? store,
}) async {
  final svc = service ?? UpdateService();
  final prefs = store ?? const UpdateStore();

  ReleaseInfo? release;
  String current;
  try {
    current = await svc.currentVersion();
    release = await svc.fetchLatest();
  } catch (e) {
    if (manual && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update check failed: $e')));
    }
    return;
  } finally {
    svc.close();
  }

  await prefs.setLastCheck(DateTime.now());
  if (!context.mounted) return;

  if (release == null || !isNewer(release, current)) {
    if (manual) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're on the latest version")),
      );
    }
    return;
  }

  // An auto-check honours the skipped version; a manual check always prompts.
  if (!manual) {
    final skipped = await prefs.skippedVersion();
    if (skipped == release.version) return;
    if (!context.mounted) return;
  }

  final choice = await showUpdateDialog(context, release, current);
  switch (choice) {
    case UpdateChoice.skip:
      await prefs.setSkippedVersion(release.version);
    case UpdateChoice.update:
      if (context.mounted) await _downloadAndInstall(context, release);
    case UpdateChoice.later:
    case null:
      break;
  }
}

/// The "Update available" prompt. The primary action autofocuses so a TV
/// remote's OK acts immediately; Back returns null (= Later). Public so the
/// D-pad focus behaviour can be pinned by a widget test.
Future<UpdateChoice?> showUpdateDialog(
  BuildContext context,
  ReleaseInfo release,
  String current,
) {
  final canInstall =
      UpdateInstaller.isSupported && release.assetForCurrentPlatform() != null;
  return showDialog<UpdateChoice>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.panelHi,
      title: Text('Update available — ${release.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You have $current. Version ${release.version} is available.',
              style: const TextStyle(color: AppColors.textLo),
            ),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    release.notes,
                    style: const TextStyle(fontSize: 13, height: 1.35),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, UpdateChoice.skip),
          child: const Text('Skip this version'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, UpdateChoice.later),
          child: const Text('Later'),
        ),
        FilledButton(
          // Autofocus so a TV remote's OK acts on the dialog immediately — the
          // modal's focus scope otherwise lands on nothing until the first
          // arrow press. The primary action gets the focus ring.
          autofocus: true,
          onPressed: () => Navigator.pop(context, UpdateChoice.update),
          child: Text(canInstall ? 'Update' : 'View release'),
        ),
      ],
    ),
  );
}

Future<void> _downloadAndInstall(
  BuildContext context,
  ReleaseInfo release,
) async {
  final installer = UpdateInstaller();
  final asset = release.assetForCurrentPlatform();

  // Nothing to install in-app (macOS/Linux, or a release missing this
  // platform's asset) — just open the release page.
  if (!UpdateInstaller.isSupported || asset == null) {
    await installer.openReleasePage(release.htmlUrl);
    installer.close();
    return;
  }

  final progress = ValueNotifier<double>(0);
  var dialogOpen = true;
  var canceled = false;

  void closeDialog() {
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    dialogOpen = false;
  }

  // Cancel = abort the in-flight download (force-closing the client breaks the
  // stream), close the dialog, and skip the install. Reachable via the dialog's
  // Cancel button *and* the remote/system Back (which pops the route → `.then`).
  void cancel() {
    if (canceled) return;
    canceled = true;
    installer.close();
    closeDialog();
  }

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(progress: progress, onCancel: cancel),
    ).then((_) {
      dialogOpen = false;
      // Dismissed some other way (Back button) — treat as cancel.
      if (!canceled) cancel();
    }),
  );

  try {
    final file = await installer.download(
      asset,
      _filenameFor(asset, release),
      onProgress: (p) {
        if (!canceled) progress.value = p;
      },
    );
    if (canceled) return;
    closeDialog();
    if (!context.mounted) return;

    final outcome = await installer.install(release, file);
    if (!context.mounted) return;
    switch (outcome) {
      case InstallOutcome.needsPermission:
        await _promptInstallPermission(context, installer, release);
      case InstallOutcome.launched:
        if (Platform.isWindows) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Updating — the app will restart…')),
          );
          // Give the helper a beat to start, then quit so files unlock.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          exit(0);
        }
      case InstallOutcome.openedInBrowser:
        break;
    }
  } catch (e) {
    if (canceled) return; // user aborted — stay silent
    closeDialog();
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  } finally {
    progress.dispose();
    installer.close();
  }
}

Future<void> _promptInstallPermission(
  BuildContext context,
  UpdateInstaller installer,
  ReleaseInfo release,
) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.panelHi,
      title: const Text('Allow app installs'),
      content: const Text(
        'To update from within the app, allow iptvs to install apps in the '
        'next screen, then tap Update again. You can also download it from the '
        'releases page instead.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Open in browser'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open settings'),
        ),
      ],
    ),
  );
  if (go == true) {
    await installer.requestInstallPermission();
  } else if (go == false) {
    await installer.openReleasePage(release.htmlUrl);
  }
}

String _filenameFor(Uri asset, ReleaseInfo release) {
  final last = asset.pathSegments.isNotEmpty ? asset.pathSegments.last : '';
  if (last.isNotEmpty) return last;
  return Platform.isAndroid
      ? 'iptvs-${release.version}.apk'
      : 'iptvs-${release.version}.zip';
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.progress, required this.onCancel});
  final ValueListenable<double> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panelHi,
      title: const Text('Downloading update'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (context, value, _) {
          final pct = (value * 100).clamp(0, 100).toStringAsFixed(0);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Indeterminate until the first chunk gives us a fraction.
              LinearProgressIndicator(value: value > 0 ? value : null),
              const SizedBox(height: 10),
              Text('$pct%', style: const TextStyle(color: AppColors.textLo)),
            ],
          );
        },
      ),
      // Gives the modal a focus target on a TV (so OK/Back have somewhere to
      // land) and a way to abort a slow download.
      actions: [
        TextButton(
          autofocus: true,
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
