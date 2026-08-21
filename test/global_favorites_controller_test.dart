// Tests for the cross-source ("all sources") favorites controller: what it
// aggregates, what it deliberately drops, and that its async publish is
// generation-guarded like every other controller in the app.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/global_favorites_controller.dart';
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
