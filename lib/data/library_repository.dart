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

/// Sits between a [Source] and the [AppDatabase]: serves channels from cache
/// when available, refreshes EPG when stale, and only hits the provider for
/// the heavy fetch on a cold start or an explicit refresh.
class LibraryRepository {
  final Source source;
  final AppDatabase db;

  /// EPG is re-fetched if older than this (or on a forced refresh).
  static const _epgMaxAge = Duration(hours: 3);

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

  Future<void> _ensureEpg(List<Channel> channels,
      {required bool forceRefresh}) async {
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
}