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
class GlobalFavoritesController extends ChangeNotifier {
  final AppDatabase db;
  final SourceStore store;

  GlobalFavoritesController({required this.db, required this.store});

  List<GlobalFavoriteChannel> _items = const [];
  List<GlobalFavoriteChannel> get items => _items;

  bool _loading = false;
  bool get loading => _loading;

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
      final categoryLists = await Future.wait(
        sourceIds.map(db.readCategories),
      );
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
    final byId = {for (final c in configs) c.id: c};
    // The user's arrangement of the sources screen is the outer rank; the query
    // already returns each source's rows in that source's own channel order,
    // which `orderedByCatalog` keeps as the innermost tie-break.
    final sourceRanks = catalogRanks(configs.map((c) => c.id));
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
    super.dispose();
  }
}
