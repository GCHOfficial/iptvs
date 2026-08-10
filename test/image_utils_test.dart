import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/widgets/image_utils.dart';

void main() {
  group('scaledImageCacheSize', () {
    test('uses physical pixels and clamps excessive DPR', () {
      // Physical pixels, then rounded up to the bucket: 100x2 = 200 -> 224,
      // and the DPR clamp holds 5 at 3, so 100x5 = 300 -> 320 rather than 500.
      expect(scaledImageCacheSize(100, 2), 224);
      expect(scaledImageCacheSize(100, 5), 320);
      expect(scaledImageCacheSize(100, 5), lessThan(scaledImageCacheSize(200, 3)));
    });

    test('never converts infinity or NaN to an integer', () {
      expect(scaledImageCacheSize(double.infinity, 2), kImageCacheSizeBucket);
      expect(scaledImageCacheSize(double.nan, 2), kImageCacheSizeBucket);
      // An unusable DPR falls back to 1, so these stay at the logical size.
      expect(scaledImageCacheSize(100, double.infinity), 128);
      expect(scaledImageCacheSize(100, double.nan), 128);
    });

    test('keeps invalid and extreme dimensions within codec bounds', () {
      expect(scaledImageCacheSize(0, 0), kImageCacheSizeBucket);
      expect(scaledImageCacheSize(-20, -2), kImageCacheSizeBucket);
      expect(scaledImageCacheSize(100000, 3), 8192);
    });

    test('rounds the bucket up, never down', () {
      // Never below the display size: a short decode would be upscaled by the
      // BoxFit.cover above it.
      expect(scaledImageCacheSize(193, 1), 224);
      expect(scaledImageCacheSize(223, 1), 224);
      expect(scaledImageCacheSize(192, 1), 192);
    });

    test('a small layout wobble keeps one cache key', () {
      // The bug this bucket exists for: a poster sized from its own
      // constraints re-decoded (placeholder and all) every time its box moved
      // by a pixel or two. The focus ring no longer resizes anything (see
      // kFocusableCardBorderWidth); this is what covers everything else that
      // wobbles — a window drag, a text-scale change, a fractional grid
      // division — so a few pixels resolve to the same key instead of a miss.
      final resting = scaledImageCacheSize(176.0, 2);
      for (final width in [172.0, 173.5, 175.0, 176.0]) {
        expect(scaledImageCacheSize(width, 2), resting);
      }
    });
  });

  group('logImageFailure', () {
    setUp(debugResetImageFailureLog);

    List<DiagnosticsEntry> imageEntries() => DiagnosticsLog.instance.entries
        .where((entry) => entry.scope == 'image')
        .toList();

    test('records the first failure with its url and error', () {
      final before = imageEntries().length;
      logImageFailure('HttpException: connection closed', 'https://cdn/p.jpg');
      final entries = imageEntries();
      expect(entries.length, before + 1);
      expect(entries.last.message, contains('fetch failed'));
      expect(entries.last.message, contains('p.jpg'));
      expect(entries.last.message, contains('connection closed'));
    });

    test('throttles a storm into one entry plus a suppressed count', () {
      // The failure mode this exists for is systemic — every tile on screen
      // fails at once. Unthrottled, that evicts the 800-entry ring buffer and
      // destroys the context needed to explain it.
      final before = imageEntries().length;
      for (var i = 0; i < 50; i++) {
        logImageFailure('boom', 'https://cdn/$i.jpg');
      }
      expect(imageEntries().length, before + 1);

      // Release the throttle without sleeping: the count survives, so the next
      // entry has to account for everything the storm swallowed.
      debugImageFailureLogWindow = Duration.zero;
      logImageFailure('boom', 'https://cdn/next.jpg');
      expect(imageEntries().last.message, contains('49 suppressed'));
    });

    test('redacts credentials carried by a provider logo url', () {
      // Channel logos come off the provider, not a public CDN, so they can
      // embed the account's credentials — and the log is user-exportable.
      logImageFailure(
        'boom',
        'http://portal.example/live/joe/hunter2/logo.png',
      );
      final message = imageEntries().last.message;
      expect(message, isNot(contains('hunter2')));
      expect(message, isNot(contains('joe')));
    });
  });
}
