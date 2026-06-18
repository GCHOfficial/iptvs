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
  final String? categoryId;
  final String? parentId;
  final List<MediaCategory> categories;
  final List<MediaItem> items;
  final bool fromCache;
  final DateTime? syncedAt;
  final int loadedPages;
  final int totalPages;

  const MediaLibrarySnapshot({
    required this.kind,
    this.categoryId,
    this.parentId,
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
  static const _initialMediaPages = 1;
  static const _mediaPagesPerLoad = 3;
  static const _fallbackCategoryPages = 1;
  static const _fallbackCategoryLimit = 8;

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
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
  }) async {
    await source.connect();
    final parentId = parent?.id;
    if (!forceRefresh) {
      final sync = await db.mediaSyncState(
        source.id,
        kind,
        categoryId: categoryId,
        parentId: parentId,
      );
      if (sync != null) {
        final items = await db.readMediaItems(
          source.id,
          kind,
          categoryId: categoryId,
          parentId: parentId,
        );
        if (items.isNotEmpty) {
          return MediaLibrarySnapshot(
            kind: kind,
            categoryId: categoryId,
            parentId: parentId,
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
    final fetched = await _fetchMediaItems(
      kind,
      categories,
      categoryId: categoryId,
      parent: parent,
    );
    await db.replaceMediaLibrary(
      source.id,
      kind,
      categories,
      fetched.items,
      categoryId: categoryId,
      parentId: parentId,
      loadedPages: fetched.loadedPages,
      totalPages: fetched.totalPages,
    );
    return MediaLibrarySnapshot(
      kind: kind,
      categoryId: categoryId,
      parentId: parentId,
      categories: categories,
      items: fetched.items,
      fromCache: false,
      syncedAt: DateTime.now(),
      loadedPages: fetched.loadedPages,
      totalPages: fetched.totalPages,
    );
  }

  Future<({List<MediaItem> items, int loadedPages, int totalPages})>
  _fetchMediaItems(
    ContentKind kind,
    List<MediaCategory> categories, {
    String? categoryId,
    MediaItem? parent,
  }) async {
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
      final fetched = await source.mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
      totalPages = fetched.totalPages;
      loadedPages = page;
      addAll(fetched.items);
      if (!fetched.hasMore) break;
    }
    if (out.isNotEmpty || categories.isEmpty) {
      return (items: out, loadedPages: loadedPages, totalPages: totalPages);
    }
    if (categoryId != null) {
      return (items: out, loadedPages: loadedPages, totalPages: totalPages);
    }

    for (final category in _prioritizedFallbackCategories(kind, categories)) {
      addAll(
        await source.mediaItems(
          kind,
          categoryId: category.id,
          parent: parent,
          maxPages: _fallbackCategoryPages,
        ),
      );
      if (out.length >= 200) break;
    }
    return (items: out, loadedPages: 1, totalPages: 1);
  }

  Iterable<MediaCategory> _prioritizedFallbackCategories(
    ContentKind kind,
    List<MediaCategory> categories,
  ) {
    final ordered = [...categories];
    if (kind == ContentKind.series) {
      int score(MediaCategory category) {
        final title = category.title.toLowerCase();
        if (title.contains('series') ||
            title.contains('shows') ||
            title.contains('episodes')) {
          return 0;
        }
        if (title.contains('tv')) return 1;
        return 2;
      }

      ordered.sort((a, b) {
        final byScore = score(a).compareTo(score(b));
        return byScore == 0 ? a.title.compareTo(b.title) : byScore;
      });
    }
    return ordered.take(_fallbackCategoryLimit);
  }

  Future<MediaLibrarySnapshot> loadMoreMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
  }) async {
    await source.connect();
    final parentId = parent?.id;
    final sync = await db.mediaSyncState(
      source.id,
      kind,
      categoryId: categoryId,
      parentId: parentId,
    );
    if (sync == null || sync.loadedPages >= sync.totalPages) {
      return MediaLibrarySnapshot(
        kind: kind,
        categoryId: categoryId,
        parentId: parentId,
        categories: await db.readMediaCategories(source.id, kind),
        items: await db.readMediaItems(
          source.id,
          kind,
          categoryId: categoryId,
          parentId: parentId,
        ),
        fromCache: true,
        syncedAt: sync?.syncedAt,
        loadedPages: sync?.loadedPages ?? 1,
        totalPages: sync?.totalPages ?? 1,
      );
    }

    var loadedPages = sync.loadedPages;
    var totalPages = sync.totalPages;
    final items = <MediaItem>[];
    for (var i = 0; i < _mediaPagesPerLoad && loadedPages < totalPages; i++) {
      final fetched = await source.mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: loadedPages + 1,
      );
      loadedPages = fetched.page;
      totalPages = fetched.totalPages;
      items.addAll(fetched.items);
      if (!fetched.hasMore) break;
    }
    await db.appendMediaItems(
      source.id,
      kind,
      items,
      categoryId: categoryId,
      parentId: parentId,
      loadedPages: loadedPages,
      totalPages: totalPages,
    );
    return MediaLibrarySnapshot(
      kind: kind,
      categoryId: categoryId,
      parentId: parentId,
      categories: await db.readMediaCategories(source.id, kind),
      items: await db.readMediaItems(
        source.id,
        kind,
        categoryId: categoryId,
        parentId: parentId,
      ),
      fromCache: false,
      syncedAt: DateTime.now(),
      loadedPages: loadedPages,
      totalPages: totalPages,
    );
  }

  Future<MediaItem> mediaDetails(MediaItem item) => source.mediaDetails(item);

  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) => db.readExternalMetadata(source.id, item, provider);

  Future<void> cacheExternalMetadata(
    MediaItem item,
    ExternalMetadata metadata,
  ) => db.cacheExternalMetadata(source.id, item, metadata);

  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    await source.connect();
    return source.searchMedia(kind, query, categoryId: categoryId);
  }

  Future<StreamInfo> resolveMedia(MediaItem item) => source.resolveMedia(item);
}
