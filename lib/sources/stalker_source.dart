import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;

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

  StalkerSource({
    required this.portal,
    required this.mac,
    this.profile = MagProfile.mag250,
    this.lang = 'en',
    this.timezone = 'Europe/Bucharest',
    this.diagnostics = true,
  });

  @override
  String get id => 'stalker:$portal|$mac';

  @override
  String get name => 'Stalker · $mac';

  @override
  Future<void> connect() async {
    await _resolveEndpoint(); // handshake happens here and sets _token
    await _getProfile();
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
    return StreamInfo(
      url: url,
      // Some portals gate the stream fetch on the MAG UA too.
      headers: {'User-Agent': profile.userAgent},
    );
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
    final r = await _call({'type': 'vod', 'action': 'get_categories'});
    final js = r['js'];
    if (js is! List) return const [];
    return js
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map(
          (c) => MediaCategory(
            id: '${c['id']}',
            title: '${c['title'] ?? c['name'] ?? ''}',
            kind: kind,
          ),
        )
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
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return const [];
    }
    final rows = await _getOrderedList(
      type: 'vod',
      category: categoryId,
      maxPages: maxPages,
    );
    return rows
        .where((m) {
          final isSeries = '${m['is_series']}' == '1';
          return kind == ContentKind.series ? isSeries : !isSeries;
        })
        .map((m) => _mapMediaItem(m, kind: kind, categoryId: categoryId))
        .toList();
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return MediaPage(items: const [], page: page, totalPages: page);
    }
    final raw = await _getOrderedListPage(
      type: 'vod',
      category: categoryId,
      page: page,
    );
    final items = raw.rows
        .where((m) {
          final isSeries = '${m['is_series']}' == '1';
          return kind == ContentKind.series ? isSeries : !isSeries;
        })
        .map((m) => _mapMediaItem(m, kind: kind, categoryId: categoryId))
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
    final raw = await _getOrderedListPage(
      type: 'vod',
      category: categoryId,
      search: q,
      page: 1,
    );
    return raw.rows
        .where((m) {
          final isSeries = '${m['is_series']}' == '1';
          return kind == ContentKind.series ? isSeries : !isSeries;
        })
        .map((m) => _mapMediaItem(m, kind: kind, categoryId: categoryId))
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
    final cmd = _vodCommand(item);
    final r = await _call({
      'type': 'vod',
      'action': 'create_link',
      'cmd': cmd,
      'forced_storage': '0',
      'disable_ad': '0',
    });
    final js = r['js'];
    final raw = js is Map ? _firstString(js, ['url', 'cmd']) : null;
    if (raw == null) throw StalkerException('VOD create_link returned no URL');
    return StreamInfo(
      url: _stripStreamPrefix(raw),
      headers: {'User-Agent': profile.userAgent},
      isLive: false,
    );
  }

  DateTime? _epochToDate(dynamic v) {
    final secs = v is int ? v : int.tryParse('$v');
    if (secs == null || secs == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
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
      final channels = list
          .map((e) => _mapChannel(Map<String, dynamic>.from(e)))
          .toList();
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

  Channel _mapChannel(Map<String, dynamic> ch) {
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
      extra: extra,
    );
  }

  MediaItem _mapMediaItem(
    Map<String, dynamic> item, {
    required ContentKind kind,
    String? categoryId,
  }) {
    final id =
        _firstString(item, ['id', 'movie_id', 'video_id', 'stream_id']) ?? '';
    return MediaItem(
      id: id,
      title: _firstString(item, ['name', 'title']) ?? 'Untitled',
      kind: kind,
      categoryId: categoryId ?? _firstString(item, ['category_id']),
      poster: _firstString(item, ['screenshot_uri', 'poster', 'cover']),
      description: _firstString(item, ['description', 'descr', 'plot']),
      year: _firstString(item, ['year', 'released']),
      extra: {
        ...item,
        'movieId': _firstString(item, ['movie_id', 'id']) ?? id,
      },
    );
  }

  String _vodCommand(MediaItem item) {
    final direct = item.extra['cmd']?.toString();
    if (direct != null && direct.isNotEmpty) return direct;
    final streamId = _firstString(item.extra, [
      'stream_id',
      'video_id',
      'series_id',
      'movieId',
      'id',
    ]);
    if (streamId == null || streamId.isEmpty) {
      throw StalkerException('Movie "${item.title}" has no stream id');
    }
    return '/media/file_$streamId.mpg';
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

  String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
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

    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    _debug(
      '${_actionName(params)} HTTP ${resp.statusCode} ${_redactUrl(endpoint)} '
      'body=${body.length}B',
    );
    if (resp.statusCode != 200) {
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
    developer.log(redacted, name: 'iptvs.stalker');
    debugPrint('[iptvs.stalker] $redacted');
  }
}
