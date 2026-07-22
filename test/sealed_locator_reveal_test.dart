// Pins the reveal points in [LibraryRepository]: a cached model carries its
// playback locator sealed (`extra['secretLocator']`), and every call that hands
// a model to the owning [Source] must decrypt it first. Missing one is a silent
// failure — the content simply stops resolving — so this file walks each
// crossing and asserts on what the Source actually received.
//
// See CLAUDE.md "Sealed playback locators" and docs/validation-baseline.md.

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  late Directory tempDir;
  late AppDatabase db;
  late _RecordingSource source;
  late LibraryRepository repo;

  const channelUrl = 'http://provider.invalid/live/acct/tok/9.ts';
  const movieCmd = '/media/file_42.mpg';
  const seasonCmd = '/media/season_7.mpg';

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_reveal_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    source = _RecordingSource();
    repo = LibraryRepository(source: source, db: db);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Writes [channel] through the cache and reads it back still sealed.
  Future<Channel> cachedChannel(Channel channel) async {
    await db.replaceLibrary(source.id, 'Rec', const [], [channel]);
    final cached = (await db.readChannels(source.id)).single;
    expect(
      hasSealedLocator(cached.extra),
      isTrue,
      reason: 'the fixture must actually be sealed for the test to mean much',
    );
    return cached;
  }

  Future<MediaItem> cachedItem(MediaItem item) async {
    await db.replaceMediaLibrary(
      source.id,
      item.kind,
      const [],
      [item],
      loadedPages: 1,
      totalPages: 2,
    );
    final cached = (await db.readMediaItems(source.id, item.kind)).single;
    expect(hasSealedLocator(cached.extra), isTrue);
    return cached;
  }

  void expectRevealed(Map<String, dynamic>? extra, String key, String value) {
    expect(extra, isNotNull);
    expect(extra![key], value);
    expect(extra, isNot(contains(secretLocatorKey)));
  }

  test('resolve reveals the channel locator', () async {
    final cached = await cachedChannel(
      const Channel(id: 'ch1', name: 'One', extra: {'url': channelUrl}),
    );
    await repo.resolve(cached);
    expectRevealed(source.resolvedChannel?.extra, 'url', channelUrl);
  });

  test('resolveArchive reveals the channel locator', () async {
    final cached = await cachedChannel(
      const Channel(
        id: 'ch1',
        name: 'One',
        archiveDays: 3,
        extra: {'url': channelUrl},
      ),
    );
    await repo.resolveArchive(
      cached,
      Programme(
        channelId: 'ch1',
        start: DateTime.utc(2026),
        stop: DateTime.utc(2026, 1, 1, 1),
        title: 'Past',
      ),
    );
    expectRevealed(source.archivedChannel?.extra, 'url', channelUrl);
  });

  test('resolveMedia reveals the item locator', () async {
    final cached = await cachedItem(
      const MediaItem(
        id: 'm1',
        title: 'Alpha',
        kind: ContentKind.movie,
        extra: {'cmd': movieCmd},
      ),
    );
    await repo.resolveMedia(cached);
    expectRevealed(source.resolvedMedia?.extra, 'cmd', movieCmd);
  });

  test('mediaDetails reveals the item locator', () async {
    final cached = await cachedItem(
      const MediaItem(
        id: 'm1',
        title: 'Alpha',
        kind: ContentKind.movie,
        extra: {'cmd': movieCmd},
      ),
    );
    await repo.mediaDetails(cached);
    expectRevealed(source.detailedItem?.extra, 'cmd', movieCmd);
  });

  // The load-bearing pair: `parent` is a cached season, and
  // `StalkerSource._seasonPlaybackHints` reads `parent.extra['cmd']` to give
  // every episode it synthesizes a playable command.
  test('loadMedia reveals the parent before paging its children', () async {
    final season = await cachedItem(
      const MediaItem(
        id: 's1',
        title: 'Season 1',
        kind: ContentKind.season,
        extra: {'cmd': seasonCmd},
      ),
    );
    await repo.loadMedia(ContentKind.episode, parent: season);
    expectRevealed(source.pagedParent?.extra, 'cmd', seasonCmd);
  });

  test('loadMoreMedia reveals the parent', () async {
    final season = await cachedItem(
      const MediaItem(
        id: 's1',
        title: 'Season 1',
        kind: ContentKind.season,
        extra: {'cmd': seasonCmd},
      ),
    );
    // Seed page state for the episode listing so loadMoreMedia actually pages.
    await db.replaceMediaLibrary(
      source.id,
      ContentKind.episode,
      const [],
      const [MediaItem(id: 'e1', title: 'E1', kind: ContentKind.episode)],
      parentId: season.id,
      loadedPages: 1,
      totalPages: 2,
    );
    source.pagedParent = null;

    await repo.loadMoreMedia(ContentKind.episode, parent: season);
    expectRevealed(source.pagedParent?.extra, 'cmd', seasonCmd);
  });

  test('an already-plaintext model passes through untouched', () async {
    const fresh = Channel(id: 'ch2', name: 'Two', extra: {'url': channelUrl});
    final before = db.vault.decryptCount;
    await repo.resolve(fresh);
    expect(identical(source.resolvedChannel, fresh), isTrue);
    expect(db.vault.decryptCount, before);
  });
}

/// A [Source] that records the exact models the repository handed it.
class _RecordingSource implements Source {
  Channel? resolvedChannel;
  Channel? archivedChannel;
  MediaItem? resolvedMedia;
  MediaItem? detailedItem;
  MediaItem? pagedParent;

  @override
  String get id => 'rec';

  @override
  String get name => 'Rec';

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [];

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    resolvedChannel = channel;
    return const StreamInfo(url: 'http://stream');
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    archivedChannel = channel;
    return const StreamInfo(url: 'http://archive', isLive: false);
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    pagedParent = parent;
    return const [];
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    pagedParent = parent;
    return MediaPage(items: const [], page: page, totalPages: page);
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    detailedItem = item;
    return item;
  }

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    resolvedMedia = item;
    return const StreamInfo(url: 'http://vod', isLive: false);
  }

  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();

  @override
  Future<void> dispose() async {}
}
