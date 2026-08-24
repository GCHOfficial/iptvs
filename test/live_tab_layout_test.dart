// LiveTabView's *layout* contract, independent of ChannelListScreen.
//
// Two things are pinned here, both of which decide whether the wide preview
// panel is reachable at all on a touch device:
//
//   * **One width authority.** Everything that branches on "wide" — the screen's
//     `_isWide()` (which the focus coordinator takes as its `isWide` callback,
//     so it governs where Up escapes and whether Left/Back can reach the
//     sidebar), `_play`'s preview-first-vs-fullscreen split, the long-press
//     gate, and `LiveLayoutMetrics` — reads the *window* width from
//     `MediaQuery`. The body's own constraints are narrower whenever the
//     screen's `SafeArea` eats a left/right system-bar or cutout inset (Android
//     landscape, edge-to-edge). A `LayoutBuilder` here therefore used to render
//     the *phone* layout for a window that every other branch treated as wide,
//     and that band was a dead zone: no preview panel and no long-press sheet,
//     a tap starting an audible preview with nothing on screen showing it, and
//     the Back ladder stalling at rung 2 forever because `focusCategories()`
//     focused a sidebar node that had never been built.
//   * **The hint never names an input the device lacks.** A `deliberate`
//     preview starts on OK *or* on a pointer — tapping a row runs the same
//     `onPlayChannel` path. The wording must say so, or a tablet in landscape
//     reads "Press OK/Select to preview" as an instruction it cannot follow.
//
// These build `LiveTabView` directly with stub callbacks, so they need no
// libmpv and run everywhere (unlike the screen-level tests in
// `channel_list_focus_test.dart`, which construct a real preview player).

import 'package:flutter/foundation.dart'
    show
        debugDefaultTargetPlatformOverride,
        defaultTargetPlatform,
        TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart' show AppColors, kWideLayoutMinWidth;

