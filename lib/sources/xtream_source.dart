import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../data/load_token.dart';
import '../data/net.dart';
import 'expiry.dart';
import 'source.dart';
import 'xmltv.dart';

/// A [Source] backed by an Xtream Codes panel (host + username + password).
///
/// Implements live TV; VOD and series can be layered on the same interface
/// later. Stream URLs follow `/live/USER/PASS/STREAM_ID.ext`.
class XtreamSource implements Source, BatchedEpgSource, CatchupSource {
  final String sourceId;
  final String host; // e.g. http://host:port
  final String username;
  final String password;
  final String streamExtension; // 'ts' (most compatible) or 'm3u8'
  /// Expiry carried by an M3U/get.php URL before it was converted to an
  /// Xtream source. Some panels expose it in the playlist URL but omit it
  /// from `player_api.php`.
  final String? playlistExpiryHint;

  /// Advanced per-source catch-up overrides. When omitted, Xtream panels are
  /// treated as using the device wall clock.
  final String? catchupTimezone;
  final int? catchupOffsetMinutes;
  final int? catchupMaxDays;
  @visibleForTesting
  final Future<dynamic> Function(Map<String, String> params)? debugApi;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;
  final Map<String, Future<List<MediaItem>>> _mediaListCache = {};

  // Stalker portals usually return compact provider pages, often around
  // 14 rows. Xtream's common API does not expose equivalent paging, so keep
  // the app-facing page small and let category filters/search carry discovery.
  static const _mediaPageSize = 14;
  static const _searchResultLimit = 120;

  XtreamSource({
    required this.sourceId,
    required this.host,
    required this.username,
    required this.password,
    this.streamExtension = 'ts',
    this.playlistExpiryHint,
    this.catchupTimezone,
    this.catchupOffsetMinutes,
    this.catchupMaxDays,
    this.debugApi,
    this.displayName,
  });

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  String get _base {
    var h = host.trim();
    if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://$h';
    if (h.endsWith('/')) h = h.substring(0, h.length - 1);
    return h;
  }

  @override
  String get id => sourceId;

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'Xtream · ${Uri.tryParse(_base)?.host ?? 'panel'}';

  @override
  CatchupCapability get catchupCapability => CatchupCapability(
    mode: CatchupUrlMode.xtreamTimeshift,
    timezone: catchupTimezone,
    fixedOffsetMinutes: catchupOffsetMinutes,
    maxArchiveWindow: catchupMaxDays == null
        ? null
        : Duration(days: catchupMaxDays!),
    startFormat: 'yyyy-MM-dd:HH-mm',
  );

  @override
  Future<void> connect() async {
    final info = await _api({});
    final user = info is Map ? info['user_info'] : null;
    if (user is Map && '${user['auth']}' == '0') {
      throw StateError('Xtream authentication failed');
    }
  }

