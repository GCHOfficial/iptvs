import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../data/diagnostics_log.dart';
import '../data/net.dart';
import '../data/source_store.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import 'favorites_order.dart';

/// A favorited live channel together with the source that owns it.
///
/// [sourceLabel] is resolved from the [SourceConfig] rather than the cached
/// row, so it matches the name shown everywhere else (app bar, player badge).
@immutable
class GlobalFavoriteChannel {
  final Channel channel;
  final SourceConfig config;

  const GlobalFavoriteChannel({required this.channel, required this.config});

  String get sourceId => config.id;
  String get sourceLabel =>
      config.label.trim().isEmpty ? config.kind.name : config.label.trim();

  /// Stable identity across sources: the same provider channel id can appear in
  /// several lists, which is exactly the duplicate case the source chip exists
  /// to disambiguate.
  ///
  /// A record rather than a joined string, so no delimiter has to be chosen
  /// that cannot occur inside either half — provider ids are arbitrary text.
  /// Dart records compare structurally, so this works directly as a set key.
  (String, String) get globalId => (sourceId, channel.id);
}

/// The cross-source ("all sources") live Favorites view.
///
/// Reads straight from the cache, so it needs no catalog loaded and no source
/// active — favorites are already stored cross-source (the `favorites` primary
/// key is `(source_id, kind, item_id)`), and every source leaves its `channels`
/// rows behind. Channels come back with locators **sealed**; playback reveals
/// the single channel through its owning source's repository.
///
/// Favorites whose source has since been deleted are dropped: the cache row can
/// outlive the [SourceConfig], and a row with no source can neither be labelled
/// nor played.
///
/// Rows come back in **catalog reading order** — the user's own source order
/// first (as arranged on the sources screen), then category order inside each
/// source, then channel order inside each category. Without the source level
/// this list interleaves every provider by raw channel number, which reads as
/// no order at all once two lists are configured: a row numbered 2 in one
/// provider lands above a row numbered 5 in another, next to a source chip
/// saying they are unrelated. See `favorites_order.dart` for why the order is
/// derived rather than stored.
///
/// Rows carry an **EPG**, keyed by `(sourceId, channelId)` — see [epgFor]. That
/// pair is the entire reason they can: a guide is per-source and the live tab's
/// own now/next maps are keyed by channel id alone, which a foreign row can
/// collide with, so handing those over would print another provider's programme
/// against this channel. A foreign source's guide is only refreshed while that
/// source is active and so can be stale, but staleness degrades to *nothing*
/// rather than to something wrong: both halves of the query are bounded by the
/// current instant, so an out-of-date guide simply stops matching.
class GlobalFavoritesController extends ChangeNotifier {
  final AppDatabase db;
  final SourceStore store;

  GlobalFavoritesController({required this.db, required this.store});

  List<GlobalFavoriteChannel> _items = const [];
  List<GlobalFavoriteChannel> get items => _items;

  bool _loading = false;
  bool get loading => _loading;

  /// The ranks the last [load] ordered by, kept so a favorite toggled on the
  /// active source can be slotted into place without re-reading anything.
  Map<String, int> _sourceRanks = const {};
  final Map<String, Map<String, int>> _categoryRanksBySource = {};

  /// Whether [load] has ever completed. Until it has there is no ordered list
  /// to insert into, so [applyLocalChange] falls back to a full load.
  bool _loadedOnce = false;

  /// Now/next for these rows, keyed by **`(sourceId, channelId)`**.
  ///
  /// Never by channel id alone: this is the one view where two providers'
  /// channels share a list, and provider ids are unique only within a provider.
  Map<(String, String), Programme> _now = const {};
  Map<(String, String), Programme> _next = const {};

  /// Whether any row has a guide entry — the live tab reads this to choose the
  /// row height, so it must describe what the rows will actually draw.
  bool get hasEpg => _now.isNotEmpty || _next.isNotEmpty;

  /// The guide for one row. Both halves are null for a source with no cached
  /// guide, which is the ordinary case for a provider not yet browsed.
  ({Programme? now, Programme? next}) epgFor(
    String sourceId,
    String channelId,
  ) => (now: _now[(sourceId, channelId)], next: _next[(sourceId, channelId)]);

  Timer? _epgTimer;

