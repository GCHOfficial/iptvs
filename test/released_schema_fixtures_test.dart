import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/historical_database_fixtures.dart';

/// A schema signature covering table columns, indexes (name-keyed, ignoring
/// creation order), and foreign keys — used to compare a migrated database
/// against a fresh install of the same target version.
Future<Map<String, Object?>> schemaSignature(Database db) async {
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  final signature = <String, Object?>{};
  for (final tableRow in tables) {
    final table = tableRow['name'] as String;
    final columns = await db.rawQuery('PRAGMA table_info("$table")');
    final indexList = await db.rawQuery('PRAGMA index_list("$table")');
    final indexes = <String, Object?>{};
    for (final index in indexList) {
      final name = index['name'] as String;
      final indexInfo = await db.rawQuery('PRAGMA index_info("$name")');
      indexes[name] = {
        'unique': index['unique'],
        'origin': index['origin'],
        'partial': index['partial'],
        'columns': indexInfo,
      };
    }
    final foreignKeys = await db.rawQuery('PRAGMA foreign_key_list("$table")');
    signature[table] = {
      'columns': columns,
      'indexes': indexes,
      'foreignKeys': foreignKeys,
    };
  }
  return signature;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('iptvs_released_schema');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  for (final version in releasedSchemaVersions) {
    test(
      'released v$version fixture upgrades and preserves seeded data',
      () async {
        final path = '${tempDir.path}/v$version.db';
        await createReleasedDatabaseFixture(path, version);

        final raw = await databaseFactoryFfi.openDatabase(path);
        expect(await raw.getVersion(), version);
        await raw.close();

        final db = await AppDatabase.openAt(path);
        final channels = await db.readChannels('released-source');
        expect(channels.single.name, 'Fixture Channel');
        expect(channels.single.archiveDays, version >= 10 ? 7 : 0);
        expect(
          await db.readFavoriteIds('released-source', ContentKind.live),
          version >= 9 ? {'channel-1'} : isEmpty,
        );
        final position = await db.readPlaybackPosition(
          'released-source',
          ContentKind.movie,
          'movie-1',
        );
        if (version >= 11) {
          expect(position?.position, const Duration(minutes: 1));
        } else {
          expect(position, isNull);
        }
        final programmes = await db.programmesForChannel(
          'released-source',
          'channel-1',
          from: DateTime.fromMillisecondsSinceEpoch(0),
          to: DateTime.fromMillisecondsSinceEpoch(10000),
        );
        expect(programmes.single.title, 'Fixture Programme');
        final metadata = await db.readExternalMetadata(
          'released-source',
          const MediaItem(id: 'movie-1', title: 'Fixture Movie', kind: ContentKind.movie),
          'tmdb',
        );
        expect(metadata?.title, 'Fixture Movie (TMDB)');
        await db.close();
      },
    );
  }

  test('rejects a schema version that was not publicly tagged', () async {
    await expectLater(
      createReleasedDatabaseFixture('${tempDir.path}/v7.db', 7),
      throwsArgumentError,
    );
  });

  group('schema parity with a fresh install', () {
    for (final version in releasedSchemaVersions) {
      test('migrated v$version fixture matches a fresh install', () async {
        final migratedPath = '${tempDir.path}/v$version.db';
        await createReleasedDatabaseFixture(migratedPath, version);
        final migratedDb = await AppDatabase.openAt(migratedPath);
        await migratedDb.close();

        final freshPath = '${tempDir.path}/fresh$version.db';
        final freshDb = await AppDatabase.openAt(freshPath);
        await freshDb.close();

        final migratedRaw = await databaseFactoryFfi.openDatabase(
          migratedPath,
        );
        final migratedSignature = await schemaSignature(migratedRaw);
        await migratedRaw.close();

        final freshRaw = await databaseFactoryFfi.openDatabase(freshPath);
        final freshSignature = await schemaSignature(freshRaw);
        await freshRaw.close();

        expect(migratedSignature, equals(freshSignature));
      });
    }
  });

  group('second open is a stable no-op', () {
    for (final version in releasedSchemaVersions) {
      test('re-opening the migrated v$version fixture changes nothing', () async {
        final path = '${tempDir.path}/v$version.db';
        await createReleasedDatabaseFixture(path, version);

        final firstOpen = await AppDatabase.openAt(path);
        await firstOpen.readChannels('released-source');
        await firstOpen.close();

        final rawAfterFirst = await databaseFactoryFfi.openDatabase(path);
        final signatureAfterFirst = await schemaSignature(rawAfterFirst);
        await rawAfterFirst.close();

        final secondOpen = await AppDatabase.openAt(path);
        final channels = await secondOpen.readChannels('released-source');
        expect(channels.single.name, 'Fixture Channel');
        expect(
          await secondOpen.readFavoriteIds('released-source', ContentKind.live),
          version >= 9 ? {'channel-1'} : isEmpty,
        );
        final position = await secondOpen.readPlaybackPosition(
          'released-source',
          ContentKind.movie,
          'movie-1',
        );
        if (version >= 11) {
          expect(position?.position, const Duration(minutes: 1));
        } else {
          expect(position, isNull);
        }
        await secondOpen.close();

        final rawAfterSecond = await databaseFactoryFfi.openDatabase(path);
        expect(await rawAfterSecond.getVersion(), AppDatabase.schemaVersion);
        final signatureAfterSecond = await schemaSignature(rawAfterSecond);
        await rawAfterSecond.close();

        expect(signatureAfterSecond, equals(signatureAfterFirst));
      });
    }
  });
}