  @override
  Future<List<Category>> categories() async {
    final r = await _api({'action': 'get_live_categories'});
    if (r is! List) return const [];
    return r
        .whereType<Map>()
        .map(
          (c) => Category(
            id: '${c['category_id']}',
            title: '${c['category_name']}',
          ),
        )
        .toList();
  }

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    final params = {'action': 'get_live_streams'};
    if (categoryId != null) params['category_id'] = categoryId;
    Object? raw;
    try {
      raw = await _fetchCatalogRaw(params);
    } on HttpWorkloadException {
      if (categoryId != null) rethrow;
      return _channelsPartitionedByCategory();
    }
    return _channelsFromRaw(raw);
  }

  /// Xtream's common API has no formal pagination for live streams, but most
  /// panels honor category_id. If the monolithic catalog crosses the bounded
  /// response limit, partition it by category and merge stable stream IDs.
  Future<List<Channel>> _channelsPartitionedByCategory() async {
    final available = await categories();
    if (available.isEmpty) {
      throw const HttpWorkloadException(
        'Xtream live catalog is too large and exposes no categories',
      );
    }
    final out = <Channel>[];
    final seen = <String>{};
    for (final category in available) {
      final raw = await _fetchCatalogRaw({
        'action': 'get_live_streams',
        'category_id': category.id,
      });
      for (final channel in await _channelsFromRaw(raw)) {
        if (seen.add(channel.id)) out.add(channel);
      }
    }
    return out;
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final streamId = channel.extra['streamId']?.toString() ?? channel.id;
    return StreamInfo(
      url: '$_base/live/$username/$password/$streamId.$streamExtension',
    );
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    final streamId = channel.extra['streamId']?.toString() ?? channel.id;
    final duration = programme.stop.difference(programme.start).inMinutes;
    return StreamInfo(
      url:
          '$_base/timeshift/$username/$password/$duration/'
          '${_timeshiftStart(programme.start, catchupCapability)}/$streamId.$streamExtension',
      isLive: false,
    );
  }

  /// Xtream timeshift start stamp `Y-m-d:H-i`. XMLTV times are absolute, but the
  /// endpoint expects the panel's local time; we use the device's local zone
  /// (device ≈ panel region in practice). A per-source offset is the future
  /// refinement if a panel sits in a different zone.
  @visibleForTesting
  static String timeshiftStart(
    DateTime start, [
    CatchupCapability? capability,
  ]) => _timeshiftStart(
    start,
    capability ?? const CatchupCapability(mode: CatchupUrlMode.xtreamTimeshift),
  );

  static String _timeshiftStart(DateTime start, CatchupCapability capability) =>
      formatCatchupTime(start, capability);

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final map = _tvgIdMap(channels);
    if (map.isEmpty) return const [];
    final bytes = await _download(_xmltvUri, kEpgWorkload);
    return parseXmltv(bytes, map);
  }

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) {
    final map = _tvgIdMap(channels);
    if (map.isEmpty) return null;
    return _streamEpg(map, token);
  }

  Map<String, String> _tvgIdMap(List<Channel> channels) {
    final map = <String, String>{};
    for (final c in channels) {
      final tvg = c.extra['tvgId']?.toString();
      if (tvg != null && tvg.isNotEmpty) map[tvg] = c.id;
    }
    return map;
  }

  Uri get _xmltvUri =>
      Uri.parse('$_base/xmltv.php?username=$username&password=$password');

  Stream<List<Programme>> _streamEpg(
    Map<String, String> map,
    LoadToken? token,
  ) async* {
    final bytes = await _download(_xmltvUri, kEpgWorkload);
    yield* parseXmltvBatched(bytes, map, token: token);
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async {
    final action = switch (kind) {
      ContentKind.movie => 'get_vod_categories',
      ContentKind.series => 'get_series_categories',
      _ => null,
    };
    if (action == null) return const [];
    final r = await _api({'action': action});
    return _listFromAny(r)
        .map((c) {
          final m = Map<String, dynamic>.from(c);
          return MediaCategory(
            id: _firstString(m, ['category_id', 'id']) ?? '',
            title: _firstString(m, ['category_name', 'name', 'title']) ?? '',
            kind: kind,
          );
        })
        .where((c) => c.id.isNotEmpty && c.title.isNotEmpty)
        .toList();
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    if (kind == ContentKind.season && parent != null) {
      return _seriesSeasons(parent);
    }
    if (kind == ContentKind.episode && parent != null) {
      return _seasonEpisodes(parent);
    }
    final pagesToLoad = maxPages ?? 1;
    final out = <MediaItem>[];
    for (var page = 1; page <= pagesToLoad; page++) {
      final fetched = await mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
      out.addAll(fetched.items);
      if (!fetched.hasMore) break;
    }
    return out;
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (kind == ContentKind.season && parent != null) {
      return MediaPage(
        items: await _seriesSeasons(parent),
        page: page,
        totalPages: page,
      );
    }
    if (kind == ContentKind.episode && parent != null) {
      return MediaPage(
        items: _seasonEpisodes(parent),
        page: page,
        totalPages: page,
      );
    }
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return MediaPage(items: const [], page: page, totalPages: page);
    }
    if (categoryId == null) {
      return _aggregateMediaPage(kind, page: page);
    }
    final items = await _fetchMediaList(kind, categoryId: categoryId);
    return _sliceMediaPage(items, page: page);
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return const [];
    }
    if (categoryId != null) {
      return (await _fetchMediaList(kind, categoryId: categoryId))
          .where((item) => item.title.toLowerCase().contains(q))
          .take(_searchResultLimit)
          .toList();
    }
    final results = <MediaItem>[];
    final seen = <String>{};
    final categories = await mediaCategories(kind);
    if (categories.isEmpty) {
      final items = await _fetchMediaList(kind);
      return items
          .where((item) => item.title.toLowerCase().contains(q))
          .take(_searchResultLimit)
          .toList();
    }
    for (final category in categories) {
      final items = await _fetchMediaList(kind, categoryId: category.id);
      for (final item in items) {
        if (!item.title.toLowerCase().contains(q)) continue;
        if (item.id.isNotEmpty && !seen.add(item.id)) continue;
        results.add(item);
        if (results.length >= _searchResultLimit) return results;
      }
    }
    return results;
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    final action = switch (item.kind) {
      ContentKind.movie => 'get_vod_info',
      ContentKind.series => 'get_series_info',
      _ => null,
    };
    if (action == null) return item;
    final idParam = item.kind == ContentKind.movie ? 'vod_id' : 'series_id';
    final r = await _api({'action': action, idParam: item.id});
    final details = r is Map ? Map<String, dynamic>.from(r) : const {};
    final info = details['info'] is Map
        ? Map<String, dynamic>.from(details['info'] as Map)
        : details;
    return item.copyWith(
      poster:
          _firstString(info, ['movie_image', 'cover', 'cover_big']) ??
          item.poster,
      description:
          _firstString(info, ['description', 'plot']) ?? item.description,
      year:
          _firstString(info, ['releasedate', 'release_date', 'year']) ??
          item.year,
      extra: {...item.extra, 'details': details},
    );
  }

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (item.kind != ContentKind.movie && item.kind != ContentKind.episode) {
      throw UnsupportedError('${item.kind.name} is not directly playable yet');
    }
    final ext = item.extra['container_extension']?.toString();
    final extension = ext == null || ext.isEmpty ? 'mp4' : ext;
    final path = item.kind == ContentKind.movie ? 'movie' : 'series';
    return StreamInfo(
      url: '$_base/$path/$username/$password/${item.id}.$extension',
      headers: {HttpHeaders.userAgentHeader: 'VLC/3.0.20 LibVLC/3.0.20'},
      isLive: false,
    );
  }

  @override
  Future<DateTime?> subscriptionExpiry() async {
    final info = await _api({});
    final user = info is Map ? info['user_info'] : null;
    if (user is Map) {
      final parsed = parseExpiryValue(user['exp_date']);
      if (parsed != null) return parsed;
    }
    return parseExpiryValue(playlistExpiryHint);
  }

  @override
  Future<void> dispose() async => _http.close(force: true);

  // ── http ──────────────────────────────────────────────────────────────

  Future<dynamic> _api(Map<String, String> params) async {
    final override = debugApi;
    if (override != null) return override(params);
    final uri = Uri.parse('$_base/player_api.php').replace(
      queryParameters: {'username': username, 'password': password, ...params},
    );
    final bytes = await _download(uri, kProviderJsonWorkload);
    return _decodeJson(bytes);
  }

  /// Catalog responses (`get_vod_streams`/`get_live_streams`) can be many MB;
  /// decoding them on the UI thread stalls the frame. Offload big payloads to a
  /// background isolate, but decode small ones inline — isolate spawn overhead
  /// would dominate for the many tiny auth/category calls.
  static const _isolateJsonThreshold = 256 * 1024;

  Future<dynamic> _decodeJson(Uint8List bytes) {
    if (bytes.length < _isolateJsonThreshold) {
      return Future.value(_decodeJsonBytes(bytes));
    }
    return compute(_decodeJsonBytes, bytes);
  }

  /// Fetches a catalog endpoint (`get_live_streams`/`get_vod_streams`/
  /// `get_series`) and hands back either the already-decoded value from
  /// [debugApi] (tests bypass HTTP entirely) or the raw response bytes for a
  /// real panel call. Real bytes let the caller route through the one-pass
  /// typed worker below instead of decoding into a dynamic tree first.
  Future<Object?> _fetchCatalogRaw(Map<String, String> params) async {
    final override = debugApi;
    if (override != null) return override(params);
    final uri = Uri.parse('$_base/player_api.php').replace(
      queryParameters: {'username': username, 'password': password, ...params},
    );
    return _download(uri, kProviderJsonWorkload);
  }

  /// Bounded one-pass ingestion for `get_live_streams`: [raw] is either the
  /// decoded [debugApi] value (mapped inline — it's already small, synthetic
  /// test data) or real response bytes, which get the same threshold-gated
  /// isolate/inline routing as [_decodeJson].
  Future<List<Channel>> _channelsFromRaw(Object? raw) => raw is Uint8List
      ? _decodeLiveChannels(raw)
      : Future.value(mapLiveChannels(raw));

  Future<List<Channel>> _decodeLiveChannels(Uint8List bytes) {
    if (bytes.length < _isolateJsonThreshold) {
      return Future.value(decodeLiveChannelsBytes(bytes));
    }
    return compute(decodeLiveChannelsBytes, bytes);
  }

  /// Bounded one-pass ingestion for `get_vod_streams`/`get_series`. See
  /// [_channelsFromRaw] for the debugApi-vs-real-bytes split.
  Future<List<MediaItem>> _mediaItemsFromRaw(Object? raw, ContentKind kind) =>
      raw is Uint8List
      ? _decodeMediaItems(raw, kind)
      : Future.value(mapMediaItemsFromDecoded(raw, kind));

  Future<List<MediaItem>> _decodeMediaItems(Uint8List bytes, ContentKind kind) {
    final args = XtreamMediaDecodeArgs(bytes, kind);
    if (bytes.length < _isolateJsonThreshold) {
      return Future.value(decodeMediaItemsBytes(args));
    }
    return compute(decodeMediaItemsBytes, args);
  }

  Future<Uint8List> _download(Uri uri, HttpWorkloadPolicy policy) async {
    final operation = HttpOperation(policy);
    final req = await operation.wait(_http.getUrl(uri));
    final resp = await operation.wait(req.close());
    if (resp.statusCode != 200) {
      // redactUrl strips the username/password query params from the panel URL.
      throw StateError('HTTP ${resp.statusCode} from ${redactUrl(uri)}');
    }
    return operation.readBytes(resp);
  }

  Future<MediaPage> _aggregateMediaPage(
    ContentKind kind, {
    required int page,
  }) async {
    final categories = await mediaCategories(kind);
    if (categories.isEmpty) {
      final items = await _fetchMediaList(kind);
      return _sliceMediaPage(items, page: page);
    }

    final start = (page - 1) * _mediaPageSize;
    var skipped = 0;
    final pageItems = <MediaItem>[];
    final seen = <String>{};

    for (final category in categories) {
      final items = await _fetchMediaList(kind, categoryId: category.id);
      if (skipped + items.length <= start) {
        skipped += items.length;
        continue;
      }

      final startInCategory = math.max(0, start - skipped);
      for (var i = startInCategory; i < items.length; i++) {
        final item = items[i];
        if (item.id.isNotEmpty && !seen.add(item.id)) continue;
        pageItems.add(item);
        if (pageItems.length >= _mediaPageSize) {
          return MediaPage(items: pageItems, page: page, totalPages: page + 1);
        }
      }
      skipped += items.length;
    }

    return MediaPage(items: pageItems, page: page, totalPages: page);
  }

  MediaPage _sliceMediaPage(List<MediaItem> items, {required int page}) {
    final totalPages = items.isEmpty
        ? page
        : (items.length / _mediaPageSize).ceil();
    final start = (page - 1) * _mediaPageSize;
    if (start >= items.length) {
      return MediaPage(items: const [], page: page, totalPages: page);
    }
    final end = math.min(start + _mediaPageSize, items.length);
    return MediaPage(
      items: items.sublist(start, end),
      page: page,
      totalPages: totalPages < page ? page : totalPages,
    );
  }

  Future<List<MediaItem>> _fetchMediaList(
    ContentKind kind, {
    String? categoryId,
  }) {
    final key = '${kind.name}:${categoryId ?? ''}';
    return _mediaListCache.putIfAbsent(key, () async {
      final action = switch (kind) {
        ContentKind.movie => 'get_vod_streams',
        ContentKind.series => 'get_series',
        _ => null,
      };
      if (action == null) return const <MediaItem>[];
      final params = {'action': action};
      if (categoryId != null) params['category_id'] = categoryId;
      final raw = await _fetchCatalogRaw(params);
      return _mediaItemsFromRaw(raw, kind);
    });
  }

  Future<List<MediaItem>> _seriesSeasons(MediaItem series) async {
    final details = await _seriesDetails(series);
    final episodes = details['episodes'];
    if (episodes is! Map) return const [];
    final infoSeasons = details['seasons'] is List
        ? (details['seasons'] as List).whereType<Map>().toList()
        : const <Map>[];
    return episodes.keys.map((key) {
      final seasonNumber = int.tryParse(key.toString());
      final info = infoSeasons
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => '${e['season_number'] ?? e['season']}' == '$key')
          .cast<Map<String, dynamic>?>()
          .firstWhere((e) => e != null, orElse: () => null);
      final title =
          _firstString(info ?? const {}, ['name', 'title']) ??
          'Season ${seasonNumber ?? key}';
      return MediaItem(
        id: '${series.id}:season:$key',
        title: title,
        kind: ContentKind.season,
        parentId: series.id,
        poster:
            _firstString(info ?? const {}, ['cover', 'cover_big']) ??
            series.poster,
        seasonNumber: seasonNumber,
        extra: {
          'seriesId': series.id,
          'seasonId': '$key',
          'episodes': episodes[key],
          'details': details,
        },
      );
    }).toList();
  }

  List<MediaItem> _seasonEpisodes(MediaItem season) {
    final raw = season.extra['episodes'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((entry) {
      final m = Map<String, dynamic>.from(entry);
      final id = _firstString(m, ['id', 'episode_id', 'stream_id']) ?? '';
      return MediaItem(
        id: id,
        title: _firstString(m, ['title', 'name']) ?? 'Episode',
        kind: ContentKind.episode,
        parentId: season.id,
        poster:
            _firstString(m, ['movie_image', 'cover', 'cover_big']) ??
            season.poster,
        description: _firstString(m, ['plot', 'description']),
        year: _firstString(m, ['releasedate', 'release_date', 'year']),
        durationSeconds: _parseDurationSeconds(
          _firstString(m, ['duration', 'time', 'length']),
        ),
        seasonNumber: season.seasonNumber,
        episodeNumber: _parseInt(m['episode_num'] ?? m['episode_number']),
        extra: m,
      );
    }).toList();
  }

  Future<Map<String, dynamic>> _seriesDetails(MediaItem series) async {
    final existing = series.extra['details'];
    if (existing is Map) return Map<String, dynamic>.from(existing);
    final r = await _api({'action': 'get_series_info', 'series_id': series.id});
    return r is Map ? Map<String, dynamic>.from(r) : const {};
  }

  @visibleForTesting
  MediaItem debugMapMediaItem(Map<String, dynamic> m, ContentKind kind) =>
      _mapMediaItem(m, kind);
}

