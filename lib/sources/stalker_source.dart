import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../data/diagnostics_log.dart';
import '../data/net.dart';
import 'expiry.dart';
import 'source.dart';

/// A MAG set-top-box profile emulated to the portal.
class MagProfile {
  final String model;
  final String userAgent;
  const MagProfile({required this.model, required this.userAgent});

  /// Widely accepted default.
  static const mag250 = MagProfile(
    model: 'MAG250',
    userAgent:
        'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 '
        '(KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3',
  );
}

class StalkerException implements Exception {
  final String message;
  StalkerException(this.message);
  @override
  String toString() => 'StalkerException: $message';
}

String redactStalkerDiagnostic(String value) {
  var out = value;
  out = out.replaceAll(
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer <redacted>',
  );
  out = out.replaceAll(
    RegExp(r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}', caseSensitive: false),
    '<mac>',
  );
  out = out.replaceAllMapped(
    RegExp(r'(username|password|token|mac)=([^&;\s]+)', caseSensitive: false),
    (m) => '${m[1]}=<redacted>',
  );
  return out;
}

/// Deterministic MAG identity values derived from the subscriber MAC.
class MagIdentity {
  final String mac;
  final String serial;
  final String deviceId;
  final String deviceId2;
  final String signature;
  final String hwVersion2;

  const MagIdentity({
    required this.mac,
    required this.serial,
    required this.deviceId,
    required this.deviceId2,
    required this.signature,
    required this.hwVersion2,
  });

  factory MagIdentity.fromMac(String mac) {
    final normalizedMac = mac.trim().toUpperCase();
    final serial = _digest(md5, normalizedMac).substring(0, 13);
    final deviceId = _digest(sha256, normalizedMac);
    final deviceId2 = deviceId;
    final signature = _digest(
      sha256,
      '$normalizedMac$serial$deviceId$deviceId2',
    );
    return MagIdentity(
      mac: normalizedMac,
      serial: serial,
      deviceId: deviceId,
      deviceId2: deviceId2,
      signature: signature,
      hwVersion2: _digest(sha1, normalizedMac),
    );
  }

  Map<String, String> profileParams({
    required MagProfile profile,
    required int timestamp,
  }) {
    final random = timestamp.toString();
    final metrics = jsonEncode({
      'mac': mac,
      'sn': serial,
      'type': 'STB',
      'model': profile.model,
      'uid': '',
      'random': random,
    });

    return {
      'stb_type': profile.model,
      'sn': serial,
      'device_id': deviceId,
      'device_id2': deviceId2,
      'signature': signature,
      'hw_version_2': hwVersion2,
      'client_type': 'STB',
      'metrics': metrics,
      'auth_second_step': '1',
      'not_valid_token': '0',
    };
  }

  static String _digest(Hash hash, String input) =>
      hash.convert(utf8.encode(input)).toString().toUpperCase();
}

String? stalkerItemIdentity(Map<String, dynamic> item) {
  for (final key in ['id', 'movie_id', 'video_id', 'channel_id', 'ch_id']) {
    final value = item[key];
    if (value == null) continue;
    final text = value.toString();
    if (text.isNotEmpty && text != 'null') return '$key:$text';
  }
  return null;
}

class _OrderedListPage {
  final List<Map<String, dynamic>> rows;
  final int totalPages;

  const _OrderedListPage({required this.rows, required this.totalPages});
}

/// A [Source] backed by a Stalker / Ministra portal (panel URL + MAC).
///
/// Point this at a portal you're entitled to. Field mappings follow the
/// standard Stalker schema; if a particular panel names a field differently,
/// adjust [_mapChannel].
class StalkerSource implements Source {
  final String portal; // e.g. http://host:port/c/
  final String mac;
  final MagProfile profile;
  final String lang;
  final String timezone;
  final bool diagnostics;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  String? _endpoint;
  String? _referer;
  String? _token;
  List<Channel>? _channelCache;
  final Map<String, String> _vodCategoryTitles = {};
  Future<void>? _connectFuture;
  bool _profileLoaded = false;

  StalkerSource({
    required this.portal,
    required this.mac,
    this.profile = MagProfile.mag250,
    this.lang = 'en',
    this.timezone = 'Europe/Bucharest',
    this.diagnostics = true,
    this.displayName,
  });

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  @override
  String get id => 'stalker:$portal|$mac';

  @override
  String get name =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : 'Stalker · $mac';

  @override
  Future<void> connect() async {
    if (_profileLoaded) return;
    final pending = _connectFuture;
    if (pending != null) return pending;
    final future = _connect();
    _connectFuture = future;
    try {
      await future;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connect() async {
    await _resolveEndpoint(); // handshake happens here and sets _token
    await _getProfile();
    _profileLoaded = true;
  }

  @override
  Future<List<Category>> categories() async {
    final r = await _call({'type': 'itv', 'action': 'get_genres'});
    final js = r['js'];
    if (js is! List) return const [];
    return js
        .map((e) => Map<String, dynamic>.from(e))
        .map((g) => Category(id: '${g['id']}', title: '${g['title']}'))
        .toList();
  }

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    _channelCache ??= await _fetchAllChannels();
    if (categoryId == null) return _channelCache!;
    return _channelCache!.where((c) => c.categoryId == categoryId).toList();
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final cmd = _liveCommand(channel);
    if (cmd == null || cmd.isEmpty) {
      throw StalkerException('Channel "${channel.name}" has no cmd to resolve');
    }
    _debug(
      'resolve live id=${channel.id} name=${channel.name} cmd=${_commandShape(cmd)}',
    );
    final r = await _call({
      'type': 'itv',
      'action': 'create_link',
      'cmd': cmd,
      'forced_storage': '0',
      'disable_ad': '0',
    });
    final js = r['js'];
    final raw = js is Map ? _firstString(js, ['url', 'cmd']) : null;
    if (raw == null) throw StalkerException('create_link returned no URL');
    final url = _normalizeLiveStreamUrl(raw, channel);
    _debug('resolved live id=${channel.id} url=${_redactUrl(url)}');
    return StreamInfo(url: url, headers: _playbackHeaders());
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    // Stalker catch-up: resolve the live URL, then append the portable archive
    // params most portals honor (`utc` = programme start, `lutc` = now, both
    // unix seconds). Resolve at play time — the archive URL is as short-lived as
    // the live one it's built from.
    final live = await resolve(channel);
    final url = archiveUrl(live.url, programme.start, DateTime.now());
    _debug('resolved archive id=${channel.id} url=${_redactUrl(url)}');
    return StreamInfo(url: url, headers: live.headers, isLive: false);
  }

  /// Append Stalker catch-up params to a resolved live [liveUrl]: `utc` =
  /// [start] and `lutc` = [now], both unix seconds. Pure so it's unit-testable
  /// without the network create_link.
  @visibleForTesting
  static String archiveUrl(String liveUrl, DateTime start, DateTime now) {
    final utc = start.toUtc().millisecondsSinceEpoch ~/ 1000;
    final lutc = now.toUtc().millisecondsSinceEpoch ~/ 1000;
    final sep = liveUrl.contains('?') ? '&' : '?';
    return '$liveUrl${sep}utc=$utc&lutc=$lutc';
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    // Stalker keys EPG by channel id directly, so `channels` isn't needed.
    // Bulk EPG for all channels for the next few hours, keyed by channel id.
    final r = await _call({
      'type': 'itv',
      'action': 'get_epg_info',
      'period': '6',
    });
    final js = r['js'];
    final data = (js is Map && js['data'] is Map)
        ? js['data'] as Map
        : (js is Map ? js : null);
    if (data == null) return const [];

    final out = <Programme>[];
    data.forEach((chId, list) {
      if (list is! List) return;
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final start = _epochToDate(m['start_timestamp']);
        final stop = _epochToDate(m['stop_timestamp']);
        if (start == null || stop == null) continue;
        out.add(
          Programme(
            channelId: '$chId',
            start: start,
            stop: stop,
            title: '${m['name'] ?? ''}',
            description: m['descr']?.toString(),
          ),
        );
      }
    });
    return out;
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async {
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return const [];
    }
    if (kind == ContentKind.series) {
      final seriesCategories = await _mediaCategoriesForType('series', kind);
      if (seriesCategories.isNotEmpty) return seriesCategories;
    }
    return _mediaCategoriesForType('vod', kind);
  }

