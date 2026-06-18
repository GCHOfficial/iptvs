import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'source.dart';
import 'xmltv.dart';

/// A [Source] backed by an extended M3U/M3U8 playlist (URL).
///
/// Stream URLs are static, so resolving needs no network. EPG comes from an
/// XMLTV guide — either an explicit [epgUrl] or the playlist's own
/// `url-tvg`/`x-tvg-url` header attribute.
class M3uSource implements Source {
  final String playlistUrl;
  final String? epgUrl;
  final String? userAgent;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  List<Channel>? _channels;
  List<Category>? _categories;
  String? _headerEpgUrl;

  M3uSource({required this.playlistUrl, this.epgUrl, this.userAgent});

  @override
  String get id => 'm3u:$playlistUrl';

  @override
  String get name => 'M3U · ${Uri.tryParse(playlistUrl)?.host ?? 'playlist'}';

  @override
  Future<void> connect() async {} // nothing to authenticate

  @override
  Future<List<Category>> categories() async {
    await _ensureParsed();
    return _categories!;
  }

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    await _ensureParsed();
    if (categoryId == null) return _channels!;
    return _channels!.where((c) => c.categoryId == categoryId).toList();
  }

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final url = channel.extra['url']?.toString();
    if (url == null || url.isEmpty) {
      throw StateError('Channel "${channel.name}" has no stream URL');
    }
    return StreamInfo(
      url: url,
      headers: userAgent != null ? {'User-Agent': userAgent!} : const {},
    );
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final url = epgUrl ?? _headerEpgUrl;
    if (url == null) return const [];
    final map = <String, String>{};
    for (final c in channels) {
      final tvg = c.extra['tvgId']?.toString();
      if (tvg != null && tvg.isNotEmpty) map[tvg] = c.id;
    }
    if (map.isEmpty) return const [];
    final bytes = await _download(Uri.parse(url));
    return parseXmltv(bytes, map);
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: const [], page: page, totalPages: page);

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('M3U source only exposes playlist channels');

  @override
  Future<void> dispose() async => _http.close(force: true);

  // ── parsing ────────────────────────────────────────────────────────────

  Future<void> _ensureParsed() async {
    if (_channels != null) return;
    final bytes = await _download(Uri.parse(playlistUrl));
    _parse(utf8.decode(bytes, allowMalformed: true));
  }

  void _parse(String content) {
    final channels = <Channel>[];
    final categoryTitles = <String>{};

    String? name, group, logo, tvgId;

    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) {
        _headerEpgUrl = _attr(line, 'url-tvg') ?? _attr(line, 'x-tvg-url');
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        tvgId = _attr(line, 'tvg-id');
        logo = _attr(line, 'tvg-logo');
        group = _attr(line, 'group-title');
        name = _name(line);
        continue;
      }
      if (line.startsWith('#')) continue; // other directives (#EXTVLCOPT etc.)

      // A URL line completes the pending channel.
      if (name != null) {
        final g = (group == null || group.isEmpty) ? 'Uncategorized' : group;
        categoryTitles.add(g);
        channels.add(
          Channel(
            id: (tvgId != null && tvgId.isNotEmpty) ? tvgId : line,
            name: name,
            number: channels.length + 1,
            logo: (logo != null && logo.isNotEmpty) ? logo : null,
            categoryId: g,
            extra: {
              'url': line,
              if (tvgId != null && tvgId.isNotEmpty) 'tvgId': tvgId,
            },
          ),
        );
        name = group = logo = tvgId = null;
      }
    }

    _channels = channels;
    _categories = (categoryTitles.toList()..sort())
        .map((t) => Category(id: t, title: t))
        .toList();
  }

  String? _attr(String line, String key) =>
      RegExp('$key="([^"]*)"').firstMatch(line)?.group(1);

  String _name(String extinf) {
    final lastQuote = extinf.lastIndexOf('"');
    final comma = extinf.indexOf(',', lastQuote == -1 ? 0 : lastQuote);
    return comma == -1 ? '' : extinf.substring(comma + 1).trim();
  }

  Future<Uint8List> _download(Uri uri) async {
    final req = await _http.getUrl(uri);
    if (userAgent != null) {
      req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
    }
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw StateError('HTTP ${resp.statusCode} fetching $uri');
    }
    final builder = BytesBuilder();
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
