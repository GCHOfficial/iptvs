import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../data/source_store.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';

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
    final rows = await db.readFavoriteChannelsAcrossSources();
    final configs = await store.list();
    if (_disposed || gen != _generation) return;
    final byId = {for (final c in configs) c.id: c};
    _set(() {
      _items = [
        for (final row in rows)
          if (byId[row.sourceId] case final config?)
            GlobalFavoriteChannel(channel: row.channel, config: config),
      ];
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
