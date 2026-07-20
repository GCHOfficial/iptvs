import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/media_tab_view.dart';

void main() {
  test('desktop catalogue retains the established fixed column counts', () {
    expect(MediaGridMetrics.forWidth(960).columns, 4);
    expect(MediaGridMetrics.forWidth(1600).columns, 6);
  });

  test('compact TV catalogue fits more posters at common viewport widths', () {
    expect(MediaGridMetrics.forWidth(960, compact: true).columns, 5);
    expect(MediaGridMetrics.forWidth(1280, compact: true).columns, 7);
    expect(MediaGridMetrics.forWidth(1920, compact: true).columns, 10);
  });

  test('compact TV catalogue column count stays bounded', () {
    expect(MediaGridMetrics.forWidth(860, compact: true).columns, 5);
    expect(MediaGridMetrics.forWidth(4000, compact: true).columns, 10);
  });
}
