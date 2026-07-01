// Tests for the persistence layer: AppDatabase schema/migrations and the
// LibraryRepository cache behaviour. These exercise the real SQLite engine via
// the FFI factory (desktop), without depending on path_provider.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('iptvs_db_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String dbPath() => '${tempDir.path}/iptv.db';

  group('AppDatabase migrations', () {
    test('upgrades a v1 database to the current schema, preserving data', () async {
      // Build the original (v1) schema by hand, seed a source + channel, then
      // reopen through AppDatabase so the full onUpgrade chain runs.
      sqfliteFfiInit();
      final raw = await databaseFactoryFfi.openDatabase(
        dbPath(),
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE sources (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
              'synced_at INTEGER)',
            );
            await db.execute(
              'CREATE TABLE categories (source_id TEXT NOT NULL, id TEXT NOT NULL, '
              'title TEXT NOT NULL, PRIMARY KEY (source_id, id))',
            );
            await db.execute(
              'CREATE TABLE channels (source_id TEXT NOT NULL, id TEXT NOT NULL, '
              'name TEXT NOT NULL, number INTEGER, logo TEXT, category_id TEXT, '
              'extra TEXT, PRIMARY KEY (source_id, id))',
            );
          },
        ),
      );
      await raw.insert('sources', {
        'id': 'src1',
        'name': 'Legacy',
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      });
      await raw.insert('channels', {
        'source_id': 'src1',
        'id': 'ch1',
        'name': 'Channel One',
        'number': 1,
      });
      await raw.close();

      final db = await AppDatabase.openAt(dbPath());

      // Old data survived the migration.
      final channels = await db.readChannels('src1');
      expect(channels, hasLength(1));
      expect(channels.first.name, 'Channel One');
      // The v9->v10 ALTER added archive_days with a 0 default for legacy rows.
      expect(channels.first.archiveDays, 0);
      expect(await db.lastSynced('src1'), isNotNull);

      // Tables added across later versions are now usable.
      expect(
        await db.mediaSyncState('src1', ContentKind.movie),
        isNull, // queryable (no rows yet), proving the table exists
      );
      await db.close();
    });

    test('opening twice is a no-op upgrade', () async {
      final first = await AppDatabase.openAt(dbPath());
      await first.close();
      final second = await AppDatabase.openAt(dbPath());
      expect(await second.readChannels('missing'), isEmpty);
      await second.close();
    });

    test('fresh create has a usable external_metadata table', () async {
      // Regression: onCreate must build external_metadata, not just the
      // v3->7 upgrade branch — a fresh install was landing at the current
      // schema with the table missing, crashing every metadata query.
      final db = await AppDatabase.openAt(dbPath());
      const item = MediaItem(id: 'm1', title: 'Alpha', kind: ContentKind.movie);
      final metadata = ExternalMetadata(
        provider: 'tmdb',
        providerKey: '123',
        title: 'Alpha (enriched)',
        rating: 8.1,
        refreshedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );

      await db.cacheExternalMetadata('src1', item, metadata);
      final read = await db.readExternalMetadata('src1', item, 'tmdb');
      expect(read, isNotNull);
      expect(read!.title, 'Alpha (enriched)');
      expect(read.rating, 8.1);
      await db.close();
    });

    test('repairs a v7 database missing external_metadata', () async {
      // A DB created fresh at v7 (the buggy version) has every media table
      // except external_metadata. The v7->8 upgrade must add it.
      sqfliteFfiInit();
      final raw = await databaseFactoryFfi.openDatabase(
        dbPath(),
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, _) async {
            // Minimal v7-era shape: just enough that the v7->8 branch is the
            // only thing that can create external_metadata. `channels` has
            // existed since v1, so include it — the v9->v10 ALTER targets it.
            await db.execute(
              'CREATE TABLE sources (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
              'synced_at INTEGER, epg_synced_at INTEGER)',
            );
            await db.execute(
              'CREATE TABLE channels (source_id TEXT NOT NULL, id TEXT NOT NULL, '
              'name TEXT NOT NULL, number INTEGER, logo TEXT, category_id TEXT, '
              'extra TEXT, PRIMARY KEY (source_id, id))',
            );
          },
        ),
      );
      // Prove the table is absent before the upgrade.
      final before = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND "
        "name='external_metadata'",
      );
      expect(before, isEmpty);
      await raw.close();

      final db = await AppDatabase.openAt(dbPath());
      const item = MediaItem(id: 'm1', title: 'Alpha', kind: ContentKind.movie);
      final metadata = ExternalMetadata(
        provider: 'mdblist',
        providerKey: 'tt0001',
        rating: 6.4,
        refreshedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );

      await db.cacheExternalMetadata('src1', item, metadata);
      final read = await db.readExternalMetadata('src1', item, 'mdblist');
      expect(read, isNotNull);
      expect(read!.rating, 6.4);
      await db.close();
    });
  });

  group('AppDatabase media round-trip', () {
    test('writes and reads back a media library with paging state', () async {
      final db = await AppDatabase.openAt(dbPath());
      const kind = ContentKind.movie;
      final items = [
        const MediaItem(id: 'm1', title: 'Alpha', kind: kind, year: '2001'),
        const MediaItem(id: 'm2', title: 'Beta', kind: kind, rating: 7.5),
      ];

      await db.replaceMediaLibrary(
        'src1',
        kind,
        const [MediaCategory(id: 'c1', title: 'Action', kind: kind)],
        items,
        loadedPages: 1,
        totalPages: 3,
      );

      final read = await db.readMediaItems('src1', kind);
      expect(read.map((i) => i.title), ['Alpha', 'Beta']); // display order
      expect(read.firstWhere((i) => i.id == 'm2').rating, 7.5);

      final sync = await db.mediaSyncState('src1', kind);
      expect(sync, isNotNull);
      expect(sync!.loadedPages, 1);
      expect(sync.totalPages, 3);
      await db.close();
    });
  });

  group('AppDatabase favorites', () {
    test('adds, reads, and removes favorites per source and kind', () async {
      final db = await AppDatabase.openAt(dbPath());

      expect(await db.readFavoriteIds('src1', ContentKind.live), isEmpty);
      expect(await db.isFavorite('src1', ContentKind.live, 'ch1'), isFalse);

      await db.setFavorite('src1', ContentKind.live, 'ch1', true);
      await db.setFavorite('src1', ContentKind.live, 'ch2', true);
      await db.setFavorite('src1', ContentKind.movie, 'm1', true);

      expect(
        await db.readFavoriteIds('src1', ContentKind.live),
        {'ch1', 'ch2'},
      );
      // Kinds are independent.
      expect(await db.readFavoriteIds('src1', ContentKind.movie), {'m1'});
      expect(await db.readFavoriteIds('src1', ContentKind.series), isEmpty);
      // Sources are independent.
      expect(await db.readFavoriteIds('src2', ContentKind.live), isEmpty);
      expect(await db.isFavorite('src1', ContentKind.live, 'ch1'), isTrue);

      // Toggling off removes it; re-adding is idempotent (no PK clash).
      await db.setFavorite('src1', ContentKind.live, 'ch1', false);
      await db.setFavorite('src1', ContentKind.live, 'ch2', true);
      expect(await db.readFavoriteIds('src1', ContentKind.live), {'ch2'});
      await db.close();
    });

    test('survives a library refresh (replaceLibrary)', () async {
      final db = await AppDatabase.openAt(dbPath());
      await db.replaceLibrary(
        'src1',
        'Src',
        const [Category(id: 'c1', title: 'News')],
        const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
      );
      await db.setFavorite('src1', ContentKind.live, 'ch1', true);

      // A refresh wipes and rewrites channels/categories...
      await db.replaceLibrary(
        'src1',
        'Src',
        const [Category(id: 'c1', title: 'News')],
        const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
      );

      // ...but favorites are a separate table and persist.
      expect(await db.readFavoriteIds('src1', ContentKind.live), {'ch1'});
      await db.close();
    });

    test('fresh create exposes a usable favorites table', () async {
      // Regression guard mirroring the external_metadata fix: onCreate (not just
      // the v8->9 repair branch) must build favorites.
      final db = await AppDatabase.openAt(dbPath());
      await db.setFavorite('src1', ContentKind.series, 's1', true);
      expect(await db.readFavoriteIds('src1', ContentKind.series), {'s1'});
      await db.close();
    });
  });

  group('AppDatabase channels', () {
    test('persists a channel catch-up window across replaceLibrary', () async {
      final db = await AppDatabase.openAt(dbPath());
      await db.replaceLibrary(
        'src1',
        'Src',
        const [Category(id: 'c1', title: 'News')],
        const [
          Channel(id: 'arch', name: 'Archive', categoryId: 'c1', archiveDays: 5),
          Channel(id: 'plain', name: 'Plain', categoryId: 'c1'),
        ],
      );

      final channels = await db.readChannels('src1');
      final byId = {for (final c in channels) c.id: c};
      expect(byId['arch']!.archiveDays, 5);
      expect(byId['arch']!.hasArchive, isTrue);
      expect(byId['plain']!.archiveDays, 0);
      expect(byId['plain']!.hasArchive, isFalse);
      await db.close();
    });
  });

  group('AppDatabase programmes', () {
    test('returns a channel\'s programmes overlapping a window, ordered',
        () async {
      final db = await AppDatabase.openAt(dbPath());
      DateTime t(int h, [int m = 0]) => DateTime.utc(2024, 1, 1, h, m);
      await db.replaceEpg('src1', [
        Programme(channelId: 'ch1', start: t(8), stop: t(9), title: 'Early'),
        Programme(channelId: 'ch1', start: t(10), stop: t(11), title: 'A'),
        Programme(channelId: 'ch1', start: t(11), stop: t(12), title: 'B'),
        Programme(channelId: 'ch1', start: t(13), stop: t(14), title: 'Late'),
        Programme(channelId: 'ch2', start: t(10), stop: t(11), title: 'Other'),
      ]);

      final progs = await db.programmesForChannel(
        'src1',
        'ch1',
        from: t(10),
        to: t(12),
      );
      // Ordered by start; other channels excluded; out-of-window dropped.
      expect(progs.map((p) => p.title), ['A', 'B']);

      // Overlap, not containment: a window edge that cuts through A and B still
      // includes both (A ends after `from`, B starts before `to`).
      final overlap = await db.programmesForChannel(
        'src1',
        'ch1',
        from: t(10, 30),
        to: t(11, 30),
      );
      expect(overlap.map((p) => p.title), ['A', 'B']);

      // A window before any cached programme is empty.
      final empty = await db.programmesForChannel(
        'src1',
        'ch1',
        from: t(0),
        to: t(1),
      );
      expect(empty, isEmpty);
      await db.close();
    });
  });

  group('LibraryRepository', () {
    test('fetches from the source on a cold load, then serves from cache', () async {
      final db = await AppDatabase.openAt(dbPath());
      final source = _FakeSource();
      final repo = LibraryRepository(source: source, db: db);

      final cold = await repo.load();
      expect(cold.fromCache, isFalse);
      expect(cold.channels, hasLength(2));
      expect(source.channelCalls, 1);

      final warm = await repo.load();
      expect(warm.fromCache, isTrue);
      expect(warm.channels, hasLength(2));
      // The cache served the second load without touching the provider again.
      expect(source.channelCalls, 1);

      final forced = await repo.load(forceRefresh: true);
      expect(forced.fromCache, isFalse);
      expect(source.channelCalls, 2);
      await db.close();
    });

    test('archiveProgrammes gates on archive and honours the window', () async {
      final db = await AppDatabase.openAt(dbPath());
      final repo = LibraryRepository(source: _FakeSource(), db: db);
      final now = DateTime.now();

      await db.replaceEpg('fake', [
        // Inside a 2-day window (yesterday) and outside it (a week ago).
        Programme(
          channelId: 'ch1',
          start: now.subtract(const Duration(days: 1, hours: 1)),
          stop: now.subtract(const Duration(days: 1)),
          title: 'Yesterday',
        ),
        Programme(
          channelId: 'ch1',
          start: now.subtract(const Duration(days: 7, hours: 1)),
          stop: now.subtract(const Duration(days: 7)),
          title: 'LastWeek',
        ),
      ]);

      // A non-archive channel never touches the guide.
      final none = await repo.archiveProgrammes(
        const Channel(id: 'ch1', name: 'One'),
      );
      expect(none, isEmpty);

      // A 2-day archive channel sees only the in-window programme.
      final within = await repo.archiveProgrammes(
        const Channel(id: 'ch1', name: 'One', archiveDays: 2),
      );
      expect(within.map((p) => p.title), ['Yesterday']);
      await db.close();
    });

    test('resolveArchive delegates to the source', () async {
      final db = await AppDatabase.openAt(dbPath());
      final repo = LibraryRepository(source: _FakeSource(), db: db);
      // _FakeSource has no catch-up, so the passthrough surfaces its throw.
      await expectLater(
        repo.resolveArchive(
          const Channel(id: 'ch1', name: 'One', archiveDays: 2),
          Programme(
            channelId: 'ch1',
            start: DateTime(2024),
            stop: DateTime(2024, 1, 1, 1),
            title: 'X',
          ),
        ),
        throwsUnsupportedError,
      );
      await db.close();
    });
  });
}

/// Minimal in-memory [Source] that records how often the heavy fetch runs.
class _FakeSource implements Source {
  int channelCalls = 0;

  @override
  String get id => 'fake';

  @override
  String get name => 'Fake';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async =>
      const [Category(id: 'c1', title: 'News')];

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    channelCalls++;
    return const [
      Channel(id: 'a', name: 'A', categoryId: 'c1'),
      Channel(id: 'b', name: 'B', categoryId: 'c1'),
    ];
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<StreamInfo> resolveArchive(Channel channel, Programme programme) async =>
      throw UnsupportedError('no catch-up');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => const [];

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
