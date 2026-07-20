import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/live_tab_view.dart';

void main() {
  test('short wide TV viewport uses bounded compact metrics', () {
    final metrics = LiveLayoutMetrics.forSize(const Size(960, 540));

    expect(metrics.scale, 0.75);
    expect(metrics.previewHeight, 142.5);
    expect(metrics.previewWidth, 187.5);
    expect(metrics.categoryPaneWidth, 180);
    expect(metrics.channelRowExtent(false), 56);
    expect(metrics.channelRowExtent(true), 88);
    expect(metrics.categoryRowExtent, 40);
  });

  test('large desktop viewport keeps standard metrics', () {
    final metrics = LiveLayoutMetrics.forSize(const Size(1600, 900));

    expect(metrics.scale, 1);
    expect(metrics.previewHeight, 190);
    expect(metrics.previewWidth, 250);
    expect(metrics.categoryPaneWidth, 240);
    expect(metrics.channelRowExtent(false), kChannelRowExtentPlain);
    expect(metrics.channelRowExtent(true), kChannelRowExtentWithEpg);
    expect(metrics.categoryRowExtent, kCategoryRowExtent);
  });

  test('4K TV logical viewport requests compact wide metrics', () {
    final metrics = LiveLayoutMetrics.forSize(
      const Size(1920, 1080),
      compactWideLayout: true,
    );

    expect(metrics.scale, 0.625);
    expect(metrics.previewHeight, 120);
    expect(metrics.channelRowExtent(false), 56);
  });

  test('phone layout is not density-scaled', () {
    final metrics = LiveLayoutMetrics.forSize(const Size(400, 800));
    expect(metrics.scale, 1);
  });
}
