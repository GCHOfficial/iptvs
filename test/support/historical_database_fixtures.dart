import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema versions present in public repository tags.
const releasedSchemaVersions = [8, 9, 10, 11];

/// Creates a small, seeded database with the fresh-install schema used by a
/// tagged release. SQL is kept in source form so fixture changes are reviewable.
Future<void> createReleasedDatabaseFixture(String path, int version) async {
  if (!releasedSchemaVersions.contains(version)) {
    throw ArgumentError.value(version, 'version', 'not a released schema');
  }

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (final statement in _v8Schema) {
          await db.execute(statement);
        }
        if (version >= 9) {
          for (final statement in _v9Schema) {
            await db.execute(statement);
          }
        }
        if (version >= 10) {
          await db.execute(
            'ALTER TABLE channels ADD COLUMN '
            'archive_days INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (version >= 11) {
          for (final statement in _v11Schema) {
            await db.execute(statement);
          }
        }
        await _seed(db, version);
      },
    ),
  );
  await db.close();
}

Future<void> _seed(Database db, int version) async {
  const sourceId = 'released-source';
  await db.insert('sources', {
    'id': sourceId,
    'name': 'Released fixture',
    'synced_at': 1000,
    'epg_synced_at': 2000,
  });
  await db.insert('categories', {
    'source_id': sourceId,
    'id': 'news',
    'title': 'News',
  });
  await db.insert('channels', {
    'source_id': sourceId,
    'id': 'channel-1',
    'name': 'Fixture Channel',
    'number': 1,
    'category_id': 'news',
    'extra': '{"tvgId":"fixture.channel"}',
    if (version >= 10) 'archive_days': 7,
  });
  await db.insert('programmes', {
    'source_id': sourceId,
    'channel_id': 'channel-1',
    'start': 1000,
    'stop': 2000,
    'title': 'Fixture Programme',
  });
  await db.insert('media_items', {
    'source_id': sourceId,
    'kind': 'movie',
    'id': 'movie-1',
    'title': 'Fixture Movie',
    'display_order': 1,
  });
  if (version >= 9) {
    await db.insert('favorites', {
      'source_id': sourceId,
      'kind': 'live',
      'item_id': 'channel-1',
      'created_at': 3000,
    });
  }
  if (version >= 11) {
    await db.insert('playback_positions', {
      'source_id': sourceId,
      'kind': 'movie',
      'item_id': 'movie-1',
      'position_ms': 60000,
      'duration_ms': 600000,
      'updated_at': 4000,
    });
  }
  await db.insert('external_metadata', {
    'source_id': sourceId,
    'media_kind': 'movie',
    'media_id': 'movie-1',
    'provider': 'tmdb',
    'provider_key': 'movie/123',
    'title': 'Fixture Movie (TMDB)',
    'overview': 'Fixture overview.',
    'rating': 7.5,
    'refreshed_at': 5000,
  });
}

const _v8Schema = [
  '''
    CREATE TABLE sources (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      synced_at INTEGER,
      epg_synced_at INTEGER
    )
  ''',
  '''
    CREATE TABLE categories (
      source_id TEXT NOT NULL,
      id TEXT NOT NULL,
      title TEXT NOT NULL,
      PRIMARY KEY (source_id, id)
    )
  ''',
  '''
    CREATE TABLE channels (
      source_id TEXT NOT NULL,
      id TEXT NOT NULL,
      name TEXT NOT NULL,
      number INTEGER,
      logo TEXT,
      category_id TEXT,
      extra TEXT,
      PRIMARY KEY (source_id, id)
    )
  ''',
  '''
    CREATE TABLE programmes (
      source_id TEXT NOT NULL,
      channel_id TEXT NOT NULL,
      start INTEGER NOT NULL,
      stop INTEGER NOT NULL,
      title TEXT NOT NULL,
      description TEXT
    )
  ''',
  'CREATE INDEX idx_prog_lookup '
      'ON programmes(source_id, channel_id, start)',
  '''
    CREATE TABLE media_sync (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      synced_at INTEGER NOT NULL,
      loaded_pages INTEGER NOT NULL DEFAULT 1,
      total_pages INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (source_id, kind)
    )
  ''',
  '''
    CREATE TABLE media_categories (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      id TEXT NOT NULL,
      title TEXT NOT NULL,
      PRIMARY KEY (source_id, kind, id)
    )
  ''',
  '''
    CREATE TABLE media_items (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      id TEXT NOT NULL,
      title TEXT NOT NULL,
      parent_id TEXT,
      category_id TEXT,
      poster TEXT,
      backdrop TEXT,
      description TEXT,
      year TEXT,
      rating REAL,
      duration_seconds INTEGER,
      season_number INTEGER,
      episode_number INTEGER,
      provider_id TEXT,
      extra TEXT,
      display_order INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (source_id, kind, id)
    )
  ''',
  'CREATE INDEX idx_media_items_source_kind '
      'ON media_items(source_id, kind)',
  'CREATE INDEX idx_media_items_source_kind_cat '
      'ON media_items(source_id, kind, category_id)',
  '''
    CREATE TABLE media_enrichment (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      media_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      provider_id TEXT,
      title TEXT,
      overview TEXT,
      poster TEXT,
      backdrop TEXT,
      year TEXT,
      rating REAL,
      payload TEXT,
      refreshed_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, kind, media_id, provider)
    )
  ''',
  '''
    CREATE TABLE media_page_state (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      parent_id TEXT NOT NULL DEFAULT '',
      category_id TEXT NOT NULL DEFAULT '',
      synced_at INTEGER NOT NULL,
      loaded_pages INTEGER NOT NULL DEFAULT 1,
      total_pages INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (source_id, kind, parent_id, category_id)
    )
  ''',
  '''
    CREATE TABLE external_metadata (
      source_id TEXT NOT NULL,
      media_kind TEXT NOT NULL,
      media_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      provider_key TEXT NOT NULL,
      title TEXT,
      overview TEXT,
      poster TEXT,
      backdrop TEXT,
      year TEXT,
      rating REAL,
      payload TEXT,
      refreshed_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, media_kind, media_id, provider)
    )
  ''',
  'CREATE INDEX idx_external_metadata_provider '
      'ON external_metadata(provider, provider_key)',
  'CREATE INDEX idx_channels_source ON channels(source_id)',
  'CREATE INDEX idx_channels_source_cat ON channels(source_id, category_id)',
];

const _v9Schema = [
  '''
    CREATE TABLE favorites (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      item_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, kind, item_id)
    )
  ''',
  'CREATE INDEX idx_favorites_source_kind '
      'ON favorites(source_id, kind)',
];

const _v11Schema = [
  '''
    CREATE TABLE playback_positions (
      source_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      item_id TEXT NOT NULL,
      position_ms INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, kind, item_id)
    )
  ''',
  'CREATE INDEX idx_positions_source_updated '
      'ON playback_positions(source_id, updated_at)',
];
