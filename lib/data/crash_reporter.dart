import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'crash_budget.dart';
import 'crash_test.dart';
import 'diagnostics_log.dart';
import 'distribution_channel.dart';
import 'net.dart';

/// The Sentry DSN, injected at build time by the release workflows
/// (`--dart-define=SENTRY_DSN=...`, from the repo **variable** of that name —
/// a DSN is a public write-only ingest key, not a secret).
///
/// **Empty is the normal state** for development builds, forks and the whole
/// test suite, and an empty DSN means the SDK is never started at all.
const String kSentryDsn = String.fromEnvironment('SENTRY_DSN');

/// Device-local persistence for the "Send crash reports" switch.
///
/// Deliberately **not** `SourceConfig.settings`: that blob rides the source row
/// into the cloud panel, and a consent decision is a property of *this device*,
/// not of a provider or a profile. Mirrors [UpdateStore]'s one-key-per-
/// preference idiom (the app has no SharedPreferences on the Dart side).
class CrashReportingStore {
  static const _kEnabled = 'crash_reporting_enabled';

  final FlutterSecureStorage _storage;

  const CrashReportingStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Whether crash reports may be sent. **Defaults to true** (owner decision:
  /// on by default, with a switch to turn it off), so an absent key — a fresh
  /// install, or a keychain that cannot be read — reads as enabled.
  Future<bool> enabled() async {
    try {
      final raw = await _storage.read(key: _kEnabled);
      return raw != 'false';
    } catch (_) {
      return true;
    }
  }

  Future<void> setEnabled(bool value) =>
      _storage.write(key: _kEnabled, value: value ? 'true' : 'false');
}

/// How many frames identify a fault. Mirrored by `CrashScrub.FINGERPRINT_FRAMES`.
const int kFingerprintFrames = 3;

/// Picks the frames that identify a fault, **innermost first**.
///
/// ## The order is the whole point
///
/// Sentry's stack-trace protocol stores frames **outermost first** — the
/// process entry point is `frames.first` and the throw site is `frames.last`
/// (sentry-dart reverses the parsed Dart trace in
/// `SentryStackTraceFactory.parse`; sentry-java does the same in
/// `SentryStackTraceFactory.getStackFrames`, `Collections.reverse`). So taking
/// "the first three frames" takes the three frames *furthest* from the fault,
/// which on Android is `ZygoteInit.main` / `RuntimeInit$MethodAndArgsCaller.run`
/// / `Method.invoke` for **every** main-thread crash there has ever been. Every
/// such crash of one exception type then shares one fingerprint, and the
/// de-duplication window silently swallows all but the first per 24 h.
///
/// ## Why the in-app preference cannot be relied on alone
///
/// In-app frames are the right identity when they exist, but on Android they
/// never do: sentry-java decides `isInApp` from `inAppIncludes`, and the only
/// entry `AndroidOptionsInitializer.readDefaultOptionValues` adds is the
/// **`applicationId`** (`com.gchofficial.iptvs.player[.dev|.direct]`), while
/// this app's classes live under the **namespace** `com.gchofficial.iptvs`.
/// Nothing matches, there are no default excludes, and `isInApp` returns `null`
/// for every frame. R8 would defeat a prefix match anyway, since app classes
/// ship renamed (`f5.run`). The fallback therefore has to be the *innermost*
/// frames, not the outermost ones.
///
/// Returns at most [kFingerprintFrames] entries: the innermost in-app frames if
/// the event has any, otherwise the innermost frames of all.
@visibleForTesting
List<String> fingerprintFrames(List<({String id, bool? inApp})> frames) {
  final innermostFirst = frames.reversed.toList();
  final inApp = innermostFirst.where((frame) => frame.inApp == true);
  final chosen = inApp.isNotEmpty ? inApp : innermostFirst;
  return [for (final frame in chosen.take(kFingerprintFrames)) frame.id];
}

/// An opaque, stable identity for one fault, used to de-duplicate.
///
/// Built from the exception type plus the innermost few frames, preferring
/// in-app ones — see [fingerprintFrames] for why that order is load-bearing.
/// Hashed rather than stored verbatim because the budget file is written by two
/// languages and read by neither a human nor Sentry; a hash keeps file size
/// bounded and keeps any stray text (a file path, a symbol name) out of a file
/// that outlives the process.
///
/// `CrashScrub.fingerprint` + `NativeCrashScrubber.fingerprintOf` are the
/// Kotlin twin, and must stay identical: the two languages share one budget
/// file, so a rule that differs would de-duplicate the same fault twice.
String crashFingerprint(SentryEvent event) {
  final parts = <String>[];
  final exceptions = event.exceptions;
  if (exceptions != null && exceptions.isNotEmpty) {
    final first = exceptions.first;
    parts.add(first.type ?? 'error');
    parts.addAll(
      fingerprintFrames([
        for (final frame
            in first.stackTrace?.frames ?? const <SentryStackFrame>[])
          (
            id: '${frame.package ?? ''}:${frame.function ?? ''}',
            inApp: frame.inApp,
          ),
      ]),
    );
  } else {
    parts.add(event.type ?? 'event');
    parts.add(event.message?.formatted ?? event.culprit ?? '');
  }
  return sha256
      .convert(utf8.encode(parts.join('|')))
      .toString()
      .substring(0, 32);
}

/// The part of a fingerprint a log line prints: enough to tell two faults
/// apart in one export, short enough that it reads as an identifier rather
/// than a hash. Kotlin's `NativeCrashScrubber` prints the same prefix.
@visibleForTesting
String shortFingerprint(String fingerprint) =>
    fingerprint.length <= 8 ? fingerprint : fingerprint.substring(0, 8);

/// Runs **every** free-form string on [event] through [redactText].
///
/// Provider URLs carry credentials in both the query string (`?username=…`)
/// and the path (`/live/<user>/<pass>/1.ts`), and an exception thrown anywhere
/// in the provider layer quotes the URL it was fetching. A crash report is a
/// diagnostics export sent to a third party, so it gets at least the same
/// treatment as the exportable log — field by field, not best-effort.
///
/// Deliberately exhaustive and deliberately *in place*: the protocol objects
/// are mutable, and a `copyWith`-style rewrite would silently drop any field
/// added by a future SDK version. Anything this function does not reach is
/// listed in the body with a reason.
@visibleForTesting
SentryEvent scrubSentryEvent(SentryEvent event) {
  final message = event.message;
  if (message != null) {
    event.message = SentryMessage(
      _clean(message.formatted),
      template: message.template == null ? null : _clean(message.template!),
      params: message.params
          ?.map((p) => p is String ? _clean(p) : p)
          .toList(),
    );
  }
  event.logger = _scrub(event.logger);
  event.culprit = _scrub(event.culprit);
  event.transaction = _scrub(event.transaction);
  // `serverName` is a hostname the enricher may fill in; it is not a provider
  // URL, but it is the device's own name on some platforms — drop it outright
  // rather than redact it, since nothing here needs it.
  event.serverName = null;

  final exceptions = event.exceptions;
  if (exceptions != null) {
    for (final exception in exceptions) {
      exception.value = _scrub(exception.value);
      // `module` and `type` are Dart/Java type names; a type name cannot
      // carry a URL and scrubbing it would break Sentry's grouping.
      for (final frame in exception.stackTrace?.frames ?? const []) {
        frame.contextLine = _scrub(frame.contextLine);
      }
    }
  }

  final tags = event.tags;
  if (tags != null) {
    event.tags = tags.map((key, value) => MapEntry(key, _clean(value)));
  }
  // ignore: deprecated_member_use
  final extra = event.extra;
  if (extra != null) {
    // ignore: deprecated_member_use
    event.extra = extra.map((key, value) => MapEntry(key, _scrubValue(value)));
  }
  // `contexts` is deliberately left alone. Its entries are the SDK's own
  // typed structures (device, os, app, runtime) built from platform
  // properties — none of which can hold a provider URL — and rewriting them
  // as untyped maps would corrupt the payload. Nothing in this app calls
  // `setContexts`, so there is no free-form text there to reach.

  final breadcrumbs = event.breadcrumbs;
  if (breadcrumbs != null) {
    event.breadcrumbs = breadcrumbs.map(scrubBreadcrumb).toList();
  }

  // `request` would carry a URL verbatim. No Dart HTTP integration is
  // installed (see [initCrashReporting]) so it should always be null; drop it
  // anyway, because "should be null" is not a redaction policy.
  event.request = null;
  event.user = null;
  return event;
}

/// Runs a breadcrumb's message and data through [redactText].
///
/// Breadcrumbs are the likeliest carrier: they are short strings assembled
/// from whatever was happening, and on Android they are also **synced into the
/// native scope** (`enableNdkScopeSync`) so a native crash carries them too.
/// Scrubbing here therefore protects the NDK and tombstone paths as well,
/// because `Scope._addBreadCrumbSync` runs `beforeBreadcrumb` *before* it
/// notifies the scope observers that push to the native SDK.
@visibleForTesting
Breadcrumb scrubBreadcrumb(Breadcrumb crumb) {
  crumb.message = _scrub(crumb.message);
  crumb.category = _scrub(crumb.category);
  final data = crumb.data;
  if (data != null) {
    crumb.data = data.map((key, value) => MapEntry(key, _scrubValue(value)));
  }
  return crumb;
}

/// Credential-shaped `key=value` pairs, redacted wherever they appear.
///
/// [redactText] only rewrites a query string when the text contains a full
/// `http(s)://` locator — a bare `player_api.php?user=…&pw=…` quoted in an
/// exception message falls through its `value.contains('/')` guard untouched.
/// That gap is harmless in the exportable diagnostics log, which the user
/// reads before sharing, and is not harmless in a payload that leaves the
/// device automatically. Deliberately narrow (a known key name immediately
/// followed by `=`) so it cannot mangle ordinary prose, and applied *after*
/// [redactText] so it also catches anything that pass left.
///
/// Mirrored by `CrashScrub.credentialPairs` in `crash/CrashScrub.kt`; the same
/// vectors are asserted on both sides.
final RegExp _credentialPairs = RegExp(
  r'\b(user|username|pass|password|pw|pwd|token|auth|api_?key|key|mac|sn|device_?id|stream_?token|play_?token)=[^&\s"'
  r"'<>]+",
  caseSensitive: false,
);

@visibleForTesting
String redactCredentialPairs(String value) => value.replaceAllMapped(
  _credentialPairs,
  (match) => '${match.group(1)}=<redacted>',
);

/// The single scrub every string on a crash payload goes through.
@visibleForTesting
String cleanCrashText(String value) =>
    redactCredentialPairs(redactText(value));

String _clean(String value) => cleanCrashText(value);

String? _scrub(String? value) =>
    (value == null || value.isEmpty) ? value : cleanCrashText(value);

Object? _scrubValue(Object? value) {
  if (value is String) return _clean(value);
  if (value is List) return value.map(_scrubValue).toList();
  if (value is Map) {
    return value.map(
      (key, inner) => MapEntry(key.toString(), _scrubValue(inner)),
    );
  }
  return value;
}

/// Owns the crash-reporting lifecycle: the consent gate, the quota guard, the
/// redaction callbacks, and — on Android — installing the native-side twin of
/// the last two.
///
/// ## What reaches which scrub
///
/// `sentry_flutter` pushes Dart events *down* into the native SDK
/// (`FileSystemTransport` → `captureEnvelope`); nothing comes back up. So the
/// Dart `beforeSend` below sees **only Dart events**. Android Java/Kotlin
/// uncaught exceptions, NDK signal crashes and Android 12+ tombstones are
/// captured and sent by the Java SDK and never pass through it; so are
/// Windows/Linux Breakpad crashes, which sentry-native writes and uploads on
/// its own, and iOS/macOS crashes, which sentry-cocoa does.
///
/// Android therefore gets a second, native scrubber: `NativeCrashScrubber`
/// (Kotlin) replaces `SentryOptions.beforeSend`/`beforeBreadcrumb` on the live
/// `SentryAndroidOptions`, which `SentryClient.captureEvent` consults for
/// **every** Java-side event including cached outbox envelopes — sentry-java
/// re-captures those through `captureEvent` rather than forwarding them raw,
/// and runs `beforeSend` on them with no "is cached" exemption.
///
/// Windows, Linux and iOS native crashes have no equivalent hook:
/// sentry-native's `before_send`/`on_crash` are not wired up by
/// `sentry_flutter`, and the Cocoa channel carries no `beforeSend` either — so
/// a desktop Breakpad minidump or an iOS crash report is outside the per-event
/// budget. Each is still bounded: one record per actual process crash, carrying
/// frames plus a scope whose breadcrumbs this file already scrubbed, with no
/// Java-style outbox replay. The crash-loop guard still covers them, because a
/// withheld [SentryFlutter.init] means the native SDK is never initialised and
/// nothing cached is ever flushed. If that ever becomes the dominant source,
/// the fix is a Kotlin-shaped twin for each platform, not a sampling rate.
class CrashReporter {
  CrashReporter._();
  static final CrashReporter instance = CrashReporter._();

