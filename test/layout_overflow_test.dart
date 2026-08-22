// Fixed-extent surfaces must never overflow, at any window size or text scale.
//
// Three of this app's browsing surfaces size a box from a **prediction** of what
// its text will cost — the live channel row (a selection model that scrolls by
// `index * itemExtent`, so the extent is authoritative), the poster grid's
// `childAspectRatio`, and the Continue-watching rail's tile height. A prediction
// built from font metrics is exactly the kind of thing that is quietly 1–2 px
// short on a real font, and three separate attempts to fix that by *raising the
// prediction* left the reported overflow unchanged. The fix those attempts were
// missing is structural: the content is now laid out unconstrained inside a
// `ClipRect`, so the geometry cannot report an overflow no matter what the
// prediction says. This file is what pins that.
//
// **It loads the real Inter font.** With `flutter_test`'s default font every
// line is exactly `1.0 * fontSize` tall and none of these surfaces overflows —
// the bug is invisible. Under Inter a 12.5 px run lays out at 18 px (ratio
// ~1.41, plus the engine rounding each line's ascent and descent up to a whole
// logical pixel), which is what made the cursor row and the rail tile overflow
// on a windowed desktop layout. Without the structural fix every `takeException`
// below returns a `RenderFlex overflowed by …` error.

import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart' show PlaybackPosition;
import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/screens/media_tab_controller.dart'
    show ContinueWatchingEntry, kAllSourcesFavoritesCategoryId;
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';

