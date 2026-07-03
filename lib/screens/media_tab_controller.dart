import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../sources/source.dart';

/// Pseudo-category id for the "Favorites" view (live and media). Not a provider
/// category — it loads the full "All" set and is filtered client-side.
const kFavoritesCategoryId = '__favorites__';

/// Cap on how many items an automatic (post-load) metadata enrichment pass
/// touches, so a large catalog doesn't fan out into a huge burst of API calls.
const _autoEnrichLimit = 40;

/// One "Continue watching" rail entry: the cached item + its saved position.
class ContinueWatchingEntry {
  final MediaItem item;
  final PlaybackPosition position;
  const ContinueWatchingEntry({required this.item, required this.position});
}

/// Owns one media tab's (movies *or* series) browsing state and the async
/// operations that mutate it — load, paging, search, and metadata enrichment —
/// as a [ChangeNotifier] so the view rebuilds via `ListenableBuilder` instead of
/// a `setState` on the whole screen. Pure derivations (visible-item filtering,
/// the status line, the category list) stay in the screen, which reads these
/// fields; navigation, favorites, and the search text box also stay there.
///
/// Both controllers (movie, series) live for the screen's lifetime, so their
/// state survives switching tabs — the behaviour the old kind-keyed maps had.
class MediaTabController extends ChangeNotifier {
  final ContentKind kind;
  final LibraryRepository repo;

  /// Surfaces an enrichment failure to the user (the screen shows a snackbar);
  /// only used for the explicit "refresh displayed metadata" action.
  final void Function(String message)? onEnrichError;

  MediaTabController({
    required this.kind,
    required this.repo,
    this.onEnrichError,
  }) : firstFocusNode = FocusNode(debugLabel: 'media.${kind.name}.first'),
       scrollController = ScrollController();

  /// Loaded page(s) for the current category (drives paging / "load more").
  MediaLibrarySnapshot? snapshot;

  /// Selected category id, or [kFavoritesCategoryId], or null for "All".
  String? categoryId;

  bool loading = false;
  bool loadingMore = false;
  bool searching = false;
  bool enriching = false;
  String? error;
  ({int done, int total})? enrichmentProgress;

  /// Provider search results (flat, non-paged) and the query they answer.
  List<MediaItem> searchResults = const [];
  String? searchQuery;

  /// Last item played from this tab; autofocused on return when still visible.
  String? lastPlayedId;

  /// First-item focus node (the D-pad "home" of the grid) and the grid's own
  /// scroll controller — per-tab so scroll position is independent.
  final FocusNode firstFocusNode;
  final ScrollController scrollController;

  int _enrichGeneration = 0;
  String? _pendingSearch;
  bool _disposed = false;

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  /// The real category to fetch — the Favorites pseudo-category isn't a provider
  /// category, so it loads the full "All" set and is filtered client-side.
  String? get _loadCategory =>
      categoryId == kFavoritesCategoryId ? null : categoryId;

  /// "Continue watching" entries for this tab, newest first: in-progress
  /// movies on the movie tab, in-progress episodes on the series tab.
  List<ContinueWatchingEntry> continueWatching = const [];

  /// Which position kind this tab resumes (episodes drive the series tab).
  ContentKind get _resumeKind =>
      kind == ContentKind.movie ? ContentKind.movie : ContentKind.episode;

  /// Rebuild [continueWatching] from the saved positions, resolving ids
  /// against the cached media items (unknown ids — e.g. items whose category
  /// was never cached — are skipped rather than shown title-less).
  Future<void> loadContinueWatching() async {
    final positions = await repo.db.readRecentPositions(repo.source.id);
    final wanted = positions.where((p) => p.kind == _resumeKind).toList();
    if (wanted.isEmpty) {
      if (continueWatching.isNotEmpty) {
        _set(() => continueWatching = const []);
      }
      return;
    }
    final items = await repo.db.readMediaItemsByIds(
      repo.source.id,
      _resumeKind,
      [for (final p in wanted) p.itemId],
    );
    if (_disposed) return;
    final byId = {for (final item in items) item.id: item};
    _set(() {
      continueWatching = [
        for (final position in wanted)
          if (byId[position.itemId] case final item?)
            ContinueWatchingEntry(item: item, position: position),
      ];
    });
  }

  /// Drops one entry from "Continue watching" — clears its saved resume
  /// position so it won't reappear, and updates the in-memory list
  /// immediately rather than waiting on a full [loadContinueWatching] reload.
  Future<void> removeFromContinueWatching(ContinueWatchingEntry entry) async {
    _set(
      () => continueWatching = continueWatching
          .where((e) => e.item.id != entry.item.id)
          .toList(),
    );
    await repo.db.clearPlaybackPosition(
      repo.source.id,
      entry.position.kind,
      entry.item.id,
    );
  }

  Future<void> load({bool forceRefresh = false}) async {
    final categoryToLoad = _loadCategory;
    _set(() {
      _cancelEnrich();
      loading = true;
      error = null;
    });
    unawaited(loadContinueWatching());
    try {
      final snap = await repo.loadMedia(
        kind,
        categoryId: categoryToLoad,
        forceRefresh: forceRefresh,
      );
      if (_disposed) return;
      DiagnosticsLog.instance.add(
        'library',
        'loaded ${kind.name} source=${repo.source.name} items=${snap.items.length} category=${categoryToLoad ?? '<all>'} force=$forceRefresh cache=${snap.fromCache} pages=${snap.loadedPages}/${snap.totalPages}',
      );
      _set(() {
        snapshot = snap;
        loading = false;
      });
      if (repo.autoEnrichMetadata) {
        unawaited(_enrich(snap.items, maxItems: _autoEnrichLimit));
      }
    } catch (e) {
      _set(() {
        error = '$e';
        loading = false;
      });
    }
  }

