import '../sources/source.dart';
import 'app_database.dart';

class LibrarySnapshot {
  final List<Category> categories;
  final List<Channel> channels;
  final bool fromCache;
  final DateTime? syncedAt;

  const LibrarySnapshot({
    required this.categories,
    required this.channels,
    required this.fromCache,
    required this.syncedAt,
  });
}

class MediaLibrarySnapshot {
  final ContentKind kind;
  final List<MediaCategory> categories;
  final List<MediaItem> items;
  final bool fromCache;
  final DateTime? syncedAt;
  final int loadedPages;
  final int totalPages;

  const MediaLibrarySnapshot({
    required this.kind,
    required this.categories,
    required this.items,
    required this.fromCache,
    required this.syncedAt,
    this.loadedPages = 1,
    this.totalPages = 1,
  });

  bool get hasMore => loadedPages < totalPages;
}

/// Sits between a [Source] and the [AppDatabase]: serves channels from cache
/// when available, refreshes EPG when stale, and only hits the provider for
/// the heavy fetch on a cold start or an explicit refresh.
class LibraryRepository {
  final Source source;
  final AppDatabase db;

  /// EPG is re-fetched if older than this (or on a forced refresh).
  static const _epgMaxAge = Duration(hours: 3);
  static const _initialMediaPages = 4;
  static const _fallbackCategoryPages = 1;

  LibraryRepository({required this.source, required this.db});

  Future<LibrarySnapshot> load({bool forceRefresh = false}) async {
    // Always connect: cheap auth, and resolve()/playback/EPG need it.
    await source.connect();

    final snapshot = await _loadChannels(forceRefresh: forceRefresh);

    // EPG is best-effort and time-sensitive — refresh on its own schedule, and
    // never let an EPG failure break the channel list.
    try {
      await _ensureEpg(snapshot.channels, forceRefresh: forceRefresh);
    } catch (_) {
      // Source may not provide EPG, or the call failed — ignore.
    }

    return snapshot;
  }

  Future<LibrarySnapshot> _loadChannels({required bool forceRefresh}) async {
    if (!forceRefresh) {
      final synced = await db.lastSynced(source.id);
      if (synced != null) {
        final channels = await db.readChannels(source.id);
        if (channels.isNotEmpty) {
          return LibrarySnapshot(
            categories: await db.readCategories(source.id),
            channels: channels,
            fromCache: true,
            syncedAt: synced,
          );
        }
      }
    }

    final categories = await source.categories();
    final channels = await source.channels();
    await db.replaceLibrary(source.id, source.name, categories, channels);
    return LibrarySnapshot(
      categories: categories,
      channels: channels,
      fromCache: false,
      syncedAt: DateTime.now(),
    );
  }

  Future<void> _ensureEpg(
    List<Channel> channels, {
    required bool forceRefresh,
  }) async {
    final last = await db.lastEpgSynced(source.id);
    final stale = last == null || DateTime.now().difference(last) > _epgMaxAge;
    if (!forceRefresh && !stale) return;

    final programmes = await source.epg(channels);
    if (programmes.isNotEmpty) {
      await db.replaceEpg(source.id, programmes);
    }
  }

  Future<({Map<String, Programme> now, Map<String, Programme> next})>
  nowNext() => db.nowNext(source.id, DateTime.now());

  Future<StreamInfo> resolve(Channel channel) => source.resolve(channel);

  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    bool forceRefresh = false,
  }) async {
    await source.connect();
    if (!forceRefresh) {
      final sync = await db.mediaSyncState(source.id, kind);
      if (sync != null) {
        final items = await db.readMediaItems(source.id, kind);
        if (items.isNotEmpty) {
          return MediaLibrarySnapshot(
            kind: kind,
            categories: await db.readMediaCategories(source.id, kind),
            items: items,
            fromCache: true,
            syncedAt: sync.syncedAt,
            loadedPages: sync.loadedPages,
            totalPages: sync.totalPages,
          );
        }
      }
    }

    final categories = await source.mediaCategories(kind);
    final fetched = await _fetchMediaItems(kind, categories);
    await db.replaceMediaLibrary(
      source.id,
      kind,
      categories,
      fetched.items,
      loadedPages: fetched.loadedPages,
      totalPages: fetched.totalPages,
    );
    return MediaLibrarySnapshot(
      kind: kind,
      categories: categories,
      items: fetched.items,
      fromCache: false,
      syncedAt: DateTime.now(),
      loadedPages: fetched.loadedPages,
      totalPages: fetched.totalPages,
    );
  }

  Future<({List<MediaItem> items, int loadedPages, int totalPages})>
  _fetchMediaItems(ContentKind kind, List<MediaCategory> categories) async {
    final out = <MediaItem>[];
    final seen = <String>{};
    var loadedPages = 1;
    var totalPages = 1;
    void addAll(List<MediaItem> items) {
      for (final item in items) {
        if (item.id.isNotEmpty && seen.add(item.id)) out.add(item);
      }
    }

    for (var page = 1; page <= _initialMediaPages; page++) {
      final fetched = await source.mediaItemsPage(kind, page: page);
      totalPages = fetched.totalPages;
      loadedPages = page;
      addAll(fetched.items);
      if (!fetched.hasMore) break;
    }
    if (out.isNotEmpty || categories.isEmpty) {
      return (items: out, loadedPages: loadedPages, totalPages: totalPages);
    }

    for (final category in categories) {
      addAll(
        await source.mediaItems(
          kind,
          categoryId: category.id,
          maxPages: _fallbackCategoryPages,
        ),
      );
      if (out.length >= 200) break;
    }
    return (items: out, loadedPages: 1, totalPages: 1);
  }

  Future<MediaLibrarySnapshot> loadMoreMedia(ContentKind kind) async {
    await source.connect();
    final sync = await db.mediaSyncState(source.id, kind);
    if (sync == null || sync.loadedPages >= sync.totalPages) {
      return MediaLibrarySnapshot(
        kind: kind,
        categories: await db.readMediaCategories(source.id, kind),
        items: await db.readMediaItems(source.id, kind),
        fromCache: true,
        syncedAt: sync?.syncedAt,
        loadedPages: sync?.loadedPages ?? 1,
        totalPages: sync?.totalPages ?? 1,
      );
    }

    final page = sync.loadedPages + 1;
    final fetched = await source.mediaItemsPage(kind, page: page);
    final loadedPages = fetched.page;
    final totalPages = fetched.totalPages;
    await db.appendMediaItems(
      source.id,
      kind,
      fetched.items,
      loadedPages: loadedPages,
      totalPages: totalPages,
    );
    return MediaLibrarySnapshot(
      kind: kind,
      categories: await db.readMediaCategories(source.id, kind),
      items: await db.readMediaItems(source.id, kind),
      fromCache: false,
      syncedAt: DateTime.now(),
      loadedPages: loadedPages,
      totalPages: totalPages,
    );
  }

  Future<MediaItem> mediaDetails(MediaItem item) => source.mediaDetails(item);

  Future<StreamInfo> resolveMedia(MediaItem item) => source.resolveMedia(item);
}
