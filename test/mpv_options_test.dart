import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/mpv_options.dart';

void main() {
  group('kLiveMpvOptions stream-lavf-o', () {
    final stream = kLiveMpvOptions['stream-lavf-o']!;

    test('FFmpeg never reconnects a streamed live body in place', () {
      // Providers answer a live TS with a close-delimited body, so *every*
      // end of stream looks "premature" to FFmpeg and it retries the
      // post-redirect URL — whose per-connection token a portal has already
      // spent. Where it does reconnect, on a provider that front-loads a
      // backlog, it splices older content in and the audio timestamps reset.
      // Live recovery is the app watchdog's job, because only the app
      // re-resolves first and so comes back with a token that works.
      expect(stream, contains('reconnect_streamed=0'));
      expect(stream, isNot(contains('reconnect_streamed=1')));
    });

    test('the plain reconnect and the delay cap stay', () {
      // `reconnect=1` still covers a connection dropping mid-body with a
      // known content length, which is the case FFmpeg's retry is good at.
      expect(stream, contains('reconnect=1'));
      expect(stream, contains('reconnect_delay_max=5'));
    });

    test('reconnect_at_eof stays out', () {
      // An HLS live manifest is a *finite* HTTP resource: with that flag
      // ffmpeg reads its EOF as an error and reconnects forever, so the
      // demuxer probe never completes and the stream never opens at all.
      expect(stream, isNot(contains('reconnect_at_eof')));
    });
  });

  group('kLiveMpvOptions is live-only', () {
    test('carries no buffer-depth key — the preset owns those', () {
      // `cache-secs` comes from the per-source preset and `demuxer-max-bytes`
      // from media_kit's per-surface configuration; this map must not shadow
      // either, or a preset change would silently do nothing.
      expect(kLiveMpvOptions.containsKey('cache-secs'), isFalse);
      expect(kLiveMpvOptions.containsKey('demuxer-max-bytes'), isFalse);
    });

    test('keeps the no-back-buffer and no-disk-cache choices', () {
      // A live stream is never seeked backwards, and a file cache for a
      // provider URL fails outright on restricted temp paths.
      expect(kLiveMpvOptions['demuxer-max-back-bytes'], '0');
      expect(kLiveMpvOptions['cache-on-disk'], 'no');
    });
  });
}
