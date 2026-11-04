import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/crash_budget.dart';
import 'package:iptvs/data/crash_reporter.dart';
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
}
