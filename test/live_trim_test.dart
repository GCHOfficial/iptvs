import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/live_trim.dart';

void main() {
  group('decideLiveTrim', () {
    test('a deep cache is stepped over, leaving the target cushion', () {
      // 30 s held ahead of a playhead at 1:00:00 → jump 28 s, landing 2 s
      // short of the cache's leading edge.
      final decision = decideLiveTrim(positionMs: 3600000, aheadMs: 30000);
      expect(decision.canSkip, isTrue);
      expect(decision.jumpMs, 28000);
      expect(decision.targetPositionMs, 3628000);
      expect(decision.unavailable, isNull);
    });

    test('the target is never the cache end — kTrimTargetMs stays behind it', () {
      // Landing *on* the live edge would leave the demuxer nothing to absorb
      // the next hiccup, so the very next stall would undo the skip.
      final decision = decideLiveTrim(positionMs: 0, aheadMs: 45000);
      expect(decision.targetPositionMs, 45000 - kTrimTargetMs);
    });

    test('an unknown cache offers nothing', () {
      final decision = decideLiveTrim(positionMs: 10000, aheadMs: -1);
      expect(decision.canSkip, isFalse);
      expect(decision.unavailable, LiveTrimUnavailable.unknown);
    });

    test('a cache too shallow to be worth the hitch offers nothing', () {
      // Exactly at the boundary: a jump of kTrimMinJumpMs - 1 is refused, the
      // jump itself is taken.
      final tooSmall = decideLiveTrim(
        positionMs: 0,
        aheadMs: kTrimTargetMs + kTrimMinJumpMs - 1,
      );
      expect(tooSmall.canSkip, isFalse);
      expect(tooSmall.unavailable, LiveTrimUnavailable.small);

      final justEnough = decideLiveTrim(
        positionMs: 0,
        aheadMs: kTrimTargetMs + kTrimMinJumpMs,
      );
      expect(justEnough.canSkip, isTrue);
      expect(justEnough.jumpMs, kTrimMinJumpMs);
    });

    test('an empty cache is "small", not "unknown"', () {
      // Zero is a measurement: the surface answered, and the answer is that
      // there is nothing to skip over.
      expect(
        decideLiveTrim(positionMs: 0, aheadMs: 0).unavailable,
        LiveTrimUnavailable.small,
      );
    });

    test('a negative playhead clamps rather than seeking backwards', () {
      // mpv reports a negative `time-pos` on a stream whose timeline starts
      // behind its first played frame; an absolute seek to a negative target
      // on a live TS is how a "go to live" press becomes a reload.
      final decision = decideLiveTrim(positionMs: -60000, aheadMs: 30000);
      expect(decision.canSkip, isTrue);
      expect(decision.targetPositionMs, 0);
    });
  });

  group('LiveTrimDecision.verifiedBy', () {
    final decision = decideLiveTrim(positionMs: 0, aheadMs: 30000);

    test('half the requested jump is enough', () {
      // mpv seeks to the keyframe at or before the target, so a skip that
      // really happened routinely lands short — on a long GOP, by seconds.
      expect(decision.jumpMs, 28000);
      expect(decision.verifiedBy(14000), isTrue);
      expect(decision.verifiedBy(13999), isFalse);
      expect(decision.verifiedBy(28000), isTrue);
    });

    test('a seek that did nothing is not verified', () {
      // The failure this guards: a surface that acknowledges the command and
      // leaves the playhead where it was. The press then falls through to the
      // reload it has always done.
      expect(decision.verifiedBy(0), isFalse);
      expect(decision.verifiedBy(300), isFalse);
      expect(decision.verifiedBy(-5000), isFalse);
    });

    test('an odd jump has no off-by-one at the half mark', () {
      final odd = decideLiveTrim(positionMs: 0, aheadMs: 9001);
      expect(odd.jumpMs, 7001);
      expect(odd.verifiedBy(3500), isFalse);
      expect(odd.verifiedBy(3501), isTrue);
    });
  });

  group('log lines', () {
    test('a verified skip names what it bought and what it had', () {
      expect(
        liveTrimSkipLogLine(jumpedMs: 27400, aheadBeforeMs: 30000),
        'live latency skip jumped=27400ms ahead_before=30000ms',
      );
    });

    test('every fallback reason has a line', () {
      expect(
        liveTrimUnavailableLogLine(LiveTrimUnavailable.unknown),
        'live latency skip unavailable reason=unknown',
      );
      expect(
        liveTrimUnavailableLogLine(LiveTrimUnavailable.small),
        'live latency skip unavailable reason=small',
      );
      expect(
        liveTrimUnavailableLogLine(LiveTrimUnavailable.unverified),
        'live latency skip unavailable reason=unverified',
      );
    });

    test('carries no identifiers — durations only', () {
      final line = liveTrimSkipLogLine(jumpedMs: 1, aheadBeforeMs: 2);
      expect(line, isNot(contains('http')));
      expect(line, isNot(contains('/')));
    });
  });
}