/// Isolate entrypoint: decode UTF-8 JSON bytes. Top-level + pure so it can run
/// under [compute]. Returns the raw decoded tree (List/Map of primitives),
/// which is sendable back across the isolate port. Used for the small/generic
/// calls (auth, categories, `get_series_info`) that have no typed worker.
dynamic _decodeJsonBytes(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes, allowMalformed: true));

/// Maps a decoded `get_live_streams` response (or a category-partitioned
/// slice of one) straight to typed [Channel]s. Top-level + pure: it's the
/// core of [decodeLiveChannelsBytes] (isolate path) and is also called
/// directly with an already-decoded [debugApi] value (test path, no bytes to
/// decode). Public so fixture-driven tests can exercise it directly.
@visibleForTesting
List<Channel> mapLiveChannels(dynamic decoded) {
  if (decoded is! List) return const [];
  return decoded.whereType<Map>().map((s) {
    final m = Map<String, dynamic>.from(s);
    final streamId = '${m['stream_id']}';
    final epgId = m['epg_channel_id']?.toString();
    return Channel(
      id: streamId,
      name: '${m['name']}',
      number: int.tryParse('${m['num']}'),
      logo:
          (m['stream_icon'] is String &&
              (m['stream_icon'] as String).isNotEmpty)
          ? m['stream_icon'] as String
          : null,
      categoryId: m['category_id']?.toString(),
      archiveDays: _archiveDays(m['tv_archive'], m['tv_archive_duration']),
      extra: {
        'streamId': streamId,
        if (epgId != null && epgId.isNotEmpty) 'tvgId': epgId,
      },
    );
  }).toList();
}

