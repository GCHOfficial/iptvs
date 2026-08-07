import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';

/// Pure-logic coverage for the shared live-reconnect backoff policy
/// (`reconnectMinGapMs`), the Dart mirror of Android's
/// `ReconnectPolicy.minGapMs`. The embedded/Windows watchdog and the
/// Linux-native IPC watchdog both go through this, so all three platforms back
/// off identically. Mirrors `android/.../player/ReconnectPolicyTest.kt`.
void main() {
  group('reconnectMinGapMs', () {
    test('first attempt waits one stall interval', () {
      expect(
        reconnectMinGapMs(priorAttempts: 0, force: false),
        kReconnectStallMs,
      );
    });

    test('backoff grows with each prior attempt', () {
      expect(
        reconnectMinGapMs(priorAttempts: 1, force: false),
        kReconnectStallMs * 2,
      );
      expect(
        reconnectMinGapMs(priorAttempts: 2, force: false),
        kReconnectStallMs * 3,
      );
    });

    test('backoff is capped at the maximum', () {
      expect(
        reconnectMinGapMs(priorAttempts: 3, force: false),
        kReconnectMaxBackoffMs,
      );
      expect(
        reconnectMinGapMs(priorAttempts: 10, force: false),
        kReconnectMaxBackoffMs,
      );
    });

    test('a forced reconnect always uses the base stall threshold', () {
      expect(
        reconnectMinGapMs(priorAttempts: 5, force: true),
        kReconnectStallMs,
      );
    });
  });

  group('shouldReconnectOnCompleted', () {
    // A clean server-side EOF maps to completed=true with buffering=false, so
    // the buffering-gated stall watchdog can never see it — live must treat
    // it as a drop (parity with the Linux-native end-file drop signal).
    test('live clean EOF on the embedded/Windows path reconnects', () {
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: true,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('VOD completing is a legitimate end of playback', () {
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: false,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });

    test('ignored while a separate engine owns playback and the embedded '
        'player is idle (Linux native mpv / Android native Activity)', () {
      // `nativeSessionActive` is true only when the media_kit `_player` sits
      // idle behind a separate engine — its `completed` describes a stopped
      // engine, not the stream.
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: true,
          nativeSessionActive: true,
        ),
        isFalse,
      );
    });

    test('Windows native HDR-live reconnects on a clean EOF (the same _player '
        'plays through the HWND, so nativeSessionActive stays false)', () {
      // On Windows the native HWND path renders through the SAME media_kit
      // `_player` (a `vo` swap, no separate engine), so its `completed` is a
      // genuine live drop. `_PlayerScreenState` derives `nativeSessionActive`
      // from `_separateEngineOwnsPlayback`, which excludes Windows by design —
      // so the reconnect fires (and `_reconnectLive` reopens `_player` on the
      // HWND surface).
      expect(
        shouldReconnectOnCompleted(
          completed: true,
          isLive: true,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('completed=false (open/stop resets) never reconnects', () {
      expect(
        shouldReconnectOnCompleted(
          completed: false,
          isLive: true,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldApplyEmbeddedResume', () {
    const resume = Duration(minutes: 12);
    const duration = Duration(minutes: 90);

    test('seeks the embedded player once a real duration arrives', () {
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: duration,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('Windows native HDR VOD still resumes — the HWND surface is this '
        'same _player, so nativeSessionActive stays false', () {
      // The regression this pins: `_nativePlaybackLaunched` starts **true** on
      // Windows for every non-preview open (`_usesWindowsNativeSurface`), and
      // gating the resume seek on it suppressed the seek for every Windows VOD.
      // Positions were saved (`_persistPlaybackPosition` gates on Android/iOS
      // only) but never restored, so Continue Watching always restarted at 0.
      // `_separateEngineOwnsPlayback` excludes Windows, so the seek fires.
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: duration,
          nativeSessionActive: false,
        ),
        isTrue,
      );
    });

    test('a separate engine is never seeked here', () {
      // Android/iOS native players get the resume point in the `resumeMs` open
      // payload and the Linux native mpv process via `--start=`; this `_player`
      // is idle, so seeking it would do nothing but could clobber state.
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: duration,
          nativeSessionActive: true,
        ),
        isFalse,
      );
    });

    test('an unknown duration waits rather than seeking blind', () {
      // mpv reports 0 until the demuxer is ready; a cold seek there is dropped.
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: resume,
          duration: Duration.zero,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });

    test('no saved position means no seek', () {
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: null,
          duration: duration,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });

    test('a resume point at or past the end is ignored', () {
      // Guards a shorter re-resolved variant of the same title (and the
      // kFinishedFraction row that should have been cleared) from seeking to
      // EOF and instantly "completing".
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: duration,
          duration: duration,
          nativeSessionActive: false,
        ),
        isFalse,
      );
      expect(
        shouldApplyEmbeddedResume(
          pendingResume: duration + const Duration(minutes: 1),
          duration: duration,
          nativeSessionActive: false,
        ),
        isFalse,
      );
    });
  });
}
