import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';

/// Pure-logic coverage for [decideIosFallbackAction] — the gate on the iOS
/// AVPlayer→mpv runtime fallback (`engineFailed`, docs/ios.md "engineFailed is
/// a cross-language handoff").
///
/// The whole point of this being a pure function is that the underlying
/// question — *does entering PiP, or presenting `.overFullScreen`, produce a
/// Flutter `AppLifecycleState` transition on iOS?* — is decided inside the
/// engine binary and is not knowable from this repo. So the decision must be
/// correct for **every** combination of what the signals might say, including
/// the two that a wrong mapping would produce:
///
/// - PiP active while Flutter still reports `resumed` (the deferral would
///   never engage → mpv opens behind the PiP window), and
/// - blocked forever with no wake edge ever arriving (the deferral engages and
///   never releases → playback silently dead).
///
/// The first is fixed by Swift stating PiP authoritatively; the second by the
/// deferral becoming *visible* rather than staying silent.
void main() {
  IosFallbackAction decide({
    AppLifecycleState? flutter = AppLifecycleState.resumed,
    bool? appActive,
    bool? pipActive,
    Duration deferredFor = Duration.zero,
  }) => decideIosFallbackAction(
    flutterLifecycle: flutter,
    nativeAppActive: appActive,
    nativePipActive: pipActive,
    deferredFor: deferredFor,
  );

  group('decideIosFallbackAction — safe windows', () {
    test('runs when every signal agrees the host is visible', () {
      expect(
        decide(
          flutter: AppLifecycleState.resumed,
          appActive: true,
          pipActive: false,
        ),
        IosFallbackAction.run,
      );
    });

    test('runs when Swift stated nothing and Flutter says resumed', () {
      // Degradation contract: a plugin build that never sends the native facts
      // (no IptvsPlayerViewController yet, or no PiP provider registered) must
      // behave like the pre-existing lifecycle-only gate, not stall.
      expect(decide(), IosFallbackAction.run);
    });

    test('a null Flutter lifecycle is an absence, not a veto', () {
      // `WidgetsBinding.instance.lifecycleState` is null until the first
      // lifecycle message arrives. Treating that as "unsafe" would manufacture
      // the exact silent stall this gate exists to prevent.
      expect(decide(flutter: null), IosFallbackAction.run);
      expect(decide(flutter: null, appActive: true), IosFallbackAction.run);
    });
  });

  group('decideIosFallbackAction — vetoes', () {
    test('PiP vetoes even when Flutter reports resumed', () {
      // The headline case: if entering PiP leaves Flutter at `resumed`, the
      // lifecycle check alone never fires and mpv would open (taking a second
      // provider connection) behind the PiP window. Swift can see PiP; Flutter
      // cannot, so this veto is the only authoritative one.
      expect(
        decide(
          flutter: AppLifecycleState.resumed,
          appActive: true,
          pipActive: true,
        ),
        IosFallbackAction.wait,
      );
    });

    test('an inactive UIApplication vetoes even when Flutter reports '
        'resumed', () {
      // Guards the direction where Flutter's lifecycle is stale or was never
      // delivered — which is by construction the case around a player that is
      // presented `.overFullScreen` precisely so it fires no transition.
      expect(
        decide(flutter: AppLifecycleState.resumed, appActive: false),
        IosFallbackAction.wait,
      );
    });

    test('every non-resumed Flutter state vetoes', () {
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        expect(
          decide(flutter: state, appActive: true, pipActive: false),
          IosFallbackAction.wait,
          reason: '$state must not be treated as visible',
        );
      }
    });

    test('a single veto is enough — belt and braces, not majority vote', () {
      expect(
        decide(flutter: null, appActive: null, pipActive: true),
        IosFallbackAction.wait,
      );
      expect(
        decide(flutter: null, appActive: false, pipActive: null),
        IosFallbackAction.wait,
      );
      expect(
        decide(flutter: AppLifecycleState.paused, appActive: null),
        IosFallbackAction.wait,
      );
    });
  });

  group('decideIosFallbackAction — no path dead-ends', () {
    test('a wait becomes a surfaced retry once the clock runs out', () {
      expect(
        decide(flutter: AppLifecycleState.paused, deferredFor: Duration.zero),
        IosFallbackAction.wait,
      );
      expect(
        decide(
          flutter: AppLifecycleState.paused,
          deferredFor: kIosFallbackSurfaceAfter - const Duration(seconds: 1),
        ),
        IosFallbackAction.wait,
      );
      expect(
        decide(
          flutter: AppLifecycleState.paused,
          deferredFor: kIosFallbackSurfaceAfter,
        ),
        IosFallbackAction.surface,
        reason: 'the threshold itself must already surface',
      );
      expect(
        decide(
          flutter: AppLifecycleState.paused,
          deferredFor: const Duration(hours: 4),
        ),
        IosFallbackAction.surface,
      );
    });

    test('surfaces no matter which signal is the one blocking', () {
      const long = Duration(minutes: 5);
      expect(
        decide(pipActive: true, deferredFor: long),
        IosFallbackAction.surface,
      );
      expect(
        decide(appActive: false, deferredFor: long),
        IosFallbackAction.surface,
      );
      expect(
        decide(flutter: AppLifecycleState.hidden, deferredFor: long),
        IosFallbackAction.surface,
      );
    });

    test('a surfaced deferral still runs itself the moment it becomes '
        'safe', () {
      // Surfacing is additive, never terminal: the overlay is a second escape
      // hatch alongside the automatic wake, not a replacement for it.
      expect(
        decide(
          appActive: true,
          pipActive: false,
          deferredFor: const Duration(hours: 4),
        ),
        IosFallbackAction.run,
      );
    });

    test('the surfacing window is bounded and short enough to be noticed', () {
      // A transient control-centre pull or app-switch must not flash an error;
      // a genuinely wrong visibility predicate must be obvious in one sitting.
      expect(kIosFallbackSurfaceAfter.inSeconds, greaterThanOrEqualTo(5));
      expect(kIosFallbackSurfaceAfter.inSeconds, lessThanOrEqualTo(30));
    });

    test('the surfaced message leaks no locator or engine detail', () {
      // `engineFailed` reasons embed the failing URL, which carries provider
      // credentials — the user-facing string must be a fixed constant.
      expect(kIosFallbackDeferredMessage, isNot(contains('://')));
      expect(kIosFallbackDeferredMessage.toLowerCase(), isNot(contains('mpv')));
      expect(
        kIosFallbackDeferredMessage.toLowerCase(),
        isNot(contains('avplayer')),
      );
    });
  });

  group('decideIosFallbackAction — an explicit surfaceAfter override', () {
    test('honours a caller-supplied threshold', () {
      expect(
        decideIosFallbackAction(
          flutterLifecycle: AppLifecycleState.paused,
          nativeAppActive: null,
          nativePipActive: null,
          deferredFor: const Duration(seconds: 2),
          surfaceAfter: const Duration(seconds: 3),
        ),
        IosFallbackAction.wait,
      );
      expect(
        decideIosFallbackAction(
          flutterLifecycle: AppLifecycleState.paused,
          nativeAppActive: null,
          nativePipActive: null,
          deferredFor: const Duration(seconds: 3),
          surfaceAfter: const Duration(seconds: 3),
        ),
        IosFallbackAction.surface,
      );
    });
  });
}
