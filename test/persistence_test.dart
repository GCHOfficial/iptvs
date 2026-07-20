// Tests for the persistence layer: AppDatabase schema/migrations and the
// LibraryRepository cache behaviour. These exercise the real SQLite engine via
// the FFI factory (desktop), without depending on path_provider.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_identity.dart';

import 'support/historical_database_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
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
            // `programmes` has existed since onCreate/oldV<2, so a genuine v7
            // install always has it too — the v11->v12 index-add branch targets it.
            await db.execute(
              'CREATE TABLE programmes (source_id TEXT NOT NULL, '
              'channel_id TEXT NOT NULL, start INTEGER NOT NULL, '
              'stop INTEGER NOT NULL, title TEXT NOT NULL, description TEXT)',
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

      expect(await db.readFavoriteIds('src1', ContentKind.live), {
        'ch1',
        'ch2',
      });
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
          Channel(
            id: 'arch',
            name: 'Archive',
            categoryId: 'c1',
            archiveDays: 5,
          ),
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

    test(
      'replaceLibrary does not reset epg_synced_at on a repeat channel refresh',
      () async {
        // Regression pin: replaceLibrary used to INSERT OR REPLACE the
        // sources row, wiping epg_synced_at on every channel refresh
        // regardless of whether EPG itself was touched.
        final db = await AppDatabase.openAt(dbPath());
        await db.replaceLibrary(
          'src1',
          'Src',
          const [Category(id: 'c1', title: 'News')],
          const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
        );
        await db.replaceEpg('src1', [
          Programme(
            channelId: 'ch1',
            start: DateTime.utc(2024, 1, 1, 10),
            stop: DateTime.utc(2024, 1, 1, 11),
            title: 'A',
          ),
        ]);
        final t0 = await db.lastEpgSynced('src1');
        expect(t0, isNotNull);

        // A second, unrelated channel-library refresh must not touch EPG
        // freshness.
        await db.replaceLibrary(
          'src1',
          'Src',
          const [Category(id: 'c1', title: 'News')],
          const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
        );
        expect(await db.lastEpgSynced('src1'), t0);
        await db.close();
      },
    );
  });

  group('AppDatabase playback positions', () {
    test(
      'round-trips a resume position and lists recents newest-first',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        await db.savePlaybackPosition(
          'src',
          ContentKind.movie,
          'm1',
          position: const Duration(minutes: 12),
          duration: const Duration(minutes: 90),
        );
        await db.savePlaybackPosition(
          'src',
          ContentKind.episode,
          'e1',
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 42),
        );

        final read = await db.readPlaybackPosition(
          'src',
          ContentKind.movie,
          'm1',
        );
        expect(read, isNotNull);
        expect(read!.position, const Duration(minutes: 12));
        expect(read.duration, const Duration(minutes: 90));
        expect(read.progress, closeTo(12 / 90, 0.001));

        final recents = await db.readRecentPositions('src');
        expect(recents.map((p) => p.itemId).toList(), ['e1', 'm1']);
        // Other sources see nothing.
        expect(await db.readRecentPositions('other'), isEmpty);
        await db.close();
      },
    );

    test(
      'finishing a title clears its row; early positions are ignored',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        await db.savePlaybackPosition(
          'src',
          ContentKind.movie,
          'm1',
          position: const Duration(minutes: 30),
          duration: const Duration(minutes: 90),
        );
        // Past the finished threshold -> row removed.
        await db.savePlaybackPosition(
          'src',
          ContentKind.movie,
          'm1',
          position: const Duration(minutes: 88),
          duration: const Duration(minutes: 90),
        );
        expect(
          await db.readPlaybackPosition('src', ContentKind.movie, 'm1'),
          isNull,
        );
        // Under 10s in -> not worth a row.
        await db.savePlaybackPosition(
          'src',
          ContentKind.movie,
          'm2',
          position: const Duration(seconds: 5),
          duration: const Duration(minutes: 90),
        );
        expect(
          await db.readPlaybackPosition('src', ContentKind.movie, 'm2'),
          isNull,
        );
        await db.close();
      },
    );

    test('v10 database gains the playback_positions table on upgrade', () async {
      // Simulate a pre-v11 install: open at v10 (no positions table), then
      // reopen through AppDatabase so the oldV < 11 repair branch runs.
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final raw = await openDatabase(
        dbPath(),
        version: 10,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE sources (id TEXT PRIMARY KEY, '
            'name TEXT NOT NULL, synced_at INTEGER, epg_synced_at INTEGER)',
          );
          // `programmes` has existed since onCreate/oldV<2, so a genuine v10
          // install always has it too — the v11->v12 index-add branch targets it.
          await db.execute(
            'CREATE TABLE programmes (source_id TEXT NOT NULL, '
            'channel_id TEXT NOT NULL, start INTEGER NOT NULL, '
            'stop INTEGER NOT NULL, title TEXT NOT NULL, description TEXT)',
          );
        },
      );
      await raw.close();

      final db = await AppDatabase.openAt(dbPath());
      await db.savePlaybackPosition(
        'src',
        ContentKind.movie,
        'm1',
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 90),
      );
      expect(
        await db.readPlaybackPosition('src', ContentKind.movie, 'm1'),
        isNotNull,
      );
      await db.close();
    });
  });

  group('AppDatabase programmes', () {
    test(
      'programmesForChannels batches the window query per channel',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h) => DateTime.utc(2024, 1, 1, h);
        await db.replaceEpg('src1', [
          Programme(channelId: 'ch1', start: t(10), stop: t(11), title: 'A'),
          Programme(channelId: 'ch1', start: t(11), stop: t(12), title: 'B'),
          Programme(channelId: 'ch2', start: t(10), stop: t(11), title: 'C'),
          Programme(
            channelId: 'ch3',
            start: t(1),
            stop: t(2),
            title: 'OutOfWindow',
          ),
        ]);

        final byChannel = await db.programmesForChannels(
          'src1',
          ['ch1', 'ch2', 'ch3'],
          from: t(10),
          to: t(12),
        );

        expect(byChannel['ch1']!.map((p) => p.title), ['A', 'B']);
        expect(byChannel['ch2']!.map((p) => p.title), ['C']);
        expect(byChannel.containsKey('ch3'), isFalse);
        expect(
          await db.programmesForChannels(
            'src1',
            const [],
            from: t(0),
            to: t(23),
          ),
          isEmpty,
        );
        await db.close();
      },
    );

    test(
      'returns a channel\'s programmes overlapping a window, ordered',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h, [int m = 0]) => DateTime.utc(2024, 1, 1, h, m);
        await db.replaceEpg('src1', [
          Programme(channelId: 'ch1', start: t(8), stop: t(9), title: 'Early'),
          Programme(channelId: 'ch1', start: t(10), stop: t(11), title: 'A'),
          Programme(channelId: 'ch1', start: t(11), stop: t(12), title: 'B'),
          Programme(channelId: 'ch1', start: t(13), stop: t(14), title: 'Late'),
          Programme(
            channelId: 'ch2',
            start: t(10),
            stop: t(11),
            title: 'Other',
          ),
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
      },
    );

    test(
      'a failure mid-insert rolls back the whole replaceEpg transaction',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h, [int m = 0]) => DateTime.utc(2024, 1, 1, h, m);
        // Seed the sources row first — replaceEpg's timestamp update is a
        // no-op without it, which would make `before` trivially null.
        await db.replaceLibrary(
          'src1',
          'Src',
          const [Category(id: 'c1', title: 'News')],
          const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
        );
        final good = Programme(
          channelId: 'ch1',
          start: t(10),
          stop: t(11),
          title: 'Good',
        );
        await db.replaceEpg('src1', [good]);
        final before = await db.lastEpgSynced('src1');
        expect(before, isNotNull);

        // The iterable yields one row, then throws mid-loop — proves the
        // delete + partial insert both roll back together with the timestamp.
        await expectLater(
          db.replaceEpg(
            'src1',
            _throwingProgrammes(
              Programme(
                channelId: 'ch1',
                start: t(12),
                stop: t(13),
                title: 'Partial',
              ),
            ),
          ),
          throwsA(isA<StateError>()),
        );

        final result = await db.nowNext('src1', t(10, 30));
        expect(result.now['ch1']?.title, 'Good');
        expect(await db.lastEpgSynced('src1'), before);
        await db.close();
      },
    );
  });

  group('AppDatabase.replaceEpgStream', () {
    test(
      'a success-empty stream clears stale rows and advances epg_synced_at',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h, [int m = 0]) => DateTime.utc(2024, 1, 1, h, m);
        await db.replaceLibrary(
          'src1',
          'Src',
          const [Category(id: 'c1', title: 'News')],
          const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
        );
        await db.replaceEpg('src1', [
          Programme(
            channelId: 'ch1',
            start: t(10),
            stop: t(11),
            title: 'Stale',
          ),
        ]);

        // Millisecond-truncated to match epg_synced_at's storage precision —
        // an empty stream is fast enough end-to-end that comparing against a
        // microsecond-precision `DateTime.now()` was flaky (the stored value
        // can floor into the same millisecond as a `beforeCall` that's a
        // fraction of a millisecond ahead of it).
        final beforeCall = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
        );
        await db.replaceEpgStream(
          'src1',
          const Stream<List<Programme>>.empty(),
        );

        final result = await db.nowNext('src1', t(10, 30));
        expect(result.now, isEmpty);
        final synced = await db.lastEpgSynced('src1');
        expect(synced, isNotNull);
        expect(
          synced!.isAtSameMomentAs(beforeCall) || synced.isAfter(beforeCall),
          isTrue,
        );
        await db.close();
      },
    );

    test(
      'a mid-stream error retains the last-good guide and old timestamp',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h, [int m = 0]) => DateTime.utc(2024, 1, 1, h, m);
        await db.replaceLibrary(
          'src1',
          'Src',
          const [Category(id: 'c1', title: 'News')],
          const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
        );
        await db.replaceEpg('src1', [
          Programme(channelId: 'ch1', start: t(10), stop: t(11), title: 'Good'),
        ]);
        final before = await db.lastEpgSynced('src1');
        expect(before, isNotNull);

        Stream<List<Programme>> throwingBatches() async* {
          yield [
            Programme(
              channelId: 'ch1',
              start: t(12),
              stop: t(13),
              title: 'Partial',
            ),
          ];
          throw StateError('epg batch feed failed mid-stream');
        }

        await expectLater(
          db.replaceEpgStream('src1', throwingBatches()),
          throwsA(isA<StateError>()),
        );

        final result = await db.nowNext('src1', t(10, 30));
        expect(result.now['ch1']?.title, 'Good');
        expect(await db.lastEpgSynced('src1'), before);
        await db.close();
      },
    );

    test('a completed multi-batch stream lands all rows atomically', () async {
      final db = await AppDatabase.openAt(dbPath());
      DateTime t(int h, [int m = 0]) => DateTime.utc(2024, 1, 1, h, m);
      await db.replaceLibrary(
        'src1',
        'Src',
        const [Category(id: 'c1', title: 'News')],
        const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
      );

      Stream<List<Programme>> batches() async* {
        yield [
          Programme(channelId: 'ch1', start: t(10), stop: t(11), title: 'A'),
        ];
        yield [
          Programme(channelId: 'ch1', start: t(11), stop: t(12), title: 'B'),
        ];
        yield [
          Programme(channelId: 'ch1', start: t(12), stop: t(13), title: 'C'),
        ];
      }

      final metrics = await db.replaceEpgStream('src1', batches());

      final progs = await db.programmesForChannel(
        'src1',
        'ch1',
        from: t(9),
        to: t(14),
      );
      expect(progs.map((p) => p.title), ['A', 'B', 'C']);
      expect(await db.lastEpgSynced('src1'), isNotNull);
      expect(metrics.providerDuration, isNot(Duration.zero));
      expect(metrics.databaseDuration, isNot(Duration.zero));
      await db.close();
    });
  });

  group('AppDatabase EPG index', () {
    Future<bool> indexExists(String path) async {
      // A fresh connection to inspect sqlite_master. `openDatabase` here is
      // singleInstance by default, so it must run *after* the AppDatabase
      // connection to the same path has been closed — otherwise it hands
      // back (and then closes) that very same shared connection.
      final raw = await databaseFactoryFfi.openDatabase(path);
      final rows = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND "
        "name='idx_prog_source_start'",
      );
      await raw.close();
      return rows.isNotEmpty;
    }

    test('idx_prog_source_start exists on a fresh database', () async {
      final path = dbPath();
      final db = await AppDatabase.openAt(path);
      await db.close();
      expect(await indexExists(path), isTrue);
    });

    test(
      'a v11 database gains idx_prog_source_start on upgrade, keeping seeded EPG',
      () async {
        final path = dbPath();
        await createReleasedDatabaseFixture(path, 11);

        final db = await AppDatabase.openAt(path);
        // The fixture's seeded programme survived the v11->v12 upgrade.
        final progs = await db.programmesForChannel(
          'released-source',
          'channel-1',
          from: DateTime.fromMillisecondsSinceEpoch(0),
          to: DateTime.fromMillisecondsSinceEpoch(3000),
        );
        expect(progs.map((p) => p.title), ['Fixture Programme']);
        await db.close();

        expect(await indexExists(path), isTrue);
      },
    );

    test('a large now-next query is served by idx_prog_source_start', () async {
      final db = await AppDatabase.openAt(dbPath());
      final firstStart = DateTime.utc(2026, 1, 1);
      const channelCount = 2000;
      const perChannel = 10; // ~20k programmes total.
      final programmes = <Programme>[
        for (var c = 0; c < channelCount; c++)
          for (var i = 0; i < perChannel; i++)
            Programme(
              channelId: 'channel-$c',
              start: firstStart.add(Duration(hours: i)),
              stop: firstStart.add(Duration(hours: i + 1)),
              title: 'P$c-$i',
            ),
      ];
      await db.replaceEpg('perf-source', programmes);

      final plan = await db.explainNowQueryPlan(
        'perf-source',
        firstStart.add(const Duration(minutes: 30)),
      );
      expect(plan.any((d) => d.contains('idx_prog_source_start')), isTrue);
      await db.close();
    });
  });

  group('stable identity migration', () {
    test('moves cache, favorites, EPG, and positions atomically', () async {
      final db = await AppDatabase.openAt(dbPath());
      final now = DateTime.now();
      await db.replaceLibrary(
        'xtream:http://provider.invalid|old-user',
        'Provider',
        const [Category(id: 'news', title: 'News')],
        const [Channel(id: '42', name: 'Channel', categoryId: 'news')],
      );
      await db.replaceEpg('xtream:http://provider.invalid|old-user', [
        Programme(
          channelId: '42',
          start: now.subtract(const Duration(minutes: 5)),
          stop: now.add(const Duration(minutes: 25)),
          title: 'Now',
        ),
      ]);
      await db.setFavorite(
        'xtream:http://provider.invalid|old-user',
        ContentKind.live,
        '42',
        true,
      );
      await db.savePlaybackPosition(
        'xtream:http://provider.invalid|old-user',
        ContentKind.movie,
        'movie-7',
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 90),
      );

      await db.migrateSourceNamespace(
        'xtream:http://provider.invalid|old-user',
        'stable-source-uuid',
      );

      expect(await db.readChannels('stable-source-uuid'), hasLength(1));
      expect(await db.readFavoriteIds('stable-source-uuid', ContentKind.live), {
        '42',
      });
      expect(
        await db.readPlaybackPosition(
          'stable-source-uuid',
          ContentKind.movie,
          'movie-7',
        ),
        isNotNull,
      );
      expect(
        (await db.nowNext('stable-source-uuid', now)).now['42']?.title,
        'Now',
      );
      expect(
        await db.readChannels('xtream:http://provider.invalid|old-user'),
        isEmpty,
      );
      await db.close();
    });

    test(
      'rewrites legacy M3U URL keys without losing favorites or EPG',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        const locator =
            'HTTP://Example.Invalid:80/a/../live/1.ts?username=u&password=p';
        final stableId = stableM3uChannelId(locator);
        final now = DateTime.now();
        await db.replaceLibrary(
          'stable-m3u-source',
          'M3U',
          const [Category(id: 'news', title: 'News')],
          const [
            Channel(
              id: locator,
              name: 'Channel',
              categoryId: 'news',
              extra: {'url': locator, 'tvgId': 'channel.one'},
            ),
          ],
        );
        await db.replaceEpg('stable-m3u-source', [
          Programme(
            channelId: locator,
            start: now.subtract(const Duration(minutes: 5)),
            stop: now.add(const Duration(minutes: 25)),
            title: 'Now',
          ),
        ]);
        await db.setFavorite(
          'stable-m3u-source',
          ContentKind.live,
          locator,
          true,
        );

        await db.migrateM3uChannelIds('stable-m3u-source');

        expect(
          (await db.readChannels('stable-m3u-source')).single.id,
          stableId,
        );
        expect(
          await db.readFavoriteIds('stable-m3u-source', ContentKind.live),
          {stableId},
        );
        expect(
          (await db.nowNext('stable-m3u-source', now)).now[stableId]?.title,
          'Now',
        );
        await db.close();
      },
    );
  });

  group('LibraryRepository', () {
    test(
      'fetches from the source on a cold load, then serves from cache',
      () async {
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
      },
    );

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

    test(
      'a success-empty EPG refresh clears stale programmes and advances the sync time',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        final source = _FakeSource()..epgResult = const [];
        final repo = LibraryRepository(source: source, db: db);
        final now = DateTime.now();

        await db.replaceEpg('fake', [
          Programme(
            channelId: 'a',
            start: now.subtract(const Duration(minutes: 30)),
            stop: now.add(const Duration(minutes: 30)),
            title: 'Stale',
          ),
        ]);

        final beforeLoad = DateTime.now();
        await repo.load(forceRefresh: true);

        final result = await db.nowNext('fake', now);
        expect(result.now, isEmpty);
        final synced = await db.lastEpgSynced('fake');
        expect(synced, isNotNull);
        expect(
          synced!.isAtSameMomentAs(beforeLoad) || synced.isAfter(beforeLoad),
          isTrue,
        );
        await db.close();
      },
    );

    test(
      'a failed EPG refresh retains cached programmes and does not advance the sync time',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        final now = DateTime.now();

        // Seed the sources row first (replaceLibrary), then the good EPG —
        // replaceEpg's timestamp update is a no-op if the sources row is
        // absent, so order matters for a meaningful t0.
        await db.replaceLibrary(
          'fake',
          'Fake',
          const [Category(id: 'c1', title: 'News')],
          const [
            Channel(id: 'a', name: 'A', categoryId: 'c1'),
            Channel(id: 'b', name: 'B', categoryId: 'c1'),
          ],
        );
        await db.replaceEpg('fake', [
          Programme(
            channelId: 'a',
            start: now.subtract(const Duration(minutes: 30)),
            stop: now.add(const Duration(minutes: 30)),
            title: 'Good',
          ),
        ]);
        final t0 = await db.lastEpgSynced('fake');
        expect(t0, isNotNull);

        final source = _FakeSource()..epgThrow = Exception('epg fetch failed');
        final repo = LibraryRepository(source: source, db: db);

        // Forced refresh: the channel-library replace no longer clobbers
        // epg_synced_at, and the EPG fetch itself fails; load()'s outer catch
        // swallows the exception so the channel list still loads.
        await repo.load(forceRefresh: true);

        // replaceEpg is never reached on a failed fetch, so the earlier
        // delete-then-insert never ran — the cached programme survives, and
        // the EPG sync timestamp is untouched.
        final result = await db.nowNext('fake', now);
        expect(result.now['a']?.title, 'Good');
        expect(await db.lastEpgSynced('fake'), t0);
        await db.close();
      },
    );
  });
}

/// Yields [first], then throws — used to exercise `replaceEpg` rolling back a
/// partially-inserted batch when the source iterable fails mid-stream.
Iterable<Programme> _throwingProgrammes(Programme first) sync* {
  yield first;
  throw StateError('epg source failed mid-stream');
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
  Future<List<Category>> categories() async => const [
    Category(id: 'c1', title: 'News'),
  ];

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
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('no catch-up');

  /// Configurable EPG behaviour for tests; defaults preserve prior behaviour
  /// (a no-EPG source returning success-empty).
  List<Programme> epgResult = const [];
  Object? epgThrow;

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    if (epgThrow != null) throw epgThrow!;
    return epgResult;
  }

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
