import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile_sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../sources/source.dart';
import '../sources/source_identity.dart';

/// A saved VOD resume point (see `playback_positions`).
class PlaybackPosition {
  final ContentKind kind;
  final String itemId;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const PlaybackPosition({
    required this.kind,
    required this.itemId,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  /// 0..1 watched fraction (0 when the duration is unknown).
  double get progress => duration > Duration.zero
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;
}

/// Local SQLite cache of a source's categories, channels, and EPG, keyed by
/// [Source.id], so launches are instant and search/guide work offline.
class AppDatabase {
  final Database _db;
  AppDatabase._(this._db);

  /// Current schema version. Bump this and add an [onUpgrade] branch whenever
  /// the schema changes.
  static const schemaVersion = 11;

  static Future<AppDatabase> open() async {
    // Desktop platforms use the FFI implementation; mobile uses the plugin.
    final DatabaseFactory factory;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
    } else {
      factory = mobile_sqflite.databaseFactory;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'iptv.db');
    return _openWithFactory(path, factory);
  }

  /// Opens (and migrates) the database at an explicit [path] using the FFI
  /// factory. Lets tests exercise schema creation, migrations, and the
  /// read/write methods without depending on `path_provider`.
  @visibleForTesting
  static Future<AppDatabase> openAt(String path) async {
    sqfliteFfiInit();
    return _openWithFactory(path, databaseFactoryFfi);
  }

  static Future<AppDatabase> _openWithFactory(
    String path,
    DatabaseFactory factory,
  ) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, _) async {
          await db.execute('''
          CREATE TABLE sources (
            id           TEXT PRIMARY KEY,
            name         TEXT NOT NULL,
            synced_at    INTEGER,
            epg_synced_at INTEGER
          )
        ''');
          await db.execute('''
          CREATE TABLE categories (
            source_id TEXT NOT NULL,
            id        TEXT NOT NULL,
            title     TEXT NOT NULL,
            PRIMARY KEY (source_id, id)
          )
        ''');
          await db.execute('''
          CREATE TABLE channels (
            source_id   TEXT NOT NULL,
            id          TEXT NOT NULL,
            name        TEXT NOT NULL,
            number      INTEGER,
            logo        TEXT,
            category_id TEXT,
            extra       TEXT,
            archive_days INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (source_id, id)
          )
        ''');
          await _createProgrammes(db);
          await _createMediaTables(db);
          await _createFavorites(db);
          await _createPlaybackPositions(db);
          await db.execute(
            'CREATE INDEX idx_channels_source ON channels(source_id)',
          );
          await db.execute(
            'CREATE INDEX idx_channels_source_cat ON channels(source_id, category_id)',
          );
        },
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 2) {
            await db.execute(
              'ALTER TABLE sources ADD COLUMN epg_synced_at INTEGER',
            );
            await _createProgrammes(db);
          }
          if (oldV < 3) {
            await _createMediaTables(db);
          }
          if (oldV >= 3 && oldV < 4) {
            await _addMediaPagingColumns(db);
            await _createMediaEnrichment(db);
          }
          if (oldV < 5) {
            await _createMediaPageState(db);
          }
          if (oldV >= 3 && oldV < 6) {
            await _addMediaDisplayOrderColumn(db);
          }
          if (oldV >= 3 && oldV < 7) {
            await _addMediaHierarchyColumns(db);
            await _addMediaPageParentColumn(db);
            await _createExternalMetadata(db);
          }
          if (oldV < 8) {
            // Repair DBs created fresh at v7 (and pre-v3 upgrades): `onCreate` /
            // `_createMediaTables` built every media table except external_metadata,
            // so it was missing until now. Idempotent (CREATE TABLE IF NOT EXISTS).
            await _createExternalMetadata(db);
          }
          if (oldV < 9) {
            // User favorites. `_createFavorites` lives outside `_createMediaTables`,
            // so this repair branch covers every upgrade path (incl. pre-v3, which
            // skips the v3+ media ALTER branches). Idempotent.
            await _createFavorites(db);
          }
          if (oldV < 10) {
            // Catch-up window per channel. The `channels` table is built in
            // `onCreate` (not `_createMediaTables`), so every upgrade path lands
            // here; the ALTER is guarded against a pre-existing column.
            await _addChannelArchiveColumn(db);
          }
          if (oldV < 11) {
            // VOD resume positions. Standalone table (like `favorites`, outside
            // `_createMediaTables`), so this one repair branch covers every
            // upgrade path. Idempotent.
            await _createPlaybackPositions(db);
          }
        },
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _createProgrammes(Database db) async {
    await db.execute('''
      CREATE TABLE programmes (
        source_id   TEXT NOT NULL,
        channel_id  TEXT NOT NULL,
        start       INTEGER NOT NULL,
        stop        INTEGER NOT NULL,
        title       TEXT NOT NULL,
        description TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_prog_lookup ON programmes(source_id, channel_id, start)',
    );
  }

  static Future<void> _createMediaTables(Database db) async {
    await db.execute('''
      CREATE TABLE media_sync (
        source_id TEXT NOT NULL,
        kind      TEXT NOT NULL,
        synced_at INTEGER NOT NULL,
        loaded_pages INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (source_id, kind)
      )
    ''');
    await db.execute('''
      CREATE TABLE media_categories (
        source_id TEXT NOT NULL,
        kind      TEXT NOT NULL,
        id        TEXT NOT NULL,
        title     TEXT NOT NULL,
        PRIMARY KEY (source_id, kind, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE media_items (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        id          TEXT NOT NULL,
        title       TEXT NOT NULL,
        parent_id   TEXT,
        category_id TEXT,
        poster      TEXT,
        backdrop    TEXT,
        description TEXT,
        year        TEXT,
        rating      REAL,
        duration_seconds INTEGER,
        season_number INTEGER,
        episode_number INTEGER,
        provider_id TEXT,
        extra       TEXT,
        display_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_id, kind, id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_media_items_source_kind ON media_items(source_id, kind)',
    );
    await db.execute(
      'CREATE INDEX idx_media_items_source_kind_cat ON media_items(source_id, kind, category_id)',
    );
    await _createMediaEnrichment(db);
    await _createMediaPageState(db);
    await _createExternalMetadata(db);
  }

  static Future<void> _addMediaPagingColumns(Database db) async {
    await db.execute(
      'ALTER TABLE media_sync ADD COLUMN loaded_pages INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE media_sync ADD COLUMN total_pages INTEGER NOT NULL DEFAULT 1',
    );
  }

  static Future<void> _createMediaEnrichment(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_enrichment (
        source_id     TEXT NOT NULL,
        kind          TEXT NOT NULL,
        media_id      TEXT NOT NULL,
        provider      TEXT NOT NULL,
        provider_id   TEXT,
        title         TEXT,
        overview      TEXT,
        poster        TEXT,
        backdrop      TEXT,
        year          TEXT,
        rating        REAL,
        payload       TEXT,
        refreshed_at  INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, media_id, provider)
      )
    ''');
  }

  static Future<void> _createMediaPageState(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_page_state (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        parent_id   TEXT NOT NULL DEFAULT '',
        category_id TEXT NOT NULL DEFAULT '',
        synced_at   INTEGER NOT NULL,
        loaded_pages INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (source_id, kind, parent_id, category_id)
      )
    ''');
  }

  static Future<void> _addMediaDisplayOrderColumn(Database db) async {
    await db.execute(
      'ALTER TABLE media_items ADD COLUMN display_order INTEGER NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _addMediaHierarchyColumns(Database db) async {
    Future<void> add(String sql) async {
      try {
        await db.execute(sql);
      } on DatabaseException catch (e) {
        if (!_isDuplicateColumn(e)) rethrow;
      }
    }

    await add('ALTER TABLE media_items ADD COLUMN parent_id TEXT');
    await add('ALTER TABLE media_items ADD COLUMN backdrop TEXT');
    await add('ALTER TABLE media_items ADD COLUMN rating REAL');
    await add('ALTER TABLE media_items ADD COLUMN duration_seconds INTEGER');
    await add('ALTER TABLE media_items ADD COLUMN season_number INTEGER');
    await add('ALTER TABLE media_items ADD COLUMN episode_number INTEGER');
    await add('ALTER TABLE media_items ADD COLUMN provider_id TEXT');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_parent ON media_items(source_id, kind, parent_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_provider ON media_items(source_id, kind, provider_id)',
    );
  }

  static Future<void> _addMediaPageParentColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE media_page_state ADD COLUMN parent_id TEXT NOT NULL DEFAULT ""',
      );
    } on DatabaseException catch (e) {
      if (!_isDuplicateColumn(e)) rethrow;
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_page_state_v7 (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        parent_id   TEXT NOT NULL DEFAULT '',
        category_id TEXT NOT NULL DEFAULT '',
        synced_at   INTEGER NOT NULL,
        loaded_pages INTEGER NOT NULL DEFAULT 1,
        total_pages INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (source_id, kind, parent_id, category_id)
      )
    ''');
    await db.execute('''
      INSERT OR REPLACE INTO media_page_state_v7
      (source_id, kind, parent_id, category_id, synced_at, loaded_pages, total_pages)
      SELECT source_id, kind, COALESCE(parent_id, ''), category_id,
             synced_at, loaded_pages, total_pages
      FROM media_page_state
    ''');
    await db.execute('DROP TABLE media_page_state');
    await db.execute(
      'ALTER TABLE media_page_state_v7 RENAME TO media_page_state',
    );
  }

  static Future<void> _addChannelArchiveColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE channels ADD COLUMN archive_days INTEGER NOT NULL DEFAULT 0',
      );
    } on DatabaseException catch (e) {
      if (!_isDuplicateColumn(e)) rethrow;
    }
  }

  static bool _isDuplicateColumn(DatabaseException e) {
    final message = e.toString().toLowerCase();
    return message.contains('duplicate column') ||
        message.contains('duplicate column name');
  }

  static Future<void> _createExternalMetadata(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS external_metadata (
        source_id    TEXT NOT NULL,
        media_kind   TEXT NOT NULL,
        media_id     TEXT NOT NULL,
        provider     TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        title        TEXT,
        overview     TEXT,
        poster       TEXT,
        backdrop     TEXT,
        year         TEXT,
        rating       REAL,
        payload      TEXT,
        refreshed_at INTEGER NOT NULL,
        PRIMARY KEY (source_id, media_kind, media_id, provider)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_external_metadata_provider ON external_metadata(provider, provider_key)',
    );
  }

  static Future<void> _createFavorites(Database db) async {
    // Favorited live channels / movies / series, keyed by their source-stable
    // ids. Deliberately separate from `channels` / `media_items` so a library
    // refresh (which replaces those rows) never drops a user's favorites.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites (
        source_id  TEXT NOT NULL,
        kind       TEXT NOT NULL,
        item_id    TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, item_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_favorites_source_kind ON favorites(source_id, kind)',
    );
  }

  static Future<void> _createPlaybackPositions(Database db) async {
    // VOD resume positions (movies/episodes), keyed like `favorites` by the
    // source-stable ids and deliberately separate from `media_items` so a
    // library refresh never drops them. Rows are removed when playback
    // finishes (>~95%) or the media is deleted upstream.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_positions (
        source_id   TEXT NOT NULL,
        kind        TEXT NOT NULL,
        item_id     TEXT NOT NULL,
        position_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, item_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_positions_source_updated '
      'ON playback_positions(source_id, updated_at)',
    );
  }

  /// Atomically moves every cache and user-state row from the pre-PR4
  /// credential-derived namespace to the stable [SourceConfig.id] namespace.
  ///
  /// A destination collision aborts and rolls back the complete transaction;
  /// callers must run this before publishing or caching rows under [toSourceId].
  Future<void> migrateSourceNamespace(
    String fromSourceId,
    String toSourceId,
  ) async {
    if (fromSourceId == toSourceId) return;
    await _db.transaction((txn) async {
      for (final table in const [
        'categories',
        'channels',
        'programmes',
        'media_sync',
        'media_categories',
        'media_items',
        'media_enrichment',
        'media_page_state',
        'external_metadata',
        'favorites',
        'playback_positions',
      ]) {
        await txn.update(
          table,
          {'source_id': toSourceId},
          where: 'source_id = ?',
          whereArgs: [fromSourceId],
        );
      }
      await txn.update(
        'sources',
        {'id': toSourceId},
        where: 'id = ?',
        whereArgs: [fromSourceId],
      );
    });
  }

  /// Rewrites legacy raw-URL M3U channel keys to opaque normalized hashes while
  /// preserving cached channels, EPG references, and live favorites in one
  /// transaction. Equivalent locators intentionally collapse to one channel;
  /// their EPG rows and favorite state are retained under the shared identity.
  Future<void> migrateM3uChannelIds(String sourceId) async {
    await _db.transaction((txn) async {
      final mappings = <String, String>{};
      final channelRows = await txn.query(
        'channels',
        columns: ['id', 'extra'],
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      for (final row in channelRows) {
        final oldId = row['id'] as String;
        if (isStableM3uChannelId(oldId)) continue;
        final extra = row['extra'] as String?;
        final decoded = extra == null
            ? const <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(extra) as Map);
        final locator = decoded['url']?.toString() ?? oldId;
        mappings[oldId] = stableM3uChannelId(locator);
      }

      // Favorites/EPG can outlive a replaced channel cache. Their legacy M3U
      // keys were the raw locator itself, so migrate any remaining references.
      final favoriteRows = await txn.query(
        'favorites',
        columns: ['item_id'],
        where: 'source_id = ? AND kind = ? AND item_id NOT LIKE ?',
        whereArgs: [sourceId, ContentKind.live.name, 'm3u-channel:%'],
      );
      for (final row in favoriteRows) {
        final oldId = row['item_id'] as String;
        mappings.putIfAbsent(oldId, () => stableM3uChannelId(oldId));
      }
      final programmeRows = await txn.rawQuery(
        'SELECT DISTINCT channel_id FROM programmes '
        'WHERE source_id = ? AND channel_id NOT LIKE ?',
        [sourceId, 'm3u-channel:%'],
      );
      for (final row in programmeRows) {
        final oldId = row['channel_id'] as String;
        mappings.putIfAbsent(oldId, () => stableM3uChannelId(oldId));
      }

      for (final entry in mappings.entries) {
        final oldId = entry.key;
        final newId = entry.value;
        if (oldId == newId) continue;
        await txn.rawInsert(
          'INSERT OR IGNORE INTO channels '
          '(source_id, id, name, number, logo, category_id, extra, archive_days) '
          'SELECT source_id, ?, name, number, logo, category_id, extra, archive_days '
          'FROM channels WHERE source_id = ? AND id = ?',
          [newId, sourceId, oldId],
        );
        await txn.delete(
          'channels',
          where: 'source_id = ? AND id = ?',
          whereArgs: [sourceId, oldId],
        );
        await txn.update(
          'programmes',
          {'channel_id': newId},
          where: 'source_id = ? AND channel_id = ?',
          whereArgs: [sourceId, oldId],
        );
        await txn.rawInsert(
          'INSERT OR IGNORE INTO favorites (source_id, kind, item_id, created_at) '
          'SELECT source_id, kind, ?, created_at FROM favorites '
          'WHERE source_id = ? AND kind = ? AND item_id = ?',
          [newId, sourceId, ContentKind.live.name, oldId],
        );
        await txn.delete(
          'favorites',
          where: 'source_id = ? AND kind = ? AND item_id = ?',
          whereArgs: [sourceId, ContentKind.live.name, oldId],
        );
      }
    });
  }

  // ── playback positions (VOD resume) ───────────────────────────────────────

  /// Upsert the resume position for an item; clears the row instead when the
  /// user is effectively done (past [kFinishedFraction] of the duration), so
  /// finished titles drop out of "Continue watching".
  static const kFinishedFraction = 0.95;

  Future<void> savePlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId, {
    required Duration position,
    required Duration duration,
  }) async {
    if (duration > Duration.zero &&
        position.inMilliseconds >=
            duration.inMilliseconds * kFinishedFraction) {
      await clearPlaybackPosition(sourceId, kind, itemId);
      return;
    }
    // Ignore the first instants — a resume row for second 0 is just noise.
    if (position < const Duration(seconds: 10)) return;
    await _db.insert('playback_positions', {
      'source_id': sourceId,
      'kind': kind.name,
      'item_id': itemId,
      'position_ms': position.inMilliseconds,
      'duration_ms': duration.inMilliseconds,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<PlaybackPosition?> readPlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) async {
    final rows = await _db.query(
      'playback_positions',
      where: 'source_id = ? AND kind = ? AND item_id = ?',
      whereArgs: [sourceId, kind.name, itemId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToPlaybackPosition(rows.first);
  }

  Future<void> clearPlaybackPosition(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) => _db.delete(
    'playback_positions',
    where: 'source_id = ? AND kind = ? AND item_id = ?',
    whereArgs: [sourceId, kind.name, itemId],
  );

  /// Most recently watched in-progress items for [sourceId], newest first —
  /// the data behind the "Continue watching" rail.
  Future<List<PlaybackPosition>> readRecentPositions(
    String sourceId, {
    int limit = 20,
  }) async {
    final rows = await _db.query(
      'playback_positions',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_rowToPlaybackPosition).toList();
  }

  static PlaybackPosition _rowToPlaybackPosition(Map<String, Object?> r) =>
      PlaybackPosition(
        kind: ContentKind.values.byName(r['kind'] as String),
        itemId: r['item_id'] as String,
        position: Duration(milliseconds: r['position_ms'] as int),
        duration: Duration(milliseconds: r['duration_ms'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );

  // ── favorites ─────────────────────────────────────────────────────────────

  /// The set of favorited item ids for [sourceId] / [kind].
  Future<Set<String>> readFavoriteIds(String sourceId, ContentKind kind) async {
    final rows = await _db.query(
      'favorites',
      columns: ['item_id'],
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    return {for (final r in rows) r['item_id'] as String};
  }

  Future<bool> isFavorite(
    String sourceId,
    ContentKind kind,
    String itemId,
  ) async {
    final rows = await _db.query(
      'favorites',
      columns: ['item_id'],
      where: 'source_id = ? AND kind = ? AND item_id = ?',
      whereArgs: [sourceId, kind.name, itemId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Adds or removes a favorite. Returns the new favorited state.
  Future<bool> setFavorite(
    String sourceId,
    ContentKind kind,
    String itemId,
    bool favorite,
  ) async {
    if (favorite) {
      await _db.insert('favorites', {
        'source_id': sourceId,
        'kind': kind.name,
        'item_id': itemId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await _db.delete(
        'favorites',
        where: 'source_id = ? AND kind = ? AND item_id = ?',
        whereArgs: [sourceId, kind.name, itemId],
      );
    }
    return favorite;
  }

  // ── channels / categories ───────────────────────────────────────────────

  Future<DateTime?> lastSynced(String sourceId) =>
      _readTime('synced_at', sourceId);

  Future<DateTime?> lastEpgSynced(String sourceId) =>
      _readTime('epg_synced_at', sourceId);

  Future<DateTime?> _readTime(String column, String sourceId) async {
    final rows = await _db.query(
      'sources',
      columns: [column],
      where: 'id = ?',
      whereArgs: [sourceId],
    );
    final v = rows.isEmpty ? null : rows.first[column];
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
  }

  Future<List<Category>> readCategories(String sourceId) async {
    final rows = await _db.query(
      'categories',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'title',
    );
    return rows
        .map(
          (r) => Category(id: r['id'] as String, title: r['title'] as String),
        )
        .toList();
  }

  /// Above this many rows, row→model mapping (a jsonDecode of `extra` per
  /// row) moves to a background isolate — it's the cache-hit startup path, so
  /// on a 50k-channel playlist it would otherwise jank every launch. Below it
  /// the isolate spawn costs more than the mapping.
  static const _isolateMapThreshold = 500;

  Future<List<Channel>> readChannels(String sourceId) async {
    final rows = await _db.query(
      'channels',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'number, name',
    );
    if (rows.length < _isolateMapThreshold) {
      return rows.map(_rowToChannel).toList();
    }
    return Isolate.run(() => rows.map(_rowToChannel).toList());
  }

  // ── movies / series / generic media ──────────────────────────────────────

  Future<DateTime?> lastMediaSynced(String sourceId, ContentKind kind) async {
    final rows = await _db.query(
      'media_sync',
      columns: ['synced_at'],
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['synced_at'] as int);
  }

  Future<({DateTime syncedAt, int loadedPages, int totalPages})?>
  mediaSyncState(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    final categoryKey = categoryId ?? '';
    final parentKey = parentId ?? '';
    final pageRows = await _db.query(
      'media_page_state',
      where: 'source_id = ? AND kind = ? AND parent_id = ? AND category_id = ?',
      whereArgs: [sourceId, kind.name, parentKey, categoryKey],
    );
    if (pageRows.isNotEmpty) {
      final row = pageRows.first;
      return (
        syncedAt: DateTime.fromMillisecondsSinceEpoch(row['synced_at'] as int),
        loadedPages: row['loaded_pages'] as int? ?? 1,
        totalPages: row['total_pages'] as int? ?? 1,
      );
    }
    if (categoryId != null || parentId != null) return null;
    final rows = await _db.query(
      'media_sync',
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      syncedAt: DateTime.fromMillisecondsSinceEpoch(row['synced_at'] as int),
      loadedPages: row['loaded_pages'] as int? ?? 1,
      totalPages: row['total_pages'] as int? ?? 1,
    );
  }

  Future<List<MediaCategory>> readMediaCategories(
    String sourceId,
    ContentKind kind,
  ) async {
    final rows = await _db.query(
      'media_categories',
      where: 'source_id = ? AND kind = ?',
      whereArgs: [sourceId, kind.name],
      orderBy: 'title',
    );
    return rows
        .map(
          (r) => MediaCategory(
            id: r['id'] as String,
            title: r['title'] as String,
            kind: kind,
          ),
        )
        .toList();
  }

  Future<List<MediaItem>> readMediaItems(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    if (parentId != null) {
      where.write(' AND parent_id = ?');
      args.add(parentId);
    }
    final rows = await _db.query(
      'media_items',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'display_order, title',
    );
    if (rows.length < _isolateMapThreshold) {
      return rows.map((r) => _rowToMediaItem(r, kind)).toList();
    }
    return Isolate.run(
      () => rows.map((r) => _rowToMediaItem(r, kind)).toList(),
    );
  }

  /// The cached media items among [ids] (any order). Used to materialize the
  /// "Continue watching" rail from saved playback positions.
  Future<List<MediaItem>> readMediaItemsByIds(
    String sourceId,
    ContentKind kind,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _db.query(
      'media_items',
      where: 'source_id = ? AND kind = ? AND id IN ($placeholders)',
      whereArgs: [sourceId, kind.name, ...ids],
    );
    return rows.map((r) => _rowToMediaItem(r, kind)).toList();
  }

  // Static (not instance) so the Isolate.run closures above capture only the
  // rows — capturing `this` would drag the non-sendable Database across.
  static MediaItem _rowToMediaItem(Map<String, Object?> r, ContentKind kind) =>
      MediaItem(
        id: r['id'] as String,
        title: r['title'] as String,
        kind: kind,
        parentId: r['parent_id'] as String?,
        categoryId: r['category_id'] as String?,
        poster: r['poster'] as String?,
        backdrop: r['backdrop'] as String?,
        description: r['description'] as String?,
        year: r['year'] as String?,
        rating: _readDouble(r['rating']),
        durationSeconds: _readInt(r['duration_seconds']),
        seasonNumber: _readInt(r['season_number']),
        episodeNumber: _readInt(r['episode_number']),
        providerId: r['provider_id'] as String?,
        extra: r['extra'] != null
            ? (jsonDecode(r['extra'] as String) as Map).cast<String, dynamic>()
            : const {},
      );

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static double? _readDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value == null) return null;
    return double.tryParse(value.toString());
  }

  Future<void> replaceMediaLibrary(
    String sourceId,
    ContentKind kind,
    List<MediaCategory> categories,
    List<MediaItem> items, {
    String? categoryId,
    String? parentId,
    int loadedPages = 1,
    int totalPages = 1,
  }) async {
    await _db.transaction((txn) async {
      if (categoryId == null && parentId == null) {
        await txn.delete(
          'media_categories',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, kind.name],
        );
        await txn.delete(
          'media_items',
          where: 'source_id = ? AND kind = ?',
          whereArgs: [sourceId, kind.name],
        );
      } else {
        final where = StringBuffer('source_id = ? AND kind = ?');
        final args = <Object?>[sourceId, kind.name];
        if (categoryId != null) {
          where.write(' AND category_id = ?');
          args.add(categoryId);
        }
        if (parentId != null) {
          where.write(' AND parent_id = ?');
          args.add(parentId);
        }
        await txn.delete(
          'media_items',
          where: where.toString(),
          whereArgs: args,
        );
      }

      final batch = txn.batch();
      if (categoryId == null) {
        for (final c in categories) {
          batch.insert('media_categories', {
            'source_id': sourceId,
            'kind': kind.name,
            'id': c.id,
            'title': c.title,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        batch.insert(
          'media_items',
          _mediaItemRow(
            sourceId,
            kind,
            item,
            parentId: parentId,
            displayOrder: i,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert('media_sync', {
        'source_id': sourceId,
        'kind': kind.name,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('media_page_state', {
        'source_id': sourceId,
        'kind': kind.name,
        'parent_id': parentId ?? '',
        'category_id': categoryId ?? '',
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });
  }

  Future<void> appendMediaItems(
    String sourceId,
    ContentKind kind,
    List<MediaItem> items, {
    String? categoryId,
    String? parentId,
    required int loadedPages,
    required int totalPages,
  }) async {
    await _db.transaction((txn) async {
      final startOrder = await _nextMediaDisplayOrder(
        txn,
        sourceId,
        kind,
        categoryId,
        parentId,
      );

      final batch = txn.batch();
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        batch.insert(
          'media_items',
          _mediaItemRow(
            sourceId,
            kind,
            item,
            parentId: parentId,
            displayOrder: startOrder + i,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      batch.insert('media_sync', {
        'source_id': sourceId,
        'kind': kind.name,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      batch.insert('media_page_state', {
        'source_id': sourceId,
        'kind': kind.name,
        'parent_id': parentId ?? '',
        'category_id': categoryId ?? '',
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'loaded_pages': loadedPages,
        'total_pages': totalPages < loadedPages ? loadedPages : totalPages,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });
  }

  Future<int> _nextMediaDisplayOrder(
    Transaction txn,
    String sourceId,
    ContentKind kind,
    String? categoryId,
    String? parentId,
  ) async {
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    if (parentId != null) {
      where.write(' AND parent_id = ?');
      args.add(parentId);
    }
    final rows = await txn.query(
      'media_items',
      columns: ['MAX(display_order) AS max_order'],
      where: where.toString(),
      whereArgs: args,
    );
    final max = rows.first['max_order'] as int?;
    return max == null ? 0 : max + 1;
  }

  Map<String, Object?> _mediaItemRow(
    String sourceId,
    ContentKind kind,
    MediaItem item, {
    String? parentId,
    required int displayOrder,
  }) => {
    'source_id': sourceId,
    'kind': kind.name,
    'id': item.id,
    'title': item.title,
    'parent_id': item.parentId ?? parentId,
    'category_id': item.categoryId,
    'poster': item.poster,
    'backdrop': item.backdrop,
    'description': item.description,
    'year': item.year,
    'rating': item.rating,
    'duration_seconds': item.durationSeconds,
    'season_number': item.seasonNumber,
    'episode_number': item.episodeNumber,
    'provider_id': item.providerId,
    'extra': item.extra.isEmpty ? null : jsonEncode(item.extra),
    'display_order': displayOrder,
  };

  Future<void> updateMediaDisplayFields(
    String sourceId,
    List<MediaItem> items,
  ) async {
    if (items.isEmpty) return;
    final batch = _db.batch();
    for (final item in items) {
      batch.update(
        'media_items',
        {
          'title': item.title,
          'poster': item.poster,
          'backdrop': item.backdrop,
          'description': item.description,
          'year': item.year,
          'rating': item.rating,
          'provider_id': item.providerId,
          'extra': item.extra.isEmpty ? null : jsonEncode(item.extra),
        },
        where: 'source_id = ? AND kind = ? AND id = ?',
        whereArgs: [sourceId, item.kind.name, item.id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> clearExternalMetadata({String? sourceId}) async {
    if (sourceId == null) {
      await _db.delete('external_metadata');
      return;
    }
    await _db.delete(
      'external_metadata',
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> resetEnrichedMediaDisplayFields({String? sourceId}) async {
    final rows = await _db.query(
      'media_items',
      where: sourceId == null ? null : 'source_id = ?',
      whereArgs: sourceId == null ? null : [sourceId],
    );
    if (rows.isEmpty) return;
    final batch = _db.batch();
    for (final row in rows) {
      final item = _rowToMediaItem(
        row,
        ContentKind.values.byName(row['kind'] as String),
      );
      final raw = item.extra;
      final title =
          _firstString(raw, [
            'providerTitle',
            'sourceTitle',
            'name',
            'title',
          ]) ??
          item.title;
      batch.update(
        'media_items',
        {
          'title': title,
          'poster': _firstString(raw, [
            'screenshot_uri',
            'poster',
            'cover',
            'stream_icon',
            'movie_image',
            'cover_big',
          ]),
          'backdrop': _firstString(raw, [
            'backdrop',
            'background',
            'cover_big',
          ]),
          'description': _firstString(raw, ['description', 'descr', 'plot']),
          'year': _firstString(raw, ['year', 'released', 'release_date']),
          'rating': _readDouble(raw['rating_imdb'] ?? raw['rating']),
          'provider_id': _firstString(raw, [
            'tmdb_id',
            'imdb_id',
            'kinopoisk_id',
          ]),
          'extra': raw.isEmpty ? null : jsonEncode(raw),
        },
        where: 'source_id = ? AND kind = ? AND id = ?',
        whereArgs: [row['source_id'], row['kind'], row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return null;
  }

  Future<ExternalMetadata?> readExternalMetadata(
    String sourceId,
    MediaItem item,
    String provider,
  ) async {
    final rows = await _db.query(
      'external_metadata',
      where:
          'source_id = ? AND media_kind = ? AND media_id = ? AND provider = ?',
      whereArgs: [sourceId, item.kind.name, item.id, provider],
    );
    if (rows.isEmpty) return null;
    return _rowToExternalMetadata(rows.first);
  }

  Future<Map<String, ExternalMetadata>> readExternalMetadataForItems(
    String sourceId,
    List<MediaItem> items,
    String provider,
  ) async {
    if (items.isEmpty) return const {};
    final out = <String, ExternalMetadata>{};
    final ids = items.map((item) => item.id).where((id) => id.isNotEmpty);
    final uniqueIds = ids.toSet().toList();
    for (var start = 0; start < uniqueIds.length; start += 500) {
      final chunk = uniqueIds.skip(start).take(500).toList();
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _db.query(
        'external_metadata',
        where: 'source_id = ? AND provider = ? AND media_id IN ($placeholders)',
        whereArgs: [sourceId, provider, ...chunk],
      );
      for (final row in rows) {
        out[row['media_id'] as String] = _rowToExternalMetadata(row);
      }
    }
    return out;
  }

  Future<void> cacheExternalMetadata(
    String sourceId,
    MediaItem item,
    ExternalMetadata metadata,
  ) async {
    await _db.insert('external_metadata', {
      'source_id': sourceId,
      'media_kind': item.kind.name,
      'media_id': item.id,
      'provider': metadata.provider,
      'provider_key': metadata.providerKey,
      'title': metadata.title,
      'overview': metadata.overview,
      'poster': metadata.poster,
      'backdrop': metadata.backdrop,
      'year': metadata.year,
      'rating': metadata.rating,
      'payload': metadata.payload.isEmpty ? null : jsonEncode(metadata.payload),
      'refreshed_at': metadata.refreshedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  ExternalMetadata _rowToExternalMetadata(Map<String, Object?> row) =>
      ExternalMetadata(
        provider: row['provider'] as String,
        providerKey: row['provider_key'] as String,
        title: row['title'] as String?,
        overview: row['overview'] as String?,
        poster: row['poster'] as String?,
        backdrop: row['backdrop'] as String?,
        year: row['year'] as String?,
        rating: _readDouble(row['rating']),
        payload: row['payload'] == null
            ? const {}
            : (jsonDecode(row['payload'] as String) as Map)
                  .cast<String, dynamic>(),
        refreshedAt: DateTime.fromMillisecondsSinceEpoch(
          row['refreshed_at'] as int,
        ),
      );

  static Channel _rowToChannel(Map<String, Object?> r) => Channel(
    id: r['id'] as String,
    name: r['name'] as String,
    number: r['number'] as int?,
    logo: r['logo'] as String?,
    categoryId: r['category_id'] as String?,
    archiveDays: (r['archive_days'] as int?) ?? 0,
    extra: r['extra'] != null
        ? (jsonDecode(r['extra'] as String) as Map).cast<String, dynamic>()
        : const {},
  );

  /// Replace all cached channels/categories for a source in one transaction.
  Future<void> replaceLibrary(
    String sourceId,
    String name,
    List<Category> categories,
    List<Channel> channels,
  ) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'categories',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      await txn.delete(
        'channels',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );

      final batch = txn.batch();
      for (final c in categories) {
        batch.insert('categories', {
          'source_id': sourceId,
          'id': c.id,
          'title': c.title,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final ch in channels) {
        batch.insert('channels', {
          'source_id': sourceId,
          'id': ch.id,
          'name': ch.name,
          'number': ch.number,
          'logo': ch.logo,
          'category_id': ch.categoryId,
          'extra': ch.extra.isEmpty ? null : jsonEncode(ch.extra),
          'archive_days': ch.archiveDays,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      batch.insert('sources', {
        'id': sourceId,
        'name': name,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });
  }

  // ── EPG ───────────────────────────────────────────────────────────────────

  Future<void> replaceEpg(String sourceId, List<Programme> programmes) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'programmes',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      final batch = txn.batch();
      for (final p in programmes) {
        batch.insert('programmes', {
          'source_id': sourceId,
          'channel_id': p.channelId,
          'start': p.start.millisecondsSinceEpoch,
          'stop': p.stop.millisecondsSinceEpoch,
          'title': p.title,
          'description': p.description,
        });
      }
      await batch.commit(noResult: true);
      await txn.update(
        'sources',
        {'epg_synced_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [sourceId],
      );
    });
  }

  /// Current and next programme per channel at time [at].
  Future<({Map<String, Programme> now, Map<String, Programme> next})> nowNext(
    String sourceId,
    DateTime at,
  ) async {
    final t = at.millisecondsSinceEpoch;
    final now = <String, Programme>{};
    final next = <String, Programme>{};

    final currentRows = await _db.rawQuery(
      'SELECT channel_id, title, start, stop, description FROM programmes '
      'WHERE source_id = ? AND start <= ? AND stop > ?',
      [sourceId, t, t],
    );
    for (final r in currentRows) {
      now[r['channel_id'] as String] = _rowToProgramme(r);
    }

    // SQLite returns the row matching MIN(start) for the bare columns.
    final nextRows = await _db.rawQuery(
      'SELECT channel_id, title, MIN(start) AS start, stop, description '
      'FROM programmes WHERE source_id = ? AND start > ? GROUP BY channel_id',
      [sourceId, t],
    );
    for (final r in nextRows) {
      next[r['channel_id'] as String] = _rowToProgramme(r);
    }
    return (now: now, next: next);
  }

  /// Cached programmes for one channel overlapping the `[from, to)` window,
  /// ordered by start — the catch-up guide's data source. A programme overlaps
  /// the window when it starts before `to` and ends after `from`. Served by
  /// `idx_prog_lookup(source_id, channel_id, start)`.
  Future<List<Programme>> programmesForChannel(
    String sourceId,
    String channelId, {
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _db.rawQuery(
      'SELECT channel_id, title, start, stop, description FROM programmes '
      'WHERE source_id = ? AND channel_id = ? AND start < ? AND stop > ? '
      'ORDER BY start',
      [
        sourceId,
        channelId,
        to.millisecondsSinceEpoch,
        from.millisecondsSinceEpoch,
      ],
    );
    return rows.map(_rowToProgramme).toList();
  }

  /// Programmes overlapping [from]..[to] for a batch of channels in one query
  /// (the EPG grid's visible window), grouped by channel id, each ordered by
  /// start. Channels without cached EPG simply have no entry.
  Future<Map<String, List<Programme>>> programmesForChannels(
    String sourceId,
    List<String> channelIds, {
    required DateTime from,
    required DateTime to,
  }) async {
    if (channelIds.isEmpty) return const {};
    final placeholders = List.filled(channelIds.length, '?').join(', ');
    final rows = await _db.rawQuery(
      'SELECT channel_id, title, start, stop, description FROM programmes '
      'WHERE source_id = ? AND channel_id IN ($placeholders) '
      'AND start < ? AND stop > ? '
      'ORDER BY channel_id, start',
      [
        sourceId,
        ...channelIds,
        to.millisecondsSinceEpoch,
        from.millisecondsSinceEpoch,
      ],
    );
    final out = <String, List<Programme>>{};
    for (final row in rows) {
      final programme = _rowToProgramme(row);
      (out[programme.channelId] ??= []).add(programme);
    }
    return out;
  }

  Programme _rowToProgramme(Map<String, Object?> r) => Programme(
    channelId: r['channel_id'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
    stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
    title: r['title'] as String,
    description: r['description'] as String?,
  );

  Future<void> close() => _db.close();
}