/// Isolate entrypoint: decode + map a `get_live_streams` response in one
/// pass, so the dynamic JSON tree is built and consumed entirely inside the
/// worker isolate — only the typed [Channel] list crosses back to the main
/// isolate. Top-level + pure so it can run under [compute]; public so
/// fixture-driven tests can exercise it directly with raw bytes.
@visibleForTesting
List<Channel> decodeLiveChannelsBytes(Uint8List bytes) =>
    mapLiveChannels(jsonDecode(utf8.decode(bytes, allowMalformed: true)));

/// Maps a decoded VOD/series catalog response (`get_vod_streams`/
/// `get_series`) to typed [MediaItem]s. Shared by the already-decoded
/// [debugApi] path and [decodeMediaItemsBytes] (isolate) path.
@visibleForTesting
List<MediaItem> mapMediaItemsFromDecoded(dynamic decoded, ContentKind kind) =>
    _listFromAny(decoded)
        .map((e) => _mapMediaItem(e, kind))
        .where((item) => item.id.isNotEmpty)
        .toList();

/// Bundles the isolate arguments for [decodeMediaItemsBytes] — [compute]
/// only passes a single message, and mapping needs both the raw bytes and
/// which [ContentKind] they represent.
@visibleForTesting
class XtreamMediaDecodeArgs {
  final Uint8List bytes;
  final ContentKind kind;
  const XtreamMediaDecodeArgs(this.bytes, this.kind);
}

