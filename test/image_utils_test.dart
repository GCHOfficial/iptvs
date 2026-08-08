import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/widgets/image_utils.dart';

void main() {
  group('scaledImageCacheSize', () {
    test('uses physical pixels and clamps excessive DPR', () {
      expect(scaledImageCacheSize(100, 2), 200);
      expect(scaledImageCacheSize(100, 5), 300);
    });

    test('never converts infinity or NaN to an integer', () {
      expect(scaledImageCacheSize(double.infinity, 2), 2);
      expect(scaledImageCacheSize(double.nan, 2), 2);
      expect(scaledImageCacheSize(100, double.infinity), 100);
      expect(scaledImageCacheSize(100, double.nan), 100);
    });

    test('keeps invalid and extreme dimensions within codec bounds', () {
      expect(scaledImageCacheSize(0, 0), 1);
      expect(scaledImageCacheSize(-20, -2), 1);
      expect(scaledImageCacheSize(100000, 3), 8192);
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
