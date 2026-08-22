// Tests for the cross-source ("all sources") favorites controller: what it
// aggregates, what it deliberately drops, and that its async publish is
// generation-guarded like every other controller in the app.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/global_favorites_controller.dart';
import 'package:iptvs/screens/media_tab_controller.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  sqfliteFfiInit();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('iptvs_globalfav');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<AppDatabase> openDb() =>
      AppDatabase.openAt('${tempDir.path}/iptv.db');

  SourceConfig cfg(String id, String label) => SourceConfig(
    id: id,
    kind: SourceKind.m3u,
    label: label,
    fields: const {'playlistUrl': 'http://example.test/list.m3u'},
  );

  group('cross-source category fallback', () {
    // Regression: the "fall back to All" guard originally covered only the
    // per-source Favorites view, so unfavoriting the last foreign favorite left
    // the selection on a category that had just vanished from the pane — an
    // empty list the user could neither see selected nor move off.
    test('leaves the view once no foreign favorite is left', () {
      expect(
        shouldLeaveCrossSourceFavoritesView(
          categoryId: kAllSourcesFavoritesCategoryId,
          hasForeignFavorites: false,
        ),
        isTrue,
      );
    });

    test('stays while a foreign favorite remains', () {
      expect(
        shouldLeaveCrossSourceFavoritesView(
          categoryId: kAllSourcesFavoritesCategoryId,
          hasForeignFavorites: true,
        ),
        isFalse,
      );
    });

    test('never disturbs another category', () {
      for (final id in [null, kFavoritesCategoryId, 'news']) {
        expect(
          shouldLeaveCrossSourceFavoritesView(
            categoryId: id,
            hasForeignFavorites: false,
          ),
          isFalse,
          reason: 'category $id must be left alone',
        );
      }
    });
  });

  test('aggregates favorites from every configured source', () async {
    final db = await openDb();
    await db.replaceLibrary('src1', 'One', const [], const [
      Channel(id: 'ch1', name: 'Alpha', number: 1),
    ]);
    await db.replaceLibrary('src2', 'Two', const [], const [
      Channel(id: 'ch1', name: 'Gamma', number: 2),
    ]);
    await db.setFavorite('src1', ContentKind.live, 'ch1', true);
    await db.setFavorite('src2', ContentKind.live, 'ch1', true);

    final store = SourceStore();
    await store.setAll([cfg('src1', 'Panel One'), cfg('src2', 'Panel Two')]);

    final controller = GlobalFavoritesController(db: db, store: store);
    await controller.load();

    expect(controller.items.map((e) => e.channel.name), ['Alpha', 'Gamma']);
    expect(controller.items.map((e) => e.sourceLabel), [
      'Panel One',
      'Panel Two',
    ]);
    // Same provider channel id in two lists stays two rows — the duplicate case
    // the source chip disambiguates.
    expect(controller.items.map((e) => e.globalId).toSet().length, 2);
    controller.dispose();
    await db.close();
  });

  group('catalog reading order', () {
    // Built so the expected answer disagrees with *both* plausible wrong ones.
    // src1's provider category order is Zulu then Alpha (anti-alphabetical, so
    // a title sort is distinguishable) while its channel numbers run Alpha
    // first (so a plain `number` sort is distinguishable too). Only "provider
    // category order, then channel order inside it" yields z1, a1, a2.
    Future<GlobalFavoritesController> seed(
      AppDatabase db,
      SourceStore store, {
      required List<SourceConfig> configs,
    }) async {
      await db.replaceLibrary(
        'src1',
        'One',
        const [
          Category(id: 'zulu', title: 'Zulu'),
          Category(id: 'alpha', title: 'Alpha'),
        ],
        const [
          Channel(id: 'a1', name: 'Alpha One', number: 1, categoryId: 'alpha'),
          Channel(id: 'a2', name: 'Alpha Two', number: 2, categoryId: 'alpha'),
          Channel(id: 'z1', name: 'Zulu One', number: 3, categoryId: 'zulu'),
        ],
      );
      await db.replaceLibrary(
        'src2',
        'Two',
        const [Category(id: 'news', title: 'News')],
        const [
          Channel(id: 'n1', name: 'News One', number: 1, categoryId: 'news'),
        ],
      );
      for (final id in ['z1', 'a1', 'a2']) {
        await db.setFavorite('src1', ContentKind.live, id, true);
      }
      await db.setFavorite('src2', ContentKind.live, 'n1', true);
      await store.setAll(configs);
      return GlobalFavoritesController(db: db, store: store);
    }

    test('groups by source, then category, then channel order', () async {
      final db = await openDb();
      final controller = await seed(
        db,
        SourceStore(),
        configs: [cfg('src1', 'Panel One'), cfg('src2', 'Panel Two')],
      );
      await controller.load();

      // src1 first (it is first on the sources screen). Inside it the provider
      // lists Zulu before Alpha, so z1 leads despite carrying the *highest*
      // channel number; inside Alpha, channel order holds.
      expect(controller.items.map((e) => e.channel.id), [
        'z1',
        'a1',
        'a2',
        'n1',
      ]);
      controller.dispose();
      await db.close();
    });

    test('follows the user arrangement of the sources screen', () async {
      final db = await openDb();
      // Same data, sources the other way round.
      final controller = await seed(
        db,
        SourceStore(),
        configs: [cfg('src2', 'Panel Two'), cfg('src1', 'Panel One')],
      );
      await controller.load();

      expect(controller.items.map((e) => e.channel.id), [
        'n1',
        'z1',
        'a1',
        'a2',
      ]);
      controller.dispose();
      await db.close();
    });

    test('a favorite whose category is gone sorts last, not first', () async {
      // The catalog can be refreshed out from under a favorite: the channel row
      // survives with a category id the categories table no longer has. It is
      // still a deliberate pick, so it stays — at the end of its source.
      final db = await openDb();
      await db.replaceLibrary('src1', 'One', const [
        Category(id: 'news', title: 'News'),
      ], const [
        Channel(id: 'ghost', name: 'Ghost', number: 1, categoryId: 'dropped'),
        Channel(id: 'n1', name: 'News One', number: 2, categoryId: 'news'),
      ]);
      await db.setFavorite('src1', ContentKind.live, 'ghost', true);
      await db.setFavorite('src1', ContentKind.live, 'n1', true);

      final store = SourceStore();
      await store.setAll([cfg('src1', 'Panel One')]);
      final controller = GlobalFavoritesController(db: db, store: store);
      await controller.load();

      expect(controller.items.map((e) => e.channel.id), ['n1', 'ghost']);
      controller.dispose();
      await db.close();
    });
  });

  test('drops favorites whose source has been deleted', () async {
    final db = await openDb();
    await db.replaceLibrary('src1', 'One', const [], const [
      Channel(id: 'ch1', name: 'Alpha'),
    ]);
    await db.replaceLibrary('gone', 'Gone', const [], const [
      Channel(id: 'ch9', name: 'Orphan'),
    ]);
    await db.setFavorite('src1', ContentKind.live, 'ch1', true);
    await db.setFavorite('gone', ContentKind.live, 'ch9', true);

    final store = SourceStore();
    // 'gone' is still in the cache but no longer a configured source.
    await store.setAll([cfg('src1', 'Panel One')]);

    final controller = GlobalFavoritesController(db: db, store: store);
    await controller.load();

    expect(controller.items.map((e) => e.channel.name), ['Alpha']);
    controller.dispose();
    await db.close();
  });

  test('falls back to the source kind when the label is blank', () async {
    final db = await openDb();
    await db.replaceLibrary('src1', 'One', const [], const [
      Channel(id: 'ch1', name: 'Alpha'),
    ]);
    await db.setFavorite('src1', ContentKind.live, 'ch1', true);

    final store = SourceStore();
    await store.setAll([cfg('src1', '   ')]);

    final controller = GlobalFavoritesController(db: db, store: store);
    await controller.load();

    expect(controller.items.single.sourceLabel, 'm3u');
    controller.dispose();
    await db.close();
  });

  test('removeLocally drops a row without re-reading the database', () async {
    final db = await openDb();
    await db.replaceLibrary('src1', 'One', const [], const [
      Channel(id: 'ch1', name: 'Alpha', number: 1),
      Channel(id: 'ch2', name: 'Beta', number: 2),
    ]);
    await db.setFavorite('src1', ContentKind.live, 'ch1', true);
    await db.setFavorite('src1', ContentKind.live, 'ch2', true);

    final store = SourceStore();
    await store.setAll([cfg('src1', 'Panel One')]);

    final controller = GlobalFavoritesController(db: db, store: store);
    await controller.load();
    expect(controller.items.length, 2);

    var notified = 0;
    controller.addListener(() => notified++);

    controller.removeLocally('src1', 'ch1');
    expect(controller.items.map((e) => e.channel.id), ['ch2']);
    expect(notified, 1);

    // A row that isn't there notifies nobody.
    controller.removeLocally('src1', 'nope');
    expect(notified, 1);
    controller.dispose();
    await db.close();
  });

  test('a superseded load never publishes over a newer one', () async {
    final db = await openDb();
    await db.replaceLibrary('src1', 'One', const [], const [
      Channel(id: 'ch1', name: 'Alpha'),
    ]);
    await db.setFavorite('src1', ContentKind.live, 'ch1', true);

    final store = SourceStore();
    await store.setAll([cfg('src1', 'Panel One')]);

    final controller = GlobalFavoritesController(db: db, store: store);
    final first = controller.load();
    // Second load bumps the generation while the first is still in flight.
    final second = controller.load();
    await Future.wait([first, second]);

    expect(controller.items.length, 1);
    expect(controller.loading, isFalse);
    controller.dispose();
    await db.close();
  });
}
