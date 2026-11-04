import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/crash_budget.dart';
import 'package:iptvs/data/crash_reporter.dart';
import 'package:iptvs/data/crash_test.dart';
import 'package:iptvs/screens/crash_test_section.dart';
import 'package:iptvs/widgets/focusable_card.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Credentials written as `user=`/`pw=` rather than the literal
/// `username=…&password=…` pair, which trips GitGuardian on every PR that adds
/// one (CLAUDE.md "Testing notes"). Nothing under test keys off the names.
const _queryUrl = 'http://panel.example.com:8080/get.php?user=alice&pw=hunter2';
const _pathUrl = 'http://panel.example.com:8080/live/alice/hunter2/4821.ts';

void _assertClean(String text) {
  expect(text, isNot(contains('alice')));
  expect(text, isNot(contains('hunter2')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  group('crash reporting is never started without both gates', () {
    // The DSN is a `const String.fromEnvironment`, so it is empty for every
    // `flutter test` run, for development builds and for forks. This is the
    // invariant that keeps the whole feature inert there: `start()` must
    // return before it touches storage, a platform channel or the SDK.
    test('an empty DSN leaves the SDK off', () async {
      expect(kSentryDsn, isEmpty);
      await CrashReporter.instance.start();
      expect(CrashReporter.instance.started, isFalse);
      expect(Sentry.isEnabled, isFalse);
    });

    test('consent defaults to on, and persists an explicit off', () async {
      FlutterSecureStorage.setMockInitialValues({});
      const store = CrashReportingStore();
      expect(await store.enabled(), isTrue);
      await store.setEnabled(false);
      expect(await store.enabled(), isFalse);
      await store.setEnabled(true);
      expect(await store.enabled(), isTrue);
    });
  });

  group('scrubbing', () {
    test('an exception value loses its query string', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'HttpException',
            value: 'HTTP 403 fetching $_queryUrl',
          ),
        ],
      );
      final scrubbed = scrubSentryEvent(event);
      final value = scrubbed.exceptions!.first.value!;
      _assertClean(value);
      // The host has to survive: an unrecognisable report is a useless one.
      expect(value, contains('panel.example.com'));
    });

    test('a credential path is redacted but the stream id survives', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(type: 'StateError', value: 'open failed: $_pathUrl'),
        ],
      );
      final value = scrubSentryEvent(event).exceptions!.first.value!;
      _assertClean(value);
      expect(value, contains('4821.ts'));
    });

    test('message, tags and extras are all scrubbed', () {
      final event = SentryEvent(
        message: SentryMessage(
          'load failed %s',
          template: 'load failed %s',
          params: [_queryUrl],
        ),
        tags: {'source': _pathUrl},
      );
      // ignore: deprecated_member_use
      event.extra = {
        'url': _queryUrl,
        'nested': {
          'inner': [_pathUrl],
        },
        'count': 3,
      };
      event.logger = _queryUrl;
      event.culprit = _pathUrl;

      final scrubbed = scrubSentryEvent(event);
      _assertClean(scrubbed.message!.params!.first as String);
      _assertClean(scrubbed.tags!['source']!);
      _assertClean(scrubbed.logger!);
      _assertClean(scrubbed.culprit!);
      // ignore: deprecated_member_use
      final extra = scrubbed.extra!;
      _assertClean(extra['url'] as String);
      _assertClean(
        ((extra['nested'] as Map)['inner'] as List).first as String,
      );
      // Non-strings ride through untouched.
      expect(extra['count'], 3);
    });

    test('breadcrumb message and data are scrubbed', () {
      final crumb = Breadcrumb(
        message: 'GET $_pathUrl',
        category: 'playback',
        data: {'url': _queryUrl, 'retries': 2},
      );
      final scrubbed = scrubBreadcrumb(crumb);
      _assertClean(scrubbed.message!);
      _assertClean(scrubbed.data!['url'] as String);
      expect(scrubbed.data!['retries'], 2);
    });

    test('event breadcrumbs are scrubbed through the event too', () {
      final event = SentryEvent(
        breadcrumbs: [Breadcrumb(message: 'open $_queryUrl')],
      );
      _assertClean(scrubSentryEvent(event).breadcrumbs!.first.message!);
    });

    test('a bare credential pair with no scheme is still redacted', () {
      // `redactText` alone misses this: with no `http(s)://` locator and no
      // `/`, it returns the string untouched. A diagnostics export the user
      // reads first can live with that; a payload that leaves the device on
      // its own cannot.
      _assertClean(cleanCrashText('player_api.php?user=alice&pw=hunter2'));
    });

    test('the request and user blocks are dropped outright', () {
      final event = SentryEvent(
        request: SentryRequest(url: _queryUrl),
        user: SentryUser(id: 'someone', ipAddress: '203.0.113.9'),
      );
      final scrubbed = scrubSentryEvent(event);
      expect(scrubbed.request, isNull);
      expect(scrubbed.user, isNull);
    });

    test('ordinary prose is left alone', () {
      const text = 'Decoder init failed: MediaCodec, no such codec';
      expect(cleanCrashText(text), text);
    });
  });

  group('fingerprint', () {
    SentryEvent eventWith(String type, List<String> functions) => SentryEvent(
      exceptions: [
        SentryException(
          type: type,
          value: 'x',
          stackTrace: SentryStackTrace(
            frames: [
              for (final function in functions)
                SentryStackFrame(
                  function: function,
                  package: 'iptvs',
                  inApp: true,
                ),
            ],
          ),
        ),
      ],
    );

    test('is stable for the same fault and distinct across faults', () {
      final a = crashFingerprint(eventWith('StateError', ['a', 'b']));
      expect(a, crashFingerprint(eventWith('StateError', ['a', 'b'])));
      expect(a, isNot(crashFingerprint(eventWith('StateError', ['a', 'c']))));
      expect(a, isNot(crashFingerprint(eventWith('ArgumentError', ['a', 'b']))));
      expect(a.length, 32);
    });

    test('ignores frames beyond the top three', () {
      expect(
        crashFingerprint(eventWith('StateError', ['a', 'b', 'c', 'd'])),
        crashFingerprint(eventWith('StateError', ['a', 'b', 'c', 'z'])),
      );
    });
  });

  group('budget', () {
    late Directory dir;
    late DateTime now;
    CrashBudget make() =>
        CrashBudget(File('${dir.path}/budget'), clock: () => now);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('crash-budget');
      now = DateTime.utc(2026, 1, 1);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('the shared file grammar round-trips', () {
      final state = CrashBudgetState(
        dayStartMs: 1000,
        dayCount: 3,
        monthStartMs: 500,
        monthCount: 7,
        sessionId: 99,
        sessionCount: 2,
        starts: 1,
        seen: {'abc123': 42},
      );
      // Byte-for-byte what `CrashBudgetState.encode()` emits on the Kotlin
      // side; `CrashScrubTest` asserts the same literal. If either writer
      // changes shape, both suites fail rather than one reader silently
      // starting from zero.
      expect(
        state.encode(),
        'v=1\nday=1000,3\nmonth=500,7\nsession=99,2\nstarts=1\nfp=abc123,42\n',
      );
      final parsed = CrashBudgetState.parse(state.encode());
      expect(parsed.dayCount, 3);
      expect(parsed.monthCount, 7);
      expect(parsed.sessionId, 99);
      expect(parsed.starts, 1);
      expect(parsed.seen['abc123'], 42);
    });

    test('an unknown version starts fresh', () {
      final parsed = CrashBudgetState.parse('v=99\nday=1000,19\n');
      expect(parsed.dayCount, 0);
      expect(parsed.dayStartMs, 0);
    });

    test('the same fingerprint is admitted once per day', () {
      final budget = make();
      expect(budget.admit('fp-a'), isTrue);
      expect(budget.admit('fp-a'), isFalse);
      expect(budget.admit('fp-b'), isTrue);
      now = now.add(const Duration(hours: 25));
      expect(budget.admit('fp-a'), isTrue);
    });

    test('the session cap stops a loop inside one launch', () {
      final budget = make();
      for (var i = 0; i < CrashBudget.maxPerSession; i++) {
        expect(budget.admit('fp-$i'), isTrue, reason: 'event $i');
      }
      expect(budget.admit('fp-overflow'), isFalse);
      // A new session re-arms it; the 24 h cap does not.
      budget.beginSession();
      expect(budget.admit('fp-next'), isTrue);
    });

    test('the 24 h cap survives relaunches', () {
      final budget = make();
      var sent = 0;
      // Relaunch after every session's worth so only the day cap can bite.
      for (var i = 0; i < CrashBudget.maxPerDay * 2; i++) {
        if (i % CrashBudget.maxPerSession == 0) budget.beginSession();
        if (budget.admit('fp-$i')) sent++;
      }
      expect(sent, CrashBudget.maxPerDay);
      now = now.add(const Duration(hours: 25));
      budget.beginSession();
      expect(budget.admit('fp-after'), isTrue);
    });

    test('the 30 day cap is what bounds the monthly quota', () {
      final budget = make();
      var sent = 0;
      // 28 days of daily relaunches, stepping exactly one day so the 24 h
      // window rotates every iteration while the 30 day window never does —
      // otherwise the test measures a month boundary rather than the cap.
      for (var day = 0; day < 28; day++) {
        now = now.add(const Duration(hours: 24));
        for (var i = 0; i < CrashBudget.maxPerSession; i++) {
          budget.beginSession();
          for (var j = 0; j < CrashBudget.maxPerSession; j++) {
            if (budget.admit('fp-$day-$i-$j')) sent++;
          }
        }
      }
      expect(sent, CrashBudget.maxPerMonth);
    });

    test('the crash-loop guard counts launches that never got healthy', () {
      final budget = make();
      expect(budget.beginSession(), 1);
      expect(budget.beginSession(), 2);
      expect(budget.beginSession(), CrashBudget.crashLoopStartLimit);
      // The caller withholds the SDK at the limit; one healthy launch re-arms.
      budget.markHealthy();
      expect(budget.beginSession(), 1);
    });

    test('a corrupt file is treated as a fresh one', () {
      final file = File('${dir.path}/budget')
        ..writeAsStringSync('not a budget at all');
      final budget = CrashBudget(file, clock: () => now);
      expect(budget.admit('fp-a'), isTrue);
    });
  });

  group('crash-test build', () {
    // The flag is a `const bool.fromEnvironment`, so it is false for every
    // `flutter test` run, every development build and every release workflow
    // — only the dispatch-only `crash-test-apk.yml` passes the define. This
    // is the invariant that keeps the deliberate-crash surface out of a
    // shipped app: the Diagnostics section and `data/crash_test.dart` are
    // reachable only through `if (kCrashTest)`.
    test('the flag is off unless the define is passed', () {
      expect(kCrashTest, isFalse);
    });

    test('the environment is overridden only by the flag', () {
      // The shipped behaviour: the distribution channel, untouched.
      expect(
        sentryEnvironment(rawChannel: 'githubDirect', crashTest: false),
        'githubDirect',
      );
      expect(
        sentryEnvironment(rawChannel: 'googlePlay', crashTest: false),
        'googlePlay',
      );
      // The crash-test build: one filterable environment, whatever channel
      // the APK was built for (it is the `development` flavor, so without
      // this these events would land among real development ones).
      expect(
        sentryEnvironment(rawChannel: 'development', crashTest: true),
        kCrashTestEnvironment,
      );
      expect(
        sentryEnvironment(rawChannel: 'githubDirect', crashTest: true),
        kCrashTestEnvironment,
      );
    });

    // A crash test whose fake URL the redaction already ignores would "pass"
    // while proving nothing: no credentials would appear in the dashboard and
    // the conclusion would be wrong. Pin the payload against the same scrub
    // `beforeSend` runs. `CrashTestTest` does the same for the Kotlin twin.
    test('the fake locator is one the scrubber actually defeats', () {
      final locator = crashTestLocator();
      // Both credential shapes are present before scrubbing — the Xtream-style
      // path pair and a query parameter, which different rules catch.
      expect(locator, contains('/live/crashtest-example/not-a-real-secret/'));
      expect(locator, contains('token=not-a-real-token'));

      final cleaned = cleanCrashText(
        crashTestMessage('uncaught Dart exception'),
      );
      expect(cleaned, isNot(contains('crashtest-example')));
      expect(cleaned, isNot(contains('not-a-real-secret')));
      expect(cleaned, isNot(contains('not-a-real-token')));
      // The host must survive, or the test cannot tell a scrubbed event from
      // a mangled one.
      expect(cleaned, contains('panel.example.com:8080'));
      expect(cleaned, contains('iptvs crash test'));
    });

    // The section is mounted behind `if (kCrashTest)`, which is a `const
    // false` in every test — so without this nothing in CI ever builds it and
    // a layout or focus regression would be discovered on the device the
    // crash-test APK was dispatched to. Instantiated directly rather than
    // through the gate, and never *activated*: pressing one of these really
    // does crash the process.
    testWidgets('the section renders and every action is focusable', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CrashTestSection()),
          ),
        ),
      );
      for (final action in CrashTestAction.values) {
        expect(find.text(action.label), findsOneWidget);
      }
      // D-pad reachable: every action is a FocusableCard, never a bare
      // button or a tap-only row (CLAUDE.md "TV / remote navigation").
      expect(
        find.byType(FocusableCard),
        findsNWidgets(CrashTestAction.values.length),
      );
      // No text field of any kind on this surface — one would trap D-pad
      // focus on a television.
      expect(find.byType(EditableText), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('a scrubbed crash-test event keeps one stable fingerprint', () {
      // (d) re-fires (a) from the same throw site so `CrashBudget` drops it on
      // the fingerprint. That only works if the type and in-app frames match,
      // which is why `runCrashTest` funnels both actions through one function.
      SentryEvent event() => SentryEvent(
        exceptions: [
          SentryException(
            type: 'CrashTestException',
            value: crashTestMessage('uncaught Dart exception'),
            stackTrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  package: 'iptvs',
                  function: '_throwUncaughtDartException',
                  inApp: true,
                ),
              ],
            ),
          ),
        ],
      );
      expect(
        crashFingerprint(scrubSentryEvent(event())),
        crashFingerprint(scrubSentryEvent(event())),
      );
    });
  });

  group('proguardUuidOrNull', () {
    test('accepts the canonical UUID build.gradle.kts stamps', () {
      expect(
        proguardUuidOrNull(' db12bb1d-acfc-495d-aed0-67f6eb6bc608 '),
        'db12bb1d-acfc-495d-aed0-67f6eb6bc608',
      );
    });
    test('null, empty and malformed values become no mapping', () {
      expect(proguardUuidOrNull(null), isNull);
      expect(proguardUuidOrNull(''), isNull);
      expect(proguardUuidOrNull('unset'), isNull);
      expect(proguardUuidOrNull('db12bb1d-acfc-495d-aed0-67f6eb6bc60'), isNull);
    });
  });
}