  /// The `iptvs/device` channel, which already carries the one other
  /// "ask the platform something about itself" call (`isTelevision`).
  static const MethodChannel _channel = MethodChannel('iptvs/device');

  CrashBudget? _budget;
  bool _started = false;

  /// Whether the SDK was actually started this launch. Read by tests and by
  /// the settings card's subtitle.
  bool get started => _started;

  /// Starts crash reporting if, and only if, every gate passes.
  ///
  /// **Never awaited on the boot path.** `SentryFlutter.init` awaits its
  /// integration list — including the native SDK's own init — before it
  /// returns, so awaiting it in `main` would put a JNI `SentryAndroid.init`
  /// (and a `sentry_init` on desktop) in front of the first frame. Calling it
  /// without `appRunner` and without awaiting leaves `runApp` exactly where it
  /// was: the work here is keychain and platform-channel I/O, so it yields
  /// immediately and interleaves with the boot reads it runs beside.
  ///
  /// The cost of not awaiting is that a crash in the first few hundred
  /// milliseconds is not reported. That is the right trade — the alternative
  /// delays every launch for every user to catch a window that the crash-loop
  /// guard already handles.
  Future<void> start() async {
    if (_started) return;
    try {
      if (kSentryDsn.isEmpty) return;
      if (!await const CrashReportingStore().enabled()) return;

      final budget = CrashBudget(await _budgetFile());
      _budget = budget;
      final starts = budget.beginSession();
      // Armed **before** the crash-loop check, and deliberately so: a withheld
      // launch that then survives has to be able to clear the counter. Arming
      // it after the early return instead means `starts` only ever grows and
      // the first crash loop switches crash reporting off for good. Never
      // cancelled — it belongs to the crash-loop counter, not to the SDK, so
      // withdrawing consent mid-launch must not leave this launch counted as
      // one that never got healthy.
      Timer(CrashBudget.healthyAfter, budget.markHealthy);
      if (starts >= CrashBudget.crashLoopStartLimit) {
        DiagnosticsLog.instance.addAndPrint(
          'library',
          'crash reporting withheld: $starts launches without a healthy one',
        );
        return;
      }

      final info = await PackageInfo.fromPlatform();
      final proguardUuid = await _readProguardUuid();
      await SentryFlutter.init((options) {
        options.dsn = kSentryDsn;
        // The R8 mapping this build was stamped with. **Load-bearing:** the
        // plugin's `configureAndroidOptions` assigns this field over the
        // value sentry-android read from the manifest, so leaving it null
        // nulls the manifest's UUID too and every Java/Kotlin event goes out
        // naming no mapping — the 2026-11-04 crash test, whose frame stayed
        // `f5.run(r8-map-id-…)` with the mapping uploaded and the manifest
        // correct. Read back from the merged manifest rather than passed as
        // a dart-define, so there is one source for it.
        options.proguardUuid = proguardUuid;
        // `iptvs@<build name>` — the release tag minus its `v`, the same
        // string `tool/sentry_register_release.sh` registers from CI.
        options.release = 'iptvs@${info.version}';
        options.dist = info.buildNumber;
        // The distribution channel, *unless* this is the hand-dispatched
        // crash-test build (`kCrashTest`), whose manufactured events are
        // filed under `crashtest` so the dashboard's environment filter can
        // select or discard the whole run. Every other gate above and below
        // is untouched — the test exercises the real path, budget included.
        options.environment = sentryEnvironment(
          rawChannel: DistributionConfig.rawChannel,
          crashTest: kCrashTest,
        );

        // ── Privacy, non-negotiable (CLAUDE.md) ──────────────────────────
        options.sendDefaultPii = false;
        // No performance data at all. `tracesSampleRate` left unset means
        // tracing is off; `enableAutoPerformanceTracing` additionally stops
        // the app-start/frame instrumentation from attaching spans.
        options.enableAutoPerformanceTracing = false;
        // sentry-cocoa swizzles NSURLSession and records every request as a
        // breadcrumb — including the provider URL, with credentials. The Dart
        // flag is what drives `options.enableNetworkBreadcrumbs` on the Cocoa
        // side, and it defaults to **true**, so this line is the whole of the
        // iOS/macOS URL defence. Do not remove it.
        options.recordHttpBreadcrumbs = false;
        options.captureFailedRequests = false;
        options.captureNativeFailedRequests = false;
        // Session Replay, screenshots and view hierarchy all capture the
        // screen, which is where a provider URL is typed in. All three are
        // off by default; set explicitly so a default change cannot turn them
        // on underneath us.
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;
        options.replay.sessionSampleRate = 0;
        options.replay.onErrorSampleRate = 0;

        // ── Native crash handlers ────────────────────────────────────────
        options.enableNativeCrashHandling = true;
        // Android 12+ tombstones, off by default in the SDK. They catch the
        // kills that leave no Java or NDK event at all — the low-memory and
        // watchdog kills a television box produces.
        options.enableTombstone = true;
        // The Java option beside it, `attachRawTombstone`, is the one part of
        // a tombstone that can carry arbitrary process memory. It has no Dart
        // mirror and defaults to **false** in `SentryAndroidOptions`; the
        // native scrubber asserts it stays that way rather than trusting the
        // default.

        // ── Quota ────────────────────────────────────────────────────────
        // Bounds the burst a crash-looping device can replay from its outbox
        // at the next start, which is the one window the native budget below
        // cannot cover (it is installed a method call after the SDK starts).
        options.maxCacheItems = 5;
        options.maxBreadcrumbs = 50;

        options.beforeSend = _beforeSend;
        options.beforeBreadcrumb = (crumb, hint) =>
            crumb == null ? null : scrubBreadcrumb(crumb);
      });

      _started = true;
      await _installNativeScrubber(budget);
      DiagnosticsLog.instance.addAndPrint(
        'library',
        // The resolved *environment*, not the raw channel: on a crash-test
        // build those differ, and the exportable log is where a tester
        // confirms which one the events will be filed under.
        'crash reporting on '
        '(${sentryEnvironment(rawChannel: DistributionConfig.rawChannel, crashTest: kCrashTest)})',
      );
    } catch (error) {
      // Crash reporting must never be the reason the app does not start.
      _started = false;
      DiagnosticsLog.instance.addAndPrint(
        'library',
        'crash reporting unavailable: ${error.runtimeType}',
      );
    }
  }

