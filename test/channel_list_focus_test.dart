// D-pad regression net for ChannelListScreen's live tab.
//
// The live channel list and category sidebar are **selection models**: each has
// a single focus node (`live.channels` / `live.categories`) and a selected index
// that drives the highlight and the scroll. Rows are not focus targets. These
// tests drive real key events through the focus system and pin the contract:
//
//   * **Down wraps** at the end of both lists — the only infinite motion.
//   * **Up never wraps**: at the first row it escapes upward (channels → the
//     preview controls, or the search box on a phone; categories → the search
//     box). The old per-row-focus design wrapped Up in the sidebar, which is
//     what left users "stuck in the categories".
//   * The Back ladder peels exactly one rung per press:
//     channel list → first channel → categories → first category → search →
//     section tabs → exit confirmation → exit.
//
// Focus is asserted via RoutedFocusNode.routeKey (through focusRouteKey), the
// release-safe signal the screen routes off — debugLabel is null in release.
//
// Harness notes:
//  * repo.load runs through sqflite_common_ffi (a background isolate) whose
//    futures don't advance under the widget-test fake clock, so we drive the
//    real event loop with runAsync between pumps (`pumpUntil`).
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
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

// Set to true in setUpAll when libmpv is available; tests skip otherwise.
bool _mediaKitAvailable = false;

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUpAll(() {
    // The wide live layout builds an inline preview player (media_kit); it must
    // be able to construct headless. libmpv is only present when running from a
    // full build directory, not in a plain `flutter test` run, so we catch the
    // failure and skip rather than hard-failing.
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

  Future<void> pumpWideScreenWith(
    WidgetTester tester,
    Source source, {
    Size size = const Size(1600, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: source, db: db);
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelListScreen(repo: repo, config: config),
      ),
    );
    // "Playlists" is the live category pane header — present once loaded.
    await pumpUntil(tester, find.text('Playlists'));
  }

  Future<void> pumpWideScreen(WidgetTester tester) =>
      pumpWideScreenWith(tester, DemoSource());

  Future<void> pumpNarrowScreenWith(WidgetTester tester, Source source) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = LibraryRepository(source: source, db: db);
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelListScreen(repo: repo, config: config),
      ),
    );
    await pumpUntil(tester, find.text('Channel 0'));
  }

  /// Let the selection reveal's scroll animation (140ms) land.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// One D-pad press. Light pump — call [settle] before asserting on scroll.
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> pressTimes(
    WidgetTester tester,
    LogicalKeyboardKey key,
    int times,
  ) async {
    for (var i = 0; i < times; i++) {
      await press(tester, key);
    }
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  String focusLabel() => focusRouteKey(FocusManager.instance.primaryFocus);

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
    await settle(tester);
  }

  void focusTestWidgets(String description, WidgetTesterCallback callback) {
    testWidgets(description, (tester) async {
      if (!_mediaKitAvailable) {
        markTestSkipped('libmpv not available in this environment');
        return;
      }
      await callback(tester);
    });
  }

  // ── Entry ──────────────────────────────────────────────────────────────────

  focusTestWidgets('the channel list owns the D-pad on entry', (tester) async {
    // The list autofocuses so OK plays immediately — the tabs never autofocus.
    await pumpWideScreen(tester);
    await settle(tester);

    expect(focusLabel(), 'live.channels');

    await unmount(tester);
  });

  // ── Channel list: Down wraps, Up escapes ───────────────────────────────────

  focusTestWidgets('Down walks the channel list and wraps past the last row', (
    tester,
  ) async {
    // _ManySource has 12 channels, more than fit the viewport, so the cursor
    // genuinely scrolls the list.
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    expect(focusLabel(), 'live.channels');
    // NB: "Channel 0" also appears in the preview panel, so it can't mark the
    // list's scroll position — row 1 can.
    expect(find.text('Channel 1'), findsOneWidget);

    // Walk down far enough that the top of the list is scrolled away.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 10);
    expect(
      find.text('Channel 1'),
      findsNothing,
      reason: 'the cursor drove the list past its first rows',
    );
    expect(focusLabel(), 'live.channels');

    // Two more presses take the cursor past the last row (index 11) — it wraps
    // back to the top. This is the one infinite motion in the tab.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 2);
    expect(
      find.text('Channel 1'),
      findsOneWidget,
      reason: 'Down past the last channel wraps to the first',
    );
    expect(
      focusLabel(),
      'live.channels',
      reason: 'the wrap must never leak focus into the categories',
    );

    await unmount(tester);
  });

  focusTestWidgets(
    'Up at the first channel escapes to the preview controls — it never wraps',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);

      expect(focusLabel(), 'live.preview.favorite');
      expect(
        find.text('Channel 1'),
        findsOneWidget,
        reason: 'Up must not fling the list to its bottom (no wrap-around)',
      );

      await unmount(tester);
    },
  );

  focusTestWidgets(
    'narrow layout: Up at the first channel escapes to the search box',
    (tester) async {
      // A phone has no sidebar and no preview panel, so the row above the list is
      // the search box. It still must not wrap to the last channel.
      await pumpNarrowScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);

      expect(focusLabel(), 'live.search.cell');
      expect(find.text('Channel 0'), findsOneWidget);

      await unmount(tester);
    },
  );

  // ── Cross-pane ─────────────────────────────────────────────────────────────

  focusTestWidgets('Left crosses to the categories and Right crosses back', (
    tester,
  ) async {
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    expect(focusLabel(), 'live.channels');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');

    await press(tester, LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(focusLabel(), 'live.channels');

    await unmount(tester);
  });

  // ── Category sidebar: Down wraps, Up escapes (the "stuck" fix) ─────────────

  focusTestWidgets(
    'Up at the first category escapes to the search box — the "stuck in the '
    'categories" fix',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(focusLabel(), 'live.categories');
      expect(find.text('All channels'), findsOneWidget);

      // The cursor starts on "All channels" (index 0). The old model wrapped Up
      // to the last category here, so the only ways out were Right or Back.
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);

      expect(focusLabel(), 'live.search.cell');
      expect(
        find.text('All channels'),
        findsOneWidget,
        reason: 'Up must not wrap the sidebar to its bottom',
      );

      await unmount(tester);
    },
  );

  focusTestWidgets('Down wraps at the end of the category sidebar', (
    tester,
  ) async {
    // _ManySource has 30 categories + "All channels" = 31 rows.
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');
    expect(find.text('All channels'), findsOneWidget);

    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 20);
    expect(
      find.text('All channels'),
      findsNothing,
      reason: 'the cursor scrolled the sidebar past its first row',
    );
    expect(
      focusLabel(),
      'live.categories',
      reason: 'Down must never spill out of the sidebar',
    );

    // 11 more presses take the cursor past the last category → wraps to the top.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 11);
    expect(
      find.text('All channels'),
      findsOneWidget,
      reason: 'Down past the last category wraps to the first',
    );

    await unmount(tester);
  });

  focusTestWidgets('OK filters a category and enters its first channel', (
    tester,
  ) async {
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');

    // cat29 is the final category and contains Channel 6–11. Walking there
    // proves OK changes the data set, not merely the sidebar highlight.
    await pressTimes(tester, LogicalKeyboardKey.arrowDown, 30);
    await press(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    expect(focusLabel(), 'live.channels');
    expect(
      find.text('Channel 6'),
      findsWidgets,
      reason: 'the filtered first channel appears in the row and preview panel',
    );
    expect(find.text('Channel 0'), findsNothing);

    await unmount(tester);
  });

  // ── Search box ─────────────────────────────────────────────────────────────

  focusTestWidgets(
    'the search box drops into the channels and climbs to the tabs',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);

      // Reach the search box from the sidebar (Up at the first category).
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusLabel(), 'live.search.cell');

      // Down goes back into the content.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Up from search reaches the section tabs — the ceiling.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusLabel(), 'live.search.cell');
      await press(tester, LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(focusLabel(), 'content.tab.live');

      await unmount(tester);
    },
  );

  // ── The Back ladder ────────────────────────────────────────────────────────

  focusTestWidgets(
    'Back peels: channel -> first channel -> categories -> first category -> '
    'search -> tabs -> exit',
    (tester) async {
      final popMethods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          popMethods.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Walk the cursor down the list so the top of the list scrolls away.
      await pressTimes(tester, LogicalKeyboardKey.arrowDown, 10);
      expect(find.text('Channel 1'), findsNothing);

      // Rung 1: Back returns the cursor to the first channel (still in the list).
      await back(tester);
      expect(focusLabel(), 'live.channels');
      expect(
        find.text('Channel 1'),
        findsOneWidget,
        reason: 'the first Back resets the cursor to the first channel',
      );

      // Rung 2: from the first channel, Back leaves the list for the sidebar.
      await back(tester);
      expect(focusLabel(), 'live.categories');

      // Walk the category cursor down, then Rung 3: Back returns it to the first
      // category ("All channels") without leaving the sidebar.
      await pressTimes(tester, LogicalKeyboardKey.arrowDown, 20);
      expect(find.text('All channels'), findsNothing);
      await back(tester);
      expect(focusLabel(), 'live.categories');
      expect(
        find.text('All channels'),
        findsOneWidget,
        reason: 'Back resets the category cursor to the first row',
      );

      // Rung 4: from the first category, Back peels to the search box.
      await back(tester);
      expect(focusLabel(), 'live.search.cell');

      // Rung 5: search → the section tabs.
      await back(tester);
      expect(focusLabel(), 'content.tab.live');

      // Top of the ladder: the first Back arms the confirmation, no exit yet.
      await back(tester);
      expect(find.text('Press Back again to exit'), findsOneWidget);
      expect(popMethods, isNot(contains('SystemNavigator.pop')));

      // A second Back inside the window exits.
      await back(tester);
      expect(popMethods, contains('SystemNavigator.pop'));

      await unmount(tester);
    },
  );

  focusTestWidgets('the cursor visibly hands over between the panes', (
    tester,
  ) async {
    // The cursor is drawn from each list's `hasFocus`, but a focus change
    // rebuilds nothing on its own — so the accent used to stay stuck in the
    // channel list after Left/Back moved the D-pad to the categories, and the
    // user couldn't see where they were.
    await pumpWideScreenWith(tester, _ManySource());
    await settle(tester);

    // Row 0's name also appears in the preview panel, so drive the cursor to
    // row 1 to keep the finder unambiguous.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await settle(tester);

    Color? borderOf(Finder text) {
      final container = tester.widget<AnimatedContainer>(
        find.ancestor(of: text, matching: find.byType(AnimatedContainer)).first,
      );
      final border = (container.decoration! as BoxDecoration).border;
      return (border! as Border).top.color;
    }

    // The channel list owns the D-pad: its cursor is accented, the sidebar's isn't.
    expect(borderOf(find.text('Channel 1')), AppColors.accent);
    expect(borderOf(find.text('All channels')), isNot(AppColors.accent));

    // Left hands the D-pad to the categories — the accent must move with it.
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(focusLabel(), 'live.categories');
    expect(borderOf(find.text('All channels')), AppColors.accent);
    expect(
      borderOf(find.text('Channel 1')),
      isNot(AppColors.accent),
      reason:
          'the channel list must not keep the accent once it loses the D-pad',
    );

    await unmount(tester);
  });

  focusTestWidgets(
    'Back from the top toolbar offers to exit, not the sections',
    (tester) async {
      // The AppBar/toolbar buttons are plain IconButtons with no route key. They
      // sit *above* the ladder, so Back there should offer to exit rather than
      // dropping focus back down into the sections to be climbed out of again.
      final popMethods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          popMethods.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpWideScreen(tester);
      await settle(tester);

      // Focus an AppBar action.
      Focus.of(
        tester.element(find.byIcon(Icons.bug_report_outlined)),
      ).requestFocus();
      await tester.pump();
      expect(focusLabel(), '', reason: 'chrome buttons carry no route key');

      await back(tester);
      expect(
        find.text('Press Back again to exit'),
        findsOneWidget,
        reason: 'Back from the chrome goes straight to the exit prompt',
      );
      expect(popMethods, isNot(contains('SystemNavigator.pop')));

      await back(tester);
      expect(popMethods, contains('SystemNavigator.pop'));

      await unmount(tester);
    },
  );

  focusTestWidgets(
    'Back recovers to the tabs from unlabeled focus instead of exiting',
    (tester) async {
      // Arrowing onto an un-routed node (toolbar / AppBar action) leaves
      // focusRouteKey == '', which the ladder must treat as "recover to the tabs",
      // not "top of the ladder → exit".
      final popMethods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          popMethods.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpWideScreen(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(focusLabel(), '');

      await back(tester);
      expect(
        focusLabel(),
        'content.tab.live',
        reason: 'Back from unlabeled focus should recover to the tabs',
      );
      expect(popMethods, isNot(contains('SystemNavigator.pop')));

      await unmount(tester);
    },
  );

  // ── The per-row favorite star (intra-row action cursor) ────────────────────

  focusTestWidgets(
    'Right highlights the row\'s favorite star and OK toggles it',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Row 0's name also appears in the preview panel, so drive the cursor to
      // row 1 to keep the finders unambiguous.
      await press(tester, LogicalKeyboardKey.arrowDown);
      await settle(tester);

      Finder rowOf(String name) => find
          .ancestor(
            of: find.text(name),
            matching: find.byType(AnimatedContainer),
          )
          .first;
      Finder starIconIn(String name) => find.descendant(
        of: rowOf(name),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == Icons.star_rounded ||
                  w.icon == Icons.star_outline_rounded),
        ),
      );
      // The star cell is the icon's nearest enclosing Container; its border is
      // the intra-row cursor's accent ring.
      Color? starBorderOf(String name) {
        final container = tester.widget<Container>(
          find
              .ancestor(of: starIconIn(name), matching: find.byType(Container))
              .first,
        );
        final border = (container.decoration as BoxDecoration?)?.border;
        return (border as Border?)?.top.color;
      }

      // Every row carries a visible star; the cursor starts on the row body, so
      // no accent ring on the star yet.
      expect(starIconIn('Channel 1'), findsOneWidget);
      expect(starBorderOf('Channel 1'), isNull);

      // Right enters the row's favorite column — the star gets the accent ring
      // and the D-pad stays in the channel list (no pane change).
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusLabel(), 'live.channels');
      expect(starBorderOf('Channel 1'), AppColors.accent);

      // OK toggles the favorite in place: the outline star fills in.
      await press(tester, LogicalKeyboardKey.select);
      await pumpUntil(
        tester,
        find.descendant(
          of: rowOf('Channel 1'),
          matching: find.byIcon(Icons.star_rounded),
        ),
      );
      expect(
        tester.widget<Icon>(starIconIn('Channel 1')).icon,
        Icons.star_rounded,
      );
      expect(
        find.text('Add to favorites'),
        findsNothing,
        reason: 'no dialog: favoriting is in place now',
      );

      // Left peels the cursor back onto the row body before crossing panes.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(starBorderOf('Channel 1'), isNull);
      expect(focusLabel(), 'live.channels');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(focusLabel(), 'live.categories');

      await unmount(tester);
    },
  );

  focusTestWidgets(
    'channel and category rows expose selection, position, and actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);

      final firstChannel = find.bySemanticsLabel(
        'Channel 0, 1 of 12, Not favorite',
      );
      expect(firstChannel, findsOneWidget);
      expect(
        tester.getSemantics(firstChannel),
        matchesSemantics(
          label: 'Channel 0, 1 of 12, Not favorite',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );

      const allChannelsLabel = 'All channels, 1 of 31';
      final allChannels = find.bySemanticsLabel(allChannelsLabel);
      expect(allChannels, findsOneWidget);
      expect(
        tester.getSemantics(allChannels),
        matchesSemantics(
          label: allChannelsLabel,
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );

      semantics.dispose();
      await unmount(tester);
    },
  );

  focusTestWidgets(
    'dismissing the phone preview sheet restores the channel-list focus',
    (tester) async {
      await pumpNarrowScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      await tester.longPress(find.text('Channel 0'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Play fullscreen'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);

      expect(find.text('Play fullscreen'), findsNothing);
      expect(focusLabel(), 'live.channels');

      await unmount(tester);
    },
  );

  focusTestWidgets(
    'Back mirrors Left: it peels the favorite column before the first-row rung',
    (tester) async {
      await pumpWideScreenWith(tester, _ManySource());
      await settle(tester);
      expect(focusLabel(), 'live.channels');

      // Walk the cursor down the list, then onto row 10's star, so both peels
      // are observable (the row cursor must survive the first Back).
      await pressTimes(tester, LogicalKeyboardKey.arrowDown, 10);
      expect(find.text('Channel 1'), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await settle(tester);

      // Back #1: off the star, back onto the row body — the row cursor (and the
      // scroll position) must not move.
      await back(tester);
      expect(focusLabel(), 'live.channels');
      expect(
        find.text('Channel 1'),
        findsNothing,
        reason: 'peeling the star column must not reset the row cursor',
      );

      // Back #2: now the normal first-channel rung runs.
      await back(tester);
      expect(focusLabel(), 'live.channels');
      expect(find.text('Channel 1'), findsOneWidget);

      await unmount(tester);
    },
  );

  // ── Tabs / media (unchanged behaviour, still guarded) ──────────────────────

  focusTestWidgets('switching to the Series tab swaps out the live pane', (
    tester,
  ) async {
    await pumpWideScreen(tester);
    expect(find.text('Playlists'), findsOneWidget);

    await tester.tap(find.text('Series'));
    await tester.pump();
    expect(
      find.text('Playlists'),
      findsNothing,
      reason: 'live category pane should be gone on a media tab',
    );

    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);

    await unmount(tester);
  });

  focusTestWidgets('media tab content survives switching tabs and back', (
    tester,
  ) async {
    await pumpWideScreen(tester);

    await tester.tap(find.text('Series'));
    await tester.pump();
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);

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

  // ── Row extent ─────────────────────────────────────────────────────────────

  focusTestWidgets('a channel row carrying EPG fits its fixed row extent', (
    tester,
  ) async {
    // The lists navigate by `index * itemExtent`, so rows are a FIXED height.
    // A channel with now/next + a progress bar is the tallest row there is — if
    // kChannelRowExtentWithEpg were too small it would overflow, and every other
    // test uses an EPG-less source, so this is the only thing guarding it.
    await pumpWideScreenWith(tester, _EpgSource());
    await pumpUntil(tester, find.textContaining('Now · '));
    await settle(tester);

    // A RenderFlex overflow throws, failing the test before we get here.
    expect(find.textContaining('Now · '), findsWidgets);
    expect(find.textContaining('Next · '), findsWidgets);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  focusTestWidgets('a 960x540 TV viewport shows at least three channel rows', (
    tester,
  ) async {
    await pumpWideScreenWith(tester, DemoSource(), size: const Size(960, 540));

    final thirdRow = find.text('Tears of Steel (H.264)');
    expect(thirdRow, findsOneWidget);
    expect(
      tester.getRect(thirdRow).bottom,
      lessThanOrEqualTo(540),
      reason: 'the compact preview should leave three complete rows visible',
    );
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  focusTestWidgets('search filters the media grid', (tester) async {
    await pumpWideScreen(tester);
    await tester.tap(find.text('Series'));
    await tester.pump();
    await pumpUntil(tester, find.text('Codec Test Series'));

    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'zzzznomatch');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('No series match'));
    expect(find.text('Codec Test Series'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Codec');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpUntil(tester, find.text('Codec Test Series'));
    expect(find.text('Codec Test Series'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('repository replacement reloads controllers for the new source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstRepo = LibraryRepository(source: DemoSource(), db: db);
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelListScreen(repo: firstRepo, config: config),
      ),
    );
    await pumpUntil(tester, find.text('Big Buck Bunny (H.264)'));

    final replacementRepo = LibraryRepository(source: _ManySource(), db: db);
    await tester.pumpWidget(
      MaterialApp(
        home: ChannelListScreen(repo: replacementRepo, config: config),
      ),
    );
    await pumpUntil(tester, find.text('Channel 0'));

    expect(find.text('Channel 0'), findsOneWidget);
    expect(find.text('Big Buck Bunny (H.264)'), findsNothing);
    expect(find.text('Many'), findsOneWidget);

    await unmount(tester);
  });
}

/// A live source that actually carries EPG, so the *tall* channel row (name +
/// "Now ·" + progress + "Next ·") gets rendered at its fixed extent. Every other
/// source here returns an empty EPG, which only exercises the compact row.
class _EpgSource implements Source {
  static final DateTime _now = DateTime.now();
  static final List<Channel> _chans = [
    for (var i = 0; i < 3; i++)
      Channel(
        id: 'e$i',
        name: 'Epg Channel $i',
        categoryId: 'c0',
        number: i + 1,
      ),
  ];

  @override
  String get id => 'epgsrc';

  @override
  String get name => 'Epg';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'c0', title: 'Cat 0'),
  ];

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
  Future<List<Programme>> epg(List<Channel> channels) async => [
    for (final c in _chans) ...[
      Programme(
        channelId: c.id,
        start: _now.subtract(const Duration(minutes: 20)),
        stop: _now.add(const Duration(minutes: 40)),
        title: 'A rather long current programme title for ${c.name}',
      ),
      Programme(
        channelId: c.id,
        start: _now.add(const Duration(minutes: 40)),
        stop: _now.add(const Duration(minutes: 100)),
        title: 'An equally long upcoming programme title',
      ),
    ],
  ];

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

/// A live-only source with a sidebar long enough to scroll (30 categories) and
/// enough channels to navigate (12) — the conditions DemoSource can't create.
/// Channels are split between the first and last category so both are non-empty.
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
