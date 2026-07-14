// The live tab's D-pad contract, as pure selection logic.
//
// The channel list and the category sidebar are selection models (one focus node
// + a selected index each), so navigation is synchronous integer maths — no
// lazy-list focus race to mock. The rules these pin are deliberately asymmetric:
//
//   * **Down wraps** at the end of both lists — the only infinite motion.
//   * **Up never wraps.** At the first row it *escapes upward* (categories → the
//     search box; channels → the preview controls, or the search box on a phone).
//     The old design wrapped Up too, which is what left users "stuck in the
//     categories" with no way out but Right or Back.
//   * The channel cursor has an **intra-row favorite column**: Right enters the
//     row's star, Left peels back to the body before crossing panes, OK acts on
//     the column, and vertical moves always land back on the body.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Channel> channels(List<String> ids) => [
    for (final (i, id) in ids.indexed)
      Channel(id: id, name: 'Ch $id', number: i + 1),
  ];

  /// A coordinator over [visible] channels and [categories] (plus the implicit
  /// "All channels" at index 0). [wide] toggles the sidebar/preview layout.
  ({
    LiveFocusCoordinator focus,
    List<String> played,
    List<String> toggled,
    List<String?> activated,
    int Function() tabsFocused,
  })
  make({
    List<Channel> visible = const [],
    List<String?> categories = const [null],
    bool wide = true,
  }) {
    final played = <String>[];
    final toggled = <String>[];
    final activated = <String?>[];
    var tabs = 0;
    final focus = LiveFocusCoordinator(
      scrollController: ScrollController(),
      categoryScrollController: ScrollController(),
      visibleChannels: () => visible,
      orderedCategoryIds: () => categories,
      channelRowExtent: () => 100,
      categoryRowExtent: () => 48,
      isWide: () => wide,
      isMounted: () => true,
      onChannelSelectionChanged: (_, _) {},
      onCategoryActivated: activated.add,
      onPlayChannel: (c) => played.add(c.id),
      onToggleFavorite: (c) => toggled.add(c.id),
      onFocusTabs: () => tabs++,
    );
    return (
      focus: focus,
      played: played,
      toggled: toggled,
      activated: activated,
      tabsFocused: () => tabs,
    );
  }

  KeyEvent keyDown(LogicalKeyboardKey key) =>
      KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: key, timeStamp: Duration.zero);

  // Attach the coordinator's nodes to a real tree so `hasFocus` / `context` work.
  Future<void> host(WidgetTester tester, LiveFocusCoordinator focus,
      {bool withPreview = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Focus(
                focusNode: focus.searchCellFocusNode,
                child: const SizedBox(width: 10, height: 10),
              ),
              if (withPreview)
                Focus(
                  focusNode: focus.previewFavoriteFocusNode,
                  child: const SizedBox(width: 10, height: 10),
                ),
              Focus(
                focusNode: focus.categoriesFocusNode,
                child: const SizedBox(width: 10, height: 10),
              ),
              Focus(
                focusNode: focus.channelsFocusNode,
                child: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  group('channel list', () {
    testWidgets('Down walks the list and WRAPS past the last row', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      expect(h.focus.selectedChannelIndex, 0);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 1);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 2);
      // Past the last row: wraps to the top. This is the one infinite motion.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 0);
      expect(h.focus.region, LiveFocusRegion.channels);
    });

    testWidgets('Up walks back but NEVER wraps — at the top it escapes to the '
        'preview controls', (tester) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.selectChannel(2);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedChannelIndex, 1);
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedChannelIndex, 0);

      // At the first row Up climbs OUT — it must not wrap to the last row.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      await tester.pump();
      expect(h.focus.selectedChannelIndex, 0, reason: 'no wrap-around');
      expect(h.focus.region, LiveFocusRegion.previewControls);
    });

    testWidgets('on a phone (no preview panel) Up from the top escapes to search',
        (tester) async {
      final h = make(visible: channels(['a', 'b']), wide: false);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus, withPreview: false);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      await tester.pump();
      expect(h.focus.selectedChannelIndex, 0);
      expect(h.focus.region, LiveFocusRegion.search);
    });

    testWidgets('Left crosses to the categories (wide only)', (tester) async {
      final h = make(visible: channels(['a']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowLeft),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.categories);
    });
  });

  // The per-row favorite star: the channel cursor has two intra-row columns
  // (body / favorite). Right enters the star, Left peels back before crossing
  // panes, OK acts on whichever column holds the cursor, and every vertical
  // move resets to the body so the star column is never sticky across rows.
  group('intra-row favorite column', () {
    testWidgets('Right moves body → favorite; a second Right is consumed '
        'without change', (tester) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();
      expect(h.focus.channelColumn, ChannelRowColumn.body);

      final first = h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(first, KeyEventResult.handled);
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      // Already on the star: still consumed (geometry traversal must never
      // run in the live body), but nothing changes.
      final second = h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(second, KeyEventResult.handled);
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);
      expect(h.focus.region, LiveFocusRegion.channels);
    });

    testWidgets('Left peels favorite → body, and only then crosses to the '
        'categories (two-stage)', (tester) async {
      final h = make(visible: channels(['a']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      // First Left: back onto the row body, still in the channel pane.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowLeft),
      );
      await tester.pump();
      expect(h.focus.channelColumn, ChannelRowColumn.body);
      expect(h.focus.region, LiveFocusRegion.channels);

      // Second Left: crosses into the sidebar.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowLeft),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.categories);
    });

    testWidgets('OK plays on the body and toggles on the favorite column',
        (tester) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      // Body: OK plays.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.select),
      );
      expect(h.played, ['a']);
      expect(h.toggled, isEmpty);

      // Favorite column: OK toggles instead of playing.
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.select),
      );
      expect(h.toggled, ['a']);
      expect(h.played, ['a'], reason: 'the star press must not also play');
    });

    testWidgets('vertical moves reset the column to the body', (tester) async {
      final h = make(visible: channels(['a', 'b', 'c']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.selectChannel(1);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedChannelIndex, 2);
      expect(h.focus.channelColumn, ChannelRowColumn.body);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedChannelIndex, 1);
      expect(h.focus.channelColumn, ChannelRowColumn.body);
    });

    testWidgets('Up-escape at the first row also resets the column',
        (tester) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusChannels();
      await tester.pump();

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      expect(h.focus.channelColumn, ChannelRowColumn.favorite);

      h.focus.handleChannelsKey(
        h.focus.channelsFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.previewControls);
      expect(h.focus.channelColumn, ChannelRowColumn.body);
    });
  });

  group('category sidebar', () {
    testWidgets('Down walks the sidebar and WRAPS past the last row', (
      tester,
    ) async {
      final h = make(
        visible: channels(['a']),
        categories: [null, 'news', 'kids'],
      );
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusCategories();
      await tester.pump();

      expect(h.focus.selectedCategoryIndex, 0);
      for (var i = 1; i < 3; i++) {
        h.focus.handleCategoriesKey(
          h.focus.categoriesFocusNode,
          keyDown(LogicalKeyboardKey.arrowDown),
        );
        expect(h.focus.selectedCategoryIndex, i);
      }
      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      expect(h.focus.selectedCategoryIndex, 0, reason: 'Down wraps');
    });

    testWidgets(
        'Up NEVER wraps — at the first category it escapes to the search box '
        '(the "stuck in categories" fix)', (tester) async {
      final h = make(
        visible: channels(['a']),
        categories: [null, 'news', 'kids'],
      );
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.selectCategory(2);
      h.focus.focusCategories();
      await tester.pump();

      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedCategoryIndex, 1);
      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.focus.selectedCategoryIndex, 0);

      // The old model wrapped here, trapping the user. Now it climbs out.
      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      await tester.pump();
      expect(
        h.focus.selectedCategoryIndex,
        0,
        reason: 'must not wrap to the last category',
      );
      expect(h.focus.region, LiveFocusRegion.search);
    });

    testWidgets('Right crosses into the channel list', (tester) async {
      final h = make(visible: channels(['a', 'b']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusCategories();
      await tester.pump();

      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.arrowRight),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.channels);
    });

    testWidgets('OK applies that category as the filter', (tester) async {
      final h = make(visible: channels(['a']), categories: [null, 'news']);
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusCategories();
      h.focus.selectCategory(1);
      await tester.pump();

      h.focus.handleCategoriesKey(
        h.focus.categoriesFocusNode,
        keyDown(LogicalKeyboardKey.enter),
      );
      expect(h.activated, ['news']);
    });
  });

  group('search box', () {
    testWidgets('Down drops into the channels, Up climbs to the tabs', (
      tester,
    ) async {
      final h = make(visible: channels(['a', 'b']));
      addTearDown(h.focus.dispose);
      await host(tester, h.focus);
      h.focus.focusSearch();
      await tester.pump();

      h.focus.handleSearchCellKey(
        h.focus.searchCellFocusNode,
        keyDown(LogicalKeyboardKey.arrowDown),
      );
      await tester.pump();
      expect(h.focus.region, LiveFocusRegion.channels);

      h.focus.focusSearch();
      await tester.pump();
      h.focus.handleSearchCellKey(
        h.focus.searchCellFocusNode,
        keyDown(LogicalKeyboardKey.arrowUp),
      );
      expect(h.tabsFocused(), 1, reason: 'Up from search reaches the tabs');
    });
  });

  group('selection bookkeeping', () {
    test('the cursor clamps when the visible list shrinks', () {
      var visible = channels(['a', 'b', 'c', 'd']);
      final focus = LiveFocusCoordinator(
        scrollController: ScrollController(),
        categoryScrollController: ScrollController(),
        visibleChannels: () => visible,
        orderedCategoryIds: () => const [null],
        channelRowExtent: () => 100,
        categoryRowExtent: () => 48,
        isWide: () => true,
        isMounted: () => true,
        onChannelSelectionChanged: (_, _) {},
        onCategoryActivated: (_) {},
        onPlayChannel: (_) {},
        onToggleFavorite: (_) {},
        onFocusTabs: () {},
      );
      addTearDown(focus.dispose);

      focus.selectChannel(3);
      expect(focus.selectedChannelIndex, 3);

      // A search narrows the list under the cursor.
      visible = channels(['a']);
      focus.clampSelection();
      expect(focus.selectedChannelIndex, 0);
    });

    test('a number jump moves the cursor to that channel number', () {
      final h = make(visible: channels(['a', 'b', 'c'])); // numbers 1..3
      addTearDown(h.focus.dispose);

      h.focus.appendDigit(3);
      expect(h.focus.digitBuffer, '3');
      h.focus.commitDigitBuffer();

      expect(h.focus.digitBuffer, isEmpty);
      expect(h.focus.selectedChannelIndex, 2);
    });

    test('a number with no matching channel just clears the buffer', () {
      final h = make(visible: channels(['a']));
      addTearDown(h.focus.dispose);

      h.focus.appendDigit(9);
      h.focus.commitDigitBuffer();

      expect(h.focus.digitBuffer, isEmpty);
      expect(h.focus.selectedChannelIndex, 0);
    });
  });
}
