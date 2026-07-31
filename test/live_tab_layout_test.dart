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
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart' show kWideLayoutMinWidth;

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
    final focus = LiveFocusCoordinator(
      scrollController: scroll,
      categoryScrollController: categoryScroll,
      visibleChannels: () => list,
      orderedCategoryIds: () => const [null, 'news'],
      channelRowExtent: () => kChannelRowExtentPlain,
      categoryRowExtent: () => kCategoryRowExtent,
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
                resolvePreviewChannel: () => list.first,
                now: const {},
                next: const {},
                deliberate: deliberate,
                resolving: false,
                scrollController: scroll,
                categoryScrollController: categoryScroll,
                focus: focus,
                channelRowExtent: kChannelRowExtentPlain,
                categoryRowExtent: kCategoryRowExtent,
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
}
