import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show debugPrint;

import '../sources/source.dart';
import 'app_database.dart';
import 'diagnostics_log.dart';
import 'load_token.dart';
import 'metadata_provider.dart';
import 'net.dart' show formatBytes, redactText;
import 'programme_spool.dart';

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

  /// Cooperative-cancellation token for the in-flight [load]/[loadMedia]/
  /// [loadMoreMedia] call, additive to the controllers' `_loadGeneration`
  /// guards (see CLAUDE.md "Async publishes are generation-guarded"): the
  /// generation guard stops a stale result from being *published*; this token
  /// stops a stale call from **overwriting a populated cache** once a newer
  /// call has superseded it. It does *not* stop the write outright — a
  /// superseded load may still seed an *empty* cache (`_loadChannels`,
  /// `loadMedia`), and it does not reach the EPG batch path at all, which is
  /// cancelled by `EpgIngestCoordinator`'s own tokens instead.
  ///
  /// This is a plain settable field rather than a parameter on those methods
  /// on purpose: [LibraryRepository] is subclassed by Completer-gated test
  /// doubles (`test/live_controller_test.dart`, `test/media_tab_controller_test.dart`)
  /// that `@override` `load`/`loadMedia`/`loadMoreMedia`, and Dart requires an
  /// override to redeclare every parameter of the method it overrides —
  /// adding a new named parameter to these methods would break those pinned
  /// overrides. A caller sets [loadToken] to the token it wants honoured, then
  /// invokes the method in the same synchronous prologue (no `await` in
  /// between); each method reads it into a local at its very first line,
  /// before its own first `await`, so a later reassignment (a newer call
  /// superseding this one) can never leak into a call already under way.
  LoadToken? loadToken;

  Future<LibrarySnapshot> load({bool forceRefresh = false}) async {
    final token = loadToken;
    // Always connect: cheap auth, and resolve()/playback/EPG need it.
    await source.connect();
    // A forced reload must drop the source's in-memory catalog, or "Reload
    // source" replays a memoized list and never reaches the provider. `is`
    // doesn't promote across the unrelated RefreshableSource interface, hence
    // the explicit cast (safe, guarded by the check).
    if (forceRefresh && source is RefreshableSource) {
      (source as RefreshableSource).invalidate();
    }

    final snapshot = await _loadChannels(
      forceRefresh: forceRefresh,
      token: token,
    );

    // EPG is best-effort and time-sensitive: the channel list does not depend
    // on it, so it refreshes *behind* the returned snapshot rather than in
    // front of it. A second guide costs a second download and parse, and
    // awaiting that put 5-10 seconds of spinner between the user and a channel
    // list that was already in hand.
    //
    // Backgrounding it was tried once before and reverted, because
    // `replaceEpgStream` held one write transaction across every guide's
    // *download*: on the single sqflite connection this app shares, that
    // blocked all other database work for the length of the network fetch, and
    // switching source mid-ingest deadlocked (`channel_list_focus_test` hung
    // for ten minutes on sqflite's "database has been locked" warning). Two
    // things make it safe now, and neither is optional:
    //
    //  * [ProgrammeSpool] drains the guide to a temporary file first, so the
    //    transaction only ever spans local inserts — bounded, and with no
    //    network inside it.
    //  * [AppDatabase.epgIngest] holds one refresh at a time app-wide and waits
    //    for a superseded one to stop before its replacement starts.
    //
    // Whether it is *worth* refreshing is decided here rather than inside the
    // refresh, so a load that has nothing to do leaves [pendingEpgRefresh] null
    // instead of handing the UI a future that completes immediately. The live
    // status line reads that to say "updating guide", and a guide that was
    // already fresh would otherwise flash the message for one frame on every
    // load.
    //
    // A *superseded* load skips it outright. The load that cancelled this one
    // schedules its own, and `EpgIngestCoordinator` is last-start-wins — so a
    // late refresh from a stale load would take the slot *from* the correct one
    // already running, and match guides against the channel list this load
    // fetched rather than the one now cached. Nothing is lost by skipping:
    // `epg_synced_at` is only advanced by a refresh that actually landed, so
    // the next load still finds the guide stale and re-runs it.
    if (!(token?.isCancelled ?? false) && await _epgNeedsRefresh(forceRefresh)) {
      unawaited(
        _scheduleEpgRefresh(snapshot.channels, forceRefresh: forceRefresh),
      );
    } else {
      _pendingEpgRefresh = null;
    }

    return snapshot;
  }

  /// Whether the cached guide is old enough (or the load forced enough) to be
  /// worth re-fetching.
  Future<bool> _epgNeedsRefresh(bool forceRefresh) async {
    if (forceRefresh) return true;
    final last = await db.lastEpgSynced(source.id);
    return last == null || DateTime.now().difference(last) > _epgMaxAge;
  }

  /// The background EPG refresh this repository last started, or null if it has
  /// not started one.
  ///
  /// Exposed for tests and for any caller that genuinely needs the guide before
  /// it can continue — [load] deliberately does not wait for it.
  Future<void>? get pendingEpgRefresh => _pendingEpgRefresh;
  Future<void>? _pendingEpgRefresh;

  Future<void> _scheduleEpgRefresh(
    List<Channel> channels, {
    required bool forceRefresh,
  }) {
    // The token comes from the coordinator, not from [loadToken]: this outlives
    // the `load()` that started it, and cancellation now means "a newer refresh
    // has taken the slot", which is the coordinator's business rather than the
    // load's.
    final refresh = db.epgIngest.start(
      source.id,
      (token) => _refreshEpg(channels, forceRefresh: forceRefresh, token: token),
    );
    _pendingEpgRefresh = refresh;
    return refresh;
  }

  Future<LibrarySnapshot> _loadChannels({
    required bool forceRefresh,
    LoadToken? token,
  }) async {
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

    final providerWatch = Stopwatch()..start();
    final categories = await source.categories();
    final channels = await source.channels();
    providerWatch.stop();
    // A superseded load must never *overwrite* a cached catalog — but it must
    // still be allowed to **seed an empty one**, and the whole point of this
    // branch is the difference between the two.
    //
    // Overwriting is genuinely unsafe, for two reasons that outlive the
    // controller's generation guard (which only stops the UI publish). The
    // channel cache has no age check — `_loadChannels` above gates on "is there
    // a cache", nothing more — so whatever lands here stands until an explicit
    // forced refresh. And commit order is not fetch order: a slow superseded
    // load can land *after* the fast one that replaced it, stamping older rows
    // with a newer `synced_at`. Worse, `upgradeM3uToXtream` deliberately keeps
    // the source id, so an in-flight M3U load can outlive the upgrade and write
    // playlist-shaped rows under a source that is now Xtream — whose `resolve`
    // falls back to `channel.id` for the stream id, i.e. every channel silently
    // unplayable, permanently.
    //
    // Refusing to write *at all*, though, is how a device gets stuck, and that
    // is a real field report rather than a hypothetical: on a low-end TV box a
    // 66 MB playlist costs ~55 s (29 s download + 26 s isolate parse), and
    // every rebuild of the repository — the load-time M3U→Xtream probe alone
    // does one per app start — cancelled the load and threw the finished
    // catalog away. The cache stayed empty, so the next attempt paid the full
    // 55 s again, forever. A complete catalog is strictly better than none.
    //
    // `onlyIfAbsent` settles both orders with no sequencing and no identity on
    // the token: the stale writer commits only while there is nothing to lose,
    // and a fresh catalog that already landed makes it a no-op.
    final superseded = token?.isCancelled ?? false;
    final databaseWatch = Stopwatch()..start();
    var wrote = false;
    try {
      wrote = await db.replaceLibrary(
        source.id,
        source.name,
        categories,
        channels,
        onlyIfAbsent: superseded,
      );
    } catch (error) {
      // A supersede correlates with teardown, so the connection may be closing
      // under us. Losing the seed is acceptable; failing the load is not.
      if (!superseded) rethrow;
      DiagnosticsLog.instance.add(
        'library',
        'superseded seed for ${source.id} failed: ${error.runtimeType}',
      );
    }
    databaseWatch.stop();
    if (wrote) {
      DiagnosticsLog.instance.recordIngestion(
        scope: 'source:${source.id}',
        providerDuration: providerWatch.elapsed,
        databaseDuration: databaseWatch.elapsed,
      );
    } else {
      // The field report's worst property was silence: ~55 s of work left
      // nothing whatsoever in the exported log.
      DiagnosticsLog.instance.add(
        'library',
        'superseded load for ${source.id}: ${channels.length} channels fetched '
            'in ${providerWatch.elapsed.inMilliseconds} ms, not written '
            '(cache already populated)',
      );
    }
    return LibrarySnapshot(
      categories: categories,
      channels: channels,
      fromCache: false,
      syncedAt: DateTime.now(),
    );
  }

  /// Whether the last completed guide refresh failed outright.
  ///
  /// A failed refresh is invisible by design — the cached guide is retained and
  /// the channel list is untouched — which is right, except when there is no
  /// cached guide to retain. "No EPG at all" and "every guide URL is broken"
  /// then look identical on screen, and only the second is something the user
  /// can act on. `LiveController` pairs this with an empty guide to say so.
  ///
  /// A *superseded* refresh sets neither verdict: it is not an outcome.
  bool get lastEpgRefreshFailed => _lastEpgRefreshFailed;
  bool _lastEpgRefreshFailed = false;

  /// [_ensureEpg] wrapped in [load]'s failure policy, and the only place the
  /// [lastEpgRefreshFailed] verdict is decided.
  ///
  /// Completes without an error in every case: the coordinator drops this
  /// future, where a rejection would surface as an unhandled asynchronous
  /// error rather than as anything a user could act on.
  Future<void> _refreshEpg(
    List<Channel> channels, {
    required bool forceRefresh,
    LoadToken? token,
  }) async {
    try {
      await _ensureEpg(channels, forceRefresh: forceRefresh, token: token);
      _lastEpgRefreshFailed = false;
    } on LoadCancelledException {
      // Superseded by a newer refresh — neither a success nor a failure, so the
      // previous verdict stands rather than being overwritten by a non-event.
      DiagnosticsLog.instance.add('epg', 'EPG refresh superseded');
    } catch (error) {
      // Source may not provide EPG, or the call failed — keep the cached
      // guide and just note the failure; retry happens on the next load.
      _lastEpgRefreshFailed = true;
      DiagnosticsLog.instance.add(
        'epg',
        'EPG refresh failed; retaining cached guide: ${redactText(error.toString())}',
      );
    }
  }

  Future<void> _ensureEpg(
    List<Channel> channels, {
    required bool forceRefresh,
    LoadToken? token,
  }) async {
    // Staleness is the caller's call — [load] decides it before scheduling, and
    // this is only reachable through that. Re-reading it here would be a second
    // round trip to the same row for an answer that cannot have changed in the
    // meantime.
    if (source is BatchedEpgSource) {
      // `is` doesn't promote across unrelated interfaces (Source and
      // BatchedEpgSource share no subtype relationship), hence the explicit
      // cast — safe, guarded by the check above.
      final batchedSource = source as BatchedEpgSource;
      final batches = batchedSource.epgBatched(channels, token: token);
      if (batches != null) {
        // Download, decompress and parse every guide to a temporary file
        // **before** opening a transaction. See [ProgrammeSpool]: consumed
        // directly, this stream would have held the app's only database
        // connection for the length of the network fetch.
        //
        // A supersede propagates out of here rather than being caught: it is
        // [_refreshEpg] that decides what a cancellation means, and swallowing
        // it here recorded one as a successful guide.
        final providerWatch = Stopwatch()..start();
        final spool = await ProgrammeSpool.drain(batches);
        providerWatch.stop();
        try {
          final metrics = await db.replaceEpgStream(source.id, spool.read());
          DiagnosticsLog.instance.add(
            'epg',
            'guide staged for ${source.id}: ${spool.programmes} programmes '
                'in ${spool.batches} batches, ${formatBytes(spool.bytes)} '
                'spooled',
          );
          DiagnosticsLog.instance.recordIngestion(
            scope: 'epg:${source.id}',
            providerDuration: providerWatch.elapsed,
            databaseDuration: metrics.databaseDuration,
          );
        } finally {
          await spool.dispose();
        }
        db.notifyEpgChanged(source.id);
        return;
      }
    }

    final providerWatch = Stopwatch()..start();
    final programmes = await source.epg(channels);
    providerWatch.stop();
    if (token?.isCancelled ?? false) {
      // Superseded by a newer refresh — skip the stale guide write. Thrown
      // rather than returned so [_refreshEpg] can tell this apart from a
      // guide that genuinely landed: returning normally recorded a supersede
      // as a *success*, clearing any real failure verdict behind it. The
      // previous guide stays intact with its epg_synced_at un-advanced, so
      // the newer refresh still replaces it.
      throw const LoadCancelledException();
    }
    // Always replace — a success-empty result (a source with no EPG data)
    // must still clear any stale cached programmes and advance
    // epg_synced_at, or a no-EPG source gets re-fetched on every load.
    final databaseWatch = Stopwatch()..start();
    await db.replaceEpg(source.id, programmes);
    databaseWatch.stop();
    DiagnosticsLog.instance.recordIngestion(
      scope: 'epg:${source.id}',
      providerDuration: providerWatch.elapsed,
      databaseDuration: databaseWatch.elapsed,
    );
    db.notifyEpgChanged(source.id);
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

  /// Reveal point (see [db.revealChannel] and CLAUDE.md "Sealed playback
  /// locators"): cached channels carry their locator encrypted, so it is
  /// decrypted here — one model, at play time — before crossing into the
  /// [Source].
  Future<StreamInfo> resolve(Channel channel) async =>
      source.resolve(await db.revealChannel(channel));

  /// Resolve a past [programme] on [channel] into a catch-up stream. Resolved at
  /// play time (archive URLs are short-lived, like live). Reveal point.
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => source.resolveArchive(await db.revealChannel(channel), programme);

  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
  }) async {
    final token = loadToken;
    await source.connect();
    // A forced reload must drop any memoized VOD/series catalog before
    // fetching (see [load]); pagination (`loadMoreMedia`) never invalidates.
    if (forceRefresh && source is RefreshableSource) {
      (source as RefreshableSource).invalidate();
    }
    // Reveal point, and the easiest one to miss: `parent` is a *cached* model
    // (a season the user drilled into), so its locator is sealed, and
    // `StalkerSource._seasonPlaybackHints` reads `parent.extra['cmd']` to give
    // every episode it builds a playable command. Reassigning the parameter
    // rather than introducing a local guarantees no downstream use here can
    // keep hold of the sealed one. See CLAUDE.md "Sealed playback locators".
    if (parent != null) parent = await db.revealMediaItem(parent);
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
    // Seed-but-never-overwrite, exactly as `_loadChannels` does and for the
    // same reasons — read the long comment there. The media cache has the same
    // shape of trap: `loadMedia`'s gate above asks only whether a cache exists.
    final superseded = token?.isCancelled ?? false;
    try {
      await db.replaceMediaLibrary(
        source.id,
        kind,
        categories,
        fetchedItems,
        categoryId: categoryId,
        parentId: parentId,
        loadedPages: fetched.loadedPages,
        totalPages: fetched.totalPages,
        onlyIfAbsent: superseded,
      );
    } catch (error) {
      if (!superseded) rethrow;
      DiagnosticsLog.instance.add(
        'library',
        'superseded ${kind.name} seed for ${source.id} failed: '
            '${error.runtimeType}',
      );
    }
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
    final token = loadToken;
    await source.connect();
    // Reveal point — same reason as in [loadMedia]: `parent` reaches
    // `source.mediaItemsPage(parent:)`, which reads its locator.
    if (parent != null) parent = await db.revealMediaItem(parent);
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
    if (token?.isCancelled ?? false) {
      // Superseded by a newer load — skip the stale append; the prior sync
      // state (loadedPages/totalPages) stays intact for the next read.
      //
      // Deliberately *not* the seed-when-absent treatment `_loadChannels` and
      // `loadMedia` now get. This is a page-bookkeeping guard, not a
      // cache-freshness one: `appendMediaItems` writes back `loadedPages`/
      // `totalPages` read at the top of this method, so a late append lands
      // stale paging state over whatever replaced it. And "no cache" cannot
      // hold here anyway — this method returns early when `sync == null`, so
      // there is never an empty cache to seed.
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
        syncedAt: sync.syncedAt,
        loadedPages: sync.loadedPages,
        totalPages: sync.totalPages,
      );
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
    // Reveal point. Defensive rather than strictly required today (no
    // `mediaDetails` implementation reads a locator field), but the result is
    // merged back into the cache, so a sealed input here would round-trip a
    // stale blob through `protectSecretLocators`.
    final details = await source.mediaDetails(await db.revealMediaItem(item));
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

  /// Max metadata lookups in flight at once during [enrichMediaMetadata].
  ///
  /// Each lookup is 1-2 sequential HTTP round trips (a search call, plus a
  /// cache-miss write), so a plain serial loop over `_autoEnrichLimit` (40,
  /// see `media_tab_controller.dart`) items at a realistic ~250ms provider
  /// RTT took 15-20s before posters appeared. A fixed worker pool pulling
  /// from a shared queue keeps concurrency bounded and cheap (the
  /// `HttpClient`s are already reused per metadata-client instance, so
  /// connections are pooled) without ever `Future.wait`-ing the whole list —
  /// that would open thousands of sockets on a 250k-item catalog and get the
  /// user rate-limited or banned by the provider.
  ///
  /// This is a single constant rather than per-provider because
  /// [metadataProviders] can mix a visual provider (TMDB/TVDB) with a
  /// `ratingsOnly` one (MDBList, which rate-limits harder); per-provider caps
  /// would mean threading a limit through `MetadataProvider` itself, which
  /// ripples well beyond this method. A shared, conservative cap keeps the
  /// stricter provider safe at the cost of some possible headroom on the
  /// looser one.
  static const _enrichConcurrency = 4;

  Future<List<MediaItem>> enrichMediaMetadata(
    List<MediaItem> items, {
    int? limit,
  }) async {
    if (metadataProviders.isEmpty ||
        items.isEmpty ||
        (limit != null && limit <= 0)) {
      // Say so rather than returning in silence. A catalog refresh *deletes*
      // and re-inserts `media_items` (`replaceMediaLibrary`), so the enriched
      // poster/backdrop/title are gone until this method re-merges them from
      // the `external_metadata` cache. When it no-ops, every tile falls back to
      // the placeholder with no network request and therefore no error to log
      // anywhere — the artwork simply never appears and the session looks
      // healthy. That is the shape of a real report that took a full
      // investigation to place.
      if (metadataProviders.isEmpty && items.isNotEmpty) {
        _logMetadata(
          'enrich skipped: no metadata providers configured (items=${items.length})',
        );
      }
      return items;
    }
    final out = [...items];
    final targets = <int>[];
    for (var i = 0; i < out.length; i++) {
      if (limit != null && targets.length >= limit) break;
      final item = out[i];
      if (item.kind != ContentKind.movie &&
          item.kind != ContentKind.series &&
          item.kind != ContentKind.episode) {
        continue;
      }
      targets.add(i);
    }
    var nextTarget = 0;
    Future<void> worker() async {
      while (nextTarget < targets.length) {
        final index = targets[nextTarget++];
        try {
          out[index] = await _applyExternalMetadata(
            out[index],
            action: 'prefetch',
          );
        } catch (error) {
          // _applyExternalMetadata already swallows per-provider (network)
          // failures internally; this is a defensive backstop (e.g. a local
          // cache read/write error) so one item's failure can't strand the
          // rest of the pool or leave enrichMediaMetadata hanging.
          _logMetadata(
            'prefetch error ${out[index].kind.name}:${out[index].id}: $error',
          );
        }
      }
    }

    final workerCount = targets.length < _enrichConcurrency
        ? targets.length
        : _enrichConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    await db.updateMediaDisplayFields(source.id, out);
    // Bounded outcome summary. Per-item lines already exist, but they don't
    // answer the question that matters when a user reports "no artwork":
    // whether enrichment ran and still produced nothing. A pass that targets
    // items and returns almost none with a poster is the signature of that
    // failure, and it is invisible from the individual lines.
    final withPoster = targets
        .where((index) => (out[index].poster ?? '').isNotEmpty)
        .length;
    _logMetadata(
      'enrich done targets=${targets.length} with_poster=$withPoster',
    );
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

  /// Reveal point — see [resolve].
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      source.resolveMedia(await db.revealMediaItem(item));
}
