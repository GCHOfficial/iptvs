import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/historical_database_fixtures.dart';

void main() {
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
}