void main() {
  setUpAll(() => debugDisableNetworkChannelLogos = true);
  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  List<Channel> channels(int count) => [
    for (var i = 0; i < count; i++)
      Channel(id: 'c$i', name: 'Channel $i', number: i + 1),
  ];

  /// Pump a bare `LiveTabView` inside the same `SafeArea` shape the screen uses.
  ///
  /// [size] and [sideInset] are pushed onto the **real test view**, not injected
  /// as a `MediaQueryData` — a widget test's render surface stays 800x600 when
  /// you only override the `MediaQuery`, so an injected size would make the
  /// layout branch and the actual constraints disagree for a reason production
  /// never has. Driving the view reproduces Android landscape under
  /// edge-to-edge exactly: the window is [size] wide, and the screen's SafeArea
  /// hands the body `size.width - sideInset`.
  Future<List<String>> pumpLiveTab(
    WidgetTester tester, {
    required Size size,
    double sideInset = 0,
    bool deliberate = true,
    String? previewChannelId,
    List<Channel>? visible,
    void Function(LiveFocusCoordinator)? expose,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding(right: sideInset);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });
    final played = <String>[];
    final list = visible ?? channels(6);
    final scroll = ScrollController();
    final categoryScroll = ScrollController();
    // Derive the extents from the *same* metrics the view builds, exactly as
    // `ChannelListScreen._liveChannelRowExtent` does. Hard-coding the base
    // constants here made the harness disagree with the view under any
    // density scaling (Android's compact wide layout drops the plain row to
    // 56 and the category row to 40), which the view now asserts against —
    // the selection model scrolls by `index * extent`, so a harness that
    // pinned one value while the view laid out another was not modelling
    // production at all.
    final metrics = LiveLayoutMetrics.forSize(
      size,
      compactWideLayout: defaultTargetPlatform == TargetPlatform.android,
    );
    // `now`/`next` are empty below, so rows render without the EPG lines.
    final rowExtent = metrics.channelRowExtent(false);
    final focus = LiveFocusCoordinator(
      scrollController: scroll,
      categoryScrollController: categoryScroll,
      visibleChannels: () => list,
      orderedCategoryIds: () => const [null, 'news'],
      channelRowExtent: () => rowExtent,
      categoryRowExtent: () => metrics.categoryRowExtent,
      isWide: () => size.width >= kWideLayoutMinWidth,
      isMounted: () => true,
      onChannelSelectionChanged: (_, _) {},
      onCategoryActivated: (_) {},
      onPlayChannel: (c) => played.add(c.id),
      onToggleFavorite: (_) {},
      onFocusTabs: () {},
    );
    addTearDown(() {
      focus.dispose();
      scroll.dispose();
      categoryScroll.dispose();
    });
    expose?.call(focus);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            top: false,
            child: Builder(
              builder: (context) => LiveTabView(
                loading: false,
                error: null,
                onRetry: () {},
                visible: list,
                // Mirrors `ChannelListScreen._resolvePreviewChannel`, which
                // returns null for an empty list rather than throwing.
                resolvePreviewChannel: () => list.isEmpty ? null : list.first,
                now: const {},
                next: const {},
                showsEpg: false,
                deliberate: deliberate,
                resolving: false,
                scrollController: scroll,
                categoryScrollController: categoryScroll,
                focus: focus,
                channelRowExtent: rowExtent,
                categoryRowExtent: metrics.categoryRowExtent,
                lastPlayedChannelId: null,
                previewChannelId: previewChannelId,
                isFavorite: (_) => false,
                onToggleFavorite: (_) {},
                onPlayChannel: (c) => played.add(c.id),
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
      ),
    );
    await tester.pump();
    return played;
  }

  // "Playlists" is the category sidebar's header — it exists only in the wide
  // two-pane layout, alongside the preview panel.
  final sidebar = find.text('Playlists');

  group('wide layout width authority', () {
    testWidgets('a window over the threshold is wide', (tester) async {
      await pumpLiveTab(tester, size: const Size(960, 600));
      expect(sidebar, findsOneWidget);
    });

    testWidgets(
      'stays wide when SafeArea insets make the body narrower than the '
      'threshold',
      (tester) async {
        // 960 logical px window, 48 px landscape navigation bar on one side:
        // the body is 912 px. The screen's `_isWide()`, the coordinator's
        // `isWide`, `_play` and the long-press gate all still say wide, so the
        // layout must agree — otherwise the preview panel is gone while a tap
        // still starts a preview only the panel could show.
        await pumpLiveTab(
          tester,
          size: const Size(960, 600),
          sideInset: 48,
        );
        expect(sidebar, findsOneWidget);
      },
    );

    testWidgets('a genuinely narrow window is the phone layout', (
      tester,
    ) async {
      await pumpLiveTab(tester, size: const Size(400, 800));
      expect(sidebar, findsNothing);
    });
  });

  // `debugDefaultTargetPlatformOverride` must be cleared *inside* the test body:
  // the framework verifies the foundation debug vars are unset before any
  // `addTearDown` callback runs.
  Future<void> asAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('preview hint', () {
    testWidgets('a deliberate preview names the pointer, not only OK', (
      tester,
    ) async {
      await asAndroid(() async {
        await pumpLiveTab(tester, size: const Size(1280, 800));

        // The panel must not instruct a touch-only tablet to press a key it
        // has no way to send.
        expect(find.text('Press OK/Select to preview'), findsNothing);
        expect(find.text('OK or tap to preview'), findsOneWidget);
      });
    });

    testWidgets('tapping a channel row runs the play/preview path', (
      tester,
    ) async {
      await asAndroid(() async {
        // The rows are not focus targets (selection model), but they stay
        // tappable — that tap is what makes the hint above satisfiable without
        // a remote, because it runs the same `onPlayChannel` → `_play` path OK
        // does: preview first, fullscreen on the second activation.
        final played = await pumpLiveTab(tester, size: const Size(1280, 800));
        await tester.tap(find.text('Channel 2'));
        await tester.pump();
        expect(played, ['c2']);
      });
    });
  });

  group('the favorite star cell', () {
    // Regression: the accent ring was a `decoration` border, which *adds* its
    // width to the cell — 20 (icon) + 12 (padding) + 4 (border) = 36. That
    // fits the 44 px pointer target but not the ten-foot 32 px one, so the
    // `Center` above squeezed the cell back to 32, the `Icon` collapsed 20 →
    // 16, and a 20 px glyph paints from the *top-left* of the box it
    // overflows: on a TV the star sat ~2 px down and right of the ring drawn
    // around it. The ring is a `foregroundDecoration` now, which costs no
    // layout.
    final rowStar = find
        .descendant(
          of: find.byType(IndexedSemantics),
          matching: find.byIcon(Icons.star_outline_rounded),
        )
        .first;

    testWidgets('the ring does not move or shrink the glyph', (tester) async {
      await asAndroid(() async {
        late final LiveFocusCoordinator focus;
        await pumpLiveTab(
          tester,
          size: const Size(960, 540),
          expose: (f) => focus = f,
        );

        final size = tester.getSize(rowStar);
        final center = tester.getCenter(rowStar);
        expect(size, const Size(20, 20), reason: 'the icon is not squeezed');

        // Right enters the row's favorite column, which draws the ring.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(focus.channelColumn, ChannelRowColumn.favorite);

        expect(tester.getSize(rowStar), size);
        expect(tester.getCenter(rowStar), center);
      });
    });

    // The same property `channel_list_focus_test.dart` asserts — but that file
    // builds a real preview player, so 22 of its 23 tests skip on any machine
    // without libmpv and the whole thing runs only on CI. Reading the ring here
    // too means a change that moves it back onto `decoration` fails on a
    // developer's own `flutter test`, not two pushes later.
    testWidgets('the ring is painted, not laid out', (tester) async {
      await asAndroid(() async {
        late final LiveFocusCoordinator focus;
        await pumpLiveTab(
          tester,
          size: const Size(960, 540),
          expose: (f) => focus = f,
        );

        Border? ring() {
          final cell = tester.widget<Container>(
            find.ancestor(of: rowStar, matching: find.byType(Container)).first,
          );
          expect(
            (cell.decoration as BoxDecoration?)?.border,
            isNull,
            reason: 'a decoration border would inset the glyph',
          );
          return (cell.foregroundDecoration as BoxDecoration?)?.border
              as Border?;
        }

        expect(ring(), isNull, reason: 'the cursor starts on the row body');

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(focus.channelColumn, ChannelRowColumn.favorite);
        expect(ring()?.top.color, AppColors.accent);
      });
    });

    testWidgets('the cell fits the ten-foot hit target', (tester) async {
      await asAndroid(() async {
        await pumpLiveTab(tester, size: const Size(960, 540));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();

        final target = LiveLayoutMetrics.forSize(
          const Size(960, 540),
          compactWideLayout: true,
        ).favoriteTargetSize;
        final cell = tester
            .renderObjectList<RenderBox>(
              find.ancestor(of: rowStar, matching: find.byType(Container)),
            )
            .first;
        expect(cell.size.width, lessThanOrEqualTo(target));
        expect(cell.size.height, lessThanOrEqualTo(target));
      });
    });
  });

  group('an empty channel list keeps the category sidebar', () {
    // Regression: the empty-state `Center` used to be returned *before* the
    // width branch, so on a wide layout it replaced the whole tab — sidebar
    // included. `ChannelListScreen` nulls the toolbar's category dropdown
    // whenever live && wide, so with the sidebar gone there was no remaining
    // caller of `_selectCategory` at all: picking a provider category that
    // happens to have zero channels (common on portals) stranded the user
    // there until the app was restarted.
    testWidgets('wide keeps the sidebar and shows the message beside it', (
      tester,
    ) async {
      await pumpLiveTab(
        tester,
        size: const Size(1280, 800),
        visible: const [],
      );
      expect(sidebar, findsOneWidget, reason: 'the way back must survive');
      expect(find.textContaining('has no channels'), findsOneWidget);
    });

    testWidgets('narrow still replaces the body (the dropdown is the way back)', (
      tester,
    ) async {
      await pumpLiveTab(
        tester,
        size: const Size(500, 800),
        visible: const [],
      );
      expect(sidebar, findsNothing);
      expect(find.textContaining('has no channels'), findsOneWidget);
    });
  });
}