  Future<void> loadMore() async {
    if (loadingMore) return;
    final categoryToLoad = _loadCategory;
    final existingIds = {
      for (final item in snapshot?.items ?? const <MediaItem>[]) item.id,
    };
    _set(() {
      _cancelEnrich();
      loadingMore = true;
      error = null;
    });
    try {
      final snap = await repo.loadMoreMedia(kind, categoryId: categoryToLoad);
      if (_disposed) return;
      DiagnosticsLog.instance.add(
        'library',
        'load more ${kind.name} source=${repo.source.name} items=${snap.items.length} category=${categoryToLoad ?? '<all>'} pages=${snap.loadedPages}/${snap.totalPages}',
      );
      _set(() {
        snapshot = snap;
        loadingMore = false;
      });
      if (repo.autoEnrichMetadata) {
        final newlyLoaded = snap.items
            .where((item) => !existingIds.contains(item.id))
            .toList();
        unawaited(_enrich(newlyLoaded, maxItems: _autoEnrichLimit));
      }
    } catch (e) {
      _set(() {
        error = '$e';
        loadingMore = false;
      });
    }
  }

  Future<void> search(String query) async {
    _pendingSearch = query;
    final categoryToLoad = _loadCategory;
    _set(() {
      _cancelEnrich();
      searching = true;
      error = null;
    });
    try {
      final results = await repo.searchMedia(
        kind,
        query,
        categoryId: categoryToLoad,
      );
      // A newer keystroke superseded this search — drop the stale result.
      if (_disposed || _pendingSearch != query) return;
      DiagnosticsLog.instance.add(
        'library',
        'search ${kind.name} source=${repo.source.name} query="$query" results=${results.length} category=${categoryToLoad ?? '<all>'}',
      );
      _set(() {
        searchResults = results;
        searchQuery = query;
        searching = false;
      });
      if (repo.autoEnrichMetadata) {
        unawaited(_enrich(results, maxItems: _autoEnrichLimit));
      }
    } catch (e) {
      if (_disposed || _pendingSearch != query) return;
      _set(() {
        error = '$e';
        searching = false;
      });
    }
  }

  /// Clear an active search (query dropped below the 2-char threshold).
  void clearSearch() {
    _pendingSearch = null;
    _set(() {
      _cancelEnrich();
      searching = false;
      searchResults = const [];
      searchQuery = null;
    });
  }

  /// Switch category: reset any search and reload from the provider.
  Future<void> setCategory(String? value) async {
    _set(() {
      categoryId = value;
      _pendingSearch = null;
      searchResults = const [];
      searchQuery = null;
    });
    await load();
  }

  /// If currently viewing Favorites, fall back to "All" (used when the last
  /// favorite is removed and the view would otherwise be empty/unselectable).
  void resetFavoritesCategoryToAll() {
    if (categoryId == kFavoritesCategoryId) {
      _set(() => categoryId = null);
    }
  }

  void setLastPlayed(String id) {
    lastPlayedId = id; // no rebuild needed; read on next build
  }

  /// Explicit "refresh displayed metadata" action over the given visible items.
  Future<void> enrichVisible(List<MediaItem> visible) =>
      _enrich(visible, showErrors: true);

  void cancelEnrich() => _set(_cancelEnrich);

  void _cancelEnrich() {
    _enrichGeneration++;
    enriching = false;
    enrichmentProgress = null;
  }

  Future<void> _enrich(
    List<MediaItem> items, {
    bool showErrors = false,
    int? maxItems,
  }) async {
    final generation = ++_enrichGeneration;
    final targets = items
        .where(
          (item) =>
              item.kind == ContentKind.movie ||
              item.kind == ContentKind.series ||
              item.kind == ContentKind.episode,
        )
        .take(maxItems ?? items.length)
        .toList();
    if (targets.isEmpty) return;
    _set(() {
      enriching = true;
      enrichmentProgress = (done: 0, total: targets.length);
    });
    var done = 0;
    try {
      const chunkSize = 20;
      for (var start = 0; start < targets.length; start += chunkSize) {
        if (_enrichGeneration != generation) return;
        final chunk = targets.skip(start).take(chunkSize).toList();
        final enriched = await repo.enrichMediaMetadata(chunk);
        if (_disposed || _enrichGeneration != generation) return;
        done += chunk.length;
        final enrichedById = {for (final item in enriched) item.id: item};
        _set(() {
          _replaceItems(enrichedById);
          enrichmentProgress = (done: done, total: targets.length);
        });
        await Future<void>.delayed(Duration.zero);
      }
      if (_disposed || _enrichGeneration != generation) return;
      _set(() {
        enriching = false;
        enrichmentProgress = null;
      });
    } catch (e) {
      if (_disposed || _enrichGeneration != generation) return;
      _set(() => enriching = false);
      if (showErrors) onEnrichError?.call('Metadata enrichment failed: $e');
    }
  }

  /// Replace items in place across the loaded snapshot and search results (used
  /// by enrichment and after opening an item fetches fuller details).
  void replaceItems(Map<String, MediaItem> replacements) =>
      _set(() => _replaceItems(replacements));

  void _replaceItems(Map<String, MediaItem> replacements) {
    if (replacements.isEmpty) return;
    final snap = snapshot;
    if (snap != null) {
      snapshot = snap.copyWith(
        items: [for (final item in snap.items) replacements[item.id] ?? item],
      );
    }
    if (searchResults.isNotEmpty) {
      searchResults = [
        for (final item in searchResults) replacements[item.id] ?? item,
      ];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    firstFocusNode.dispose();
    scrollController.dispose();
    super.dispose();
  }
}
