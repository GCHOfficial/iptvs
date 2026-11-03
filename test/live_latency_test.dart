import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/live_latency.dart';

/// Feeds a tracker one sample a second from a fake wall clock, which is the
/// cadence every surface really samples at.
class _Clock {
  _Clock(this.tracker);

  final LiveLatencyTracker tracker;

  /// An epoch-shaped origin, so the tracker is exercised with the millisecond
  /// magnitudes `DateTime.now()` really hands it rather than small integers.
  static const int startMs = 1700000000000;
  int nowMs = 0;
  int positionMs = 0;
  bool lastCrossed = false;

  int get wall => startMs + nowMs;

  /// One second of wall time in which [mediaMs] of media played.
  void tick({
    int mediaMs = 1000,
    bool playing = true,
    bool buffering = false,
    int aheadMs = 5000,
    int wallMs = 1000,
  }) {
    nowMs += wallMs;
    positionMs += mediaMs;
    lastCrossed = tracker.sample(
      nowMs: wall,
      positionMs: positionMs,
      aheadMs: aheadMs,
      playing: playing,
      buffering: buffering,
    );
  }

  /// Gets past the baseline rule: one idle sample to record a reference, then
  /// one playing sample that advances media.
  void start() {
    tick(mediaMs: 0, playing: false);
    tick();
  }
}