  /// Start the periodic now/next refresh, on the same one-minute cadence as the
  /// active source's guide. Call once, after the first load.
  void startEpgRefresh() {
    _epgTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(refreshEpg()),
    );
  }

  bool _disposed = false;
  // Generation guard, as for every other async publish in this app: a reload
  // triggered by a favorite toggle must beat an in-flight earlier load.
  int _generation = 0;

  Future<void> load() async {
    final gen = ++_generation;
    _set(() => _loading = true);
    final List<({String sourceId, Channel channel})> rows;
    final List<SourceConfig> configs;
    final categoryRanksBySource = <String, Map<String, int>>{};
    try {
      rows = await db.readFavoriteChannelsAcrossSources();
      // Reads the OS keychain, which can fail outright (locked/unavailable
      // backend, or no plugin at all under `flutter test`).
      configs = await store.list();
      // Category order per source, for the middle rank. Only for sources that
      // actually contributed a row — a configured-but-unfavorited provider
      // would be a query for nothing. Concurrent rather than sequential
      // because this whole load re-runs on **every favorite toggle**, and
      // serializing one query per configured source made a star press cost the
      // sum of them instead of the longest.
      final sourceIds = {for (final row in rows) row.sourceId}.toList();
      final categoryLists = await Future.wait(sourceIds.map(db.readCategories));
      for (var i = 0; i < sourceIds.length; i++) {
        categoryRanksBySource[sourceIds[i]] = catalogRanks(
          categoryLists[i].map((c) => c.id),
        );
      }
    } catch (error) {
      // This view is additive: the per-source list must still load. Failing
      // soft here keeps a broken keychain or cache read from taking the whole
      // channel list down with it.
      DiagnosticsLog.instance.add(
        'library',
        'cross-source favorites unavailable: ${redactText('$error')}',
      );
      if (_disposed || gen != _generation) return;
      _set(() {
        _items = const [];
        _loading = false;
      });
      return;
    }
    if (_disposed || gen != _generation) return;
    _categoryRanksBySource
      ..clear()
      ..addAll(categoryRanksBySource);
    final byId = {for (final c in configs) c.id: c};
    // The user's arrangement of the sources screen is the outer rank; the query
    // already returns each source's rows in that source's own channel order,
    // which `orderedByCatalog` keeps as the innermost tie-break.
    final sourceRanks = catalogRanks(configs.map((c) => c.id));
    _sourceRanks = sourceRanks;
    _loadedOnce = true;
    _set(() {
      _items = orderedByCatalog(
        [
          for (final row in rows)
            if (byId[row.sourceId] case final config?)
              GlobalFavoriteChannel(channel: row.channel, config: config),
        ],
        sourceRank: (item) => rankOf(sourceRanks, item.sourceId),
        categoryRank: (item) => rankOf(
          categoryRanksBySource[item.sourceId] ?? const {},
          item.channel.categoryId,
        ),
      );
      _loading = false;
    });
    await refreshEpg();
  }

  /// Re-reads now/next for the rows currently listed.
  ///
  /// A **subordinate** op in the repo's async-publish sense: it reads the load
  /// generation without bumping it, so a reload always beats a refresh in
  /// flight and never the reverse.
  ///
  /// Uses the channel-constrained [AppDatabase.nowNextForChannels] rather than
  /// the whole-source [AppDatabase.nowNext]: the row set here is a small,
  /// fully-known list of favorites, which is exactly the case that query
  /// exists for — the live tab can't use it because it reads arbitrary rows.
  Future<void> refreshEpg() async {
    final gen = _generation;
    final idsBySource = <String, List<String>>{};
    for (final item in _items) {
      (idsBySource[item.sourceId] ??= <String>[]).add(item.channel.id);
    }
    if (idsBySource.isEmpty) {
      if (_now.isEmpty && _next.isEmpty) return;
      _set(() {
        _now = const {};
        _next = const {};
      });
      return;
    }
    final sourceIds = idsBySource.keys.toList();
    final at = DateTime.now();
    final List<({Map<String, Programme> now, Map<String, Programme> next})>
    perSource;
    try {
      perSource = await Future.wait([
        for (final sourceId in sourceIds)
          db.nowNextForChannels(sourceId, idsBySource[sourceId]!, at),
      ]);
    } catch (error) {
      // Fails soft for the same reason the load does: this view is additive,
      // and a guide is the least of what it is for.
      DiagnosticsLog.instance.add(
        'library',
        'cross-source favorites guide unavailable: ${redactText('$error')}',
      );
      return;
    }
    if (_disposed || gen != _generation) return;
    final now = <(String, String), Programme>{};
    final next = <(String, String), Programme>{};
    for (var i = 0; i < sourceIds.length; i++) {
      final sourceId = sourceIds[i];
      perSource[i].now.forEach((id, p) => now[(sourceId, id)] = p);
      perSource[i].next.forEach((id, p) => next[(sourceId, id)] = p);
    }
    _set(() {
      _now = now;
      _next = next;
    });
  }

  /// Reflects a favorite toggled on the **active** source, which writes the
  /// same `favorites` table this view reads through a controller that knows
  /// nothing about this one.
  ///
  /// Without it the cross-source view only caught up on the next full reload,
  /// so a channel starred from the ordinary list simply wasn't there until the
  /// user refreshed — while the per-source Favorites view updated instantly.
  ///
  /// Incremental rather than a [load] because this runs on **every star
  /// press**: a load re-reads the OS keychain ([SourceStore.list]) and requeries
  /// every contributing source. The list is already in catalog order, so the
  /// new row only has to be put in the right place.
  Future<void> applyLocalChange({
    required SourceConfig config,
    required Channel channel,
    required bool favorite,
  }) async {
    if (!favorite) {
      removeLocally(config.id, channel.id);
      return;
    }
    // Nothing ordered to insert into yet.
    if (!_loadedOnce) return load();
    final gen = _generation;
    if (!_categoryRanksBySource.containsKey(config.id)) {
      // The first favorite in this source: it contributed no row to the last
      // load, so its category order was never read. One indexed query, not a
      // whole reload.
      Map<String, int> ranks;
      try {
        ranks = catalogRanks(
          (await db.readCategories(config.id)).map((c) => c.id),
        );
      } catch (error) {
        DiagnosticsLog.instance.add(
          'library',
          'cross-source favorites category order unavailable: '
              '${redactText('$error')}',
        );
        ranks = const {};
      }
      if (_disposed || gen != _generation) return;
      _categoryRanksBySource[config.id] = ranks;
    }
    if (_items.any(
      (item) => item.sourceId == config.id && item.channel.id == channel.id,
    )) {
      return;
    }
    final added = GlobalFavoriteChannel(channel: channel, config: config);
    final next = [..._items]..insert(_insertionIndex(added), added);
    _set(() => _items = next);
    // The row is on screen already; the guide catches up. This re-queries every
    // contributing source rather than just this one — the queries are
    // channel-constrained and bounded by the favorites count, not the catalog,
    // so a merge path for one source would buy little and add a second way for
    // these maps to be maintained.
    await refreshEpg();
  }

  /// Where [candidate] belongs in [_items] to keep it in catalog order.
  ///
  /// An insertion, not a re-sort: the list is already ordered, so placing the
  /// row costs nothing but a walk of the favorites. The comparison reproduces
  /// the order [load] publishes — source rank, then category rank, then the
  /// channel order `readFavoriteChannelsAcrossSources` sorts by
  /// (`number`, `name`).
  int _insertionIndex(GlobalFavoriteChannel candidate) {
    for (var i = 0; i < _items.length; i++) {
      if (_sortsAfter(_items[i], candidate)) return i;
    }
    return _items.length;
  }

  bool _sortsAfter(GlobalFavoriteChannel a, GlobalFavoriteChannel b) {
    final bySource = rankOf(
      _sourceRanks,
      a.sourceId,
    ).compareTo(rankOf(_sourceRanks, b.sourceId));
    if (bySource != 0) return bySource > 0;
    final byCategory =
        rankOf(
          _categoryRanksBySource[a.sourceId] ?? const {},
          a.channel.categoryId,
        ).compareTo(
          rankOf(
            _categoryRanksBySource[b.sourceId] ?? const {},
            b.channel.categoryId,
          ),
        );
    if (byCategory != 0) return byCategory > 0;
    // `ORDER BY c.number, c.name`, and SQLite sorts NULL before any value.
    final an = a.channel.number;
    final bn = b.channel.number;
    if (an != bn) {
      if (an == null) return false;
      if (bn == null) return true;
      return an > bn;
    }
    return a.channel.name.compareTo(b.channel.name) > 0;
  }

  /// Drops [channel] from the in-memory list after it was unfavorited, without
  /// a database round trip. The row is already gone from `favorites`; a full
  /// [load] would only re-read the same answer.
  void removeLocally(String sourceId, String channelId) {
    final next = [
      for (final item in _items)
        if (!(item.sourceId == sourceId && item.channel.id == channelId)) item,
    ];
    if (next.length == _items.length) return;
    _set(() => _items = next);
  }

  void _set(VoidCallback mutate) {
    if (_disposed) return;
    mutate();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epgTimer?.cancel();
    super.dispose();
  }
}
