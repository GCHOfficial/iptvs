// The movies/series grid's column ladder.
//
// This replaced a two-branch rule (`width >= 1280 ? 6 : 4`) forked on
// `defaultTargetPlatform == android`, which had no height input and no upper
// bound: a 1279 px window drew 303 px tiles, a 3840 px one drew ~628 px
// posters with barely one row on screen, and an Android tablet showed 7
// columns where an iPad of the same width showed 6.
//
// The single ladder divides the viewport by `kMediaPosterTargetWidth`. The
// pins below are the contract: it must keep reproducing the column counts the
// Android-TV fork was originally introduced to get (960 -> 5, 1920 -> 10) and
// the desktop 1280 -> 6, while staying bounded at both ends.

import 'package:flutter/rendering.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/theme.dart' show kMediaPosterTargetWidth;

void main() {
  int columnsAt(double width, {double height = 800}) =>
      MediaGridMetrics.forSize(Size(width, height)).columns;

  test('reproduces the column counts the platform fork existed to produce', () {
    // Android TV render targets. Matching these is what made deleting the
    // fork safe rather than a behaviour change for TV users.
    expect(columnsAt(960, height: 540), 5);
    expect(columnsAt(1920, height: 1080), 10);
    // Desktop's established breakpoint.
    expect(columnsAt(1280), 6);
  });

  test('scales continuously instead of stepping between two extremes', () {
    // The old rule gave 4 columns for everything below 1280 and 6 above it,
    // so 1279 and 1280 differed by 50% in tile width.
    expect(columnsAt(1279), 6);
    expect(columnsAt(1280), 6);
    expect(columnsAt(1600), 8);
    expect(columnsAt(2560), 13);
  });

  test('stays bounded at both ends', () {
    // A 4K TV used to show six ~628 px posters at barely one row.
    expect(columnsAt(3840, height: 2160), 16);
    expect(columnsAt(600), 3);
    // The clamp floor holds even for an absurdly narrow viewport.
    expect(columnsAt(120), 3);
  });

  test('tiles stay in a narrow width band across the whole ladder', () {
    // The point of the ladder: a poster is roughly the same physical size on
    // a small window and on a 4K panel.
    for (final width in const [600.0, 960.0, 1280.0, 1920.0, 2560.0, 3840.0]) {
      final metrics = MediaGridMetrics.forSize(Size(width, 900));
      final tile = metrics.tileWidth(width);
      expect(
        tile,
        inInclusiveRange(150, 260),
        reason: '$width px viewport produced a ${tile.round()} px tile',
      );
    }
  });

  test('density affects gutters only, never the column count', () {
    // All that survives of the old `compact` fork, and it is keyed off
    // viewport size rather than the platform.
    final dense = MediaGridMetrics.forSize(const Size(960, 540));
    final roomy = MediaGridMetrics.forSize(const Size(1920, 1080));
    expect(dense.spacing, lessThan(roomy.spacing));
    expect(dense.padding.left, lessThan(roomy.padding.left));
  });

  test('the poster target width is the ladder divisor', () {
    // Guards against the constant drifting away from the arithmetic.
    expect(columnsAt(kMediaPosterTargetWidth * 7), 7);
  });

  test('a reserved text budget keeps the poster at a fixed 2:3', () {
    final metrics = MediaGridMetrics.forSize(const Size(1280, 800));
    final tile = metrics.tileWidth(1280);
    final ratio = metrics.childAspectRatio(tileWidth: tile, textBudget: 60);
    // A taller text budget must produce a taller cell (smaller ratio), never
    // eat into the poster — that is what made neighbouring tiles crop the
    // same poster differently.
    final tallerText = metrics.childAspectRatio(
      tileWidth: tile,
      textBudget: 90,
    );
    expect(tallerText, lessThan(ratio));
  });
}