/// Registers the app's bundled Inter faces under the family name the theme
/// asks for, so the widget tree lays text out with production metrics.
///
/// The faces live under `android/app/src/main/res/font/` (they are declared as
/// Flutter font assets in `pubspec.yaml` from there, not duplicated into an
/// `assets/` tree), and `flutter test` runs with the package root as its
/// working directory.
Future<void> loadInterFont() async {
  final loader = FontLoader('Inter');
  for (final path in const [
    'android/app/src/main/res/font/inter_regular.ttf',
    'android/app/src/main/res/font/inter_semibold.ttf',
    'android/app/src/main/res/font/inter_bold.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) {
      fail(
        'Inter face missing at $path — this test is only meaningful with the '
        'real font loaded; see the file header.',
      );
    }
    loader.addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    debugDisableNetworkChannelLogos = true;
    await loadInterFont();
  });
  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  /// Drives the real test view rather than injecting a `MediaQueryData`: the
  /// live tab asserts that its `itemExtent` and the coordinator's scroll maths
  /// were built from the same window size, so a fake size that the render
  /// surface doesn't share would not model production.
  void useWindow(WidgetTester tester, Size size, double textScale) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
  }

  group('the live channel row fits its extent', () {
    // The heights bracket every branch the live geometry has: below
    // `kShortViewportMaxHeight`, either side of the 0.95 density step where the
    // row's padding drops (684), the ~700 px band where the four-line row has
    // least slack, and the unscaled 720+ layouts. 1256x705 is the window the
    // overflow was reported from.
    for (final height in const [
      560.0,
      620.0,
      675.0,
      684.0,
      700.0,
      705.0,
      720.0,
      800.0,
      1080.0,
    ]) {
      for (final textScale in const [1.0, 1.3, 2.0]) {
        testWidgets('at 1256x$height, text scale $textScale', (tester) async {
          // Windows/desktop density (not the Android ten-foot layout), which is
          // where the overflow was seen.
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          final size = Size(1256, height);
          useWindow(tester, size, textScale);

          final channels = [
            for (var i = 0; i < 8; i++)
              Channel(
                id: 'c$i',
                // Descenders on every line: what a too-tight box clips first.
                name: 'Channel $i — Long Enough To Ellipsize pygjq',
                number: i + 1,
              ),
          ];
          final start = DateTime(2024, 1, 1, 20);
          final now = {
            for (final c in channels)
              c.id: Programme(
                channelId: c.id,
                title: 'Now Programme pygjq',
                start: start,
                stop: start.add(const Duration(hours: 1)),
              ),
          };
          final next = {
            for (final c in channels)
              c.id: Programme(
                channelId: c.id,
                title: 'Next Programme pygjq',
                start: start.add(const Duration(hours: 1)),
                stop: start.add(const Duration(hours: 2)),
              ),
          };

          final scroll = ScrollController();
          final categoryScroll = ScrollController();
          final metrics = LiveLayoutMetrics.forSize(size, textScale: textScale);
          final rowExtent = metrics.channelRowExtent(true);
          final focus = LiveFocusCoordinator(
            scrollController: scroll,
            categoryScrollController: categoryScroll,
            visibleChannels: () => channels,
            orderedCategoryIds: () => const [null, 'news'],
            channelRowExtent: () => rowExtent,
            categoryRowExtent: () => metrics.categoryRowExtent,
            isWide: () => size.width >= kWideLayoutMinWidth,
            isMounted: () => true,
            onChannelSelectionChanged: (_, _) {},
            onCategoryActivated: (_) {},
            onPlayChannel: (_) {},
            onToggleFavorite: (_) {},
            onFocusTabs: () {},
          );
          addTearDown(() {
            focus.dispose();
            scroll.dispose();
            categoryScroll.dispose();
          });

          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              home: Scaffold(
                body: SafeArea(
                  top: false,
                  child: LiveTabView(
                    loading: false,
                    error: null,
                    onRetry: () {},
                    visible: channels,
                    // Cross-source Favorites: the source chip shares the title
                    // line, so it competes for width in the same fixed-extent
                    // row. A long label is the worst case — with real font
                    // metrics this is where a too-tight box shows up.
                    sourceLabelFor: (_) => 'A Rather Long Panel Name pygjq',
                    resolvePreviewChannel: () => channels.first,
                    // Production hands the cross-source view its guide
                    // through `epgFor`, keyed by (source, channel) — the maps
                    // stay empty there. Wiring it the same way here keeps this
                    // sweep over the *real* path.
                    now: const {},
                    next: const {},
                    showsEpg: true,
                    epgFor: (c) => (now: now[c.id], next: next[c.id]),
                    deliberate: true,
                    resolving: false,
                    scrollController: scroll,
                    categoryScrollController: categoryScroll,
                    focus: focus,
                    channelRowExtent: rowExtent,
                    categoryRowExtent: metrics.categoryRowExtent,
                    lastPlayedChannelId: null,
                    previewChannelId: null,
                    isFavorite: (_) => false,
                    onToggleFavorite: (_) {},
                    onPlayChannel: (_) {},
                    onPreviewChannel: (_) {},
                    onCatchup: (_) {},
                    categories: const [Category(id: 'news', title: 'News')],
                    selectedCategoryId: null,
                    onCategorySelected: (_) {},
                    previewVideoBuilder: () => const SizedBox.shrink(),
                    previewLoading: false,
                    previewError: null,
                  ),
                ),
              ),
            ),
          );
          // The overflow only ever showed on the row carrying the accent cursor
          // border, so the list has to actually own the D-pad.
          focus.channelsFocusNode.requestFocus();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          expect(tester.takeException(), isNull);
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }
  });

  group('the cross-source favorites row fits its (shorter) extent', () {
    // The cross-source view is the one live layout that draws a source chip and
    // **no EPG**, so it runs on `channelRowExtent(false)` — a combination the
    // sweep above never covers, because it always supplies a guide.
    //
    // Regression: the screen kept computing the extent from
    // `_live.now.isNotEmpty` (the *active* source's guide) while handing this
    // view empty `now`/`next` maps, so the row was laid out at 68.1 px inside an
    // itemExtent of 105.9 — caught by `LiveTabView`'s own debug assert, which
    // this test therefore also exercises. Both sides now read `showsEpg`, one
    // value the screen derives once from `liveRowsShowEpg`; this case is the
    // cross-source view before any guide has loaded, which is still the short
    // row.
    for (final size in const [
      Size(1256, 705),
      Size(1280, 720),
      Size(1000, 600),
      Size(1920, 1080),
    ]) {
      for (final textScale in const [1.0, 1.3, 2.0]) {
        testWidgets('at $size, text scale $textScale', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          useWindow(tester, size, textScale);

          final channels = [
            for (var i = 0; i < 8; i++)
              Channel(
                id: 'c$i',
                name: 'Channel $i — Long Enough To Ellipsize pygjq',
                number: i + 1,
              ),
          ];
          final scroll = ScrollController();
          final categoryScroll = ScrollController();
          final metrics = LiveLayoutMetrics.forSize(size, textScale: textScale);
          // The whole point: `false`, and empty guide maps to match it.
          final rowExtent = metrics.channelRowExtent(false);
          final focus = LiveFocusCoordinator(
            scrollController: scroll,
            categoryScrollController: categoryScroll,
            visibleChannels: () => channels,
            orderedCategoryIds: () => const [kAllSourcesFavoritesCategoryId],
            channelRowExtent: () => rowExtent,
            categoryRowExtent: () => metrics.categoryRowExtent,
            isWide: () => size.width >= kWideLayoutMinWidth,
            isMounted: () => true,
            onChannelSelectionChanged: (_, _) {},
            onCategoryActivated: (_) {},
            onPlayChannel: (_) {},
            onToggleFavorite: (_) {},
            onFocusTabs: () {},
          );
          addTearDown(() {
            focus.dispose();
            scroll.dispose();
            categoryScroll.dispose();
          });

          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              home: Scaffold(
                body: SafeArea(
                  top: false,
                  child: LiveTabView(
                    loading: false,
                    error: null,
                    onRetry: () {},
                    visible: channels,
                    sourceLabelFor: (_) => 'A Rather Long Panel Name pygjq',
                    isPreviewingRow: (_) => false,
                    resolvePreviewChannel: () => channels.first,
                    now: const {},
                    next: const {},
                    showsEpg: false,
                    deliberate: true,
                    resolving: false,
                    scrollController: scroll,
                    categoryScrollController: categoryScroll,
                    focus: focus,
                    channelRowExtent: rowExtent,
                    categoryRowExtent: metrics.categoryRowExtent,
                    lastPlayedChannelId: null,
                    previewChannelId: null,
                    isFavorite: (_) => true,
                    onToggleFavorite: (_) {},
                    onPlayChannel: (_) {},
                    onPreviewChannel: (_) {},
                    onCatchup: (_) {},
                    categories: const [
                      Category(
                        id: kAllSourcesFavoritesCategoryId,
                        title: 'Favorites · All sources',
                      ),
                    ],
                    selectedCategoryId: kAllSourcesFavoritesCategoryId,
                    onCategorySelected: (_) {},
                    previewVideoBuilder: () => const SizedBox.shrink(),
                    previewLoading: false,
                    previewError: null,
                  ),
                ),
              ),
            ),
          );
          focus.channelsFocusNode.requestFocus();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          expect(tester.takeException(), isNull);
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }
  });

  group('the media tab fits its cells', () {
    // The rail is the surface that produced the reported
    // `BOTTOM OVERFLOWED BY 1.6 PIXELS`; the grid tiles are swept alongside it
    // because they share the same fixed-reservation design.
    for (final size in const [
      Size(1256, 705),
      Size(1280, 720),
      Size(1000, 600),
      Size(1920, 1080),
    ]) {
      for (final textScale in const [1.0, 1.3]) {
        testWidgets('grid + continue-watching rail at $size, text scale '
            '$textScale', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          useWindow(tester, size, textScale);

          final items = [
            for (var i = 0; i < 24; i++)
              MediaItem(
                id: 'm$i',
                title: 'A Rather Long Movie Title Number $i pygjq 1080p MULTI',
                kind: ContentKind.movie,
                year: '20${10 + i}',
                rating: 8.5,
              ),
          ];
          final scroll = ScrollController();
          addTearDown(scroll.dispose);

          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              home: Scaffold(
                body: SafeArea(
                  top: false,
                  child: MediaTabView(
                    kind: ContentKind.movie,
                    visible: items,
                    snapshot: null,
                    loading: false,
                    // Puts the "load more" cell in the grid alongside the tiles.
                    loadingMore: true,
                    error: null,
                    showingSearch: false,
                    lastPlayedId: null,
                    scrollController: scroll,
                    firstFocusNode: null,
                    isFavorite: (id) => id == 'm1',
                    onOpenMedia: (_) {},
                    onLoadMore: () {},
                    onRetry: () {},
                    continueWatching: [
                      for (var i = 0; i < 3; i++)
                        ContinueWatchingEntry(
                          item: items[i],
                          position: PlaybackPosition(
                            kind: ContentKind.movie,
                            itemId: items[i].id,
                            position: const Duration(minutes: 12),
                            duration: const Duration(hours: 1, minutes: 40),
                            updatedAt: DateTime(2024, 1, 1),
                          ),
                        ),
                    ],
                    onResume: (_) {},
                    onRemoveContinueWatching: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          expect(tester.takeException(), isNull);
          debugDefaultTargetPlatformOverride = null;
        });
      }
    }
  });
}