void main() {
  group('fmtDelay', () {
    test('floors to whole seconds and pads', () {
      expect(fmtDelay(0), '0:00');
      expect(fmtDelay(999), '0:00');
      expect(fmtDelay(1000), '0:01');
      expect(fmtDelay(7999), '0:07');
      expect(fmtDelay(59999), '0:59');
      expect(fmtDelay(60000), '1:00');
      expect(fmtDelay(83000), '1:23');
      expect(fmtDelay(725000), '12:05');
    });

    test('switches to h:mm:ss at an hour', () {
      expect(fmtDelay(3599999), '59:59');
      expect(fmtDelay(3600000), '1:00:00');
      expect(fmtDelay(3723000), '1:02:03');
    });

    test('a negative is clamped rather than printed', () {
      expect(fmtDelay(-1), '0:00');
    });
  });

  group('parity vectors (the shared contract — Kotlin/Swift/C++/Lua assert '
      'these exact strings too)', () {
    const vectors = <(int, int, String, String)>[
      (0, 12400, 'LIVE', '0:00 · buffer 12s'),
      (7999, -1, 'LIVE', '0:07'),
      (29999, 500, 'LIVE', '0:29 · buffer 1s'),
      (30000, 24600, 'LIVE -0:30', '0:30 · buffer 25s'),
      (83000, 24000, 'LIVE -1:23', '1:23 · buffer 24s'),
      (3723000, 0, 'LIVE -1:02:03', '1:02:03 · buffer 0s'),
    ];

    for (final (driftMs, aheadMs, badge, info) in vectors) {
      test('drift=$driftMs ahead=$aheadMs', () {
        expect(liveDelayBadgeLabel(driftMs), badge);
        expect(liveDelayInfoValue(driftMs, aheadMs), info);
      });
    }

    test('the badge sign is ASCII hyphen-minus, never U+2212', () {
      expect(liveDelayBadgeLabel(30000).contains('−'), isFalse);
      expect(liveDelayBadgeLabel(30000).codeUnitAt(5), 0x2D);
    });

    test('the warn threshold is exclusive below and inclusive at', () {
      expect(liveDelayBadgeLabel(kLiveDriftWarnMs - 1), 'LIVE');
      expect(liveDelayBadgeLabel(kLiveDriftWarnMs), 'LIVE -0:30');
    });

    test('buffer seconds round half away from zero', () {
      expect(liveDelayInfoValue(0, 500), '0:00 · buffer 1s');
      expect(liveDelayInfoValue(0, 1500), '0:00 · buffer 2s');
      expect(liveDelayInfoValue(0, 1499), '0:00 · buffer 1s');
    });

    test('an unknown buffer drops the cushion rather than printing -1', () {
      expect(liveDelayInfoValue(5000, -1), '0:05');
    });
  });

  group('log lines', () {
    test('periodic', () {
      expect(
        liveLatencyLogLine(
          driftMs: 42000,
          aheadMs: 12000,
          stalls: 3,
          stalledMs: 9000,
          discontinuities: 1,
        ),
        'live latency drift=42000ms ahead=12000ms stalls=3 stalled=9000ms '
        'disc=1',
      );
    });

    test('first crossing prefixes the same facts', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      while (!clock.lastCrossed) {
        clock.tick(mediaMs: 0, buffering: true, aheadMs: 2000);
      }
      expect(
        tracker.behindLogLine,
        'live latency behind live latency drift=30000ms ahead=2000ms '
        'stalls=1 stalled=29000ms disc=0',
      );
    });

    test('reset', () {
      expect(
        liveLatencyResetLogLine(reason: 'zap', driftMs: 61000, stalls: 2),
        'live latency reset reason=zap drift=61000ms stalls=2',
      );
    });

    test('carries no identifiers — durations and counts only', () {
      final line = liveLatencyLogLine(
        driftMs: 1,
        aheadMs: 2,
        stalls: 3,
        stalledMs: 4,
        discontinuities: 5,
      );
      expect(line, isNot(contains('http')));
      expect(line, isNot(contains('/')));
    });
  });

  group('LiveLatencyTracker baseline', () {
    test('starts unbaselined with no drift', () {
      final tracker = LiveLatencyTracker();
      expect(tracker.baselined, isFalse);
      expect(tracker.driftMs, 0);
      expect(tracker.aheadMs, -1);
    });

    test(
      'a stream that never starts accrues no drift, however long it waits',
      () {
        final tracker = LiveLatencyTracker();
        final clock = _Clock(tracker);
        for (var i = 0; i < 60; i++) {
          clock.tick(mediaMs: 0, playing: false, buffering: true);
        }
        expect(tracker.baselined, isFalse);
        expect(tracker.driftMs, 0, reason: 'startup latency is not drift');
        expect(tracker.stalls, 1);
      },
    );

    test('baselines on the first playing sample whose media advanced', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker);
      clock.tick(mediaMs: 0, playing: false);
      expect(tracker.baselined, isFalse);
      clock.tick(mediaMs: 1000);
      expect(tracker.baselined, isTrue);
      expect(tracker.driftMs, 0, reason: 'the baseline tick adds nothing');
    });

    test('playing with frozen media does not baseline', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker);
      clock.tick(mediaMs: 0);
      clock.tick(mediaMs: 0);
      expect(tracker.baselined, isFalse);
    });
  });

  group('LiveLatencyTracker drift', () {
    test('healthy 1x playback never drifts', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 300; i++) {
        clock.tick();
      }
      expect(tracker.driftMs, 0);
      expect(tracker.warned, isFalse);
    });

    test('a rebuffer adds its own wall duration, permanently', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 5; i++) {
        clock.tick(mediaMs: 0, buffering: true);
      }
      expect(tracker.driftMs, 5000);
      // And nothing gives it back once playback resumes at 1x.
      for (var i = 0; i < 100; i++) {
        clock.tick();
      }
      expect(tracker.driftMs, 5000);
    });

    test('a pause is drift too — there is deliberately no cap on the gap', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      // One sample 45 s later with no media progress: the app was backgrounded
      // or the stream paused. That really is 45 s behind live.
      clock.tick(mediaMs: 0, playing: false, wallMs: 45000);
      expect(tracker.driftMs, 45000);
    });

    test('media running slightly slow accrues the difference', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 10; i++) {
        clock.tick(mediaMs: 900);
      }
      expect(tracker.driftMs, 1000);
    });

    test('media briefly ahead of the wall clock never credits drift back', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: 0, buffering: true); // +1000 drift
      expect(tracker.driftMs, 1000);
      clock.tick(mediaMs: 1400); // catching up, within the slack
      expect(tracker.driftMs, 1000);
    });
  });

  group('LiveLatencyTracker discontinuities', () {
    test('media going backwards re-baselines and keeps the drift', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: 0, buffering: true);
      expect(tracker.driftMs, 1000);
      clock.tick(mediaMs: -30000);
      expect(tracker.discontinuities, 1);
      expect(tracker.driftMs, 1000, reason: 'a seek is not drift');
      expect(tracker.baselined, isTrue);
      // The tick after a discontinuity is measured from the new anchor.
      clock.tick();
      expect(tracker.driftMs, 1000);
    });

    test('a small backwards wobble is drift, not a discontinuity', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: -400);
      expect(tracker.discontinuities, 0);
      expect(tracker.driftMs, 1400);
    });

    test('media leaping forward past the slack is a discontinuity', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: 9000);
      expect(tracker.discontinuities, 1);
      expect(tracker.driftMs, 0);
    });

    test('media inside the 2 s forward slack is not', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: 3000);
      expect(tracker.discontinuities, 0);
      expect(tracker.driftMs, 0);
    });
  });

  group('LiveLatencyTracker stalls', () {
    test('counts transitions in, and sums the wall time spent buffering', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: 0, buffering: true);
      clock.tick(mediaMs: 0, buffering: true);
      clock.tick(); // recovered
      clock.tick();
      clock.tick(mediaMs: 0, buffering: true); // second stall
      clock.tick();
      expect(tracker.stalls, 2);
      // Two intervals ended while buffering in the first stall, one in the
      // second.
      expect(tracker.stalledMs, 3000);
    });

    test('a stall that never ends still counts once', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 10; i++) {
        clock.tick(mediaMs: 0, buffering: true);
      }
      expect(tracker.stalls, 1);
    });
  });

  group('LiveLatencyTracker warn latch', () {
    test('sample reports the first crossing exactly once', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      var crossings = 0;
      for (var i = 0; i < 60; i++) {
        clock.tick(mediaMs: 0, buffering: true);
        if (clock.lastCrossed) crossings++;
      }
      expect(crossings, 1);
      expect(tracker.driftMs, 60000);
      expect(tracker.warned, isTrue);
    });

    test('crosses exactly at the threshold, not before', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 29; i++) {
        clock.tick(mediaMs: 0, buffering: true);
      }
      expect(tracker.driftMs, 29000);
      expect(tracker.warned, isFalse);
      clock.tick(mediaMs: 0, buffering: true);
      expect(tracker.driftMs, 30000);
      expect(clock.lastCrossed, isTrue);
    });

    test('stays latched through healthy playback — only a reset clears it', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 31; i++) {
        clock.tick(mediaMs: 0, buffering: true);
      }
      expect(tracker.warned, isTrue);
      for (var i = 0; i < 600; i++) {
        clock.tick();
      }
      expect(
        tracker.warned,
        isTrue,
        reason:
            'the Go-to-live chip must not '
            'flicker around a threshold',
      );
      tracker.reset();
      expect(tracker.warned, isFalse);
    });
  });

  group('LiveLatencyTracker reset', () {
    test('clears every counter and the baseline', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(mediaMs: 0, buffering: true);
      clock.tick(mediaMs: -30000);
      expect(tracker.driftMs, greaterThan(0));

      tracker.reset();
      expect(tracker.driftMs, 0);
      expect(tracker.aheadMs, -1);
      expect(tracker.stalls, 0);
      expect(tracker.stalledMs, 0);
      expect(tracker.discontinuities, 0);
      expect(tracker.baselined, isFalse);
      expect(tracker.warned, isFalse);
    });

    test('the next session has to re-baseline before it can drift', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 10; i++) {
        clock.tick(mediaMs: 0, buffering: true);
      }
      tracker.reset();
      // A long gap straight after the reset (the re-resolve round trip) is
      // not charged to the new session.
      clock.tick(mediaMs: 0, playing: false, wallMs: 20000);
      expect(tracker.driftMs, 0);
      clock.tick();
      expect(tracker.baselined, isTrue);
      expect(tracker.driftMs, 0);
    });

    test('hasResetWorthLogging is false below the threshold', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      // A 500ms stall: ordinary jitter, well under the 1s reset-log threshold.
      clock.tick(mediaMs: 0, wallMs: 500);
      expect(tracker.driftMs, 500);
      expect(tracker.hasResetWorthLogging, isFalse);
    });

    test('hasResetWorthLogging is true at the threshold', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      // A 1000ms stall: exactly kLiveLatencyResetLogMinDriftMs.
      clock.tick(mediaMs: 0, wallMs: 1000);
      expect(tracker.driftMs, kLiveLatencyResetLogMinDriftMs);
      expect(tracker.hasResetWorthLogging, isTrue);
      expect(
        tracker.resetLogLine('reconnect'),
        'live latency reset reason=reconnect drift=1000ms stalls=0',
      );
    });
  });

  group('LiveLatencyTracker.takePeriodicLog', () {
    test('the first call only anchors the clock', () {
      final tracker = LiveLatencyTracker();
      expect(tracker.takePeriodicLog(nowMs: 1000, playing: true), isFalse);
    });

    test('is due a minute later, but only when it has something to say', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      tracker.takePeriodicLog(nowMs: clock.wall, playing: true);
      for (var i = 0; i < 120; i++) {
        clock.tick(aheadMs: 2000);
      }
      expect(
        tracker.takePeriodicLog(nowMs: clock.wall, playing: true),
        isFalse,
        reason: 'no drift and a shallow cushion is not worth exporting',
      );
    });

    test('a deep cushion alone is enough', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      tracker.takePeriodicLog(nowMs: clock.wall, playing: true);
      for (var i = 0; i < 120; i++) {
        clock.tick(aheadMs: 45000);
      }
      expect(tracker.takePeriodicLog(nowMs: clock.wall, playing: true), isTrue);
    });

    test('fires at most once a minute and consumes the slot', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      tracker.takePeriodicLog(nowMs: clock.wall, playing: true);
      for (var i = 0; i < 10; i++) {
        clock.tick(mediaMs: 0, buffering: true); // 10 s of drift
      }
      var fired = 0;
      for (var i = 0; i < 180; i++) {
        clock.tick();
        if (tracker.takePeriodicLog(nowMs: clock.wall, playing: true)) fired++;
      }
      expect(fired, 3);
    });

    test('a paused stream writes no periodic line', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      tracker.takePeriodicLog(nowMs: clock.wall, playing: true);
      for (var i = 0; i < 10; i++) {
        clock.tick(mediaMs: 0, buffering: true);
      }
      for (var i = 0; i < 120; i++) {
        clock.tick(mediaMs: 0, playing: false);
      }
      expect(
        tracker.takePeriodicLog(nowMs: clock.wall, playing: false),
        isFalse,
      );
    });
  });
}
