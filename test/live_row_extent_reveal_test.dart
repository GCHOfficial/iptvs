// The live list scrolls by exact `index * itemExtent` arithmetic, so a scroll
// offset is only correct for the extent it was computed against.
//
// Rows are 72px without an EPG line and 112 with one, and that choice can flip
// *after* the rows are on screen — most visibly in the cross-source Favorites
// view, whose guide is fetched separately and lands after the list is built.
// When it flips, the cursor is still on the right channel and the list is
// looking somewhere else, by a margin that grows with the row index. Reported
// exactly that way: the highlighted channel isn't centred, and one press of Up
// or Down snaps it back — because that press re-reveals against the extent the
// rows now actually have.
//
// These use a real attached `ScrollController`, unlike the pure coordinator
// harness: `_reveal` no-ops on a controller with no clients, so a detached one
// cannot show the bug or the fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/sources/source.dart';

const double _plainExtent = 72;
const double _epgExtent = 112;
const double _viewportHeight = 600;

List<Channel> _channels(int count) => [
  for (var i = 0; i < count; i++) Channel(id: 'c$i', name: 'Channel $i'),
];

void main() {
  /// Mounts a list driven by [controller] at [extent], the way the live tab
  /// does, and returns once it has laid out.
  Future<void> pumpList(
    WidgetTester tester,
    ScrollController controller,
    double extent,
    int count,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: _viewportHeight,
            child: ListView.builder(
              controller: controller,
              itemExtent: extent,
              itemCount: count,
              itemBuilder: (_, i) => SizedBox(height: extent, child: Text('$i')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a row-extent change re-reveals the selected row', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final channels = _channels(200);
    var extent = _plainExtent;

    final focus = LiveFocusCoordinator(
      scrollController: controller,
      categoryScrollController: ScrollController(),
      visibleChannels: () => channels,
      orderedCategoryIds: () => const [null],
      channelRowExtent: () => extent,
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

    await pumpList(tester, controller, extent, channels.length);

    // Park the cursor well down the list and let it reveal at the plain extent.
    focus.selectChannel(60);
    await tester.pumpAndSettle();
    final plainOffset = controller.offset;
    expect(
      plainOffset,
      greaterThan(0),
      reason: 'row 60 is far below the fold, so revealing it must scroll',
    );

    // The guide arrives: rows grow, and the list is rebuilt with the new
    // extent. The selection has not moved.
    extent = _epgExtent;
    await pumpList(tester, controller, extent, channels.length);

    // Without the re-reveal the offset is still the one computed for 72px
    // rows, which no longer points at row 60.
    focus.revealSelectedChannel();
    await tester.pumpAndSettle();

    // Row 60 must be fully visible at the *new* geometry.
    const top = 60 * _epgExtent;
    const bottom = top + _epgExtent;
    expect(controller.offset, lessThanOrEqualTo(top));
    expect(controller.offset + _viewportHeight, greaterThanOrEqualTo(bottom));
    expect(
      controller.offset,
      isNot(plainOffset),
      reason: 'the offset computed for the old extent cannot still be right',
    );
  });

  testWidgets('re-revealing is a no-op when the row is already in view', (
    tester,
  ) async {
    // The reveal scrolls the *minimum* amount, so a selection already on screen
    // must not jerk the list — that would fight the user mid-scroll every time
    // a late guide lands.
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final channels = _channels(200);

    final focus = LiveFocusCoordinator(
      scrollController: controller,
      categoryScrollController: ScrollController(),
      visibleChannels: () => channels,
      orderedCategoryIds: () => const [null],
      channelRowExtent: () => _epgExtent,
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

    await pumpList(tester, controller, _epgExtent, channels.length);
    focus.selectChannel(1);
    await tester.pumpAndSettle();
    expect(controller.offset, 0, reason: 'row 1 is already visible');

    focus.revealSelectedChannel();
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });

  testWidgets('re-revealing an empty list does nothing', (tester) async {
    // The cross-source view starts empty and fills in asynchronously, so this
    // runs before there is anything to reveal.
    final controller = ScrollController();
    addTearDown(controller.dispose);

    final focus = LiveFocusCoordinator(
      scrollController: controller,
      categoryScrollController: ScrollController(),
      visibleChannels: () => const <Channel>[],
      orderedCategoryIds: () => const [null],
      channelRowExtent: () => _epgExtent,
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

    await pumpList(tester, controller, _epgExtent, 0);
    focus.revealSelectedChannel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
