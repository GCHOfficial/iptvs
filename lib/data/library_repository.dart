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

  const MediaLibrarySnapshot({
    required this.kind,
    required this.categories,
    required this.items,
    required this.fromCache,
    required this.syncedAt,
  });
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
      final synced = await db.lastMediaSynced(source.id, kind);
      if (synced != null) {
        final items = await db.readMediaItems(source.id, kind);
        if (items.isNotEmpty) {
          return MediaLibrarySnapshot(
            kind: kind,
            categories: await db.readMediaCategories(source.id, kind),
            items: items,
            fromCache: true,
            syncedAt: synced,
          );
        }
      }
    }

    final categories = await source.mediaCategories(kind);
    final items = await _fetchMediaItems(kind, categories);
    await db.replaceMediaLibrary(source.id, kind, categories, items);
    return MediaLibrarySnapshot(
      kind: kind,
      categories: categories,
      items: items,
      fromCache: false,
      syncedAt: DateTime.now(),
    );
  }

  Future<List<MediaItem>> _fetchMediaItems(
    ContentKind kind,
    List<MediaCategory> categories,
  ) async {
    final out = <MediaItem>[];
    final seen = <String>{};
    void addAll(List<MediaItem> items) {
      for (final item in items) {
        if (item.id.isNotEmpty && seen.add(item.id)) out.add(item);
      }
    }

    addAll(await source.mediaItems(kind, maxPages: _initialMediaPages));
    if (out.isNotEmpty || categories.isEmpty) {
      return out;
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
    return out;
  }

  Future<MediaItem> mediaDetails(MediaItem item) => source.mediaDetails(item);

  Future<StreamInfo> resolveMedia(MediaItem item) => source.resolveMedia(item);
}
