// Focus-traversal regression net for ChannelListScreen.
//
// These guard the TV D-pad behaviours that unit tests can't see and that a
// refactor of the (very large) screen State can silently break: that the live
// channel cells are focusable with the expected labels, the cross-pane
// category -> channels move works, and switching content tabs swaps the body.
// They are written against the *current* (pre-split) widget so the same
// assertions can pin behaviour through the LiveTab/MoviesTab/SeriesTab split.
//
// Focus is asserted via RoutedFocusNode.routeKey (read through focusRouteKey),
// the release-safe signal the screen routes D-pad logic off (`live.channel.*` /
// `live.category.*`). Reading routeKey — not debugLabel — means these tests
// exercise the exact path release builds use, so a regression to a debug-only
// key fails here instead of passing in debug and breaking on real hardware.
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
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/focusable_card.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
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
  Future<void> pumpWideScreenWith(WidgetTester tester, Source source) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: source, db: db);
    await tester.pumpWidget(
      MaterialApp(home: ChannelListScreen(repo: repo, config: config)),
    );
    // "Playlists" is the live category pane header — present once loaded.
    await pumpUntil(tester, find.text('Playlists'));
  }

  Future<void> pumpWideScreen(WidgetTester tester) =>
      pumpWideScreenWith(tester, DemoSource());

  // Pump the screen in a narrow (phone) layout: no category side-pane, no
  // inline preview panel — just the channel list. Used to exercise the phone
  // Up-from-first-channel wrap (which lands on the last, off-screen, row).
  Future<void> pumpNarrowScreenWith(WidgetTester tester, Source source) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: source, db: db);
    await tester.pumpWidget(
      MaterialApp(home: ChannelListScreen(repo: repo, config: config)),
    );
    // The first channel row marks a loaded live list (no "Playlists" pane here).
    await pumpUntil(tester, find.text('Channel 0'));
  }

  // Pump a handful of frames so a coordinator focus move that jump-scrolls an
  // off-screen row into range (post-frame focus + retry) can converge.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  // Unmount so State.dispose runs (cancels the EPG timer, disposes the preview
  // player) before the binding's pending-timer check.
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  FocusableCard cardByLabel(WidgetTester tester, String label) => tester
      .widgetList<FocusableCard>(find.byType(FocusableCard))
      .firstWhere((c) => c.debugLabel == label);

  String focusLabel() => focusRouteKey(FocusManager.instance.primaryFocus);

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
      focusLabel(),
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
      focusLabel(),
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

    final label = focusLabel();
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

  focusTestWidgets(
      'Back peels correctly immediately after selecting a category',
      (tester) async {
    // Regression for "Back does nothing after freshly selecting a category
    // until you scroll the channel list once": selecting a category must land
    // focus on the routed category node (not an unlabeled/channel node), so the
    // Back ladder can peel category -> All -> tabs right away.
    await pumpWideScreen(tester);

    // Select the "Test streams" category (DemoSource's only live category).
    await tester.tap(find.text('Test streams'));
    await tester.pump();
    // Let the post-frame focusCategory reassert converge onto the category node
    // (it re-requests focus for a few frames to win the autofocus/scroll race).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      focusLabel(),
      startsWith('live.category.'),
      reason: 'selecting a category should leave focus on its routed node',
    );

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await tester.pump();
    }

    // Specific category -> "All channels".
    await back();
    expect(focusLabel(), 'live.category.all');
    // "All channels" -> the content-kind tabs.
    await back();
    expect(focusLabel(), 'content.tab.live');

    await unmount(tester);
  });

  focusTestWidgets(
      'Back recovers to the tabs from unlabeled focus instead of exiting',
      (tester) async {
    // Regression for "directional keys break Back": arrowing onto an un-routed
    // node (toolbar / AppBar action / category dropdown) leaves
    // focusRouteKey == '', which the Back ladder must treat as "recover to the
    // tabs", not "top of the ladder -> exit".
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

    // Drop routed focus so focusRouteKey reads '' — the state an un-routed
    // toolbar/AppBar node produces.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(focusLabel(), '');

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await tester.pump();
    }

    await back();
    expect(
      focusLabel(),
      'content.tab.live',
      reason: 'Back from unlabeled focus should recover to the tabs',
    );
    expect(popMethods, isNot(contains('SystemNavigator.pop')));

    await unmount(tester);
  });

  // ── Long-list D-pad cases (need a source DemoSource can't provide) ──────────
  // DemoSource has 1 category / 4 channels, so its sidebar never scrolls and
  // Down-past-the-last-category never overflows. These use _ManySource (30
  // categories, 12 channels) to pin the containment + off-screen focus-landing
  // behaviour behind the two reported bugs.

  focusTestWidgets(
      'category Up/Down wrap within the sidebar and never spill into channels',
      (tester) async {
    await pumpWideScreenWith(tester, _ManySource());
    cardByLabel(tester, 'live.category.all').focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.category.all');

    // Up from the first entry wraps to the LAST category — off-screen in the
    // tall sidebar, so this also exercises the scroll-into-view landing.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(
      focusLabel(),
      'live.category.cat29',
      reason: 'Up at the first category should wrap to the last',
    );

    // Down from the last category wraps back to All — the reported bug was that
    // it jumped into the channel pane instead.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(
      focusLabel(),
      'live.category.all',
      reason: 'Down at the last category wraps to All, never a channel',
    );
    expect(focusLabel(), isNot(startsWith('live.channel.')));

    await unmount(tester);
  });

  focusTestWidgets('Back peels after selecting an off-screen category',
      (tester) async {
    // Problem 1 on real (long) lists: selecting a category whose sidebar node
    // is scrolled out of build range must still land focus on it (not no-op),
    // so the Back ladder can peel category -> All -> tabs.
    await pumpWideScreenWith(tester, _ManySource());
    cardByLabel(tester, 'live.category.all').focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // wrap to cat29
    await settle(tester);
    expect(focusLabel(), 'live.category.cat29');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // select it (OK)
    await settle(tester);
    expect(
      focusLabel(),
      'live.category.cat29',
      reason: 'selecting an off-screen category lands focus on its routed node',
    );

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await settle(tester);
    }

    await back();
    expect(focusLabel(), 'live.category.all');
    await back();
    expect(focusLabel(), 'content.tab.live');

    await unmount(tester);
  });

  focusTestWidgets('returning from channels lands on the last-focused category',
      (tester) async {
    await pumpWideScreenWith(tester, _ManySource());
    cardByLabel(tester, 'live.category.all').focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // focus cat29
    await settle(tester);
    expect(focusLabel(), 'live.category.cat29');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // into channels
    await settle(tester);
    expect(focusLabel(), startsWith('live.channel.'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // back out
    await settle(tester);
    expect(
      focusLabel(),
      'live.category.cat29',
      reason: 'Left from channels returns to the category the user was on',
    );

    await unmount(tester);
  });

  focusTestWidgets(
      'channel ArrowUp reaches the preview controls, then the search box; Back peels to categories',
      (tester) async {
    await pumpWideScreenWith(tester, _ManySource());
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.channel.first');

    // Up from the first channel lands on the preview panel's Favorite control —
    // the only TV-reachable way to favorite a live channel.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(focusLabel(), 'live.preview.favorite');

    // Back from the preview controls peels cleanly to the category sidebar (not
    // mid-list — it must NOT wrap to the last channel).
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(focusLabel(), startsWith('live.category.'));

    // Return to the preview Favorite and press Up: it now climbs out of the
    // channel column to the toolbar's search box (directly above the preview
    // panel), so search/tabs are reachable by D-pad from here.
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(focusLabel(), 'live.preview.favorite');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect(focusLabel(), 'live.search.cell');

    await unmount(tester);
  });

  focusTestWidgets(
      'OK-hold opens the D-pad-navigable channel menu; a quick OK does not',
      (tester) async {
    // The wide-layout path to favorite the focused channel without scrolling up
    // to the preview panel: hold OK to open a menu on that channel.
    await pumpWideScreenWith(tester, _ManySource());
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.channel.first');

    // A quick OK (down→up well under the hold threshold) must NOT open the menu
    // — it activates the tile exactly as before, so the TV play/preview gesture
    // is untouched.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600)); // past the hold window
    expect(
      find.text('Add to favorites'),
      findsNothing,
      reason: 'a quick OK press must not open the context menu',
    );

    // Hold OK past the threshold → the context menu opens on that channel.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 550)); // hold fires the timer
    await tester.pump(const Duration(milliseconds: 250)); // dialog transition
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(
      find.text('Play'),
      findsOneWidget,
      reason: 'OK-hold opens the channel context menu',
    );
    expect(find.text('Add to favorites'), findsOneWidget);
    expect(
      find.text('Catch-up'),
      findsNothing,
      reason: 'this channel has no archive → no Catch-up entry',
    );

    // Fully D-pad navigable: the first action autofocuses and Down moves between
    // actions (proper TV-remote navigability inside the menu).
    expect(focusLabel(), 'channel.menu.Play');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focusLabel(),
      'channel.menu.Add to favorites',
      reason: 'Down moves between menu actions',
    );

    // Back closes the menu and returns to the channel (its scroll spot).
    await tester.binding.handlePopRoute();
    await tester.pump(); // start the pop
    await tester.pump(const Duration(milliseconds: 300)); // finish dismiss anim
    expect(find.text('Add to favorites'), findsNothing);

    await unmount(tester);
  });

  focusTestWidgets(
      'narrow layout: ArrowUp from the first channel lands on the last (no limbo)',
      (tester) async {
    // The phone/narrow layout has no preview controls above the list, so Up
    // from the first channel wraps to the last. On a list long enough that the
    // last row is off-screen, focus must actually LAND on it (the hardened
    // jump-scroll + reassert) rather than sit in limbo with no row highlighted —
    // the reported "focused no channel for some time" symptom.
    await pumpNarrowScreenWith(tester, _ManySource());
    final firstChannel = tester
        .widgetList<FocusableCard>(find.byType(FocusableCard))
        .firstWhere((c) => c.focusNode?.debugLabel == 'live.channel.first');
    firstChannel.focusNode!.requestFocus();
    await tester.pump();
    expect(focusLabel(), 'live.channel.first');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);

    expect(
      focusLabel(),
      'live.channel.ch11',
      reason: 'Up from the first channel should land on the last, not limbo',
    );

    await unmount(tester);
  });

  focusTestWidgets('initial focus lands in the channel list, not a category',
      (tester) async {
    // With the contested dual-autofocus removed, the first channel is the sole
    // autofocus, so OK plays immediately on entry.
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    expect(focusLabel(), startsWith('live.channel.'));

    await unmount(tester);
  });
}

/// A live-only fake with enough categories to scroll the sidebar (30) and
/// enough channels to navigate (12) — the conditions DemoSource can't create,
/// where the category→channel overflow and off-screen focus-landing bugs live.
/// Channels are split between the first and last category so both are
/// non-empty (selecting an empty category would hide the sidebar entirely).
class _ManySource implements Source {
  static final List<Category> _cats = [
    for (var i = 0; i < 30; i++) Category(id: 'cat$i', title: 'Category $i'),
  ];
  static final List<Channel> _chans = [
    for (var i = 0; i < 12; i++)
      Channel(
        id: 'ch$i',
        name: 'Channel $i',
        categoryId: i < 6 ? 'cat0' : 'cat29',
        number: i + 1,
      ),
  ];

  @override
  String get id => 'many';

  @override
  String get name => 'Many';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => _cats;

  @override
  Future<List<Channel>> channels({String? categoryId}) async => _chans;

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('no catch-up');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: const [], page: page, totalPages: page);

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('not playable');

  @override
  Future<DateTime?> subscriptionExpiry() async => null;

  @override
  Future<void> dispose() async {}
}
