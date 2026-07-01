import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show debugPrint;

import '../sources/source.dart';
import 'app_database.dart';
import 'diagnostics_log.dart';
import 'metadata_provider.dart';

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

  MediaLibrarySnapshot copyWith({List<MediaItem>? items}) =>
      MediaLibrarySnapshot(
        kind: kind,
        categoryId: categoryId,
        parentId: parentId,
        categories: categories,
        items: items ?? this.items,
        fromCache: fromCache,
        syncedAt: syncedAt,
        loadedPages: loadedPages,
        totalPages: totalPages,
      );
}

/// Sits between a [Source] and the [AppDatabase]: serves channels from cache
/// when available, refreshes EPG when stale, and only hits the provider for
/// the heavy fetch on a cold start or an explicit refresh.
class LibraryRepository {
  final Source source;
  final AppDatabase db;
  final List<MetadataProvider> metadataProviders;
  final bool autoEnrichMetadata;

  /// EPG is re-fetched if older than this (or on a forced refresh).
  static const _epgMaxAge = Duration(hours: 3);
  static const _initialMediaPages = 1;
  static const _mediaPagesPerLoad = 3;
  static const _fallbackCategoryPages = 1;
  static const _fallbackCategoryLimit = 8;

  LibraryRepository({
    required this.source,
    required this.db,
    MetadataProvider? metadataProvider,
    List<MetadataProvider>? metadataProviders,
    this.autoEnrichMetadata = true,
  }) : metadataProviders = metadataProviders ?? [?metadataProvider];

  bool get canEnrichMetadata => metadataProviders.isNotEmpty;

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

