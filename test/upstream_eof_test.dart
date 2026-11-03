import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/upstream_eof.dart';

void main() {
  group('parseMpvEofFlag', () {
    test('recognises get_property_string flag values', () {
      expect(parseMpvEofFlag('yes'), isTrue);
      expect(parseMpvEofFlag('YES'), isTrue);
      expect(parseMpvEofFlag(' yes '), isTrue);
      expect(parseMpvEofFlag('true'), isTrue);
    });

    test('treats everything else as not-eof', () {
      expect(parseMpvEofFlag('no'), isFalse);
      expect(parseMpvEofFlag('false'), isFalse);
      expect(parseMpvEofFlag(''), isFalse);
      expect(parseMpvEofFlag(null), isFalse);
      expect(parseMpvEofFlag('garbage'), isFalse);
    });
  });

  group('upstreamEofLogLine', () {
    test('is credential-free, durations only', () {
      expect(upstreamEofLogLine(0), 'live upstream ended ahead=0ms');
      expect(upstreamEofLogLine(29000), 'live upstream ended ahead=29000ms');
    });
  });
}
