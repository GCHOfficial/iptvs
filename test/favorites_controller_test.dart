// Unit tests for FavoritesController: per-kind favorite id state over the real
// SQLite engine (via AppDatabase.openAt, no path_provider), plus the notifier
// plumbing and the "set is now empty" signal the screen uses to fall back off
// the Favorites view.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/favorites_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late FavoritesController favorites;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_favorites_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    favorites = FavoritesController(
      repo: LibraryRepository(source: DemoSource(), db: db),
    );
  });

  tearDown(() async {
    favorites.dispose();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('starts empty for every kind', () {
    expect(favorites.ids(ContentKind.live), isEmpty);
    expect(favorites.isFavorite(ContentKind.live, 'bbb'), isFalse);
  });

  test('toggle adds/removes, persists, and notifies', () async {
    var notifications = 0;
    favorites.addListener(() => notifications++);

    final emptyAfterAdd = await favorites.toggle(ContentKind.live, 'bbb');
    expect(emptyAfterAdd, isFalse);
    expect(favorites.isFavorite(ContentKind.live, 'bbb'), isTrue);
    expect(notifications, 1);

    // Persisted to the DB (a fresh load reflects it).
    await favorites.load(ContentKind.live);
    expect(favorites.ids(ContentKind.live), {'bbb'});

    // Removing the last favorite reports the set is now empty.
    final emptyAfterRemove = await favorites.toggle(ContentKind.live, 'bbb');
    expect(emptyAfterRemove, isTrue);
    expect(favorites.isFavorite(ContentKind.live, 'bbb'), isFalse);
  });

  test('kinds are independent', () async {
    await favorites.toggle(ContentKind.live, 'bbb');
    await favorites.toggle(ContentKind.movie, 'm1');

    expect(favorites.ids(ContentKind.live), {'bbb'});
    expect(favorites.ids(ContentKind.movie), {'m1'});
    expect(favorites.ids(ContentKind.series), isEmpty);

    // Removing the movie leaves live untouched.
    final movieEmpty = await favorites.toggle(ContentKind.movie, 'm1');
    expect(movieEmpty, isTrue);
    expect(favorites.ids(ContentKind.live), {'bbb'});
  });
}
