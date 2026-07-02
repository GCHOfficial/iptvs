import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/live_focus_coordinator.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Channel> channels(List<String> ids) => [
    for (final (i, id) in ids.indexed)
      Channel(id: id, name: 'Ch $id', number: i + 1),
  ];

  LiveFocusCoordinator makeCoordinator({
    List<Channel> visible = const [],
    String? categoryId,
  }) {
    return LiveFocusCoordinator(
      scrollController: ScrollController(),
      visibleChannels: () => visible,
      categoryId: () => categoryId,
      channelById: (id) =>
          visible.where((channel) => channel.id == id).firstOrNull,
      isLiveTab: () => true,
      isRouteCurrent: () => true,
      isMounted: () => true,
      onChannelFocusChanged: (_, _) {},
    );
  }

  group('channelIdFromFocusLabel', () {
    test('maps the first-channel label to the first visible id', () {
      final coordinator = makeCoordinator(visible: channels(['a', 'b']));
      addTearDown(coordinator.dispose);
      expect(
        coordinator.channelIdFromFocusLabel(
          LiveFocusCoordinator.firstChannelLabel,
        ),
        'a',
      );
    });

    test('first-channel label with no visible channels is null', () {
      final coordinator = makeCoordinator();
      addTearDown(coordinator.dispose);
      expect(
        coordinator.channelIdFromFocusLabel(
          LiveFocusCoordinator.firstChannelLabel,
        ),
        isNull,
      );
    });

    test('extracts the id from a channel label', () {
      final coordinator = makeCoordinator();
      addTearDown(coordinator.dispose);
      expect(
        coordinator.channelIdFromFocusLabel('live.channel.xyz-123'),
        'xyz-123',
      );
    });

    test('non-channel labels are null', () {
      final coordinator = makeCoordinator();
      addTearDown(coordinator.dispose);
      expect(coordinator.channelIdFromFocusLabel('live.category.all'), isNull);
      expect(coordinator.channelIdFromFocusLabel('Focus'), isNull);
      expect(coordinator.channelIdFromFocusLabel('live.channel.'), isNull);
    });
  });

  group('focusAreaFromLabel', () {
    test('classifies each pane by label scheme', () {
      final coordinator = makeCoordinator();
      addTearDown(coordinator.dispose);
      expect(
        coordinator.focusAreaFromLabel('live.category.news'),
        LiveFocusArea.category,
      );
      expect(
        coordinator.focusAreaFromLabel('live.channel.42'),
        LiveFocusArea.channels,
      );
      expect(
        coordinator.focusAreaFromLabel(LiveFocusCoordinator.searchCellLabel),
        LiveFocusArea.search,
      );
      expect(coordinator.focusAreaFromLabel('Focus'), LiveFocusArea.unknown);
      expect(
        coordinator.focusAreaFromLabel('TvTextField.cell'),
        LiveFocusArea.unknown,
      );
    });
  });

  group('focus node registry', () {
    test('returns a stable node per channel with the routing label', () {
      final coordinator = makeCoordinator(visible: channels(['a']));
      addTearDown(coordinator.dispose);
      final node = coordinator.focusNodeForChannel('a');
      expect(node.debugLabel, 'live.channel.a');
      expect(identical(coordinator.focusNodeForChannel('a'), node), isTrue);
    });

    test('category node for null id is the "all" node', () {
      final coordinator = makeCoordinator();
      addTearDown(coordinator.dispose);
      expect(
        coordinator.focusNodeForCategory(null).debugLabel,
        'live.category.all',
      );
    });
  });

  group('noteFocusedChannel', () {
    test('notifies listeners only on change', () {
      final coordinator = makeCoordinator(visible: channels(['a', 'b']));
      addTearDown(coordinator.dispose);
      var notifications = 0;
      coordinator.addListener(() => notifications++);

      coordinator.noteFocusedChannel('a');
      coordinator.noteFocusedChannel('a');
      coordinator.noteFocusedChannel('b');

      expect(coordinator.lastFocusedChannelId, 'b');
      expect(notifications, 2);
    });
  });

  group('digit-entry channel jump', () {
    test('committing typed digits focuses the matching channel number', () {
      // channels() assigns numbers 1..n in order.
      final coordinator = makeCoordinator(visible: channels(['a', 'b', 'c']));
      addTearDown(coordinator.dispose);

      coordinator.appendDigit(2);
      expect(coordinator.digitBuffer, '2');
      coordinator.commitDigitBuffer();

      expect(coordinator.digitBuffer, isEmpty);
      expect(coordinator.lastFocusedChannelId, 'b');
      expect(coordinator.lastFocusArea, LiveFocusArea.channels);
    });

    test('a number with no matching channel just clears the buffer', () {
      final coordinator = makeCoordinator(visible: channels(['a']));
      addTearDown(coordinator.dispose);

      coordinator.appendDigit(9);
      coordinator.commitDigitBuffer();

      expect(coordinator.digitBuffer, isEmpty);
      expect(coordinator.lastFocusedChannelId, isNull);
    });

    test('clearDigitBuffer cancels pending entry and notifies', () {
      final coordinator = makeCoordinator(visible: channels(['a']));
      addTearDown(coordinator.dispose);
      var notifications = 0;
      coordinator.addListener(() => notifications++);

      coordinator.appendDigit(1);
      coordinator.appendDigit(0);
      coordinator.clearDigitBuffer();

      expect(coordinator.digitBuffer, isEmpty);
      expect(coordinator.lastFocusedChannelId, isNull);
      expect(notifications, 3); // two appends + one clear
    });
  });

  testWidgets('focus node prune keeps visible + focused nodes only', (
    tester,
  ) async {
    var visible = channels(['a', 'b', 'c']);
    final coordinator = LiveFocusCoordinator(
      scrollController: ScrollController(),
      visibleChannels: () => visible,
      categoryId: () => null,
      channelById: (id) =>
          visible.where((channel) => channel.id == id).firstOrNull,
      isLiveTab: () => true,
      isRouteCurrent: () => true,
      isMounted: () => true,
      onChannelFocusChanged: (_, _) {},
    );
    addTearDown(coordinator.dispose);
    // The prune runs in a post-frame callback — give the binding a frame.
    await tester.pumpWidget(const SizedBox());

    final a = coordinator.focusNodeForChannel('a');
    coordinator.focusNodeForChannel('b');
    coordinator.focusNodeForChannel('c');

    // Filter down to only 'c'; a and b should be pruned (and disposed).
    visible = channels(['c']);
    coordinator.scheduleFocusNodePrune();
    // The prune rides the next frame; in the app the accompanying rebuild
    // schedules it — in the test we must schedule one ourselves.
    tester.binding.scheduleFrame();
    await tester.pump();

    expect(identical(coordinator.focusNodeForChannel('a'), a), isFalse);
    expect(
      coordinator.focusNodeForChannel('c').debugLabel,
      'live.channel.c',
    );
  });
}
