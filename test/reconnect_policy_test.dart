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
      // as `_linuxNativeSession != null || (Platform.isAndroid &&
      // _nativePlaybackLaunched)` — false on Windows-native — so the reconnect
      // fires (and `_reconnectLive` reopens `_player` on the HWND surface).
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
}
