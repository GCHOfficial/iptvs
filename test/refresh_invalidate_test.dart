// Tests for the forced-reload cache-invalidation path (RefreshableSource).
//
// A Source memoizes its catalog in memory so repeated reads don't re-hit the
// provider. "Reload source" (forceRefresh) must drop that memo, or it silently
// replays the stale list. LibraryRepository invalidates on a forced load/
// loadMedia only — never on a non-forced load, and never on pagination.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('iptvs_refresh'));
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  String dbPath() => '${tempDir.path}/iptv.db';

  test('two forced live reloads hit the provider twice; cache serves between',
      () async {
    final db = await AppDatabase.openAt(dbPath());
    final source = _CountingSource();
    final repo = LibraryRepository(source: source, db: db);

    // Cold load: provider fetched once.
    await repo.load();
    expect(source.channelFetches, 1);

    // Non-forced load: served from the SQLite cache, provider untouched, and
    // invalidate() never called.
    final warm = await repo.load();
    expect(warm.fromCache, isTrue);
    expect(source.channelFetches, 1);
    expect(source.invalidateCount, 0);

    // Forced reload #1: invalidate() drops the memo, so the provider is hit
    // again (this is the bug the fix closes — before it, the memoized list
    // survived and channelFetches stayed at 1).
    await repo.load(forceRefresh: true);
    expect(source.invalidateCount, 1);
    expect(source.channelFetches, 2);

    // Forced reload #2: provider hit a third time.
    await repo.load(forceRefresh: true);
    expect(source.invalidateCount, 2);
    expect(source.channelFetches, 3);

    await db.close();
  });

  test('forced media reload invalidates; loadMoreMedia never does', () async {
    final db = await AppDatabase.openAt(dbPath());
    final source = _CountingSource();
    final repo = LibraryRepository(source: source, db: db);

    await repo.loadMedia(ContentKind.movie);
    expect(source.mediaFetches, 1);
    expect(source.invalidateCount, 0);

    // Non-forced media load: cache serves it, no invalidate.
    await repo.loadMedia(ContentKind.movie);
    expect(source.mediaFetches, 1);
    expect(source.invalidateCount, 0);

    // Pagination must not invalidate, regardless of whether it fetches.
    await repo.loadMoreMedia(ContentKind.movie);
    expect(source.invalidateCount, 0);

    // Forced media reload invalidates and re-fetches.
    await repo.loadMedia(ContentKind.movie, forceRefresh: true);
    expect(source.invalidateCount, 1);
    expect(source.mediaFetches, 2);

    await db.close();
  });
}

/// A [Source] that memoizes its catalogs in memory (like the real Stalker/M3U/
/// Xtream sources) and counts provider fetches + invalidate calls.
class _CountingSource extends Source implements RefreshableSource {
  int channelFetches = 0;
  int mediaFetches = 0;
  int invalidateCount = 0;
  List<Channel>? _channelMemo;
  List<MediaItem>? _mediaMemo;

  @override
  String get id => 'counting';

  @override
  String get name => 'Counting';

  @override
  Future<void> connect() async {}

  @override
  void invalidate() {
    invalidateCount++;
    _channelMemo = null;
    _mediaMemo = null;
  }

  @override
  Future<List<Category>> categories() async => const [
        Category(id: 'c1', title: 'General'),
      ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    final memo = _channelMemo ??= _fetchChannels();
    if (categoryId == null) return memo;
    return memo.where((c) => c.categoryId == categoryId).toList();
  }

  List<Channel> _fetchChannels() {
    channelFetches++;
    return const [
      Channel(id: 'a', name: 'A', categoryId: 'c1'),
      Channel(id: 'b', name: 'B', categoryId: 'c1'),
    ];
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      const StreamInfo(url: 'http://stream');

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => const [
        MediaCategory(id: 'm1', title: 'Movies', kind: ContentKind.movie),
      ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    final memo = _mediaMemo ??= _fetchMedia(kind);
    return MediaPage(items: memo, page: page, totalPages: page);
  }

  List<MediaItem> _fetchMedia(ContentKind kind) {
    mediaFetches++;
    return [MediaItem(id: 'movie1', title: 'Movie One', kind: kind)];
  }
}
