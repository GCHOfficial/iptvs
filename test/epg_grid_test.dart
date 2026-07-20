// Selection-cursor navigation net for the EPG grid (TV guide).
//
// The grid navigates with an explicit selection model, not Flutter's geometry
// traversal, so these pin the behaviours that make it feel right on a D-pad and
// that a refactor could silently break:
//  * the grid owns a single focus node (cells are NOT focusable — no per-cell
//    FocusableCard explosion),
//  * ArrowRight steps to the next programme on the row,
//  * ArrowDown changes channel while HOLDING the time column — it selects the
//    programme airing at the cursor time on the row below, even when that row's
//    programme boundaries are offset (where geometry traversal would drift).
//
// The two channels are seeded with deliberately *offset* boundaries so
// "holds the time column" is distinguishable from "nearest cell".

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/focusable_card.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_epg_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // Anchor everything to a single "now" so the seeded programmes are placed
  // relative to the same instant the grid opens on.
  final now = DateTime.now();
  DateTime at(int minutes) => now.add(Duration(minutes: minutes));

  const channels = [
    Channel(id: 'a', name: 'ChanA', number: 1),
    Channel(id: 'b', name: 'ChanB', number: 2),
    Channel(id: 'c', name: 'ChanC', number: 3),
  ];

  // A long synopsis on A-now to exercise the multi-line detail bar (Bug #3).
  const longSynopsis =
      'A long synopsis that should now wrap onto its own multi-line row in the '
      'detail bar instead of being cut off on the meta line.';

  // ChanA on :00/:30 boundaries; ChanB offset by 15 minutes; ChanC has an
  // *overlapping* overlong programme (C-long runs across C-1 and C-2) — the
  // real-world guide data that used to trap the cursor (Bugs #2/#4). Titles are
  // unique.
  final programmes = <Programme>[
    Programme(channelId: 'a', start: at(-30), stop: at(0), title: 'A-early'),
    Programme(
      channelId: 'a',
      start: at(0),
      stop: at(30),
      title: 'A-now',
      description: longSynopsis,
    ),
    Programme(channelId: 'a', start: at(30), stop: at(60), title: 'A-next'),
    Programme(channelId: 'a', start: at(60), stop: at(90), title: 'A-later'),
    Programme(channelId: 'b', start: at(-45), stop: at(-15), title: 'B0'),
    Programme(channelId: 'b', start: at(-15), stop: at(15), title: 'B1'),
    Programme(channelId: 'b', start: at(15), stop: at(45), title: 'B2'),
    Programme(channelId: 'b', start: at(45), stop: at(75), title: 'B3'),
    Programme(channelId: 'c', start: at(-60), stop: at(120), title: 'C-long'),
    Programme(channelId: 'c', start: at(0), stop: at(30), title: 'C-1'),
    Programme(channelId: 'c', start: at(30), stop: at(60), title: 'C-2'),
  ];

  // The detail bar's title Text is the only one at fontSize 15 (cells and the
  // ruler are 12), so it uniquely identifies the currently-selected programme.
  Finder detailTitle(String title) => find.byWidgetPredicate(
    (w) => w is Text && w.data == title && w.style?.fontSize == 15,
  );

  // Drive the real event loop (runAsync) between fake-clock pumps so the
  // sqflite/ffi programme query resolves, then let the setState land.
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

  Future<void> pumpGrid(
    WidgetTester tester, {
    List<Channel> gridChannels = channels,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Seed inside runAsync — a real sqflite/ffi write can't complete under the
    // widget-test fake clock (awaiting it directly in the test body deadlocks).
    await tester.runAsync(() => db.replaceEpg('epg', programmes));
    final repo = LibraryRepository(source: _FakeSource(), db: db);
    await tester.pumpWidget(
      MaterialApp(
        // The real text-button styling (the dialog Close focus ring) without
        // Keep this focused on dialog layout rather than the full app theme.
        theme: ThemeData.dark(
          useMaterial3: true,
        ).copyWith(textButtonTheme: AppTheme.textButtonTheme),
        home: EpgGridScreen(
          repo: repo,
          channels: gridChannels,
          onPlayChannel: (_) {},
          onPlayArchive: (_, _) {},
        ),
      ),
    );
    // The initial selection resolves once row 0's programmes load — the detail
    // bar then shows the now-programme's title.
    await pumpUntil(tester, detailTitle('A-now'));
  }

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('the grid holds one focus node and no per-cell FocusableCards', (
    tester,
  ) async {
    await pumpGrid(tester);

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'epg.grid',
      reason: 'the grid body is the single D-pad focus target',
    );
    expect(
      find.byType(FocusableCard),
      findsNothing,
      reason: 'programme cells must be lightweight, not FocusableCards',
    );

    await unmount(tester);
  });

  testWidgets('programme cells expose channel, position, and selected state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpGrid(tester);

    final selected = find.bySemanticsLabel(
      RegExp(r'^A-now, ChanA, .+, 2 of 4$'),
    );
    expect(selected, findsOneWidget);
    final data = tester.getSemantics(selected).getSemanticsData();
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    semantics.dispose();
    await unmount(tester);
  });

  testWidgets('ArrowRight steps to the next programme on the row', (
    tester,
  ) async {
    await pumpGrid(tester);

    // Initial selection is the now-programme (contains the cursor = now).
    expect(detailTitle('A-now'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(
      detailTitle('A-next'),
      findsOneWidget,
      reason: 'Right advances the selection to the next programme',
    );
    expect(detailTitle('A-now'), findsNothing);

    await unmount(tester);
  });

  testWidgets('ArrowDown changes channel but holds the time column', (
    tester,
  ) async {
    await pumpGrid(tester);

    // Move the cursor to A-next (starts at now+30).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(detailTitle('A-next'), findsOneWidget);

    // Down keeps the cursor time (now+30) and selects the ChanB programme
    // airing then — B2 [now+15, now+45] — NOT the geometrically nearest cell.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(
      detailTitle('B2'),
      findsOneWidget,
      reason: 'Down holds the time column: the B programme containing now+30',
    );
    expect(detailTitle('A-next'), findsNothing);

    await unmount(tester);
  });

  testWidgets(
    'ArrowRight advances past an overlong overlapping programme (Bugs #2/#4)',
    (tester) async {
      await pumpGrid(tester);

      // Drop onto ChanC (row 2), holding the time column at "now".
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpUntil(tester, detailTitle('C-1'));
      expect(detailTitle('C-1'), findsOneWidget);

      // Left onto the overlong C-long (which overlaps C-1 and C-2).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(detailTitle('C-long'), findsOneWidget);

      // Right must escape it — under the old time-re-resolution this snapped
      // straight back to C-long and the cursor was trapped.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        detailTitle('C-1'),
        findsOneWidget,
        reason:
            'Right steps by index, so overlap can no longer trap the cursor',
      );
      expect(detailTitle('C-long'), findsNothing);

      // And it keeps advancing.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(detailTitle('C-2'), findsOneWidget);

      await unmount(tester);
    },
  );

  testWidgets('ArrowDown keeps the selected row centered in the viewport', (
    tester,
  ) async {
    // Enough rows that the list actually scrolls; only ChanA has programmes
    // (the centering maths doesn't care what a row shows).
    final many = <Channel>[
      channels[0],
      for (var i = 1; i < 30; i++)
        Channel(id: 'x$i', name: 'Chan$i', number: i + 1),
    ];
    await pumpGrid(tester, gridChannels: many);

    for (var i = 0; i < 15; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 40));
    }
    // Let the 220ms reveal animation settle.
    await tester.pump(const Duration(milliseconds: 300));

    final position = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position)
        .firstWhere((p) => p.axis == Axis.vertical);
    const rowHeight = 52.0;
    final expected =
        (15 * rowHeight - (position.viewportDimension - rowHeight) / 2).clamp(
          0.0,
          position.maxScrollExtent,
        );
    expect(
      position.pixels,
      moreOrLessEquals(expected, epsilon: 1.0),
      reason:
          'the selected row is centered, not left at the bottom edge '
          'where the detail bar covers it',
    );

    await unmount(tester);
  });

  testWidgets(
    'an overlong programme cell is clamped at the next programme start',
    (tester) async {
      await pumpGrid(tester);

      // Reach ChanC so its programmes are loaded/painted.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpUntil(tester, detailTitle('C-1'));

      Positioned cellOf(String title) => tester.widget<Positioned>(
        find
            .ancestor(of: find.text(title), matching: find.byType(Positioned))
            .first,
      );

      // C-long really runs 180 minutes (720px) but is visually cut at C-1's
      // start: 60 minutes → 240px. The 30-minute cells stay 120px.
      expect(cellOf('C-long').width, 240);
      expect(cellOf('C-1').width, 120);
      expect(cellOf('C-2').width, 120);

      await unmount(tester);
    },
  );

  testWidgets('the selected cell paints on top of overlapping neighbours', (
    tester,
  ) async {
    await pumpGrid(tester);

    // Select the overlong C-long (Down ×2 onto ChanC, Left from C-1).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await pumpUntil(tester, detailTitle('C-1'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(detailTitle('C-long'), findsOneWidget);

    // The row's timeline Stack must list the selected cell last (Stack paints
    // later children on top). C-long's clamped 240px width identifies it.
    final stack = tester.widget<Stack>(
      find
          .ancestor(of: find.text('C-long'), matching: find.byType(Stack))
          .first,
    );
    final last = stack.children.last as Positioned;
    expect(
      last.width,
      240,
      reason:
          'the selected (overlong) cell is appended last so its highlight '
          'is never covered by overlapping neighbours',
    );

    await unmount(tester);
  });

  testWidgets('the details dialog Close button shows a visible focus ring', (
    tester,
  ) async {
    await pumpGrid(tester);

    // A future programme (A-next) → the dialog has no contextual action, so
    // Close autofocuses.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final closeFinder = find.widgetWithText(TextButton, 'Close');
    expect(closeFinder, findsOneWidget);
    final material = tester.widget<Material>(
      find.descendant(of: closeFinder, matching: find.byType(Material)).first,
    );
    final shape = material.shape as RoundedRectangleBorder?;
    expect(
      shape?.side.color,
      AppColors.accent,
      reason:
          'a focused dialog button must carry the accent ring — the '
          'default overlay alone is invisible on the dark panel',
    );
    expect(shape?.side.width, 2);

    // Close it so the test ends with no open route.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    await unmount(tester);
  });

  testWidgets('the detail bar shows the full multi-line description (Bug #3)', (
    tester,
  ) async {
    await pumpGrid(tester);

    // The selected A-now carries a long synopsis; it renders on its own line
    // (up to three) rather than being crammed onto the meta row.
    final descFinder = find.text(longSynopsis);
    expect(descFinder, findsOneWidget);
    final text = tester.widget<Text>(descFinder);
    expect(text.maxLines, 3);

    await unmount(tester);
  });

  testWidgets('focus restoration after playback is route-scoped: a covered '
      'channel-list restore must not steal the grid\'s D-pad', (tester) async {
    // Regression for "the EPG screen stops responding to the remote after
    // watching a channel": launching playback from the pushed grid route left
    // the main screen's post-player focus restore running while the grid was
    // still on top — FocusManager has no notion of routes, so the covered
    // channel-list node stole primaryFocus and the grid's onKeyEvent went
    // dead. This pins the *guard pattern* used by _restoreListFocusAfterPlayback
    // (bail unless the restoring route is current), not the full production
    // wiring — the real player route / native Activity path needs on-device
    // verification.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() => db.replaceEpg('epg', programmes));
    final repo = LibraryRepository(source: _FakeSource(), db: db);

    // The host stands in for the main screen: it owns the channel list's
    // focus node and pushes the grid on top (as _openEpgGrid does).
    final bgChannels = FocusNode(debugLabel: 'live.channels');
    addTearDown(bgChannels.dispose);
    late BuildContext hostContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(
          useMaterial3: true,
        ).copyWith(textButtonTheme: AppTheme.textButtonTheme),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return Focus(
                focusNode: bgChannels,
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
      ),
    );

    final navigator = Navigator.of(hostContext);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => EpgGridScreen(
            repo: repo,
            channels: channels,
            onPlayChannel: (_) {},
            onPlayArchive: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await pumpUntil(tester, detailTitle('A-now'));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'epg.grid');

    // "Playback": an opaque route pushed over the grid. Its pop continuation
    // runs the guarded restore post-frame — the exact shape of the production
    // code path after the player pops.
    unawaited(
      navigator
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: SizedBox.expand()),
            ),
          )
          .then((_) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              // The guard under test: the host (main screen) route is NOT the
              // visible top route — the grid still is — so the restore must bail
              // instead of stealing primaryFocus cross-route.
              if (ModalRoute.of(hostContext)?.isCurrent == false) return;
              bgChannels.requestFocus();
            });
          }),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'epg.grid',
      reason:
          'route focus restoration must hand the D-pad back to the grid — '
          'the covered channel-list node must not steal it',
    );

    // And the grid still navigates: Right advances the detail bar.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(detailTitle('A-next'), findsOneWidget);

    await unmount(tester);
  });
}

/// Minimal [Source] whose id matches the seeded EPG; the grid only reads
/// `source.id` (channels are passed in directly), so the rest are stubs.
class _FakeSource implements Source {
  @override
  String get id => 'epg';

  @override
  String get name => 'EPG';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [];

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
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();

  @override
  Future<void> dispose() async {}
}
