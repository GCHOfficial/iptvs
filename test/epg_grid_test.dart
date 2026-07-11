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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/epg_grid_screen.dart';
import 'package:iptvs/sources/source.dart';
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
  ];

  // ChanA on :00/:30 boundaries; ChanB offset by 15 minutes. Titles are unique.
  final programmes = <Programme>[
    Programme(channelId: 'a', start: at(-30), stop: at(0), title: 'A-early'),
    Programme(channelId: 'a', start: at(0), stop: at(30), title: 'A-now'),
    Programme(channelId: 'a', start: at(30), stop: at(60), title: 'A-next'),
    Programme(channelId: 'a', start: at(60), stop: at(90), title: 'A-later'),
    Programme(channelId: 'b', start: at(-45), stop: at(-15), title: 'B0'),
    Programme(channelId: 'b', start: at(-15), stop: at(15), title: 'B1'),
    Programme(channelId: 'b', start: at(15), stop: at(45), title: 'B2'),
    Programme(channelId: 'b', start: at(45), stop: at(75), title: 'B3'),
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

  Future<void> pumpGrid(WidgetTester tester) async {
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
        home: EpgGridScreen(
          repo: repo,
          channels: channels,
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

  testWidgets('the grid holds one focus node and no per-cell FocusableCards',
      (tester) async {
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

  testWidgets('ArrowRight steps to the next programme on the row',
      (tester) async {
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

  testWidgets('ArrowDown changes channel but holds the time column',
      (tester) async {
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
  Future<StreamInfo> resolveArchive(Channel channel, Programme programme) async =>
      throw UnsupportedError('no catch-up');

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
