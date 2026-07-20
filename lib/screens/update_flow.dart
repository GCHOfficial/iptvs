import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/update_installer.dart';
import '../data/update_manifest.dart';
import '../data/update_service.dart';
import '../data/update_store.dart';
import '../theme.dart';
import '../widgets/release_notes_view.dart';

/// The user's choice on the "Update available" dialog.
enum UpdateChoice { update, later, skip }

var _activeInstallFlows = 0;

/// Prevents an app-resume callback from racing the permission flow that caused
/// that same resume event.
bool get updateInstallFlowActive => _activeInstallFlows > 0;

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
  final prefs = store ?? const UpdateStore();
  final svc = service ?? UpdateService(track: await prefs.track());

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

  if (release == null || !isUpdateAllowed(release, current)) {
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
      if (context.mounted) {
        await _downloadAndInstall(context, release, current, prefs);
      }
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
      UpdateInstaller.isSupported &&
      release.assetForCurrentPlatform() != null &&
      release.artifactForCurrentPlatform() != null;
  return showDialog<UpdateChoice>(
    context: context,
    builder: (_) => _UpdateDialog(
      release: release,
      current: current,
      canInstall: canInstall,
    ),
  );
}

/// Offers to resume an Android APK that was already downloaded and verified.
///
/// Returns true when pending state existed (including when the user chose
/// Later), allowing startup to avoid presenting a second update prompt. A new
/// app version clears the stale record; missing or modified cache files fail
/// closed and will be downloaded again by the normal update check.
Future<bool> resumePendingUpdate(
  BuildContext context, {
  UpdateStore? store,
  UpdateInstaller? installer,
  Future<String> Function()? currentVersion,
}) async {
  if (updateInstallFlowActive) return true;
  if (!Platform.isAndroid || !UpdateInstaller.isSupported) return false;
  final prefs = store ?? const UpdateStore();
  final pending = await prefs.pendingUpdate();
  if (pending == null) return false;

  final current = await (currentVersion ?? appVersion)();
  if (compareVersions(current, pending.version) >= 0) {
    await prefs.clearPendingUpdate();
    return false;
  }

  final file = File(pending.path);
  try {
    await validateCachedArtifact(file, pending.artifact);
  } catch (_) {
    await prefs.clearPendingUpdate();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The cached update expired and must be downloaded again',
          ),
        ),
      );
    }
    return false;
  }
  if (!context.mounted) return true;

  final install = await showPendingUpdateDialog(context, pending.version);
  if (install != true || !context.mounted) return true;

  final ownedInstaller = installer == null;
  final activeInstaller = installer ?? UpdateInstaller();
  final release = ReleaseInfo(
    version: pending.version,
    tagName: 'v${pending.version}',
    name: 'iptvs ${pending.version}',
    notes: '',
    htmlUrl: pending.releasePage,
    androidArtifact: pending.artifact,
  );
  try {
    final outcome = await _installWithPermissionRetry(
      context,
      activeInstaller,
      release,
      file,
      pending.artifact,
    );
    if (outcome == InstallOutcome.needsPermission && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Update ready — allow app installs to continue'),
        ),
      );
    } else if (outcome == InstallOutcome.openedInBrowser) {
      await prefs.clearPendingUpdate();
    }
  } finally {
    if (ownedInstaller) activeInstaller.close();
  }
  return true;
}