  /// Cached programmes for [channel] over the catch-up window (its
  /// [Channel.archiveDays] back to now), newest-last. Empty when the channel has
  /// no archive or no cached EPG. The guide reads this to list past programmes.
  Future<List<Programme>> archiveProgrammes(Channel channel) {
    if (!channel.hasArchive) return Future.value(const []);
    final now = DateTime.now();
    return db.programmesForChannel(
      source.id,
      channel.id,
      from: now.subtract(Duration(days: channel.archiveDays)),
      to: now,
    );
  }

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
          var mergedItems = await _mergeCachedMetadata(items);
          if (parent != null) {
            mergedItems = await _applyChildExternalMetadata(
              parent,
              mergedItems,
              action: 'cache-child',
            );
            await db.updateMediaDisplayFields(source.id, mergedItems);
          }
          return MediaLibrarySnapshot(
            kind: kind,
            categoryId: categoryId,
            parentId: parentId,
            categories: await db.readMediaCategories(source.id, kind),
            items: mergedItems,
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
    final fetchedItems = parent == null
        ? fetched.items
        : await _applyChildExternalMetadata(
            parent,
            fetched.items,
            action: 'load-child',
          );
    await db.replaceMediaLibrary(
      source.id,
      kind,
      categories,
      fetchedItems,
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
      items: await _mergeCachedMetadata(fetchedItems),
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
        items: await _readMergedMediaItems(
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
      items.addAll(
        parent == null
            ? fetched.items
            : await _applyChildExternalMetadata(
                parent,
                fetched.items,
                action: 'load-more-child',
              ),
      );
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
      items: await _readMergedMediaItems(
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

  Future<MediaItem> mediaDetails(MediaItem item) async {
    final details = await source.mediaDetails(item);
    if (!_supportsMetadata(details)) {
      return details;
    }
    final merged = await _applyExternalMetadata(details, action: 'details');
    await db.updateMediaDisplayFields(source.id, [merged]);
    return merged;
  }

  Future<List<MediaItem>> _readMergedMediaItems(
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) async {
    final items = await db.readMediaItems(
      source.id,
      kind,
      categoryId: categoryId,
      parentId: parentId,
    );
    return _mergeCachedMetadata(items);
  }

  Future<List<MediaItem>> _mergeCachedMetadata(List<MediaItem> items) async {
    if (items.isEmpty) return items;
    var out = [...items];
    for (final provider in metadataProviders) {
      final metadata = await db.readExternalMetadataForItems(
        source.id,
        out,
        provider.provider,
      );
      if (metadata.isEmpty) continue;
      out = [
        for (final item in out)
          if (metadata[item.id] case final itemMetadata?)
            _mergeMetadata(
              item,
              itemMetadata,
              ratingsOnly: provider.ratingsOnly,
            )
          else
            item,
      ];
    }
    return out;
  }

  Future<List<MediaItem>> _applyChildExternalMetadata(
    MediaItem parent,
    List<MediaItem> items, {
    required String action,
  }) async {
    if (metadataProviders.isEmpty || items.isEmpty) return items;
    if (items.first.kind != ContentKind.season &&
        items.first.kind != ContentKind.episode) {
      return items;
    }
    final enrichedParent = (await _mergeCachedMetadata([parent])).first;
    final out = <MediaItem>[];
    for (final item in items) {
      out.add(
        await _applyOneChildExternalMetadata(enrichedParent, item, action),
      );
    }
    return out;
  }

  Future<MediaItem> _applyOneChildExternalMetadata(
    MediaItem parent,
    MediaItem item,
    String action,
  ) async {
    if (item.kind != ContentKind.season && item.kind != ContentKind.episode) {
      return item;
    }
    var out = item;
    var visualMatched = false;
    for (final provider in metadataProviders) {
      if (provider.ratingsOnly && !visualMatched) continue;
      final cached = await cachedExternalMetadata(out, provider.provider);
      if (cached != null) {
        _logMetadata(
          '$action cache hit ${provider.provider} ${out.kind.name}:${out.id} -> ${cached.providerKey}',
        );
        out = _mergeMetadata(out, cached, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
        continue;
      }
      try {
        final metadata = out.kind == ContentKind.season
            ? await provider.seasonMetadata(parent, out)
            : await provider.episodeMetadata(parent, out);
        if (metadata == null) {
          _logMetadata(
            '$action no match ${provider.provider} ${out.kind.name}:${out.id} title=${out.title}',
          );
          continue;
        }
        await cacheExternalMetadata(out, metadata);
        _logMetadata(
          '$action matched ${provider.provider} ${out.kind.name}:${out.id} -> ${metadata.providerKey}',
        );
        out = _mergeMetadata(out, metadata, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
      } catch (error) {
        _logMetadata(
          '$action error ${provider.provider} ${out.kind.name}:${out.id}: $error',
        );
      }
    }
    return out;
  }

  bool _supportsMetadata(MediaItem item) =>
      metadataProviders.isNotEmpty &&
      (item.kind == ContentKind.movie ||
          item.kind == ContentKind.season ||
          item.kind == ContentKind.series ||
          item.kind == ContentKind.episode);

  bool _shouldLookupMetadata(MediaItem item) {
    if (!_supportsMetadata(item)) return false;
    if (item.kind != ContentKind.episode) return true;
    return _hasExternalMetadataId(item);
  }

  bool _hasExternalMetadataId(MediaItem item) {
    final providerId = item.providerId;
    if (providerId != null && providerId.trim().isNotEmpty) return true;
    for (final key in const [
      'tmdb_id',
      'tmdbId',
      'tvdb_id',
      'tvdbId',
      'imdb_id',
      'imdbId',
    ]) {
      final value = item.extra[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value != 'null') return true;
    }
    return false;
  }

  Future<MediaItem> _applyExternalMetadata(
    MediaItem item, {
    required String action,
  }) async {
    if (!_shouldLookupMetadata(item)) {
      if (_supportsMetadata(item)) {
        _logMetadata(
          '$action skipped ${item.kind.name}:${item.id} title=${item.title}',
        );
      }
      return item;
    }
    var out = item;
    var visualMatched = false;
    for (final provider in metadataProviders) {
      if (provider.ratingsOnly && !visualMatched) continue;
      final cached = await cachedExternalMetadata(out, provider.provider);
      if (cached != null) {
        _logMetadata(
          '$action cache hit ${provider.provider} ${out.kind.name}:${out.id} -> ${cached.providerKey}',
        );
        out = _mergeMetadata(out, cached, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
        continue;
      }
      try {
        final metadata = await provider.search(out);
        if (metadata == null) {
          _logMetadata(
            '$action no match ${provider.provider} ${out.kind.name}:${out.id} title=${out.title}',
          );
          continue;
        }
        await cacheExternalMetadata(out, metadata);
        _logMetadata(
          '$action matched ${provider.provider} ${out.kind.name}:${out.id} -> ${metadata.providerKey}',
        );
        out = _mergeMetadata(out, metadata, ratingsOnly: provider.ratingsOnly);
        if (!provider.ratingsOnly) visualMatched = true;
      } catch (error) {
        _logMetadata(
          '$action error ${provider.provider} ${out.kind.name}:${out.id}: $error',
        );
      }
    }
    return out;
  }

  MediaItem _mergeMetadata(
    MediaItem item,
    ExternalMetadata metadata, {
    bool ratingsOnly = false,
  }) {
    final existingMetadata = item.extra['metadata'];
    final providerTitle =
        item.extra['providerTitle'] ??
        item.extra['sourceTitle'] ??
        item.extra['name'] ??
        item.extra['title'] ??
        item.title;
    return item.copyWith(
      title: ratingsOnly || metadata.title == null || metadata.title!.isEmpty
          ? null
          : metadata.title,
      poster: ratingsOnly ? item.poster : metadata.poster ?? item.poster,
      backdrop: ratingsOnly
          ? item.backdrop
          : metadata.backdrop ?? item.backdrop,
      description:
          ratingsOnly || metadata.overview == null || metadata.overview!.isEmpty
          ? item.description
          : metadata.overview,
      year: ratingsOnly ? item.year : metadata.year ?? item.year,
      rating: metadata.rating ?? item.rating,
      providerId: ratingsOnly || metadata.providerKey.isEmpty
          ? item.providerId
          : metadata.providerKey,
      extra: {
        ...item.extra,
        'providerTitle': providerTitle,
        'metadata': {
          if (existingMetadata is Map) ...existingMetadata,
          metadata.provider: metadata.payload,
        },
      },
    );
  }

  void _logMetadata(String message) {
    DiagnosticsLog.instance.add('metadata', message);
    developer.log(message, name: 'iptvs.metadata');
    debugPrint('[iptvs.metadata] $message');
  }

  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) => db.readExternalMetadata(source.id, item, provider);

  Future<void> cacheExternalMetadata(
    MediaItem item,
    ExternalMetadata metadata,
  ) => db.cacheExternalMetadata(source.id, item, metadata);

  Future<ExternalMetadata?> refreshExternalMetadata(MediaItem item) async {
    if (!_supportsMetadata(item)) {
      return null;
    }
    try {
      final merged = await _applyExternalMetadata(item, action: 'refresh');
      await db.updateMediaDisplayFields(source.id, [merged]);
      final provider = metadataProviders.firstWhere(
        (provider) => !provider.ratingsOnly,
        orElse: () => metadataProviders.first,
      );
      return cachedExternalMetadata(merged, provider.provider);
    } catch (error) {
      _logMetadata('refresh error ${item.kind.name}:${item.id}: $error');
      rethrow;
    }
  }

  MediaItem mergeExternalMetadata(MediaItem item, ExternalMetadata metadata) =>
      _mergeMetadata(item, metadata);

  Future<List<MediaItem>> enrichMediaMetadata(
    List<MediaItem> items, {
    int? limit,
  }) async {
    if (metadataProviders.isEmpty ||
        items.isEmpty ||
        (limit != null && limit <= 0)) {
      return items;
    }
    final out = [...items];
    var checked = 0;
    for (var i = 0; i < out.length; i++) {
      if (limit != null && checked >= limit) break;
      final item = out[i];
      if (item.kind != ContentKind.movie &&
          item.kind != ContentKind.series &&
          item.kind != ContentKind.episode) {
        continue;
      }
      checked++;
      out[i] = await _applyExternalMetadata(item, action: 'prefetch');
    }
    await db.updateMediaDisplayFields(source.id, out);
    return out;
  }

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
