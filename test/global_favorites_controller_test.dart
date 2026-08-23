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

  Future<AppDatabase> openDb() => AppDatabase.openAt('${tempDir.path}/iptv.db');

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
      await db.replaceLibrary(
        'src1',
        'One',
        const [Category(id: 'news', title: 'News')],
        const [
          Channel(id: 'ghost', name: 'Ghost', number: 1, categoryId: 'dropped'),
          Channel(id: 'n1', name: 'News One', number: 2, categoryId: 'news'),
        ],
      );
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
  group('instant population', () {
    // The reported bug: a channel starred from the *ordinary* channel list did
    // not appear in "Favorites · All sources" until the user forced a refresh,
    // while the per-source Favorites view updated immediately. The write goes
    // through `FavoritesController`, which knows nothing about this controller,
    // so nothing told this one that the table it mirrors had changed.
    Future<GlobalFavoritesController> seeded(
      AppDatabase db,
      SourceStore store,
    ) async {
      await db.replaceLibrary(
        'src1',
        'One',
        const [
          Category(id: 'news', title: 'News'),
          Category(id: 'kids', title: 'Kids'),
        ],
        const [
          Channel(id: 'n1', name: 'News One', number: 1, categoryId: 'news'),
          Channel(id: 'n2', name: 'News Two', number: 2, categoryId: 'news'),
          Channel(id: 'k1', name: 'Kids One', number: 3, categoryId: 'kids'),
        ],
      );
      await db.setFavorite('src1', ContentKind.live, 'n2', true);
      await db.setFavorite('src1', ContentKind.live, 'k1', true);
      await store.setAll([cfg('src1', 'Panel One')]);
      final controller = GlobalFavoritesController(db: db, store: store);
      await controller.load();
      return controller;
    }

    test(
      'a newly starred channel lands in catalog order, not at the end',
      () async {
        final db = await openDb();
        final store = SourceStore();
        final controller = await seeded(db, store);
        expect(controller.items.map((e) => e.channel.id), ['n2', 'k1']);

        // n1 is *first* in the News category, which is itself before Kids — so
        // appending it (the shape a naive "add to the list" would produce) is
        // distinguishable from inserting it in catalog order.
        await db.setFavorite('src1', ContentKind.live, 'n1', true);
        await controller.applyLocalChange(
          config: cfg('src1', 'Panel One'),
          channel: const Channel(
            id: 'n1',
            name: 'News One',
            number: 1,
            categoryId: 'news',
          ),
          favorite: true,
        );

        expect(controller.items.map((e) => e.channel.id), ['n1', 'n2', 'k1']);
        // And it agrees with what a full reload would have produced.
        await controller.load();
        expect(controller.items.map((e) => e.channel.id), ['n1', 'n2', 'k1']);
        controller.dispose();
        await db.close();
      },
    );

    test('unstarring drops the row without a reload', () async {
      final db = await openDb();
      final store = SourceStore();
      final controller = await seeded(db, store);

      await controller.applyLocalChange(
        config: cfg('src1', 'Panel One'),
        channel: const Channel(id: 'n2', name: 'News Two', number: 2),
        favorite: false,
      );
      expect(controller.items.map((e) => e.channel.id), ['k1']);
      controller.dispose();
      await db.close();
    });

    test('starring the same channel twice adds one row', () async {
      // Two stars racing (a held D-pad key) must not double the row — the
      // insert is unconditional otherwise.
      final db = await openDb();
      final store = SourceStore();
      final controller = await seeded(db, store);

      const channel = Channel(
        id: 'n1',
        name: 'News One',
        number: 1,
        categoryId: 'news',
      );
      final config = cfg('src1', 'Panel One');
      await controller.applyLocalChange(
        config: config,
        channel: channel,
        favorite: true,
      );
      await controller.applyLocalChange(
        config: config,
        channel: channel,
        favorite: true,
      );
      expect(controller.items.where((e) => e.channel.id == 'n1').length, 1);
      controller.dispose();
      await db.close();
    });

    test(
      'the first favorite in a source still lands in category order',
      () async {
        // src2 contributed no row to the last load, so its category order was
        // never cached — the path that has to go and read it.
        final db = await openDb();
        final store = SourceStore();
        final controller = await seeded(db, store);
        await db.replaceLibrary(
          'src2',
          'Two',
          const [
            Category(id: 'zulu', title: 'Zulu'),
            Category(id: 'alpha', title: 'Alpha'),
          ],
          const [
            Channel(id: 'z9', name: 'Zulu Nine', number: 9, categoryId: 'zulu'),
            Channel(
              id: 'a9',
              name: 'Alpha Nine',
              number: 8,
              categoryId: 'alpha',
            ),
          ],
        );
        await store.setAll([
          cfg('src1', 'Panel One'),
          cfg('src2', 'Panel Two'),
        ]);
        await controller.load();

        // Add the *later* category first, then the earlier one: only real
        // category ranking puts z9 after a9, since z9's number is the higher.
        for (final channel in const [
          Channel(id: 'a9', name: 'Alpha Nine', number: 8, categoryId: 'alpha'),
          Channel(id: 'z9', name: 'Zulu Nine', number: 9, categoryId: 'zulu'),
        ]) {
          await db.setFavorite('src2', ContentKind.live, channel.id, true);
          await controller.applyLocalChange(
            config: cfg('src2', 'Panel Two'),
            channel: channel,
            favorite: true,
          );
        }

        expect(controller.items.map((e) => e.channel.id), [
          'n2',
          'k1',
          // src2's provider order is Zulu then Alpha, so z9 comes first despite
          // the higher channel number.
          'z9',
          'a9',
        ]);
        controller.dispose();
        await db.close();
      },
    );

    test('before the first load it falls back to loading', () async {
      final db = await openDb();
      await db.replaceLibrary('src1', 'One', const [], const [
        Channel(id: 'ch1', name: 'Alpha', number: 1),
      ]);
      await db.setFavorite('src1', ContentKind.live, 'ch1', true);
      final store = SourceStore();
      await store.setAll([cfg('src1', 'Panel One')]);

      final controller = GlobalFavoritesController(db: db, store: store);
      // No `load()` first: there is no ordered list to insert into, so this has
      // to read the whole thing rather than publish a list of one.
      await controller.applyLocalChange(
        config: cfg('src1', 'Panel One'),
        channel: const Channel(id: 'ch1', name: 'Alpha', number: 1),
        favorite: true,
      );
      expect(controller.items.map((e) => e.channel.id), ['ch1']);
      controller.dispose();
      await db.close();
    });
  });

  group('EPG', () {
    // Cross-source rows used to carry no guide at all, because the live tab's
    // now/next maps are keyed by channel id — unique only *within* a provider,
    // and this is the one view where two providers meet. Keying by
    // `(sourceId, channelId)` is what makes a guide possible here.
    Programme prog(String channelId, String title, DateTime at) => Programme(
      channelId: channelId,
      start: at.subtract(const Duration(minutes: 10)),
      stop: at.add(const Duration(minutes: 20)),
      title: title,
    );

    test('resolves the owning source, never the colliding id', () async {
      final db = await openDb();
      final now = DateTime.now();
      // The same channel id in both sources — the collision the pair key
      // exists for. Different programmes, so a wrong lookup is visible.
      await db.replaceLibrary('src1', 'One', const [], const [
        Channel(id: 'shared', name: 'Alpha', number: 1),
      ]);
      await db.replaceLibrary('src2', 'Two', const [], const [
        Channel(id: 'shared', name: 'Gamma', number: 2),
      ]);
      await db.setFavorite('src1', ContentKind.live, 'shared', true);
      await db.setFavorite('src2', ContentKind.live, 'shared', true);
      await db.replaceEpg('src1', [prog('shared', 'One Now', now)]);
      await db.replaceEpg('src2', [prog('shared', 'Two Now', now)]);

      final store = SourceStore();
      await store.setAll([cfg('src1', 'Panel One'), cfg('src2', 'Panel Two')]);
      final controller = GlobalFavoritesController(db: db, store: store);
      await controller.load();

      expect(controller.hasEpg, isTrue);
      expect(controller.epgFor('src1', 'shared').now?.title, 'One Now');
      expect(controller.epgFor('src2', 'shared').now?.title, 'Two Now');
      controller.dispose();
      await db.close();
    });

    test('a source with no cached guide simply draws none', () async {
      final db = await openDb();
      await db.replaceLibrary('src1', 'One', const [], const [
        Channel(id: 'ch1', name: 'Alpha', number: 1),
      ]);
      await db.setFavorite('src1', ContentKind.live, 'ch1', true);
      final store = SourceStore();
      await store.setAll([cfg('src1', 'Panel One')]);

      final controller = GlobalFavoritesController(db: db, store: store);
      await controller.load();

      expect(controller.hasEpg, isFalse);
      expect(controller.epgFor('src1', 'ch1').now, isNull);
      expect(controller.epgFor('src1', 'ch1').next, isNull);
      controller.dispose();
      await db.close();
    });

    test(
      'a stale guide degrades to nothing rather than to something wrong',
      () async {
        // A foreign source's guide is only refreshed while that source is
        // active, so it can be arbitrarily old. Both halves of the query are
        // bounded by the current instant, so an out-of-date guide stops matching
        // instead of printing yesterday's programme as "now".
        final db = await openDb();
        final longAgo = DateTime.now().subtract(const Duration(days: 3));
        await db.replaceLibrary('src1', 'One', const [], const [
          Channel(id: 'ch1', name: 'Alpha', number: 1),
        ]);
        await db.setFavorite('src1', ContentKind.live, 'ch1', true);
        await db.replaceEpg('src1', [prog('ch1', 'Ancient', longAgo)]);

        final store = SourceStore();
        await store.setAll([cfg('src1', 'Panel One')]);
        final controller = GlobalFavoritesController(db: db, store: store);
        await controller.load();

        expect(controller.epgFor('src1', 'ch1').now, isNull);
        expect(controller.hasEpg, isFalse);
        controller.dispose();
        await db.close();
      },
    );

    test('the next programme is reported alongside the current one', () async {
      final db = await openDb();
      final now = DateTime.now();
      await db.replaceLibrary('src1', 'One', const [], const [
        Channel(id: 'ch1', name: 'Alpha', number: 1),
      ]);
      await db.setFavorite('src1', ContentKind.live, 'ch1', true);
      await db.replaceEpg('src1', [
        prog('ch1', 'Current', now),
        Programme(
          channelId: 'ch1',
          start: now.add(const Duration(minutes: 20)),
          stop: now.add(const Duration(minutes: 50)),
          title: 'Upcoming',
        ),
      ]);

      final store = SourceStore();
      await store.setAll([cfg('src1', 'Panel One')]);
      final controller = GlobalFavoritesController(db: db, store: store);
      await controller.load();

      final epg = controller.epgFor('src1', 'ch1');
      expect(epg.now?.title, 'Current');
      expect(epg.next?.title, 'Upcoming');
      controller.dispose();
      await db.close();
    });
  });

  group('liveRowsShowEpg', () {
    // The row-height predicate. The two views are asked different questions:
    // reading the *active* source's `hasEpg` in the cross-source view laid its
    // rows out at 68.1 px inside an itemExtent of 105.9.
    test('an ordinary category follows the active guide', () {
      expect(
        liveRowsShowEpg(
          categoryId: null,
          hasEpg: true,
          hasCrossSourceEpg: false,
          expectsEpg: false,
        ),
        isTrue,
      );
      expect(
        liveRowsShowEpg(
          categoryId: 'news',
          hasEpg: false,
          hasCrossSourceEpg: true,
          expectsEpg: false,
        ),
        isFalse,
      );
    });

    test('an ordinary category also follows a guide that is on its way', () {
      // The rows are laid out before the guide lands now, so a source that says
      // it carries one is taken at its word — otherwise its first load draws
      // 72 px rows and jumps to 112 px when the guide arrives.
      expect(
        liveRowsShowEpg(
          categoryId: null,
          hasEpg: false,
          hasCrossSourceEpg: false,
          expectsEpg: true,
        ),
        isTrue,
      );
    });

    test('the cross-source view ignores what the active source expects', () {
      // Same reason it ignores the active source's `hasEpg`: its rows are
      // foreign, fed by another controller's guide.
      expect(
        liveRowsShowEpg(
          categoryId: kAllSourcesFavoritesCategoryId,
          hasEpg: false,
          hasCrossSourceEpg: false,
          expectsEpg: true,
        ),
        isFalse,
      );
    });

    test('the cross-source view follows its own guide, not the active one', () {
      expect(
        liveRowsShowEpg(
          categoryId: kAllSourcesFavoritesCategoryId,
          hasEpg: true,
          hasCrossSourceEpg: false,
          expectsEpg: false,
        ),
        isFalse,
        reason:
            'the active source having a guide says nothing about whether '
            'a foreign row will draw one',
      );
      expect(
        liveRowsShowEpg(
          categoryId: kAllSourcesFavoritesCategoryId,
          hasEpg: false,
          hasCrossSourceEpg: true,
          expectsEpg: false,
        ),
        isTrue,
      );
    });
  });
}