/// The cached-update prompt is public so its TV focus/default action can be
/// pinned without requiring an Android host in widget tests.
Future<bool?> showPendingUpdateDialog(BuildContext context, String version) =>
    showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: Text('Update ready to install — $version'),
        content: const Text(
          'The verified update is already downloaded. Continue installation '
          'without downloading it again?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );

/// The update prompt as a stateful dialog so D-pad focus stays **trapped**: on a
/// TV, bare Up/Down otherwise fell through the modal barrier onto the channel
/// list behind it. A boundary [Focus] consumes vertical arrows (they never
/// escape) and routes them between the actions and a focusable, scrollable
/// changelog, which is rendered by [ReleaseNotesView] instead of raw markdown.
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.release,
    required this.current,
    required this.canInstall,
  });

  final ReleaseInfo release;
  final String current;
  final bool canInstall;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final FocusNode _notesFocus = FocusNode(debugLabel: 'update.notes');
  final FocusNode _primaryFocus = FocusNode(debugLabel: 'update.primary');
  final ScrollController _notesScroll = ScrollController();

  bool get _hasNotes => widget.release.notes.isNotEmpty;

  @override
  void dispose() {
    _notesFocus.dispose();
    _primaryFocus.dispose();
    _notesScroll.dispose();
    super.dispose();
  }

  /// Boundary key wall: bare Up/Down are always consumed so focus can never
  /// leave the dialog. Up enters the changelog; Down from the changelog returns
  /// to the actions. Everything else (Left/Right traversal, OK, Back) flows on.
  KeyEventResult _boundaryKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isVertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!isVertical) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled; // swallow the key-up too
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_hasNotes && !_notesFocus.hasFocus) _notesFocus.requestFocus();
      return KeyEventResult.handled;
    }
    // arrowDown
    if (_notesFocus.hasFocus) _primaryFocus.requestFocus();
    return KeyEventResult.handled;
  }

  /// While the changelog is focused, Up/Down scroll it; at an edge they fall
  /// through (ignored) so the boundary can move focus in/out of the notes.
  KeyEventResult _notesKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if ((!up && !down) || !_notesScroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final pos = _notesScroll.position;
    if (up && pos.pixels <= pos.minScrollExtent) return KeyEventResult.ignored;
    if (down && pos.pixels >= pos.maxScrollExtent) {
      return KeyEventResult.ignored;
    }
    const step = 90.0;
    _notesScroll.animateTo(
      (pos.pixels + (up ? -step : step)).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _boundaryKey,
      child: FocusTraversalGroup(
        child: AlertDialog(
          backgroundColor: AppColors.panelHi,
          title: Text('Update available — ${widget.release.version}'),
          content: ConstrainedBox(
            // Grows with the screen so a longer (AI-generated) changelog shows
            // more before scrolling — but never taller than 60% of the screen,
            // and no smaller than the old fixed cap on phones.
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: (MediaQuery.sizeOf(context).height * 0.6).clamp(
                280.0,
                520.0,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You have ${widget.current}. Version '
                  '${widget.release.version} is available.',
                  style: const TextStyle(color: AppColors.textLo),
                ),
                if (_hasNotes) ...[
                  const SizedBox(height: 12),
                  Flexible(
                    child: Focus(
                      focusNode: _notesFocus,
                      onKeyEvent: _notesKey,
                      onFocusChange: (_) => setState(() {}),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.panel,
                          borderRadius: BorderRadius.circular(AppRadius.tile),
                          border: Border.all(
                            color: _notesFocus.hasFocus
                                ? AppColors.accent
                                : AppColors.line,
                            width: _notesFocus.hasFocus ? 2 : 1,
                          ),
                        ),
                        child: Scrollbar(
                          controller: _notesScroll,
                          child: SingleChildScrollView(
                            controller: _notesScroll,
                            child: ReleaseNotesView(widget.release.notes),
                          ),
                        ),
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
              // Autofocus so a TV remote's OK acts on the dialog immediately —
              // the modal's focus scope otherwise lands on nothing until the
              // first arrow press. The primary action gets the focus ring.
              focusNode: _primaryFocus,
              autofocus: true,
              onPressed: () => Navigator.pop(context, UpdateChoice.update),
              child: Text(widget.canInstall ? 'Update' : 'View release'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _downloadAndInstall(
  BuildContext context,
  ReleaseInfo release,
  String current,
  UpdateStore store,
) async {
  if (!isUpdateAllowed(release, current)) {
    throw StateError('Refusing to install a non-upgrade release');
  }
  final installer = UpdateInstaller();
  final asset = release.assetForCurrentPlatform();
  final artifact = release.artifactForCurrentPlatform();

  // Nothing to install in-app (macOS/Linux, or a release missing this
  // platform's asset) — just open the release page.
  if (!UpdateInstaller.isSupported || asset == null || artifact == null) {
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

  _activeInstallFlows += 1;
  try {
    final file = await installer.download(
      asset,
      artifact,
      onProgress: (p) {
        if (!canceled) progress.value = p;
      },
    );
    if (canceled) return;
    closeDialog();
    if (!context.mounted) return;

    if (Platform.isAndroid) {
      await store.setPendingUpdate(
        PendingUpdate(
          version: release.version,
          path: file.path,
          releasePage: release.htmlUrl,
          artifact: artifact,
        ),
      );
    }
    if (!context.mounted) return;

    final outcome = await _installWithPermissionRetry(
      context,
      installer,
      release,
      file,
      artifact,
    );
    if (!context.mounted) return;
    switch (outcome) {
      case InstallOutcome.needsPermission:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Update downloaded — installation can be resumed'),
          ),
        );
      case InstallOutcome.launched:
        if (Platform.isWindows || Platform.isLinux) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Updating — the app will restart…')),
          );
          // Give the detached helper a beat to start, then quit so it can swap
          // the portable Windows folder or running Linux AppImage.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          exit(0);
        }
      case InstallOutcome.openedInBrowser:
        if (Platform.isAndroid) await store.clearPendingUpdate();
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
    _activeInstallFlows -= 1;
    progress.dispose();
    installer.close();
  }
}

enum _InstallPermissionChoice { granted, later, browser }

Future<InstallOutcome> _installWithPermissionRetry(
  BuildContext context,
  UpdateInstaller installer,
  ReleaseInfo release,
  File file,
  ReleaseArtifact artifact,
) async {
  var outcome = await installer.install(release, file);
  if (outcome != InstallOutcome.needsPermission || !context.mounted) {
    return outcome;
  }
  final choice = await _promptInstallPermission(context, installer, release);
  if (choice != _InstallPermissionChoice.granted || !context.mounted) {
    return choice == _InstallPermissionChoice.browser
        ? InstallOutcome.openedInBrowser
        : InstallOutcome.needsPermission;
  }
  await validateCachedArtifact(file, artifact);
  outcome = await installer.install(release, file);
  return outcome;
}

Future<_InstallPermissionChoice> _promptInstallPermission(
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
    return await installer.requestInstallPermission()
        ? _InstallPermissionChoice.granted
        : _InstallPermissionChoice.later;
  } else if (go == false) {
    await installer.openReleasePage(release.htmlUrl);
    return _InstallPermissionChoice.browser;
  }
  return _InstallPermissionChoice.later;
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
