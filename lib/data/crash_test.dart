import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

import 'diagnostics_log.dart';

/// Whether this build is the **crash-test** build.
///
/// A compile-time `bool.fromEnvironment`, so it is a `const false` in every
/// shipped build and the whole of this file — the Diagnostics section, the
/// triggers, the `iptvs/device` call — is unreachable and tree-shaken away.
/// Only `.github/workflows/crash-test-apk.yml` passes
/// `--dart-define=IPTVS_CRASH_TEST=true`, and that workflow is dispatch-only
/// and uploads a 7-day artifact that is never published.
///
/// Why it exists: the crash pipeline (Dart `beforeSend`, Kotlin
/// `NativeCrashScrubber`, the NDK/tombstone handlers, `CrashBudget`) has no
/// end-to-end test that an emulator or a unit suite can run — nothing in CI
/// may carry a DSN, and a real device is the only place the native handlers
/// are installed at all. So the proof is a hand-dispatched build with four
/// deliberate faults in it.
///
/// **Every other gate stays exactly as it is.** A DSN must still be compiled
/// in, the user's "Send crash reports" switch must still be on, the crash-loop
/// guard still applies and `CrashBudget` still charges every event — the point
/// is to exercise the real path, including the budget, not a bypass of it.
const bool kCrashTest = bool.fromEnvironment('IPTVS_CRASH_TEST');

/// The Sentry `environment` a crash-test build reports under.
///
/// Deliberately *not* one of `DistributionChannel`'s names: these events are
/// manufactured, and mixing them into `development` — let alone into
/// `githubDirect` — would quietly pollute the dashboard filter everyone else
/// reads. One string, so the whole test run can be selected or discarded in
/// the UI with `environment:crashtest`.
const String kCrashTestEnvironment = 'crashtest';

/// Resolves the Sentry `environment` tag. Pure, so it can be asserted without
/// a DSN (the SDK never starts in a test run).
String sentryEnvironment({
  required String rawChannel,
  required bool crashTest,
}) => crashTest ? kCrashTestEnvironment : rawChannel;

/// A fake provider URL carrying fake credentials in **both** the shapes this
/// app's redaction has to handle: the Xtream-style `/live/<user>/<pass>/<id>`
/// path segments and a `token=` query parameter.
///
/// Assembled at runtime from parts rather than written as one literal, for two
/// reasons: a literal `username=…&password=…` pair trips GitGuardian on every
/// PR that adds one (CLAUDE.md "Testing notes"), and a constant-folded literal
/// is the one thing a compiler could legitimately hoist somewhere the scrubber
/// never sees. Nothing here is real — the host is a documentation domain, and
/// `crashtest-example`/`not-a-real-secret`/`not-a-real-token` are the strings a
/// reviewer should grep the resulting Sentry event for. If any of them appears
/// in the dashboard, the scrubbing is broken, which is exactly what this build
/// is for. A crash test quoting a URL the redaction already ignores would
/// "pass" while proving nothing, so `test/crash_reporting_test.dart` pins this
/// message against `cleanCrashText` and `CrashTestTest` pins the Kotlin twin
/// against `CrashScrub.redactText`.
String crashTestLocator() {
  const host = 'panel.example.com';
  const user = 'crashtest-example';
  const pass = 'not-a-real-secret';
  const token = 'not-a-real-token';
  final path = <String>['live', user, pass, '4821.ts'].join('/');
  return 'http://$host:8080/$path?token=$token';
}

/// The exception message every trigger embeds. One function, so the Dart and
/// Kotlin faults carry the same shape and a reviewer compares like with like.
String crashTestMessage(String what) =>
    'iptvs crash test ($what) while fetching ${crashTestLocator()}';

/// The Dart fault (a). A named type so Sentry's `exception.type` is stable and
/// `crashFingerprint` groups the two throws of the repeat test together.
class CrashTestException implements Exception {
  CrashTestException(this.message);

  final String message;

  @override
  String toString() => 'CrashTestException: $message';
}

/// The four faults this build can produce, in the order the Diagnostics
/// section lists them.
enum CrashTestAction {
  /// (a) An **uncaught Dart exception** whose message embeds the fake provider
  /// URL. Proves the Dart `beforeSend` runs, scrubs and charges the budget.
  dartException,

  /// (b) An **uncaught Kotlin exception** on the Android main thread, thrown
  /// from the `iptvs/device` channel. Proves sentry-java's
  /// `UncaughtExceptionHandlerIntegration` captures it and that
  /// `NativeCrashScrubber` — not the Dart `beforeSend`, which never sees it —
  /// is what redacts it.
  kotlinException,

  /// (c) A **native SIGSEGV** raised on the UI thread through libc. Proves the
  /// NDK handler writes an outbox envelope that the next launch sends, and
  /// that `libflutter.so` frames symbolicate against the engine debug files
  /// already uploaded for this engine revision.
  nativeSigsegv,

  /// (d) A **repeat of (a)**, thrown from the same site so the fingerprint is
  /// identical. Proves `CrashBudget`'s one-event-per-fingerprint-per-24h
  /// de-duplication drops it.
  repeatDartException,
}