/// Isolate entrypoint: decode + map a VOD/series catalog response in one
/// pass — the dynamic JSON tree never leaves the worker isolate. Top-level +
/// pure so it can run under [compute]; public so fixture-driven tests can
/// exercise it directly with raw bytes.
@visibleForTesting
List<MediaItem> decodeMediaItemsBytes(XtreamMediaDecodeArgs args) =>
    mapMediaItemsFromDecoded(
      jsonDecode(utf8.decode(args.bytes, allowMalformed: true)),
      args.kind,
    );

MediaItem _mapMediaItem(Map<String, dynamic> m, ContentKind kind) {
  final id = kind == ContentKind.movie
      ? _firstString(m, ['stream_id', 'id', 'movie_id', 'vod_id'])
      : _firstString(m, ['series_id', 'id', 'stream_id']);
  return MediaItem(
    id: id ?? '',
    title: _firstString(m, ['name', 'title']) ?? 'Untitled',
    kind: kind,
    categoryId: m['category_id']?.toString(),
    poster: _firstString(m, ['stream_icon', 'cover', 'cover_big']),
    backdrop: _firstString(m, ['backdrop_path', 'backdrop', 'cover_big']),
    description: _firstString(m, ['plot', 'description']),
    year: _firstString(m, ['year', 'releaseDate', 'release_date']),
    rating: _parseDouble(_firstString(m, ['rating', 'rating_5based'])),
    providerId: _firstString(m, ['tmdb_id', 'imdb_id']),
    extra: m,
  );
}

