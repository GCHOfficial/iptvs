import 'package:flutter_test/flutter_test.dart';
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
}
