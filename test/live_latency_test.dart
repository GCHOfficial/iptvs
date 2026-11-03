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
    bool catchingUp = false,
  }) {
    nowMs += wallMs;
    positionMs += mediaMs;
    lastCrossed = tracker.sample(
      nowMs: wall,
      positionMs: positionMs,
      aheadMs: aheadMs,
      playing: playing,
      buffering: buffering,
      catchingUp: catchingUp,
    );
  }

  /// Gets past the baseline rule: one idle sample to record a reference, then
  /// one playing sample that advances media.
  ///
  /// [aheadMs] matters more than it looks: the baselining sample is a
  /// baselined sample, so its cushion is already folded into
  /// [LiveLatencyTracker.backlogMs]. A drift-only test therefore primes with
  /// `0` (or `-1`) rather than letting the default seed a 5 s backlog it never
  /// meant to measure.
  void start({int aheadMs = 5000}) {
    tick(mediaMs: 0, playing: false, aheadMs: aheadMs);
    tick(aheadMs: aheadMs);
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
          delayMs: 61000,
          backlogMs: 26000,
          creditedMs: 7000,
          aheadMs: 12000,
          stalls: 3,
          stalledMs: 9000,
          discontinuities: 1,
        ),
        'live latency drift=42000ms delay=61000ms backlog=26000ms '
        'credited=7000ms ahead=12000ms stalls=3 stalled=9000ms disc=1',
      );
    });

    test('drift stays beside delay, because they ask different questions', () {
      // A 76 s delay against 0 ms of drift is a provider backlog; the same
      // delay against 76 s of drift is this app stalling. One number cannot
      // tell a support export which of those arrived.
      final line = liveLatencyLogLine(
        driftMs: 0,
        delayMs: 76000,
        backlogMs: 76000,
        creditedMs: 0,
        aheadMs: 70000,
        stalls: 0,
        stalledMs: 0,
        discontinuities: 0,
      );
      expect(line, contains('drift=0ms'));
      expect(line, contains('delay=76000ms'));
      expect(line, contains('backlog=76000ms'));
    });

    test('first crossing prefixes the same facts', () {
      // No cushion anywhere, so this is a pure-drift crossing and the line
      // reads exactly as it did in wave 1 plus the three new fields.
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start(aheadMs: 0);
      while (!clock.lastCrossed) {
        clock.tick(mediaMs: 0, buffering: true, aheadMs: 0);
      }
      expect(
        tracker.behindLogLine,
        'live latency behind live latency drift=30000ms delay=30000ms '
        'backlog=0ms credited=0ms ahead=0ms stalls=1 stalled=29000ms '
        'disc=0',
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
        delayMs: 2,
        backlogMs: 3,
        creditedMs: 4,
        aheadMs: 5,
        stalls: 6,
        stalledMs: 7,
        discontinuities: 8,
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
      // Cushion-free, so delay is drift and this stays the wave-1 assertion.
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start(aheadMs: 0);
      for (var i = 0; i < 29; i++) {
        clock.tick(mediaMs: 0, buffering: true, aheadMs: 0);
      }
      expect(tracker.driftMs, 29000);
      expect(tracker.warned, isFalse);
      clock.tick(mediaMs: 0, buffering: true, aheadMs: 0);
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

    test('clears the backlog bound and the credit too', () {
      // A reset means a new connection: whatever backlog *that* one hands
      // over has to be measured again from scratch, and credit bought by
      // trimming a cache that no longer exists must not survive into it —
      // carried forward it would subtract from the new session's delay and
      // under-report it for as long as the session lasts.
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(aheadMs: 40000);
      tracker.credit(9000);
      clock.tick(aheadMs: 40000);
      expect(tracker.backlogMs, greaterThan(0));
      expect(tracker.creditedMs, 9000);

      tracker.reset();
      expect(tracker.backlogMs, 0);
      expect(tracker.creditedMs, 0);
      expect(tracker.delayMs, 0);
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

  group('tracker parity scenarios (the wave-2 contract — Kotlin and Swift run '
      'these exact sequences too)', () {
    /// The contract's sequences are written as absolute (t, pos) pairs, so
    /// they are replayed that way rather than through [_Clock]'s deltas:
    /// a transcription slip in a parity fixture is the one bug that would
    /// make three implementations agree on the wrong answer.
    const origin = _Clock.startMs;

    /// Samples t=0..`untilMs` at 1 Hz with pos=t and a fixed cushion — "S1"
    /// when `aheadMs` is 2000, "S2" when it is 30000. Returns whether any
    /// sample reported the first crossing.
    bool honest(LiveLatencyTracker tracker, int untilMs, int aheadMs) {
      var crossed = false;
      for (var t = 0; t <= untilMs; t += 1000) {
        if (tracker.sample(
          nowMs: origin + t,
          positionMs: t,
          aheadMs: aheadMs,
          playing: true,
          buffering: false,
        )) {
          crossed = true;
        }
      }
      return crossed;
    }

    test('S1 — honest 1x: the cushion is the whole delay', () {
      final tracker = LiveLatencyTracker();
      final crossed = honest(tracker, 60000, 2000);
      expect(tracker.driftMs, 0);
      expect(tracker.backlogMs, 2000);
      expect(tracker.delayMs, 2000);
      expect(liveDelayBadgeLabel(tracker.delayMs), 'LIVE');
      expect(crossed, isFalse);
    });

    test('S2 — connect backlog: behind from the first frame', () {
      // The shipped bug this wave exists for: wave 1 read `drift=0` here and
      // showed a green LIVE pill against a stream thirty seconds behind.
      final tracker = LiveLatencyTracker();
      final crossed = honest(tracker, 60000, 30000);
      expect(tracker.driftMs, 0);
      expect(tracker.backlogMs, 30000);
      expect(tracker.delayMs, 30000);
      expect(liveDelayBadgeLabel(tracker.delayMs), 'LIVE -0:30');
      expect(crossed, isTrue);
      expect(tracker.warned, isTrue);
    });

    test('S3 — a pause on a 1x stream is not double-counted', () {
      final tracker = LiveLatencyTracker();
      honest(tracker, 10000, 2000);
      // Frozen media, rising cushion: the provider keeps queueing at 1x while
      // nothing plays. `ahead` rises *with* drift, so the backlog bound must
      // stay exactly where the playing phase left it.
      for (var t = 11000; t <= 70000; t += 1000) {
        tracker.sample(
          nowMs: origin + t,
          positionMs: 10000,
          aheadMs: 2000 + ((t - 10000) * 28000) ~/ 60000,
          playing: false,
          buffering: false,
        );
      }
      expect(tracker.driftMs, 60000);
      expect(tracker.backlogMs, 2000);
      expect(tracker.delayMs, 62000);
    });

    test('S4 — a verified skip, then the cache refills from the backlog', () {
      final tracker = LiveLatencyTracker();
      honest(tracker, 20000, 30000);
      expect(tracker.delayMs, 30000);

      // The skip: credited explicitly, because the jump itself arrives as a
      // media-time discontinuity the tracker deliberately refuses to read as
      // anything.
      tracker.credit(27000);
      tracker.sample(
        nowMs: origin + 21000,
        positionMs: 20000 + 28000,
        aheadMs: 3000,
        playing: true,
        buffering: false,
      );
      expect(tracker.discontinuities, 1);
      expect(tracker.driftMs, 0, reason: 'a seek is not drift');
      expect(tracker.delayMs, 3000);

      // The refill. The provider still holds the backlog, so the cushion
      // climbs back — and with the credit already in hand the bound rises by
      // exactly what was trimmed, instead of pretending the delay went away.
      var crossed = false;
      for (var t = 22000; t <= 40000; t += 1000) {
        if (tracker.sample(
          nowMs: origin + t,
          positionMs: 48000 + (t - 21000),
          aheadMs: 3000 + ((t - 21000) * 27000) ~/ 19000,
          playing: true,
          buffering: false,
        )) {
          crossed = true;
        }
      }
      expect(tracker.backlogMs, 57000);
      expect(tracker.delayMs, 30000);
      // And the chip comes back: `credit` released the latch, so the session
      // can report being behind again once it really is.
      expect(crossed, isTrue);
    });

    test('S5 — catch-up credit only counts while the caller is catching up',
        () {
      LiveLatencyTracker run({required bool catchingUp}) {
        final tracker = LiveLatencyTracker();
        honest(tracker, 10000, 30000);
        for (var k = 1; k <= 20; k++) {
          tracker.sample(
            nowMs: origin + 10000 + 1000 * k,
            positionMs: 10000 + 1050 * k,
            aheadMs: 30000 - 50 * k,
            playing: true,
            buffering: false,
            catchingUp: catchingUp,
          );
        }
        return tracker;
      }

      final caught = run(catchingUp: true);
      expect(caught.creditedMs, 1000);
      expect(caught.driftMs, 0);
      expect(caught.backlogMs, 30000);
      expect(caught.delayMs, 29000);

      // The identical samples without the flag: media running ahead of the
      // wall clock is a demuxer settling, not delay removed. Wave 1's
      // "no credit-back" rule is what stops a jittery 1x stream from
      // slowly erasing a real delay.
      final drifted = run(catchingUp: false);
      expect(drifted.creditedMs, 0);
      expect(drifted.delayMs, 30000);
    });
  });

  group('LiveLatencyTracker backlog', () {
    test('an unknown cushion bounds nothing', () {
      // `-1` is "this surface cannot answer", not "there is no cushion".
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start(aheadMs: -1);
      for (var i = 0; i < 10; i++) {
        clock.tick(aheadMs: -1);
      }
      expect(tracker.backlogMs, 0);
      expect(tracker.delayMs, 0);
    });

    test('only ever rises, even as the cushion drains', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(aheadMs: 45000);
      expect(tracker.backlogMs, 45000);
      for (var i = 0; i < 10; i++) {
        clock.tick(aheadMs: 1000);
      }
      expect(
        tracker.backlogMs,
        45000,
        reason: 'the stream did not move closer to live by playing it at 1x',
      );
      expect(tracker.delayMs, 45000);
    });

    test('delay never goes negative', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      clock.tick(aheadMs: 2000);
      tracker.credit(600000);
      expect(tracker.delayMs, 0);
    });
  });

  group('LiveLatencyTracker.credit', () {
    test('ignores a non-positive jump', () {
      final tracker = LiveLatencyTracker();
      tracker.credit(0);
      tracker.credit(-5000);
      expect(tracker.creditedMs, 0);
    });

    test('releases the warn latch without resetting the session', () {
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start();
      for (var i = 0; i < 31; i++) {
        clock.tick(mediaMs: 0, buffering: true, aheadMs: 2000);
      }
      expect(tracker.warned, isTrue);
      final drift = tracker.driftMs;

      tracker.credit(20000);
      expect(tracker.warned, isFalse, reason: 'the press was answered');
      expect(tracker.driftMs, drift, reason: 'not a reset — drift stands');
      expect(tracker.stalls, 1);
      expect(tracker.baselined, isTrue);
    });
  });

  group('LiveLatencyTracker.takePeriodicLog', () {
    test('the first call only anchors the clock', () {
      final tracker = LiveLatencyTracker();
      expect(tracker.takePeriodicLog(nowMs: 1000, playing: true), isFalse);
    });

    test('is due a minute later, but only when it has something to say', () {
      final tracker = LiveLatencyTracker();
      // A 2 s cushion from the first sample: the gate is on *delay* now,
      // and the clock's default 5 s cushion would itself be 5 s of backlog.
      final clock = _Clock(tracker)..start(aheadMs: 2000);
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

    test('a backlog with no drift is worth a line (the gate is delay)', () {
      // George's shape: drift ~0, but a cushion the provider front-loaded.
      // 8 s of backlog is 8 s of delay, under the 30 s cushion gate.
      final tracker = LiveLatencyTracker();
      final clock = _Clock(tracker)..start(aheadMs: 8000);
      tracker.takePeriodicLog(nowMs: clock.wall, playing: true);
      for (var i = 0; i < 120; i++) {
        clock.tick(aheadMs: 8000);
      }
      expect(tracker.driftMs, 0);
      expect(tracker.delayMs, 8000);
      expect(tracker.takePeriodicLog(nowMs: clock.wall, playing: true), isTrue);
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
