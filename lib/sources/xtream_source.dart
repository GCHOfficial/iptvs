import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'source.dart';
import 'xmltv.dart';

/// A [Source] backed by an Xtream Codes panel (host + username + password).
///
/// Implements live TV; VOD and series can be layered on the same interface
/// later. Stream URLs follow `/live/USER/PASS/STREAM_ID.ext`.
class XtreamSource implements Source {
  final String host; // e.g. http://host:port
  final String username;
  final String password;
  final String streamExtension; // 'ts' (most compatible) or 'm3u8'

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  XtreamSource({
    required this.host,
    required this.username,
    required this.password,
    this.streamExtension = 'ts',
  });

  String get _base {
    var h = host.trim();
    if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://$h';
    if (h.endsWith('/')) h = h.substring(0, h.length - 1);
    return h;
  }

  @override
  String get id => 'xtream:$_base|$username';

  @override
  String get name => 'Xtream · $username';

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
    final r = await _api(params);
    if (r is! List) return const [];
    return r.whereType<Map>().map((s) {
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
        extra: {
          'streamId': streamId,
          if (epgId != null && epgId.isNotEmpty) 'tvgId': epgId,
        },
      );
    }).toList();
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final streamId = channel.extra['streamId']?.toString() ?? channel.id;
    return StreamInfo(
      url: '$_base/live/$username/$password/$streamId.$streamExtension',
    );
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final map = <String, String>{};
    for (final c in channels) {
      final tvg = c.extra['tvgId']?.toString();
      if (tvg != null && tvg.isNotEmpty) map[tvg] = c.id;
    }
    if (map.isEmpty) return const [];
    final uri = Uri.parse(
      '$_base/xmltv.php?username=$username&password=$password',
    );
    final bytes = await _download(uri);
    return parseXmltv(bytes, map);
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
    if (r is! List) return const [];
    return r.whereType<Map>().map((c) {
      final m = Map<String, dynamic>.from(c);
      return MediaCategory(
        id: '${m['category_id']}',
        title: '${m['category_name']}',
        kind: kind,
      );
    }).toList();
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    final action = switch (kind) {
      ContentKind.movie => 'get_vod_streams',
      ContentKind.series => 'get_series',
      _ => null,
    };
    if (action == null) return const [];
    final params = {'action': action};
    if (categoryId != null) params['category_id'] = categoryId;
    final r = await _api(params);
    if (r is! List) return const [];
    return r
        .whereType<Map>()
        .map((e) => _mapMediaItem(Map<String, dynamic>.from(e), kind))
        .toList();
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    final items = page == 1
        ? await mediaItems(kind, categoryId: categoryId, parent: parent)
        : const <MediaItem>[];
    return MediaPage(items: items, page: page, totalPages: 1);
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
      isLive: false,
    );
  }

  @override
  Future<void> dispose() async => _http.close(force: true);

  // ── http ──────────────────────────────────────────────────────────────

  Future<dynamic> _api(Map<String, String> params) async {
    final uri = Uri.parse('$_base/player_api.php').replace(
      queryParameters: {'username': username, 'password': password, ...params},
    );
    final bytes = await _download(uri);
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  }

  Future<Uint8List> _download(Uri uri) async {
    final req = await _http.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('HTTP ${resp.statusCode} from $uri');
    }
    final builder = BytesBuilder();
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  MediaItem _mapMediaItem(Map<String, dynamic> m, ContentKind kind) {
    final idKey = kind == ContentKind.movie ? 'stream_id' : 'series_id';
    return MediaItem(
      id: '${m[idKey]}',
      title: '${m['name']}',
      kind: kind,
      categoryId: m['category_id']?.toString(),
      poster: _firstString(m, ['stream_icon', 'cover', 'cover_big']),
      description: _firstString(m, ['plot', 'description']),
      year: _firstString(m, ['year', 'releaseDate', 'release_date']),
      extra: m,
    );
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
}