  Future<List<MediaCategory>> _mediaCategoriesForType(
    String type,
    ContentKind kind,
  ) async {
    final Map<String, dynamic> r;
    try {
      r = await _call({'type': type, 'action': 'get_categories'});
    } on StalkerException catch (e) {
      if (type != 'vod') {
        _debug('$type:get_categories unavailable: ${e.message}');
        return const [];
      }
      rethrow;
    }
    final js = r['js'];
    if (js is! List) return const [];
    return js
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map((c) {
          final category = MediaCategory(
            id: '${c['id']}',
            title: '${c['title'] ?? c['name'] ?? ''}',
            kind: kind,
          );
          if (category.id.isNotEmpty && category.title.isNotEmpty) {
            _vodCategoryTitles['$type:${category.id}'] = category.title;
            _vodCategoryTitles[category.id] = category.title;
          }
          return category;
        })
        .where((c) => c.title.isNotEmpty)
        .toList();
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    if (!_supportsVodListKind(kind)) {
      return const [];
    }
    if (kind == ContentKind.episode && parent != null) {
      final embedded = _episodesFromEmbeddedSeason(parent);
      if (embedded.isNotEmpty) return embedded;
    }
    final type = _stalkerListType(kind, parent);
    final List<Map<String, dynamic>> rows;
    try {
      rows = await _getOrderedList(
        type: type,
        category: categoryId,
        movieId: _parentMovieId(kind, parent),
        seasonId: _parentSeasonId(kind, parent),
        maxPages: maxPages,
      );
    } on StalkerException catch (e) {
      if (type == 'vod') rethrow;
      _debug('$type:get_ordered_list unavailable: ${e.message}');
      return _vodMediaItems(
        kind,
        categoryId: categoryId,
        parent: parent,
        maxPages: maxPages,
      );
    }
    final filtered = _filterMediaRows(
      rows,
      kind,
      type: type,
      categoryId: categoryId,
    );
    if (filtered.isEmpty && kind == ContentKind.series && type != 'vod') {
      return _vodMediaItems(
        kind,
        categoryId: categoryId,
        parent: parent,
        maxPages: maxPages,
      );
    }
    return filtered
        .map(
          (m) => _mapMediaItem(
            m,
            kind: kind,
            categoryId: categoryId,
            parent: parent,
            stalkerType: type,
          ),
        )
        .toList();
  }

