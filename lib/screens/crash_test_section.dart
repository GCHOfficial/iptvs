import 'package:flutter/material.dart';

import '../data/crash_reporter.dart';
import '../data/crash_test.dart';
import '../data/diagnostics_log.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';

/// The Diagnostics screen's "Crash test" section — **only** in the
/// hand-dispatched crash-test build.
///
/// Mounted behind `if (kCrashTest)`, a compile-time `const false` everywhere
/// else, so in a shipped build this widget is unreachable and the tree shaker
/// removes it along with `data/crash_test.dart`. Nothing here is gated on
/// `kDebugMode`: the whole point is a `--release` APK, which is the only
/// configuration where the native crash handlers and the release-mode engine
/// (the one whose debug files are uploaded to Sentry) actually exist.
///
/// D-pad navigable by construction: every action is a [FocusableCard], which
/// takes OK/Enter/Select and scrolls itself into view. No text field appears
/// on this route — a bare `TextField` traps D-pad focus (CLAUDE.md "TV /
/// remote navigation").
class CrashTestSection extends StatelessWidget {
  const CrashTestSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          // A warning-coloured edge, because every one of these buttons does
          // something destructive on purpose and two of them end the process.
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.bug_report_outlined,
                    size: 20,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Crash test (environment: $kCrashTestEnvironment)',
                    style: const TextStyle(
                      color: AppColors.textHi,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'Deliberate faults, for proving crash capture end to end on '
                  'a real device. Every normal gate still applies: a DSN must '
                  'be compiled in, "Send crash reports" must be on, and the '
                  'send budget still charges each event.',
                  style: TextStyle(
                    color: AppColors.textLo,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
              _StatusLine(),
              for (final action in CrashTestAction.values)
                _CrashTestButton(action: action),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether the SDK is actually running. Without it a tester cannot tell a
/// working scrub from a build that never started Sentry at all — the two look
/// identical from the dashboard (nothing arrives).
class _StatusLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final started = CrashReporter.instance.started;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        started
            ? 'Sentry is running — events will be sent.'
            : 'Sentry is NOT running (no DSN, consent off, or crash-loop '
                  'guard tripped). Nothing below will reach the dashboard.',
        style: TextStyle(
          color: started ? AppColors.success : AppColors.danger,
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}

class _CrashTestButton extends StatelessWidget {
  const _CrashTestButton({required this.action});

  final CrashTestAction action;

  @override
  Widget build(BuildContext context) {
    final supported = crashTestSupported(action);
    return Opacity(
      opacity: supported ? 1 : 0.45,
      child: FocusableCard(
        // Still focusable when unsupported, so a D-pad never meets a dead
        // gap in the middle of the list; the tap just explains itself.
        semanticsLabel: '${action.label}. ${action.expectation}',
        onTap: () => _fire(context, supported),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      action.label,
                      style: const TextStyle(
                        color: AppColors.textHi,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (action.isFatal)
                    const Text(
                      'ends the app',
                      style: TextStyle(
                        color: AppColors.warning,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  supported
                      ? action.expectation
                      : 'Not available on this platform.',
                  style: const TextStyle(
                    color: AppColors.textLo,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _fire(BuildContext context, bool supported) {
    if (!supported) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${action.label} is Android-only')),
      );
      return;
    }
    // Logged *before* the fault, because two of the four kill the process and
    // the exportable log is the only record that survives into the next
    // launch — which is also where the native event is sent from.
    DiagnosticsLog.instance.addAndPrint(
      'library',
      'crash test requested: ${action.name}',
    );
    final note = runCrashTest(action);
    DiagnosticsLog.instance.addAndPrint('library', note);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(action.expectation)));
  }
}
