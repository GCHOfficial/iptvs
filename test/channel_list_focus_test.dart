// Focus-traversal regression net for ChannelListScreen.
//
// These guard the TV D-pad behaviours that unit tests can't see and that a
// refactor of the (very large) screen State can silently break: that the live
// channel cells are focusable with the expected labels, the cross-pane
// category -> channels move works, and switching content tabs swaps the body.
// They are written against the *current* (pre-split) widget so the same
// assertions can pin behaviour through the LiveTab/MoviesTab/SeriesTab split.
//
// Focus is asserted via FocusNode.debugLabel, which the screen itself already
// treats as a first-class signal (it routes D-pad logic off `primaryFocus`
// labels like `live.channel.*` / `live.category.*`).
//
// Notes on the test harness:
//  * repo.load / loadMedia run through sqflite_common_ffi (a background
//    isolate) whose futures don't advance under the widget-test fake clock, so
//    we drive the real event loop with runAsync between pumps (`pumpUntil`).
//    This also lets sqflite's in-flight transactions finish and cancel their
//    internal lock-timeout timers before the widget is disposed.
//  * The screen holds a 1-minute periodic EPG timer, so we never pumpAndSettle;
//    tests unmount at the end so State.dispose cancels it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/focusable_card.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

// Set to true in setUpAll when libmpv is available; tests skip otherwise.
bool _mediaKitAvailable = false;

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUpAll(() {
    // The wide live layout builds an inline preview player (media_kit); it must
    // be able to construct headless. libmpv-2.dll is only present when running
    // from a full Windows build directory, not in a plain `flutter test` run,
    // so we catch the failure and skip the tests below rather than hard-failing.
    try {
      MediaKit.ensureInitialized();
      _mediaKitAvailable = true;
    } catch (_) {
      // libmpv not in PATH — tests will be skipped.
    }
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_focus_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const config = SourceConfig(
    id: 'demo',
    kind: SourceKind.demo,
    label: 'Demo',
    fields: {},
  );

  // Alternate real-loop progress (runAsync) with fake-clock pumps until [until]
  // matches or we give up. Lets sqflite/ffi futures resolve and post-frame
  // focus callbacks land without pumpAndSettle (blocked by the EPG timer).
  Future<void> pumpUntil(WidgetTester tester, Finder until) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (until.evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  // Pump the screen in a wide (TV/desktop) layout so the side-by-side category
  // pane + channel list are present, then let the async load settle.
  Future<void> pumpWideScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: DemoSource(), db: db);
    await tester.pumpWidget(
      MaterialApp(home: ChannelListScreen(repo: repo, config: config)),
    );
    // "Playlists" is the live category pane header — present once loaded.
    await pumpUntil(tester, find.text('Playlists'));
  }

  // Unmount so State.dispose runs (cancels the EPG timer, disposes the preview
  // player) before the binding's pending-timer check.
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  FocusableCard cardByLabel(WidgetTester tester, String label) => tester
      .widgetList<FocusableCard>(find.byType(FocusableCard))
      .firstWhere((c) => c.debugLabel == label);

  String? focusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  // Wrapper that skips when libmpv is not present in the test environment.
  void focusTestWidgets(String description, WidgetTesterCallback callback) {
    testWidgets(description, (tester) async {
      if (!_mediaKitAvailable) {
        markTestSkipped('libmpv not available in this environment');
        return;
      }
      await callback(tester);
    });
  }

  focusTestWidgets('the first live channel cell is focusable with its label',
      (tester) async {
    await pumpWideScreen(tester);

    // The first channel carries the dedicated 'live.channel.first' node (the
    // D-pad "home" of the channel list) as its *focus node* (the card's own
    // debugLabel is the channel id). Requesting focus on it must land.
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();

    expect(focusLabel(), 'live.channel.first');

    await unmount(tester);
  });

  focusTestWidgets('ArrowRight from a category moves focus to the channel list',
      (tester) async {
    await pumpWideScreen(tester);

    // Focus the (selected) "All" category cell explicitly, so the test does not
    // depend on where the contested load-time autofocus happened to settle.
    final allCategory = cardByLabel(tester, 'live.category.all');
    expect(
      allCategory.focusNode,
      isNotNull,
      reason: 'selected category should carry the external focus node',
    );
    allCategory.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), startsWith('live.category.'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      focusLabel() ?? '',
      startsWith('live.channel.'),
      reason: 'ArrowRight from the category pane should focus a channel',
    );

    await unmount(tester);
  });

  focusTestWidgets('ArrowLeft from a channel moves focus back to the category pane',
      (tester) async {
    // The reverse of the cross-pane move above (channel -> category); guards
    // _ChannelTile's onMoveLeftToCategory wiring through _focusCategoryFromChannels.
    await pumpWideScreen(tester);
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.channel.first');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      focusLabel() ?? '',
      startsWith('live.category.'),
      reason: 'ArrowLeft from a channel should focus the category pane',
    );

    await unmount(tester);
  });

  focusTestWidgets('ArrowDown moves focus down the channel list', (tester) async {
    // Guards the channel-list D-pad navigation (_moveDownInLiveChannels): from
    // the first channel, ArrowDown lands on a different (non-first) channel.
    await pumpWideScreen(tester);
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.channel.first');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final label = focusLabel() ?? '';
    expect(label, startsWith('live.channel.'));
    expect(
      label,
      isNot('live.channel.first'),
      reason: 'ArrowDown should advance to the next channel',
    );

    await unmount(tester);
  });

  focusTestWidgets('ArrowDown from the last channel wraps back to the first',
      (tester) async {
    // Guards the wrap branch of _moveDownInLiveChannels (nextIndex == 0): from
    // the last visible channel, ArrowDown returns to live.channel.first — the
    // path that jumps the list to the top and re-requests focus post-frame.
    // DemoSource has 4 channels, all visible in the wide layout.
    await pumpWideScreen(tester);
    final lastChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .lastWhere(
          (c) =>
              (c.focusNode?.debugLabel?.startsWith('live.channel.') ?? false) &&
              c.focusNode?.debugLabel != 'live.channel.first',
        );
    lastChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), startsWith('live.channel.'));
    expect(focusLabel(), isNot('live.channel.first'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      focusLabel(),
      'live.channel.first',
      reason: 'ArrowDown from the last channel should wrap to the first',
    );

    await unmount(tester);
  });

  focusTestWidgets('switching to the Series tab swaps out the live pane',
      (tester) async {
    await pumpWideScreen(tester);

    // The category side-pane is live-only; its "Playlists" header marks the
    // live tab.
    expect(find.text('Playlists'), findsOneWidget);

    await tester.tap(find.text('Series'));
    await tester.pump(); // apply the tab-switch setState
    expect(
      find.text('Playlists'),
      findsNothing,
      reason: 'live category pane should be gone on a media tab',
    );

    // Let the media load finish (the DemoSource series appears) so sqflite's
    // in-flight transaction — and its lock-timeout timer — completes before we
    // dispose the tree.
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);

    await unmount(tester);
  });

  focusTestWidgets('media tab content survives switching tabs and back',
      (tester) async {
    // Guards the "state persists across tab switches" behaviour that the split
    // into per-kind media tabs must preserve: after visiting Series, leaving to
    // another tab, and returning, the series content is still there.
    await pumpWideScreen(tester);

    await tester.tap(find.text('Series'));
    await tester.pump();
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);

    // Leave to Movies, then back to Live, then back to Series.
    await tester.tap(find.text('Movies'));
    await tester.pump();
    await pumpUntil(tester, find.text('Live'));
    await tester.tap(find.text('Live'));
    await tester.pump();
    await pumpUntil(tester, find.text('Playlists'));
    expect(find.text('Playlists'), findsOneWidget);

    await tester.tap(find.text('Series'));
    await tester.pump();
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(
      find.text('Codec Test Series'),
      findsOneWidget,
      reason: 'series content should return after round-tripping tabs',
    );

    await unmount(tester);
  });

  focusTestWidgets('search filters the media grid', (tester) async {
    // Guards the media search path (query -> _visibleMedia filtering) that the
    // controller move must preserve. DemoSource series is titled
    // "Codec Test Series"; a non-matching query empties the grid, a matching
    // one restores it.
    await pumpWideScreen(tester);
    await tester.tap(find.text('Series'));
    await tester.pump();
    await pumpUntil(tester, find.text('Codec Test Series'));

    // Enter the search box (TvTextField is an "OK to edit" cell), type a
    // non-matching query.
    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzzznomatch');
    // Past the 450ms search debounce, then let it settle.
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('No series match'));
    expect(find.text('Codec Test Series'), findsNothing);

    // A matching query brings it back.
    await tester.enterText(find.byType(TextField), 'Codec');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);

    await unmount(tester);
  });

  focusTestWidgets(
      'Back peels channel -> category -> tabs, then exits only on double-Back',
      (tester) async {
    // Guards the TV Back ladder end-to-end: from the channel list Back climbs
    // to the sidebar, then to the tabs, and from the top the app exits only on
    // a second Back inside the confirmation window (a first Back shows the
    // "Press Back again to exit" snackbar and must NOT call
    // SystemNavigator.pop).
    final popMethods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        popMethods.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpWideScreen(tester);
    // Focus the first channel explicitly (the load-time autofocus is
    // contested; see the other tests).
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.channel.first');

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await tester.pump();
    }

    // Channel list (not scrolled deep) -> the selected category ("All
    // channels" — the default selection).
    await back();
    expect(focusLabel(), 'live.category.all');

    // "All channels" -> the content-kind tabs.
    await back();
    expect(focusLabel(), 'content.tab.live');

    // Top of the ladder: first Back arms the confirmation, no exit yet.
    await back();
    expect(find.text('Press Back again to exit'), findsOneWidget);
    expect(popMethods, isNot(contains('SystemNavigator.pop')));

    // Second Back inside the window exits.
    await back();
    expect(popMethods, contains('SystemNavigator.pop'));

    await unmount(tester);
  });
}
