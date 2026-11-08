// The MAG portal watchdog (keep-alive) — see docs/sources.md "The portal
// watchdog (keep-alive)".
//
// **This is a hypothesis test shipped behind evidence, not a known fix**: the
// open-source `stalker_portal` server records the poll as `users.keep_alive`
// and nothing in it kills a stream when the polls stop. These tests pin the
// *client* behaviour against the STB source they were derived from, and pin
// the lifecycle rules that keep a timer from outliving playback.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/playback_keep_alive.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';
import 'package:iptvs/sources/stalker_watchdog.dart';

void main() {
  Channel channel(String id) =>
      Channel(id: id, name: 'Channel $id', categoryId: '1');

  /// A portal whose every call is served from memory. `calls` collects the
  /// parameter maps so the watchdog payload can be asserted exactly.
  StalkerSource portal({
    required List<Map<String, String>> calls,
    Map<String, dynamic>? watchdogJs,
    bool watchdogFails = false,
    bool diagnostics = false,
    String id = 'stalker-test',
  }) => StalkerSource(
    sourceId: id,
    portal: 'http://example.invalid/c/',
    mac: '00:1A:79:12:34:56',
    diagnostics: diagnostics,
    debugApi: (params) async {
      calls.add(Map<String, String>.from(params));
      if (params['action'] == 'get_events') {
        if (watchdogFails) throw StalkerException('HTTP 503 from <redacted>');
        return {'js': watchdogJs ?? {'msgs': 0, 'additional_services_on': '1'}};
      }
      return const {'js': <String, dynamic>{}};
    },
  );

  group('stalkerWatchdogInterval', () {
    test('uses the portal profile value when it sends one', () {
      // `c/xpcom.common.js:1172,1399` — the box reads `watchdog_timeout` out of
      // get_profile and hands it to `watchdog.run`.
      final resolved = stalkerWatchdogInterval({'watchdog_timeout': 120});
      expect(resolved.interval, const Duration(seconds: 120));
      expect(resolved.source, StalkerWatchdogIntervalSource.profile);
    });

    test('reads it from a string, the way parseInt does', () {
      expect(
        stalkerWatchdogInterval({'watchdog_timeout': '120'}).interval,
        const Duration(seconds: 120),
      );
      expect(
        stalkerWatchdogInterval({'watchdog_timeout': '180 '}).interval,
        const Duration(seconds: 180),
      );
    });

    test('falls back to the STB default when the portal says nothing', () {
      // `c/watchdog.js:8` + the `timeout*1000 || this.request_timeout`
      // fallback at `c/watchdog.js:23`: an absent, zero or unparseable value
      // leaves a real box polling every 30 s.
      for (final js in <Map<dynamic, dynamic>?>[
        null,
        <String, dynamic>{},
        {'watchdog_timeout': 0},
        {'watchdog_timeout': ''},
        {'watchdog_timeout': 'nope'},
        {'watchdog_timeout': -5},
      ]) {
        final resolved = stalkerWatchdogInterval(js);
        expect(resolved.interval, kStalkerWatchdogFallbackInterval, reason: '$js');
        expect(resolved.source, StalkerWatchdogIntervalSource.fallback);
      }
    });

    test('clamps to the range the portal config documents', () {
      // `server/config.ini:196` — "Set between 30 and 300."
      expect(
        stalkerWatchdogInterval({'watchdog_timeout': 5}).interval,
        kStalkerWatchdogMinInterval,
      );
      expect(
        stalkerWatchdogInterval({'watchdog_timeout': 86400}).interval,
        kStalkerWatchdogMaxInterval,
      );
    });
  });

  group('watchdog diagnostics helpers', () {
    test('logging is throttled to the first three, then one in ten', () {
      expect([for (var n = 1; n <= 12; n++) stalkerWatchdogShouldLog(n)], [
        true, true, true, // 1..3
        false, false, false, false, false, false, // 4..9
        true, // 10
        false, false, // 11..12
      ]);
      expect(stalkerWatchdogShouldLog(20), isTrue);
    });

    test('events= is a count, or key names, and never a value', () {
      expect(stalkerWatchdogEventsNote({'msgs': 0}), '0');
      expect(stalkerWatchdogEventsNote({'msgs': '2'}), '2');
      expect(
        stalkerWatchdogEventsNote({'msg': 'Your account expires soon', 'id': 7}),
        '[id,msg]',
      );
      expect(stalkerWatchdogEventsNote(const <String, dynamic>{}), 'none');
      expect(stalkerWatchdogEventsNote('oops'), 'none');
    });

    test('a failure quotes the status the portal gave, or a dash', () {
      expect(
        stalkerWatchdogStatus(StalkerException('HTTP 503 from <redacted>')),
        '503',
      );
      expect(stalkerWatchdogStatus(StalkerException('Non-JSON response')), '-');
    });
  });

  group('StalkerSource watchdog', () {
    test('starts on play and sends the MAG payload', () {
      fakeAsync((async) {
        final calls = <Map<String, String>>[];
        final source = portal(calls: calls);
        source.playbackStarted(channel('42'));
        async.flushMicrotasks();

        // `watchdog.run` sends one immediately (`c/watchdog.js:61`) rather than
        // waiting out the first interval.
        expect(calls, hasLength(1));
        expect(calls.single, {
          'type': 'watchdog',
          'action': 'get_events',
          'cur_play_type': '1', // live TV (stb.get_current_place)
          'event_active_id': '0',
          'init': '1',
        });

        async.elapse(kStalkerWatchdogFallbackInterval);
        expect(calls, hasLength(2));
        // `init` is "the box just started", once per portal load.
        expect(calls[1]['init'], '0');

        source.playbackStopped();
        async.elapse(const Duration(minutes: 5));
        expect(calls, hasLength(2));
        source.dispose();
      });
    });

    test('a rapid zap keeps one timer, not one per channel', () {
      fakeAsync((async) {
        final calls = <Map<String, String>>[];
        final source = portal(calls: calls);
        // Every settle resolves, and every resolve re-arms. If that restarted
        // the timer, a session that zaps briskly would never complete an
        // interval and the keep-alive would never fire again.
        for (var i = 0; i < 10; i++) {
          source.playbackStarted(channel('$i'));
          async.elapse(const Duration(seconds: 3));
        }
        // 30 s of elapsed time: the one immediate poll, plus the one the
        // single periodic timer has fired by now.
        expect(calls, hasLength(2));
        async.elapse(kStalkerWatchdogFallbackInterval);
        expect(calls, hasLength(3));
        source.playbackStopped();
        source.dispose();
      });
    });

    test('nothing is sent after dispose', () {
      fakeAsync((async) {
        final calls = <Map<String, String>>[];
        final source = portal(calls: calls);
        source.playbackStarted(channel('1'));
        async.flushMicrotasks();
        expect(calls, hasLength(1));
        // Disposing with a preview still running is a real path (the screen
        // going away). A surviving timer would poll a closed HttpClient for
        // the rest of the process's life.
        source.dispose();
        async.elapse(const Duration(minutes: 10));
        expect(calls, hasLength(1));
      });
    });

    test('a long session does not flood the exportable log', () {
      fakeAsync((async) {
        DiagnosticsLog.instance.clear();
        final calls = <Map<String, String>>[];
        final source = portal(calls: calls, diagnostics: true);
        source.playbackStarted(channel('7'));
        async.elapse(const Duration(minutes: 30)); // 60 polls at 30 s
        source.playbackStopped();

        final lines = DiagnosticsLog.instance.entries
            .where((e) => e.message.startsWith('watchdog HTTP'))
            .toList();
        // 61 polls, 3 + one in ten logged.
        expect(calls.length, greaterThan(60));
        expect(lines.length, lessThan(12));
        expect(lines.first.message, contains('interval=30s'));
        expect(lines.first.message, contains('events=0'));
        // The per-request transport lines are suppressed for the watchdog, or
        // they alone would be three per poll.
        expect(
          DiagnosticsLog.instance.entries.where(
            (e) => e.message.contains('get_events HTTP'),
          ),
          isEmpty,
        );
        source.dispose();
        DiagnosticsLog.instance.clear();
      });
    });

    test('a failing watchdog says so on the first failure', () {
      fakeAsync((async) {
        DiagnosticsLog.instance.clear();
        final calls = <Map<String, String>>[];
        final source = portal(
          calls: calls,
          diagnostics: true,
          watchdogFails: true,
        );
        source.playbackStarted(channel('7'));
        async.flushMicrotasks();
        final lines = DiagnosticsLog.instance.entries
            .where((e) => e.message.startsWith('watchdog HTTP'))
            .toList();
        expect(lines, hasLength(1));
        expect(lines.single.message, contains('watchdog HTTP 503'));
        source.playbackStopped();
        source.dispose();
        DiagnosticsLog.instance.clear();
      });
    });
  });

  group('PlaybackKeepAliveCoordinator', () {
    test('arming a second source disarms the first', () {
      fakeAsync((async) {
        final a = <Map<String, String>>[];
        final b = <Map<String, String>>[];
        final first = portal(calls: a, id: 'a');
        final second = portal(calls: b, id: 'b');
        final coordinator = PlaybackKeepAliveCoordinator();

        coordinator.started(first, channel('1'));
        async.flushMicrotasks();
        expect(a, hasLength(1));

        // A cross-source zap: provider B is playing now, so provider A must
        // stop being told that something is.
        coordinator.started(second, channel('9'));
        async.elapse(const Duration(minutes: 2));
        expect(a, hasLength(1));
        expect(b.length, greaterThan(1));

        coordinator.stopAll();
        final settled = b.length;
        async.elapse(const Duration(minutes: 2));
        expect(b, hasLength(settled));
        first.dispose();
        second.dispose();
      });
    });

    test('a stale stop cannot silence the session that superseded it', () {
      fakeAsync((async) {
        final calls = <Map<String, String>>[];
        final source = portal(calls: calls);
        final coordinator = PlaybackKeepAliveCoordinator();

        // The preview arms, then fullscreen arms through its own resolve, then
        // the preview's teardown runs — the exact order the Android handoff
        // produces.
        final previewToken = coordinator.started(source, channel('1'));
        coordinator.started(source, channel('1'));
        coordinator.stopped(previewToken);
        async.elapse(const Duration(minutes: 2));
        expect(calls.length, greaterThan(1));
        expect(coordinator.current, isNotNull);

        coordinator.stopAll();
        expect(coordinator.current, isNull);
        source.dispose();
      });
    });

    test('a source with no keep-alive still takes the slot', () {
      fakeAsync((async) {
        final calls = <Map<String, String>>[];
        final stalker = portal(calls: calls);
        final coordinator = PlaybackKeepAliveCoordinator();
        coordinator.started(stalker, channel('1'));
        async.flushMicrotasks();
        expect(calls, hasLength(1));

        // "Something else is playing now" is true whether or not the new
        // provider needs a keep-alive of its own.
        coordinator.started(DemoSource(), channel('1'));
        expect(coordinator.current, isNull);
        async.elapse(const Duration(minutes: 2));
        expect(calls, hasLength(1));
        stalker.dispose();
      });
    });
  });
}
