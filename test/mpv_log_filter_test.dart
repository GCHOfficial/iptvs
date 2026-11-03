import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/mpv_log_filter.dart';

void main() {
  bool relay(String level, String prefix, String text) =>
      shouldRelayMpvLog(level: level, prefix: prefix, text: text);

  test('non-ffmpeg warnings and errors are relayed', () {
    expect(relay('warn', 'playlist', 'Reading plaintext playlist.'), isTrue);
    expect(relay('error', 'cplayer', 'Failed to open'), isTrue);
  });

  test('levels below warn are never relayed', () {
    expect(relay('info', 'cplayer', 'anything'), isFalse);
    expect(relay('v', 'ffmpeg', 'http: Will reconnect at 1 in 0 second(s)'),
        isFalse);
  });

  test('ffmpeg decode and demux noise stays dropped', () {
    expect(relay('warn', 'ffmpeg/video', 'hevc: Could not find ref with POC 3'),
        isFalse);
    expect(relay('error', 'ffmpeg/video', 'h264: non-existing PPS 0 referenced'),
        isFalse);
    expect(relay('warn', 'ffmpeg/demuxer', 'mpegts: Packet corrupt'), isFalse);
  });

  test("ffmpeg's HTTP transport lines are relayed", () {
    // Verbatim shapes from FFmpeg 9 / mpv 0.41 on a dropped live TS stream.
    expect(
      relay('warn', 'ffmpeg',
          'http: Stream ends prematurely at 33423360, should be 18446744073709551615'),
      isTrue,
    );
    expect(
      relay('warn', 'ffmpeg',
          'http: Will reconnect at 33423360 in 0 second(s), error=Input/output error.'),
      isTrue,
    );
    expect(relay('error', 'ffmpeg', 'HTTP error 403 Forbidden'), isTrue);
  });
}