  /// Applies the consent change. The SDK cannot be *started* mid-session
  /// (its native half has to be up before the handlers it installs are worth
  /// anything), so turning the switch on takes effect at the next launch —
  /// which the settings card says. Turning it **off** closes the SDK straight
  /// away, because a user withdrawing consent should not have to relaunch for
  /// it to hold.
  Future<void> setEnabled(bool value) async {
    await const CrashReportingStore().setEnabled(value);
    if (!value && _started) {
      _started = false;
      await Sentry.close();
    }
  }

  FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint hint) {
    final scrubbed = scrubSentryEvent(event);
    final budget = _budget;
    if (budget == null) return scrubbed;
    final fingerprint = crashFingerprint(scrubbed);
    final outcome = budget.check(fingerprint);
    if (outcome.isAdmitted) return scrubbed;
    // The only trace a refused event leaves. Credential-free by construction:
    // one of four fixed reason words plus a hash prefix. Without it a user's
    // export cannot tell "never reported" from "reported once, then
    // de-duplicated for a day" — see [CrashBudgetOutcome].
    DiagnosticsLog.instance.addAndPrint(
      'library',
      'crash report dropped (${outcome.name}) '
          'fp=${shortFingerprint(fingerprint)}',
    );
    return null;
  }

  Future<File> _budgetFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'crash_budget.json'));
  }

  /// Hands the Android layer the same budget file and asks it to put our
  /// `beforeSend`/`beforeBreadcrumb` on the live `SentryAndroidOptions`,
  /// replacing the plugin's own tagging callback (which it re-implements).
  ///
  /// Called as soon as [SentryFlutter.init] returns, which is the earliest
  /// moment the options object exists. Anything the Java SDK flushed from a
  /// previous run's outbox in that window carries the plugin's callback
  /// instead — bounded by `maxCacheItems` above, and structurally
  /// credential-free, since a cached native event is frames plus a scope whose
  /// breadcrumbs went through [scrubBreadcrumb] before they were synced.
  /// The `io.sentry.proguard-uuid` this APK's manifest carries, or null —
  /// off Android, on dev/PR builds (which carry no UUID), or if the call
  /// fails. Never throws: crash reporting must not be why the app won't start.
  Future<String?> _readProguardUuid() async {
    if (!Platform.isAndroid) return null;
    try {
      return proguardUuidOrNull(
        await _channel.invokeMethod<String>('sentryProguardUuid'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _installNativeScrubber(CrashBudget budget) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('installCrashScrubber', {
        'budgetPath': budget.file.path,
      });
    } catch (error) {
      DiagnosticsLog.instance.addAndPrint(
        'library',
        'native crash scrubber unavailable: ${error.runtimeType}',
      );
    }
  }
}

/// Accepts only a canonical UUID, the shape `build.gradle.kts` stamps — so a
/// malformed value from the platform side becomes "no mapping" rather than a
/// debug image Sentry can never resolve.
@visibleForTesting
String? proguardUuidOrNull(String? raw) {
  if (raw == null) return null;
  final v = raw.trim();
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(v)
      ? v
      : null;
}