List<Map<String, dynamic>> _listFromAny(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }
  if (value is Map) {
    for (final key in const [
      'data',
      'items',
      'results',
      'series',
      'movies',
      'available_channels',
      'categories',
    ]) {
      final nested = value[key];
      final rows = _listFromAny(nested);
      if (rows.isNotEmpty) return rows;
    }
  }
  return const [];
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  if (value == null) return null;
  return int.tryParse(value.toString());
}

/// Catch-up window in days from a live-stream's `tv_archive` (0/1) and
/// `tv_archive_duration` (days). Archive off → 0; on but duration
/// missing/zero → [kDefaultArchiveDays].
int _archiveDays(dynamic archive, dynamic duration) {
  final on = archive == 1 || archive == '1' || archive == true;
  if (!on) return 0;
  final days = _parseInt(duration) ?? 0;
  return days > 0 ? days : kDefaultArchiveDays;
}

double? _parseDouble(String? value) {
  if (value == null) return null;
  return double.tryParse(value.replaceAll(',', '.'));
}

int? _parseDurationSeconds(String? value) {
  if (value == null || value.isEmpty) return null;
  final direct = int.tryParse(value);
  if (direct != null) return direct;
  final parts = value.split(':').map(int.tryParse).toList();
  if (parts.any((part) => part == null)) return null;
  if (parts.length == 3) return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
  if (parts.length == 2) return parts[0]! * 60 + parts[1]!;
  return null;
}

String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty && text != 'null') return text;
  }
  return null;
}

/// Credentials extracted from a URL that points at an Xtream Codes panel
/// (typically a `get.php` playlist link). [host] is `scheme://host[:port]`.
class XtreamCredentials {
  final String host;
  final String username;
  final String password;
  const XtreamCredentials({
    required this.host,
    required this.username,
    required this.password,
  });
}

/// Pulls Xtream credentials out of [uri] when it looks like a panel link —
/// either `http://user:pass@host/...` or `?username=…&password=…`. Returns
/// null when host/username/password aren't all present.
XtreamCredentials? xtreamCredentialsFromUrl(Uri uri) {
  String? username;
  String? password;
  if (uri.userInfo.isNotEmpty) {
    final parts = uri.userInfo.split(':');
    if (parts.length >= 2) {
      username = parts[0];
      password = parts.sublist(1).join(':');
    }
  }
  username ??= uri.queryParameters['username'];
  password ??= uri.queryParameters['password'];
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    return null;
  }
  if (uri.host.isEmpty) return null;
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
  final host = '$scheme://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  return XtreamCredentials(host: host, username: username, password: password);
}
