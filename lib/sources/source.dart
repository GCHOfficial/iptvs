import 'package:flutter/foundation.dart';

/// Provider-agnostic domain model + interface for an IPTV source.
///
/// Stalker, Xtream Codes, and M3U each implement [Source], so the rest of the
/// app never needs to know which kind of provider it's talking to. To add a
/// new provider you implement this one interface and change nothing else.

@immutable
class Category {
  final String id;
  final String title;
  const Category({required this.id, required this.title});
}

enum ContentKind { live, movie, series, season, episode }

@immutable
class MediaCategory {
  final String id;
  final String title;
  final ContentKind kind;

  const MediaCategory({
    required this.id,
    required this.title,
    required this.kind,
  });
}

@immutable
class Channel {
  final String id;
  final String name;
  final String? logo;
  final String? categoryId;
  final int? number;

  /// Provider-specific payload the owning [Source] knows how to interpret in
  /// [Source.resolve] — e.g. Stalker's `cmd`, Xtream's stream id. Keeps
  /// provider details out of the shared model.
  final Map<String, dynamic> extra;

  const Channel({
    required this.id,
    required this.name,
    this.logo,
    this.categoryId,
    this.number,
    this.extra = const {},
  });
}

@immutable
class MediaItem {
  final String id;
  final String title;
  final ContentKind kind;
  final String? parentId;
  final String? categoryId;
  final String? poster;
  final String? backdrop;
  final String? description;
  final String? year;
  final double? rating;
  final int? durationSeconds;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? providerId;
  final Map<String, dynamic> extra;

  const MediaItem({
    required this.id,
    required this.title,
    required this.kind,
    this.parentId,
    this.categoryId,
    this.poster,
    this.backdrop,
    this.description,
    this.year,
    this.rating,
    this.durationSeconds,
    this.seasonNumber,
    this.episodeNumber,
    this.providerId,
    this.extra = const {},
  });

  MediaItem copyWith({
    String? id,
    String? title,
    ContentKind? kind,
    String? parentId,
    String? categoryId,
    String? poster,
    String? backdrop,
    String? description,
    String? year,
    double? rating,
    int? durationSeconds,
    int? seasonNumber,
    int? episodeNumber,
    String? providerId,
    Map<String, dynamic>? extra,
  }) => MediaItem(
    id: id ?? this.id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    parentId: parentId ?? this.parentId,
    categoryId: categoryId ?? this.categoryId,
    poster: poster ?? this.poster,
    backdrop: backdrop ?? this.backdrop,
    description: description ?? this.description,
    year: year ?? this.year,
    rating: rating ?? this.rating,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber ?? this.episodeNumber,
    providerId: providerId ?? this.providerId,
    extra: extra ?? this.extra,
  );
}

@immutable
class MediaPage {
  final List<MediaItem> items;
  final int page;
  final int totalPages;

  const MediaPage({
    required this.items,
    required this.page,
    required this.totalPages,
  });

  bool get hasMore => page < totalPages;
}

@immutable
class ExternalMetadata {
  final String provider;
  final String providerKey;
  final String? title;
  final String? overview;
  final String? poster;
  final String? backdrop;
  final String? year;
  final double? rating;
  final Map<String, dynamic> payload;
  final DateTime refreshedAt;

  const ExternalMetadata({
    required this.provider,
    required this.providerKey,
    this.title,
    this.overview,
    this.poster,
    this.backdrop,
    this.year,
    this.rating,
    this.payload = const {},
    required this.refreshedAt,
  });
}

/// A resolved, playable stream: the URL plus any HTTP headers the player must
/// send (User-Agent, Referer, etc.). Stalker and Xtream often need a MAG
/// User-Agent here; M3U usually needs nothing.
///
/// [isLive] is set by the owning [Source] — liveness is provider metadata, not
/// something to infer from the stream (an HLS live window reports a finite
/// duration, which looks just like VOD). Live streams get no seek bar; VOD does.
@immutable
class StreamInfo {
  final String url;
  final Map<String, String> headers;
  final bool isLive;
  const StreamInfo({
    required this.url,
    this.headers = const {},
    this.isLive = true,
  });
}

@immutable
class Programme {
  final String channelId;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? description;

  const Programme({
    required this.channelId,
    required this.start,
    required this.stop,
    required this.title,
    this.description,
  });
}

abstract class Source {
  /// Stable identifier, used as the cache key for this source's data.
  String get id;

  /// Display name for the UI.
  String get name;

  /// Authenticate / prepare the source. For M3U this may be a no-op.
  Future<void> connect();

  /// Live TV categories.
  Future<List<Category>> categories();

  /// Channels, optionally filtered to a single category.
  Future<List<Channel>> channels({String? categoryId});

  /// Turn a channel into a playable stream. For Stalker this is where
  /// create_link is called — the URL is short-lived, so resolve at play time,
  /// never ahead of it.
  Future<StreamInfo> resolve(Channel channel);

  /// Electronic program guide for roughly the next few hours, given the
  /// source's [channels] (XMLTV sources need them to map tvg-id → channel id;
  /// Stalker ignores them and keys by channel id directly). Programmes are
  /// keyed via [Programme.channelId]. Sources without EPG return an empty list.
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    final items = await mediaItems(
      kind,
      categoryId: categoryId,
      parent: parent,
    );
    return MediaPage(items: items, page: page, totalPages: page);
  }

  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final page = await mediaItemsPage(kind, categoryId: categoryId);
    return page.items
        .where((item) => item.title.toLowerCase().contains(q))
        .toList();
  }

  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('This source does not support ${item.kind.name}');

  /// Release any held resources.
  Future<void> dispose() async {}
}