  Future<List<MediaItem>> _vodMediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    final rows = await _getOrderedList(
      type: 'vod',
      category: categoryId,
      movieId: _parentMovieId(kind, parent),
      seasonId: _parentSeasonId(kind, parent),
      maxPages: maxPages,
    );
    return _filterMediaRows(rows, kind, type: 'vod', categoryId: categoryId)
        .map(
          (m) => _mapMediaItem(
            m,
            kind: kind,
            categoryId: categoryId,
            parent: parent,
            stalkerType: 'vod',
          ),
        )
        .toList();
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (!_supportsVodListKind(kind)) {
      return MediaPage(items: const [], page: page, totalPages: page);
    }
    if (kind == ContentKind.episode && parent != null) {
      final embedded = _episodesFromEmbeddedSeason(parent);
      if (embedded.isNotEmpty) {
        return MediaPage(items: embedded, page: page, totalPages: page);
      }
    }
    final type = _stalkerListType(kind, parent);
    final _OrderedListPage raw;
    try {
      raw = await _getOrderedListPage(
        type: type,
        category: categoryId,
        movieId: _parentMovieId(kind, parent),
        seasonId: _parentSeasonId(kind, parent),
        page: page,
      );
    } on StalkerException catch (e) {
      if (type == 'vod') rethrow;
      _debug('$type:get_ordered_list unavailable: ${e.message}');
      return _vodMediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
    }
    final filtered = _filterMediaRows(
      raw.rows,
      kind,
      type: type,
      categoryId: categoryId,
    );
    if (filtered.isEmpty && kind == ContentKind.series && type != 'vod') {
      return _vodMediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
    }
    final items = filtered
        .map(
          (m) => _mapMediaItem(
            m,
            kind: kind,
            categoryId: categoryId,
            parent: parent,
            stalkerType: type,
          ),
        )
        .toList();
    if (items.isEmpty && parent != null) {
      final detailsItems = await _mediaItemsFromDetails(kind, parent);
      if (detailsItems.isNotEmpty) {
        return MediaPage(items: detailsItems, page: page, totalPages: page);
      }
    }
    return MediaPage(
      items: items,
      page: page,
      totalPages: raw.totalPages < page ? page : raw.totalPages,
    );
  }

  Future<MediaPage> _vodMediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    final raw = await _getOrderedListPage(
      type: 'vod',
      category: categoryId,
      movieId: _parentMovieId(kind, parent),
      seasonId: _parentSeasonId(kind, parent),
      page: page,
    );
    final items =
        _filterMediaRows(raw.rows, kind, type: 'vod', categoryId: categoryId)
            .map(
              (m) => _mapMediaItem(
                m,
                kind: kind,
                categoryId: categoryId,
                parent: parent,
                stalkerType: 'vod',
              ),
            )
            .toList();
    return MediaPage(
      items: items,
      page: page,
      totalPages: raw.totalPages < page ? page : raw.totalPages,
    );
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final q = query.trim();
    if (q.isEmpty ||
        (kind != ContentKind.movie && kind != ContentKind.series)) {
      return const [];
    }
    final type = kind == ContentKind.series ? 'series' : 'vod';
    final _OrderedListPage raw;
    try {
      raw = await _getOrderedListPage(
        type: type,
        category: categoryId,
        search: q,
        page: 1,
      );
    } on StalkerException catch (e) {
      if (type == 'vod') rethrow;
      _debug('$type:get_ordered_list search unavailable: ${e.message}');
      final fallback = await _getOrderedListPage(
        type: 'vod',
        category: categoryId,
        search: q,
        page: 1,
      );
      return _filterMediaRows(
            fallback.rows,
            kind,
            type: 'vod',
            categoryId: categoryId,
          )
          .map(
            (m) => _mapMediaItem(
              m,
              kind: kind,
              categoryId: categoryId,
              stalkerType: 'vod',
            ),
          )
          .toList();
    }
    final filtered = _filterMediaRows(
      raw.rows,
      kind,
      type: type,
      categoryId: categoryId,
    );
    final rows = filtered.isNotEmpty || kind != ContentKind.series
        ? (rows: filtered, type: type)
        : (
            rows: _filterMediaRows(
              (await _getOrderedListPage(
                type: 'vod',
                category: categoryId,
                search: q,
                page: 1,
              )).rows,
              kind,
              type: 'vod',
              categoryId: categoryId,
            ),
            type: 'vod',
          );
    return rows.rows
        .map(
          (m) => _mapMediaItem(
            m,
            kind: kind,
            categoryId: categoryId,
            stalkerType: rows.type,
          ),
        )
        .toList();
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    if (item.kind != ContentKind.movie && item.kind != ContentKind.series) {
      return item;
    }
    final movieId = item.extra['movieId']?.toString() ?? item.id;
    final Map<String, dynamic> r;
    try {
      r = await _call({
        'type': 'vod',
        'action': 'get_movie_details',
        'movie_id': movieId,
      });
    } on StalkerException catch (e) {
      _debug(
        'get_movie_details unavailable for id=$movieId; using list metadata: ${e.message}',
      );
      return item;
    }
    final js = r['js'];
    final details = js is Map ? Map<String, dynamic>.from(js) : const {};
    return item.copyWith(
      poster:
          _firstString(details, ['screenshot_uri', 'poster', 'cover']) ??
          item.poster,
      description:
          _firstString(details, ['description', 'descr', 'plot']) ??
          item.description,
      year: _firstString(details, ['year', 'released']) ?? item.year,
      extra: {...item.extra, 'details': details},
    );
  }

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (item.kind != ContentKind.movie && item.kind != ContentKind.episode) {
      throw StalkerException('${item.kind.name} is not directly playable yet');
    }
    final params = {
      'type': 'vod',
      'action': 'create_link',
      'cmd': _vodCommand(item),
      'forced_storage': '0',
      'disable_ad': '0',
      ..._seriesCreateLinkParams(item),
    };
    var r = await _call(params);
    var js = r['js'];
    var raw = js is Map ? _firstString(js, ['url', 'cmd']) : null;
    if (raw != null && _hasPlaceholderStreamQuery(raw)) {
      final fallback = _alternateSeriesEpisodeCommand(item);
      if (fallback != null && fallback != params['cmd']) {
        _debug(
          'series create_link returned placeholder stream; retrying with alternate episode cmd',
        );
        r = await _call({...params, 'cmd': fallback});
        js = r['js'];
        raw = js is Map ? _firstString(js, ['url', 'cmd']) : null;
      }
    }
    if (raw == null) throw StalkerException('VOD create_link returned no URL');
    if (_hasPlaceholderStreamQuery(raw)) {
      throw StalkerException('VOD create_link returned placeholder stream');
    }
    return StreamInfo(
      url: _stripStreamPrefix(raw),
      headers: _playbackHeaders(),
      isLive: false,
      subtitles: js is Map
          ? _parsePlaybackSubtitles(js['subtitles'])
          : const [],
    );
  }

  DateTime? _epochToDate(dynamic v) {
    final secs = v is int ? v : int.tryParse('$v');
    if (secs == null || secs == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  }

  @override
  Future<DateTime?> subscriptionExpiry() async {
    final r = await _call({'type': 'account_info', 'action': 'get_main_info'});
    final js = r['js'];
    if (js is! Map) return null;
    for (final key in const [
      'end_date',
      'expire_billing_date',
      'subscription_expire',
      'exp_date',
    ]) {
      final parsed = parseExpiryValue(js[key]);
      if (parsed != null) return parsed;
    }
    final tariff = js['tariff'];
    if (tariff is Map) {
      final parsed = parseExpiryValue(tariff['expire_date']);
      if (parsed != null) return parsed;
    }
    return null;
  }

  @override
  Future<void> dispose() async => _http.close(force: true);

  // ── data mapping ───────────────────────────────────────────────────────────

  Future<List<Channel>> _fetchAllChannels() async {
    try {
      final r = await _call({'type': 'itv', 'action': 'get_all_channels'});
      final js = r['js'];
      final list = (js is Map && js['data'] is List)
          ? js['data'] as List
          : (js is List ? js : const []);
      // get_all_channels returns the whole portal in one payload (tens of
      // thousands of rows on big portals) — build the Channel objects off the
      // UI isolate. _mapChannel and its helpers are static/pure, so the
      // closure captures only the decoded JSON list.
      final channels = list.length < 500
          ? list.map((e) => _mapChannel(Map<String, dynamic>.from(e))).toList()
          : await Isolate.run(
              () => list
                  .map((e) => _mapChannel(Map<String, dynamic>.from(e)))
                  .toList(),
            );
      if (channels.isNotEmpty) return channels;
    } on StalkerException catch (e) {
      // Some portals only expose ITV through paginated get_ordered_list.
      _debug(
        'get_all_channels failed; falling back to ordered list: ${e.message}',
      );
    }
    return _fetchChannelsWithOrderedList();
  }

  Future<List<Channel>> _fetchChannelsWithOrderedList() async {
    final genres = await categories();
    final seen = <String>{};
    final out = <Channel>[];
    for (final genre in genres) {
      final rows = await _getOrderedList(type: 'itv', genre: genre.id);
      for (final row in rows) {
        row.putIfAbsent('tv_genre_id', () => genre.id);
        final channel = _mapChannel(row);
        if (seen.add(channel.id)) out.add(channel);
      }
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _getOrderedList({
    required String type,
    String? genre,
    String? category,
    String? movieId,
    String? seasonId,
    String? episodeId,
    String? search,
    int? maxPages,
  }) async {
    final first = await _getOrderedListPage(
      type: type,
      genre: genre,
      category: category,
      movieId: movieId,
      seasonId: seasonId,
      episodeId: episodeId,
      search: search,
      page: 1,
    );
    final totalPages = maxPages == null
        ? first.totalPages
        : first.totalPages.clamp(1, maxPages).toInt();
    final rows = <Map<String, dynamic>>[...first.rows];
    for (var page = 2; page <= totalPages; page++) {
      final next = await _getOrderedListPage(
        type: type,
        genre: genre,
        category: category,
        movieId: movieId,
        seasonId: seasonId,
        episodeId: episodeId,
        search: search,
        page: page,
      );
      rows.addAll(next.rows);
    }
    return _dedupeStalkerRows(rows);
  }

  Future<_OrderedListPage> _getOrderedListPage({
    required String type,
    required int page,
    String? genre,
    String? category,
    String? movieId,
    String? seasonId,
    String? episodeId,
    String? search,
  }) async {
    final params = <String, String>{
      'type': type,
      'action': 'get_ordered_list',
      'p': '$page',
    };
    void add(String key, String? value) {
      if (value != null && value.isNotEmpty) params[key] = value;
    }

    add('genre', genre);
    add('category', category);
    add('movie_id', movieId);
    if (type == 'series') {
      add('series_id', movieId);
      add('parent_id', movieId);
    }
    add('season_id', seasonId);
    add('episode_id', episodeId);
    add('search', search);
    add('query', search);
    add('search_string', search);

    final r = await _call(params);
    final js = r['js'];
    final rows = _extractListData(js);
    final totalItems = _parseInt(js is Map ? js['total_items'] : null);
    final maxPageItems = _parseInt(js is Map ? js['max_page_items'] : null);
    return _OrderedListPage(
      rows: rows,
      totalPages: _inferTotalPages(
        totalItems: totalItems,
        itemsOnPage: rows.length,
        maxPageItems: maxPageItems,
      ),
    );
  }

  List<Map<String, dynamic>> _extractListData(dynamic js) {
    final list = (js is Map && js['data'] is List)
        ? js['data'] as List
        : (js is List ? js : const []);
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> _dedupeStalkerRows(
    List<Map<String, dynamic>> rows,
  ) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      final key = stalkerItemIdentity(row);
      if (key != null && !seen.add(key)) continue;
      out.add(row);
    }
    return out;
  }

  int _inferTotalPages({
    required int? totalItems,
    required int itemsOnPage,
    required int? maxPageItems,
  }) {
    if (totalItems == null || totalItems <= 0) return 1;
    final pageSize = (maxPageItems != null && maxPageItems > 0)
        ? maxPageItems
        : itemsOnPage;
    if (pageSize <= 0 || totalItems <= pageSize) return 1;
    return (totalItems / pageSize).ceil();
  }

  int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static Channel _mapChannel(Map<String, dynamic> ch) {
    final id =
        _firstString(ch, ['id', 'ch_id', 'channel_id', 'stream_id']) ??
        '${ch['name']}';
    final cmd = _firstString(ch, ['cmd', 'url']);
    final extra = <String, dynamic>{'streamId': id, 'raw': ch};
    if (cmd != null) extra['cmd'] = cmd;
    return Channel(
      id: id,
      name: _firstString(ch, ['name', 'title']) ?? 'Untitled',
      number: int.tryParse('${ch['number'] ?? ch['num'] ?? ''}'),
      logo: _firstString(ch, ['logo', 'icon', 'stream_icon']),
      categoryId: _firstString(ch, ['tv_genre_id', 'genre_id', 'category_id']),
      archiveDays: _archiveDays(ch),
      extra: extra,
    );
  }

  /// Catch-up window in days from a raw ITV channel row: `tv_archive_duration`
  /// (days) when present, else a flag (`archive`/`allow_archive`) → default.
  static int _archiveDays(Map<String, dynamic> ch) {
    final raw = ch['tv_archive_duration'] ?? ch['archive_duration'];
    final days = raw is int ? raw : (int.tryParse('${raw ?? ''}') ?? 0);
    if (days > 0) return days;
    final on = ch['archive'] == 1 ||
        ch['archive'] == '1' ||
        ch['allow_archive'] == 1 ||
        ch['allow_archive'] == '1';
    return on ? kDefaultArchiveDays : 0;
  }

  MediaItem _mapMediaItem(
    Map<String, dynamic> item, {
    required ContentKind kind,
    String? categoryId,
    MediaItem? parent,
    String stalkerType = 'vod',
  }) {
    final id = _mediaItemId(item, kind: kind, parent: parent);
    final seasonNumber = _seriesSeasonNumber(item);
    return MediaItem(
      id: id,
      title: _firstString(item, ['name', 'title']) ?? 'Untitled',
      kind: kind,
      parentId: parent?.id ?? _firstString(item, ['parent_id', 'series_id']),
      categoryId: categoryId ?? _firstString(item, ['category_id']),
      poster: _firstString(item, ['screenshot_uri', 'poster', 'cover', 'pic']),
      backdrop: _firstString(item, ['backdrop', 'background', 'cover_big']),
      description: _firstString(item, ['description', 'descr', 'plot']),
      year: _firstString(item, ['year', 'released']),
      rating: _parseDouble(
        _firstString(item, ['rating_imdb', 'rating_kinopoisk', 'rating']),
      ),
      durationSeconds: _parseDurationSeconds(
        _firstString(item, ['duration', 'time', 'length']),
      ),
      seasonNumber: seasonNumber,
      episodeNumber: _parseInt(
        item['episode_number'] ?? item['episode'] ?? item['numbering'],
      ),
      providerId: _firstString(item, ['tmdb_id', 'imdb_id', 'kinopoisk_id']),
      extra: {
        ...item,
        'movieId': _mediaItemSeriesId(item, kind: kind, parent: parent) ?? id,
        'stalkerType': stalkerType,
        if (parent != null) 'parentId': parent.id,
        if (kind == ContentKind.season)
          'seasonId': _seriesSeasonKey(item) ?? id,
        if (kind == ContentKind.episode)
          'episodeId': _firstString(item, ['episode_id', 'id']) ?? id,
      },
    );
  }

  String _mediaItemId(
    Map<String, dynamic> item, {
    required ContentKind kind,
    MediaItem? parent,
  }) {
    if (kind == ContentKind.season) {
      final seasonKey = _seriesSeasonKey(item);
      if (parent != null && seasonKey != null) {
        return '${parent.id}:season:$seasonKey';
      }
      return seasonKey ?? _firstStableId(item) ?? '';
    }
    if (kind == ContentKind.episode) {
      return _firstPlayableId(item) ?? _firstStableId(item) ?? '';
    }
    return _normalizeCompositeSeriesId(_firstStableId(item)) ?? '';
  }

  String? _firstStableId(Map<String, dynamic> item) => _firstString(item, [
    'id',
    'movie_id',
    'series_id',
    'video_id',
    'stream_id',
    'season_id',
    'episode_id',
  ]);

  String? _mediaItemSeriesId(
    Map<String, dynamic> item, {
    required ContentKind kind,
    MediaItem? parent,
  }) {
    if (kind == ContentKind.season || kind == ContentKind.episode) {
      final fromParent = _firstString(parent?.extra ?? const {}, [
        'movieId',
        'series_id',
        'id',
      ]);
      return _normalizeCompositeSeriesId(fromParent ?? parent?.id);
    }
    return _normalizeCompositeSeriesId(
      _firstString(item, ['movie_id', 'series_id', 'id']),
    );
  }

  String? _normalizeCompositeSeriesId(String? value) {
    if (value == null) return null;
    var text = value.trim();
    if (text.isEmpty || text == 'null') return null;
    final seasonMarker = text.indexOf(':season:');
    if (seasonMarker > 0) text = text.substring(0, seasonMarker);
    final parts = text.split(':');
    if (parts.length >= 2 &&
        parts.first.isNotEmpty &&
        parts.every((part) => int.tryParse(part) != null)) {
      return parts.first;
    }
    return text;
  }

  Future<List<MediaItem>> _mediaItemsFromDetails(
    ContentKind kind,
    MediaItem parent,
  ) async {
    if (kind != ContentKind.season && kind != ContentKind.episode) {
      return const [];
    }
    final details = await _movieDetails(parent);
    if (details.isEmpty) return const [];
    if (kind == ContentKind.season) return _seasonsFromDetails(parent, details);
    return _episodesFromDetails(parent, details);
  }

  @visibleForTesting
  List<MediaItem> debugSeasonsFromDetails(
    MediaItem series,
    Map<String, dynamic> details,
  ) => _seasonsFromDetails(series, details);

  @visibleForTesting
  List<MediaItem> debugEpisodesFromDetails(
    MediaItem parent,
    Map<String, dynamic> details,
  ) => _episodesFromDetails(parent, details);

  @visibleForTesting
  List<MediaItem> debugEpisodesFromEmbeddedSeason(MediaItem season) =>
      _episodesFromEmbeddedSeason(season);

  @visibleForTesting
  bool debugMatchesVodListKind(
    Map<String, dynamic> item,
    ContentKind kind, {
    String? categoryTitle,
  }) => _matchesVodListKind(item, kind, categoryTitle: categoryTitle);

  @visibleForTesting
  bool debugMatchesSeriesListKind(
    Map<String, dynamic> item,
    ContentKind kind,
  ) => _matchesSeriesListKind(item, kind);

  @visibleForTesting
  MediaItem debugMapMediaItem(
    Map<String, dynamic> item,
    ContentKind kind, {
    MediaItem? parent,
    String stalkerType = 'vod',
  }) =>
      _mapMediaItem(item, kind: kind, parent: parent, stalkerType: stalkerType);

  @visibleForTesting
  String debugVodCommand(MediaItem item) => _vodCommand(item);

  Future<Map<String, dynamic>> _movieDetails(MediaItem item) async {
    final existing = item.extra['details'];
    if (existing is Map) return Map<String, dynamic>.from(existing);
    final movieId = item.extra['movieId']?.toString() ?? item.id;
    try {
      final r = await _call({
        'type': 'vod',
        'action': 'get_movie_details',
        'movie_id': movieId,
      });
      final js = r['js'];
      if (js is Map) return Map<String, dynamic>.from(js);
    } on StalkerException catch (e) {
      _debug(
        'get_movie_details unavailable for id=$movieId; series fallback skipped: ${e.message}',
      );
    }
    return const {};
  }

  List<MediaItem> _seasonsFromDetails(
    MediaItem series,
    Map<String, dynamic> details,
  ) {
    final explicitSeasons = _listFromAny(
      details['seasons'] ?? details['season'],
    );
    final groupedEpisodes = _episodesGroupedBySeason(details);
    final seasonKeys = <String>{
      for (final season in explicitSeasons) ?_seasonKey(season),
      ...groupedEpisodes.keys,
    }.toList()..sort(_compareSeasonKeys);
    return [
      for (final key in seasonKeys)
        _seasonFromDetails(
          series,
          key,
          explicitSeasons
              .where((season) => _seasonKey(season) == key)
              .cast<Map<String, dynamic>?>()
              .firstWhere((season) => season != null, orElse: () => null),
          groupedEpisodes[key] ?? const [],
          details,
        ),
    ];
  }

  MediaItem _seasonFromDetails(
    MediaItem series,
    String seasonKey,
    Map<String, dynamic>? info,
    List<Map<String, dynamic>> episodes,
    Map<String, dynamic> details,
  ) {
    final seasonNumber = int.tryParse(seasonKey);
    return MediaItem(
      id: '${series.id}:season:$seasonKey',
      title:
          _firstString(info ?? const {}, ['name', 'title']) ??
          'Season ${seasonNumber ?? seasonKey}',
      kind: ContentKind.season,
      parentId: series.id,
      poster:
          _firstString(info ?? const {}, [
            'screenshot_uri',
            'poster',
            'cover',
          ]) ??
          series.poster,
      backdrop:
          _firstString(info ?? const {}, ['backdrop', 'background']) ??
          series.backdrop,
      seasonNumber: seasonNumber,
      extra: {
        'movieId': series.extra['movieId']?.toString() ?? series.id,
        'seasonId': seasonKey,
        'episodes': episodes,
        'details': details,
      },
    );
  }

  List<MediaItem> _episodesFromDetails(
    MediaItem parent,
    Map<String, dynamic> details,
  ) {
    final episodes = parent.kind == ContentKind.season
        ? _listFromAny(parent.extra['episodes'])
        : _episodesGroupedBySeason(details).values.expand((e) => e).toList();
    return [
      for (final episode in episodes)
        _episodeFromDetails(parent, episode, details),
    ];
  }

  List<MediaItem> _episodesFromEmbeddedSeason(MediaItem season) {
    if (season.kind != ContentKind.season) return const [];
    final raw =
        season.extra['episodes'] ??
        season.extra['episode'] ??
        season.extra['series'] ??
        season.extra['videos'] ??
        season.extra['files'];
    if (raw == null) return const [];
    final rows = _listFromAny(raw);
    if (rows.isNotEmpty) {
      return [
        for (final row in rows)
          _episodeFromDetails(season, {
            ..._seasonPlaybackHints(season),
            ...row,
          }, const {}),
      ];
    }
    final values = _scalarListFromAny(raw);
    if (values.isEmpty) return const [];
    final seriesId =
        _normalizeCompositeSeriesId(
          _firstString(season.extra, ['movieId', 'series_id', 'id']),
        ) ??
        _normalizeCompositeSeriesId(season.parentId) ??
        season.parentId ??
        season.id;
    final seasonId =
        _normalizeSeasonId(
          _firstString(season.extra, ['seasonId', 'season_id', 'id']),
        ) ??
        season.seasonNumber?.toString() ??
        '1';
    return [
      for (final value in values)
        _episodeFromDetails(season, {
          'id': '$seriesId:$value',
          'episode_id': '$seriesId:$value',
          'episode_number': value,
          'name': 'Episode $value',
          'movie_id': seriesId,
          'season_number': seasonId,
          ..._seasonPlaybackHints(season),
        }, const {}),
    ];
  }

  Map<String, dynamic> _seasonPlaybackHints(MediaItem season) {
    final out = <String, dynamic>{};
    final cmd = season.extra['cmd'];
    if (cmd != null) out['cmd'] = cmd;
    final path = season.extra['path'];
    if (path != null) out['path'] = path;
    return out;
  }

  MediaItem _episodeFromDetails(
    MediaItem parent,
    Map<String, dynamic> episode,
    Map<String, dynamic> details,
  ) {
    final id =
        _firstString(episode, ['id', 'episode_id', 'video_id', 'stream_id']) ??
        '${parent.id}:episode:${_firstString(episode, ['episode', 'number', 'name', 'title']) ?? ''}';
    return MediaItem(
      id: id,
      title: _firstString(episode, ['name', 'title']) ?? 'Episode',
      kind: ContentKind.episode,
      parentId: parent.id,
      poster:
          _firstString(episode, ['screenshot_uri', 'poster', 'cover']) ??
          parent.poster,
      backdrop:
          _firstString(episode, ['backdrop', 'background']) ?? parent.backdrop,
      description: _firstString(episode, ['description', 'descr', 'plot']),
      year: _firstString(episode, ['year', 'released']),
      durationSeconds: _parseDurationSeconds(
        _firstString(episode, ['duration', 'time', 'length']),
      ),
      seasonNumber:
          parent.seasonNumber ??
          _parseInt(episode['season_number'] ?? episode['season']),
      episodeNumber: _parseInt(
        episode['episode_number'] ?? episode['episode'] ?? episode['number'],
      ),
      extra: {
        ...episode,
        'movieId':
            _firstString(episode, ['movie_id', 'series_id']) ??
            parent.extra['movieId']?.toString(),
        'episodeId': id,
        'details': details,
      },
    );
  }

  Map<String, List<Map<String, dynamic>>> _episodesGroupedBySeason(
    Map<String, dynamic> details,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    final raw = details['episodes'] ?? details['episode'] ?? details['series'];
    if (raw is Map) {
      raw.forEach((key, value) {
        final rows = _listFromAny(value);
        if (rows.isNotEmpty) grouped['$key'] = rows;
      });
    } else {
      for (final episode in _listFromAny(raw)) {
        final key = _seasonKey(episode) ?? '1';
        grouped.putIfAbsent(key, () => []).add(episode);
      }
    }
    return grouped;
  }

  List<Map<String, dynamic>> _listFromAny(dynamic value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    if (value is Map && value['data'] is List) {
      return _listFromAny(value['data']);
    }
    return const [];
  }

  List<String> _scalarListFromAny(dynamic value) {
    if (value is List) {
      return [
        for (final entry in value)
          if (entry is! Map && entry != null && entry.toString().isNotEmpty)
            entry.toString(),
      ];
    }
    if (value is Map) {
      if (value['data'] is List) return _scalarListFromAny(value['data']);
      return [
        for (final entry in value.values)
          if (entry is! Map && entry is! List && entry != null)
            entry.toString(),
      ];
    }
    return const [];
  }

  String? _seasonKey(Map<String, dynamic> value) =>
      _firstString(value, ['season_id', 'season_number', 'season', 'number']);

  int _compareSeasonKeys(String a, String b) {
    final ai = int.tryParse(a);
    final bi = int.tryParse(b);
    if (ai != null && bi != null) return ai.compareTo(bi);
    return a.compareTo(b);
  }

  bool _supportsVodListKind(ContentKind kind) =>
      kind == ContentKind.movie ||
      kind == ContentKind.series ||
      kind == ContentKind.season ||
      kind == ContentKind.episode;

  String _stalkerListType(ContentKind kind, MediaItem? parent) {
    final parentType = parent?.extra['stalkerType']?.toString();
    if (parentType == 'series' || parentType == 'vod') return parentType!;
    return kind == ContentKind.movie ? 'vod' : 'series';
  }

  List<Map<String, dynamic>> _filterMediaRows(
    List<Map<String, dynamic>> rows,
    ContentKind kind, {
    required String type,
    String? categoryId,
  }) {
    final filtered = rows
        .where(
          (m) => type == 'series'
              ? _matchesSeriesListKind(m, kind)
              : _matchesVodListKind(
                  m,
                  kind,
                  categoryId: categoryId,
                  categoryType: type,
                ),
        )
        .toList();
    if (rows.isNotEmpty && filtered.isEmpty) {
      _debug(
        '$type ${kind.name} filtered 0/${rows.length}; '
        'category=${categoryId ?? '<none>'} sample=${_rowShape(rows.first)}',
      );
    }
    return filtered;
  }

  bool _matchesSeriesListKind(Map<String, dynamic> item, ContentKind kind) {
    if (kind == ContentKind.movie) return false;
    if (kind == ContentKind.episode) return _isSeriesEpisodeRow(item);
    return true;
  }

  bool _isSeriesEpisodeRow(Map<String, dynamic> item) {
    if (_firstPlayableId(item) != null) return true;
    if (_truthyFlag(item, ['is_episode', 'episode']) == true) return true;
    final title = _firstString(item, ['name', 'title'])?.toLowerCase();
    if (title != null && RegExp(r'^season\s+\d+$').hasMatch(title)) {
      return false;
    }
    if (_hasAny(item, ['episode_id', 'episode_number', 'episode_num'])) {
      return true;
    }
    return _firstStableId(item) != null && title != null;
  }

  bool _matchesVodListKind(
    Map<String, dynamic> item,
    ContentKind kind, {
    String? categoryId,
    String? categoryType,
    String? categoryTitle,
  }) {
    final series = _isSeriesVodItem(
      item,
      categoryTitle:
          categoryTitle ?? _vodCategoryTitle(categoryId, type: categoryType),
    );
    if (kind == ContentKind.movie) return series != true;
    if (kind == ContentKind.series) return series == true;
    return true;
  }

  bool? _isSeriesVodItem(Map<String, dynamic> item, {String? categoryTitle}) {
    final explicit = _truthyFlag(item, [
      'is_series',
      'is_serial',
      'serial',
      'tv_series',
      'is_tv_series',
    ]);
    if (explicit != null) return explicit;
    if (_hasAny(item, [
      'series_id',
      'seasons',
      'season',
      'episodes',
      'episode_count',
      'season_count',
    ])) {
      return true;
    }
    final itemType = _firstString(item, ['type', 'item_type', 'media_type']);
    if (itemType != null) {
      final normalized = itemType.toLowerCase();
      if (normalized.contains('series') ||
          normalized.contains('serial') ||
          normalized.contains('show')) {
        return true;
      }
      if (normalized.contains('movie') ||
          normalized.contains('film') ||
          normalized.contains('vod')) {
        return false;
      }
    }
    final category = categoryTitle?.toLowerCase() ?? '';
    if (category.contains('series') ||
        category.contains('serial') ||
        category.contains('shows') ||
        category.contains('episodes')) {
      return true;
    }
    if (category.contains('movie') ||
        category.contains('film') ||
        category.contains('vod')) {
      return false;
    }
    return null;
  }

  bool? _truthyFlag(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      if (!item.containsKey(key)) continue;
      final value = item[key];
      if (value is bool) return value;
      final text = value?.toString().trim().toLowerCase();
      if (text == null || text.isEmpty || text == 'null') continue;
      if (const {'1', 'true', 'yes', 'y', 'on'}.contains(text)) return true;
      if (const {'0', 'false', 'no', 'n', 'off'}.contains(text)) return false;
    }
    return null;
  }

  bool _hasAny(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      if (value is Iterable && value.isEmpty) continue;
      if (value is Map && value.isEmpty) continue;
      return true;
    }
    return false;
  }

  String? _firstPlayableId(Map<String, dynamic> item) {
    final value = _firstString(item, [
      'episode_id',
      'video_id',
      'stream_id',
      'file_id',
    ]);
    if (value == null || _isPlaceholderStreamId(value)) return null;
    return value;
  }

  bool _isPlaceholderStreamId(String value) {
    final text = value.trim();
    return text.isEmpty || text == '.' || text == '0' || text == 'null';
  }

  String? _seriesSeasonKey(Map<String, dynamic> item) {
    final direct = _firstString(item, [
      'season_id',
      'season_number',
      'season',
      'number',
    ]);
    if (direct != null && !_isPlaceholderStreamId(direct)) {
      return _normalizeSeasonId(direct);
    }
    final title = _firstString(item, ['name', 'title']);
    if (title == null) return null;
    final match = RegExp(
      r'\bseason\s+(\d+)\b',
      caseSensitive: false,
    ).firstMatch(title);
    return match?.group(1);
  }

  int? _seriesSeasonNumber(Map<String, dynamic> item) {
    final key = _seriesSeasonKey(item);
    if (key == null) return null;
    return int.tryParse(key);
  }

  String? _vodCategoryTitle(String? categoryId, {String? type}) {
    if (categoryId == null) return null;
    if (type != null) {
      final typed = _vodCategoryTitles['$type:$categoryId'];
      if (typed != null) return typed;
    }
    return _vodCategoryTitles[categoryId];
  }

  String _rowShape(Map<String, dynamic> row) {
    final keys = row.keys.take(16).join(',');
    final id = _firstString(row, [
      'id',
      'movie_id',
      'series_id',
      'video_id',
      'stream_id',
    ]);
    final title = _firstString(row, ['name', 'title']);
    final flags = [
      for (final key in const [
        'is_series',
        'is_serial',
        'type',
        'item_type',
        'media_type',
      ])
        if (row.containsKey(key)) '$key=${row[key]}',
    ].join(',');
    return 'keys=$keys id=${id ?? '<none>'} title=${title ?? '<none>'} flags=$flags';
  }

  String? _parentMovieId(ContentKind kind, MediaItem? parent) {
    if (parent == null) return null;
    if (kind != ContentKind.season && kind != ContentKind.episode) return null;
    return _normalizeCompositeSeriesId(
          _firstString(parent.extra, ['movieId', 'series_id', 'id']),
        ) ??
        _normalizeCompositeSeriesId(parent.id);
  }

  String? _parentSeasonId(ContentKind kind, MediaItem? parent) {
    if (parent == null || kind != ContentKind.episode) return null;
    return _normalizeSeasonId(
          _firstString(parent.extra, ['seasonId', 'season_id', 'id']),
        ) ??
        _normalizeSeasonId(parent.id);
  }

  String? _normalizeSeasonId(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty || text == 'null') return null;
    final seasonMarker = text.indexOf(':season:');
    if (seasonMarker >= 0) return text.substring(seasonMarker + 8);
    final parts = text.split(':');
    if (parts.length >= 2 &&
        parts.every((part) => int.tryParse(part) != null)) {
      return parts[1];
    }
    return text;
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

  String _vodCommand(MediaItem item) {
    final direct = item.extra['cmd']?.toString();
    if (direct != null &&
        direct.isNotEmpty &&
        (!_hasPlaceholderStreamQuery(direct) ||
            item.kind == ContentKind.episode)) {
      return direct;
    }
    final streamId = item.kind == ContentKind.episode
        ? _firstString(item.extra, [
            'episode_id',
            'stream_id',
            'video_id',
            'id',
            'movieId',
          ])
        : _firstString(item.extra, ['stream_id', 'video_id', 'movieId', 'id']);
    if (streamId == null || _isPlaceholderStreamId(streamId)) {
      throw StalkerException('Movie "${item.title}" has no stream id');
    }
    return '/media/file_$streamId.mpg';
  }

  Map<String, String> _seriesCreateLinkParams(MediaItem item) {
    if (item.kind != ContentKind.episode) return const {};
    final episode = _episodeSelector(item);
    if (episode == null) return const {};
    return {'series': episode};
  }

  String? _episodeSelector(MediaItem item) {
    final direct = _firstString(item.extra, [
      'episode_number',
      'episode_num',
      'episode',
      'numbering',
    ]);
    if (direct != null && !_isPlaceholderStreamId(direct)) return direct;
    final id = _firstString(item.extra, ['episode_id', 'id']) ?? item.id;
    final parts = id.split(':');
    if (parts.length >= 2) return parts.last;
    return null;
  }

  String? _alternateSeriesEpisodeCommand(MediaItem item) {
    if (item.kind != ContentKind.episode) return null;
    final seriesId =
        _normalizeCompositeSeriesId(
          _firstString(item.extra, ['movieId', 'series_id', 'movie_id']),
        ) ??
        _normalizeCompositeSeriesId(item.parentId);
    final episode = _episodeSelector(item);
    if (seriesId == null || episode == null) return null;
    return '/media/file_$seriesId:$episode.mpg';
  }

  bool _hasPlaceholderStreamQuery(String value) {
    final uri = Uri.tryParse(value);
    final stream = uri?.queryParameters['stream'];
    if (stream != null) return _isPlaceholderStreamId(stream);
    return RegExp(
      r'([?&]stream=\.)(?=&|$)',
      caseSensitive: false,
    ).hasMatch(value);
  }

  String? _liveCommand(Channel channel) {
    final streamId = _liveStreamId(channel);
    final direct = channel.extra['cmd']?.toString().trim();
    if (direct != null && direct.isNotEmpty) {
      final repaired = _replaceEmptyQueryValue(direct, 'stream', streamId);
      if (!_hasEmptyQueryValue(repaired, 'stream')) return repaired;
    }
    if (streamId == null || streamId.isEmpty) return direct;
    return '/play/live.php?mac=$mac&stream=$streamId&extension=ts';
  }

  String _normalizeLiveStreamUrl(String raw, Channel channel) {
    final streamId = _liveStreamId(channel);
    final stripped = _stripStreamPrefix(raw);
    final repaired = _replaceEmptyQueryValue(stripped, 'stream', streamId);
    if (_hasEmptyQueryValue(repaired, 'stream')) {
      throw StalkerException(
        'Resolved stream URL for "${channel.name}" has an empty stream id. '
        'channel_id=${channel.id} cmd=${_commandShape(channel.extra['cmd']?.toString() ?? '')}',
      );
    }
    return repaired;
  }

  String? _liveStreamId(Channel channel) {
    final fromExtra = _firstString(channel.extra, [
      'streamId',
      'id',
      'ch_id',
      'channel_id',
      'stream_id',
    ]);
    if (fromExtra != null) return fromExtra;
    return channel.id.isEmpty ? null : channel.id;
  }

  String _replaceEmptyQueryValue(
    String value,
    String key,
    String? replacement,
  ) {
    if (replacement == null || replacement.isEmpty) return value;
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasQuery) {
      final params = Map<String, String>.from(uri.queryParameters);
      if (params.containsKey(key) &&
          (params[key] == null || params[key]!.isEmpty)) {
        params[key] = replacement;
        return uri.replace(queryParameters: params).toString();
      }
    }
    final escapedKey = RegExp.escape(key);
    return value.replaceAllMapped(
      RegExp(r'([?&]' + escapedKey + r'=)(?=&|$)', caseSensitive: false),
      (m) => '${m[1]}$replacement',
    );
  }

  bool _hasEmptyQueryValue(String value, String key) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasQuery && uri.queryParameters.containsKey(key)) {
      return uri.queryParameters[key]?.isEmpty ?? true;
    }
    final escapedKey = RegExp.escape(key);
    return RegExp(
      r'([?&]' + escapedKey + r'=)(?=&|$)',
      caseSensitive: false,
    ).hasMatch(value);
  }

  static String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return null;
  }

  // ── auth + endpoint (ported from the harness) ───────────────────────────────

  Uri _base() {
    var input = portal.trim();
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      input = 'http://$input';
    }
    final u = Uri.parse(input);
    final path = u.path.endsWith('/') ? u.path : '${u.path}/';
    return u.replace(path: path.isEmpty ? '/' : path);
  }

  List<String> _candidateEndpoints() {
    final b = _base();
    final hostPort = b.hasPort ? '${b.host}:${b.port}' : b.host;
    final root = '${b.scheme}://$hostPort/';
    const files = ['portal.php', 'load.php'];
    final out = <String>[];
    void add(String prefix) {
      for (final f in files) {
        final url = '$prefix$f';
        if (!out.contains(url)) out.add(url);
      }
    }

    add(b.toString()); // exactly what the user gave
    add(root); // host root (typical for /c/ UI paths)
    add('${root}stalker_portal/server/');
    add('${root}server/');
    add('${root}stalker_portal/');
    return out;
  }

  Future<String> _resolveEndpoint() async {
    if (_endpoint != null) return _endpoint!;
    _referer = _base().toString();
    StalkerException? last;
    for (final candidate in _candidateEndpoints()) {
      try {
        final token = await _handshake(candidate);
        if (token != null) {
          _endpoint = candidate;
          _token = token;
          _debug('endpoint ok ${_redactUrl(candidate)}');
          return candidate;
        }
      } on StalkerException catch (e) {
        last = e;
        _debug('endpoint failed ${_redactUrl(candidate)}: ${e.message}');
      } catch (e) {
        last = StalkerException(e.toString());
        _debug('endpoint failed ${_redactUrl(candidate)}: $e');
      }
    }
    throw StalkerException('No working API endpoint. Last: ${last?.message}');
  }

  Future<String?> _handshake(String endpoint) async {
    final r = await _request(endpoint, {
      'type': 'stb',
      'action': 'handshake',
      'token': '',
      'prehash': '',
    });
    final js = r['js'];
    if (js is Map &&
        js['token'] is String &&
        (js['token'] as String).isNotEmpty) {
      return js['token'] as String;
    }
    return null;
  }

  Future<void> _getProfile() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final identity = MagIdentity.fromMac(mac);
    await _call({
      'type': 'stb',
      'action': 'get_profile',
      'ver':
          'ImageDescription: 0.2.18-r14-250; ImageDate: Fri Jan 15 15:20:44 EET 2016; '
          'PORTAL version: 5.1.0; API Version: JS API version: 343; '
          'STB API version: 146; Player Engine version: 0x566',
      'hd': '1',
      'num_banks': '2',
      'image_version': '218',
      'video_out': 'hdmi',
      'hw_version': '1.7-BD-00',
      'not_valid': '0',
      'timestamp': '$timestamp',
      'api_signature': '262',
      'prehash': '',
      ...identity.profileParams(profile: profile, timestamp: timestamp),
    });
  }

  /// Calls the resolved endpoint, re-handshaking once if the token expired.
  Future<Map<String, dynamic>> _call(
    Map<String, String> params, {
    bool retry = true,
  }) async {
    final ep = await _resolveEndpoint();
    final r = await _request(ep, params);
    if (retry && _looksTokenInvalid(r)) {
      // Stale token → re-auth and try once more.
      _debug('token invalid; re-handshaking for ${_actionName(params)}');
      _token = null;
      _endpoint = null;
      await _resolveEndpoint();
      if (params['action'] != 'get_profile') {
        await _getProfile();
      }
      return _call(params, retry: false);
    }
    final portalError = _portalErrorMessage(r);
    if (portalError != null) {
      throw StalkerException(
        '${_actionName(params)} failed: ${redactStalkerDiagnostic(portalError)}',
      );
    }
    return r;
  }

  Future<Map<String, dynamic>> _request(
    String endpoint,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse(
      endpoint,
    ).replace(queryParameters: {...params, 'JsHttpRequest': '1-xml'});
    for (var attempt = 1; attempt <= 3; attempt++) {
      final req = await _http.getUrl(uri);
      req.followRedirects = true;
      req.headers
        ..set(HttpHeaders.userAgentHeader, profile.userAgent)
        ..set('X-User-Agent', 'Model: ${profile.model}; Link: WiFi')
        ..set(HttpHeaders.acceptHeader, '*/*')
        ..set('Cookie', 'mac=$mac; stb_lang=$lang; timezone=$timezone')
        ..set(HttpHeaders.refererHeader, _referer ?? _base().toString());
      if (_token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      }

      final resp = await req.close().timeout(kHttpReadTimeout);
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(kHttpReadTimeout);
      _debug(
        '${_actionName(params)} HTTP ${resp.statusCode} ${_redactUrl(endpoint)} '
        'body=${body.length}B',
      );
      if (resp.statusCode != 200) {
        if (_isTransientStatus(resp.statusCode) && attempt < 3) {
          _debug(
            'transient HTTP ${resp.statusCode}; retrying ${_actionName(params)} attempt ${attempt + 1}',
          );
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
          continue;
        }
        _debug('non-200 body ${_bodyPreview(body)}');
        throw StalkerException(
          'HTTP ${resp.statusCode} from ${_redactUrl(endpoint)}',
        );
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        _debug('non-json body ${_bodyPreview(body)}');
        throw StalkerException('Non-JSON response (wrong endpoint?)');
      }
      if (decoded is! Map) throw StalkerException('Unexpected response shape');
      final result = Map<String, dynamic>.from(decoded);
      _debug('${_actionName(params)} response ${_responseShape(result)}');
      return result;
    }
    throw StalkerException('Request failed after retries');
  }

  Map<String, String> _playbackHeaders() {
    return {HttpHeaders.userAgentHeader: profile.userAgent};
  }

  List<StreamSubtitle> _parsePlaybackSubtitles(dynamic value) {
    final out = <StreamSubtitle>[];
    void add(dynamic urlValue, {dynamic label, dynamic language}) {
      final rawUrl = urlValue?.toString().trim();
      if (rawUrl == null || rawUrl.isEmpty) return;
      final subtitleUrl = _stripStreamPrefix(rawUrl);
      if (!subtitleUrl.startsWith(RegExp(r'https?://', caseSensitive: false))) {
        return;
      }
      final lang = language?.toString().trim();
      final title = label?.toString().trim();
      final fallback = lang != null && lang.isNotEmpty
          ? lang.toUpperCase()
          : 'Subtitle ${out.length + 1}';
      if (out.any((item) => item.url == subtitleUrl)) return;
      out.add(
        StreamSubtitle(
          url: subtitleUrl,
          label: title != null && title.isNotEmpty ? title : fallback,
          language: lang != null && lang.isNotEmpty ? lang : null,
        ),
      );
    }

    void parse(dynamic node, {String? keyLabel}) {
      if (node == null) return;
      if (node is String) {
        add(node, label: keyLabel, language: keyLabel);
        return;
      }
      if (node is List) {
        for (final item in node) {
          parse(item);
        }
        return;
      }
      if (node is Map) {
        final map = Map<dynamic, dynamic>.from(node);
        final url = _firstString(map, [
          'url',
          'src',
          'file',
          'link',
          'subtitle',
          'sub',
        ]);
        if (url != null) {
          add(
            url,
            label: _firstString(map, ['title', 'label', 'name']) ?? keyLabel,
            language:
                _firstString(map, ['lang', 'language', 'iso']) ?? keyLabel,
          );
          return;
        }
        for (final entry in map.entries) {
          parse(entry.value, keyLabel: entry.key?.toString());
        }
      }
    }

    parse(value);
    if (out.isNotEmpty) {
      _debug('playback subtitles parsed count=${out.length}');
    }
    return out;
  }

  bool _isTransientStatus(int statusCode) =>
      statusCode == 429 ||
      statusCode == 500 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  String _stripStreamPrefix(String cmd) {
    var s = cmd.trim();
    s = s.replaceFirst(
      RegExp(r'^(ffmpeg|ffrt3|ffrt2|ffrt|auto)\s+', caseSensitive: false),
      '',
    );
    final idx = s.indexOf(RegExp(r'https?://', caseSensitive: false));
    if (idx > 0) return s.substring(idx);
    if (idx == 0) return s;

    final base = _endpoint == null ? _base() : Uri.parse(_endpoint!);
    final hostPort = base.hasPort ? '${base.host}:${base.port}' : base.host;
    final origin = '${base.scheme}://$hostPort';
    if (s.startsWith('/')) return '$origin$s';
    return '$origin/vod4/${s.replaceFirst(RegExp(r'^/+'), '')}';
  }

  bool _looksTokenInvalid(Map<String, dynamic> response) {
    if (response['js'] == null) return true;
    final text = _diagnosticText(response).toLowerCase();
    if (text.isEmpty) return false;
    final mentionsAuth =
        text.contains('token') ||
        text.contains('session') ||
        text.contains('auth') ||
        text.contains('authorization');
    final mentionsInvalid =
        text.contains('invalid') ||
        text.contains('expired') ||
        text.contains('not valid') ||
        text.contains('denied');
    return mentionsAuth && mentionsInvalid;
  }

  String? _portalErrorMessage(Map<String, dynamic> response) {
    final js = response['js'];
    if (js == null) return 'Empty js payload';
    final direct = _firstString(response, ['error', 'msg', 'message']);
    if (direct != null) return direct;
    if (js is Map) {
      return _firstString(js, ['error', 'msg', 'message']);
    }
    if (js is bool && !js) return 'Portal returned false';
    return null;
  }

  String _diagnosticText(Map<String, dynamic> response) {
    final values = <String>[];
    void add(dynamic value) {
      if (value == null) return;
      if (value is String) values.add(value);
    }

    add(response['error']);
    add(response['msg']);
    add(response['message']);
    final js = response['js'];
    if (js is Map) {
      add(js['error']);
      add(js['msg']);
      add(js['message']);
    } else {
      add(js);
    }
    return values.join(' ');
  }

  String _actionName(Map<String, String> params) =>
      '${params['type'] ?? '?'}:${params['action'] ?? '?'}';

  String _responseShape(Map<String, dynamic> response) {
    final js = response['js'];
    final jsShape = js is Map
        ? 'map keys=${js.keys.take(12).join(',')}'
        : js is List
        ? 'list len=${js.length}'
        : js == null
        ? 'null'
        : js.runtimeType.toString();
    return 'keys=${response.keys.take(12).join(',')} js=$jsShape';
  }

  String _bodyPreview(String body) {
    final preview = body.length <= 700 ? body : '${body.substring(0, 700)}...';
    return redactStalkerDiagnostic(preview);
  }

  String _redactUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return redactStalkerDiagnostic(value);
    return uri.replace(query: '').toString();
  }

  String _commandShape(String value) {
    if (value.isEmpty) return '<empty>';
    final cleaned = redactStalkerDiagnostic(value);
    final hasEmptyStream = _hasEmptyQueryValue(value, 'stream');
    final uri = Uri.tryParse(value);
    final path = uri?.path.isNotEmpty == true ? uri!.path : '<non-url>';
    return 'path=$path emptyStream=$hasEmptyStream len=${value.length} value=${cleaned.length > 220 ? '${cleaned.substring(0, 220)}...' : cleaned}';
  }

  void _debug(String message) {
    if (!diagnostics) return;
    final redacted = redactStalkerDiagnostic(message);
    DiagnosticsLog.instance.add('stalker', redacted);
    developer.log(redacted, name: 'iptvs.stalker');
    debugPrint('[iptvs.stalker] $redacted');
  }
}
