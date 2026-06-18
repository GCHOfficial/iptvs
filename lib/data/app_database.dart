import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../sources/source.dart';

/// Local SQLite cache of a source's categories, channels, and EPG, keyed by
/// [Source.id], so launches are instant and search/guide work offline.
class AppDatabase {
  final Database _db;
  AppDatabase._(this._db);

  static Future<AppDatabase> open() async {
    // Desktop platforms use the FFI implementation; mobile uses the plugin.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'iptv.db');

    final db = await openDatabase(
      path,
      version: 3,
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
            PRIMARY KEY (source_id, id)
          )
        ''');
        await _createProgrammes(db);
        await _createMediaTables(db);
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
      },
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
        category_id TEXT,
        poster      TEXT,
        description TEXT,
        year        TEXT,
        extra       TEXT,
        PRIMARY KEY (source_id, kind, id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_media_items_source_kind ON media_items(source_id, kind)',
    );
    await db.execute(
      'CREATE INDEX idx_media_items_source_kind_cat ON media_items(source_id, kind, category_id)',
    );
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

  Future<List<Channel>> readChannels(String sourceId) async {
    final rows = await _db.query(
      'channels',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'number, name',
    );
    return rows.map(_rowToChannel).toList();
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
  }) async {
    final where = StringBuffer('source_id = ? AND kind = ?');
    final args = <Object?>[sourceId, kind.name];
    if (categoryId != null) {
      where.write(' AND category_id = ?');
      args.add(categoryId);
    }
    final rows = await _db.query(
      'media_items',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'title',
    );
    return rows.map((r) => _rowToMediaItem(r, kind)).toList();
  }

  MediaItem _rowToMediaItem(Map<String, Object?> r, ContentKind kind) =>
      MediaItem(
        id: r['id'] as String,
        title: r['title'] as String,
        kind: kind,
        categoryId: r['category_id'] as String?,
        poster: r['poster'] as String?,
        description: r['description'] as String?,
        year: r['year'] as String?,
        extra: r['extra'] != null
            ? (jsonDecode(r['extra'] as String) as Map).cast<String, dynamic>()
            : const {},
      );

  Future<void> replaceMediaLibrary(
    String sourceId,
    ContentKind kind,
    List<MediaCategory> categories,
    List<MediaItem> items,
  ) async {
    await _db.transaction((txn) async {
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

      final batch = txn.batch();
      for (final c in categories) {
        batch.insert('media_categories', {
          'source_id': sourceId,
          'kind': kind.name,
          'id': c.id,
          'title': c.title,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final item in items) {
        batch.insert('media_items', {
          'source_id': sourceId,
          'kind': kind.name,
          'id': item.id,
          'title': item.title,
          'category_id': item.categoryId,
          'poster': item.poster,
          'description': item.description,
          'year': item.year,
          'extra': item.extra.isEmpty ? null : jsonEncode(item.extra),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      batch.insert('media_sync', {
        'source_id': sourceId,
        'kind': kind.name,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });
  }

  Channel _rowToChannel(Map<String, Object?> r) => Channel(
    id: r['id'] as String,
    name: r['name'] as String,
    number: r['number'] as int?,
    logo: r['logo'] as String?,
    categoryId: r['category_id'] as String?,
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

  Programme _rowToProgramme(Map<String, Object?> r) => Programme(
    channelId: r['channel_id'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
    stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
    title: r['title'] as String,
    description: r['description'] as String?,
  );

  Future<void> close() => _db.close();
}