extension CrashTestActionCopy on CrashTestAction {
  String get label => switch (this) {
    CrashTestAction.dartException => 'Dart exception',
    CrashTestAction.kotlinException => 'Kotlin exception (Android)',
    CrashTestAction.nativeSigsegv => 'Native SIGSEGV (Android)',
    CrashTestAction.repeatDartException => 'Repeat the Dart exception',
  };

  /// The one line the button shows: what should turn up in Sentry.
  String get expectation => switch (this) {
    CrashTestAction.dartException =>
      'Expect one CrashTestException in environment:crashtest, '
          'event.origin:flutter, with the URL redacted.',
    CrashTestAction.kotlinException =>
      'Crashes the app. Expect one RuntimeException, event.origin:android / '
          'event.environment:java, URL redacted by NativeCrashScrubber.',
    CrashTestAction.nativeSigsegv =>
      'Kills the app with SIGSEGV. Expect a native event on the NEXT launch, '
          'event.environment:native, with symbolicated libflutter.so frames.',
    CrashTestAction.repeatDartException =>
      'Expect NOTHING new: same fingerprint within 24h, so CrashBudget drops '
          'it. The log line below is the only evidence.',
  };

  /// Whether this fault ends the process. Shown so a tester knows the app is
  /// about to disappear rather than wondering whether the button worked.
  bool get isFatal =>
      this == CrashTestAction.kotlinException ||
      this == CrashTestAction.nativeSigsegv;
}

/// SIGSEGV on Linux/Android.
const int _kSigsegv = 11;

typedef _RaiseNative = Int32 Function(Int32);
typedef _RaiseDart = int Function(int);

/// Fires one of the four faults. Returns a short, credential-free note for the
/// diagnostics log; a fatal action never returns at all (or returns just
/// before the process dies).
///
/// Never guarded by `kDebugMode` or by a platform check beyond what each fault
/// needs: this runs in a `--release` build on a real device, which is the only
/// configuration where the native handlers exist.
String runCrashTest(CrashTestAction action) {
  switch (action) {
    case CrashTestAction.dartException:
    case CrashTestAction.repeatDartException:
      _throwUncaughtDartException();
      return action == CrashTestAction.dartException
          ? 'crash test: threw CrashTestException (expect 1 event)'
          : 'crash test: threw CrashTestException again (expect 0 events)';

    case CrashTestAction.kotlinException:
      // Fire-and-forget: the Kotlin side replies *before* it posts the throw,
      // so this call completes and the process dies a tick later.
      //
      // The error branch is the one place the two halves of the gate can be
      // seen to disagree: a `MissingPluginException` here means Dart compiled
      // `kCrashTest` on while `build.gradle.kts` decoded `BuildConfig.
      // CRASH_TEST` off. Caught and named rather than left unhandled, which
      // would arrive in Sentry as a confusing second fault instead of the
      // diagnosis.
      unawaited(
        _crashTestChannel.invokeMethod<bool>('crashTestThrow').catchError((
          Object error,
        ) {
          DiagnosticsLog.instance.addAndPrint(
            'library',
            'crash test: Kotlin refused (${error.runtimeType}) — the Gradle '
                'gate (BuildConfig.CRASH_TEST) disagrees with kCrashTest',
          );
          return null;
        }),
      );
      return 'crash test: asked Kotlin to throw on the main thread';

    case CrashTestAction.nativeSigsegv:
      final raise = DynamicLibrary.process()
          .lookupFunction<_RaiseNative, _RaiseDart>('raise');
      raise(_kSigsegv);
      // Unreachable in practice: the signal is delivered synchronously to this
      // thread and sentry-native's handler re-raises it on the default
      // disposition. If a device somehow continues, say so rather than
      // pretending the test ran.
      return 'crash test: raise(SIGSEGV) returned — no signal was delivered';
  }
}

/// The *single* throw site for (a) and (d).
///
/// `crashFingerprint` is built from the exception type plus the first in-app
/// frames, so both presses have to throw from the same function for the
/// de-duplication test to mean anything — two sites would produce two
/// fingerprints and both events would be admitted.
///
/// Thrown from a `Timer`, not from the button handler, so it is genuinely
/// **uncaught**: the app runs in the root zone (`main` installs no
/// `runZonedGuarded`), so an error escaping a timer callback reaches
/// `PlatformDispatcher.onError`, which is the hook `sentry_flutter`'s
/// `OnErrorIntegration` installs. An exception thrown inline would be caught
/// by the framework's own gesture-handler guard and arrive as a very different
/// event.
void _throwUncaughtDartException() {
  Timer.run(() {
    throw CrashTestException(crashTestMessage('uncaught Dart exception'));
  });
}

/// The same channel `CrashReporter._installNativeScrubber` uses — this is one
/// more "ask the platform to do something about itself" call, not a new rail.
const MethodChannel _crashTestChannel = MethodChannel('iptvs/device');

/// Whether a fault can run on this platform. The two native ones are Android
/// only; the Dart pair runs anywhere.
bool crashTestSupported(CrashTestAction action) => switch (action) {
  CrashTestAction.dartException => true,
  CrashTestAction.repeatDartException => true,
  CrashTestAction.kotlinException => Platform.isAndroid,
  CrashTestAction.nativeSigsegv => Platform.isAndroid || Platform.isLinux,
};
