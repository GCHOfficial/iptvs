// Regression net for the series "Continue watching" staleness fix.
//
// Episodes picked in the series browser used to be played by a player route the
// MediaDetailsSheet pushed itself, which skipped the screen's post-playback
// "Continue watching" reload — so the series rail stayed stale until a manual
// refresh. The sheet now hands the episode to the parent via `onPlayEpisode`
// (the same path movies use, which reloads the rail on return). This test pins
// that wiring: tapping an episode invokes `onPlayEpisode` and closes the sheet,
// rather than pushing its own player.
//
// Harness note: repo.loadMedia runs through sqflite_common_ffi (a background
// isolate) whose futures don't advance under the widget-test fake clock, so we
// drive the real event loop with runAsync between pumps (`pumpUntil`), the same
// approach as channel_list_focus_test.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_media_details_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

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

  testWidgets(
    'tapping a series episode routes through onPlayEpisode and closes the sheet',
    (tester) async {
      // A tall surface so the expanded episode list fits without scrolling
      // (keeps every episode row on-screen and hittable).
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = LibraryRepository(source: DemoSource(), db: db);
      // Ids must line up with DemoSource so its season/episode loads resolve.
      const series = MediaItem(
        id: 'demo-series-1',
        title: 'Codec Test Series',
        kind: ContentKind.series,
        categoryId: 'demo-series',
      );
      MediaItem? played;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      // The sheet's ListTiles need a Material ancestor — in the
                      // app that comes from showModalBottomSheet; here a
                      // Scaffold stands in for it.
                      builder: (_) => Scaffold(
                        body: MediaDetailsSheet(
                          repo: repo,
                          item: series,
                          favorite: false,
                          onToggleFavorite: () {},
                          onPlay: null,
                          onPlayEpisode: (episode) => played = episode,
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();

      // Seasons load async; wait for the season header, then expand it.
      await pumpUntil(tester, find.text('Season 1'));
      expect(find.byType(MediaDetailsSheet), findsOneWidget);
      await tester.tap(find.text('Season 1'));

      // Episodes load async once the season expands.
      await pumpUntil(tester, find.text('1. Big Buck Bunny'));
      // Episodes are in (the progress spinner is gone), so the finite expansion
      // animation can settle before we tap.
      await tester.pumpAndSettle();

      final episodeTile = find.widgetWithText(ListTile, '1. Big Buck Bunny');
      await tester.ensureVisible(episodeTile);
      await tester.pumpAndSettle();
      await tester.tap(episodeTile);
      // Let the sheet's pop transition run to completion.
      await tester.pumpAndSettle();

      // The episode was handed to the parent play path (not pushed internally),
      // and the details sheet closed.
      expect(played, isNotNull);
      expect(played!.id, 'bbb');
      expect(find.byType(MediaDetailsSheet), findsNothing);
    },
  );
}
