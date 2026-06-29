import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/net.dart';
import 'source.dart';
import 'xmltv.dart';
import 'xtream_source.dart';

/// A [Source] backed by an extended M3U/M3U8 playlist (URL).
///
/// Stream URLs are static, so resolving needs no network. EPG comes from an
/// XMLTV guide — either an explicit [epgUrl] or the playlist's own
/// `url-tvg`/`x-tvg-url` header attribute.
class M3uSource implements Source {
  final String playlistUrl;
  final String? epgUrl;
  final String? userAgent;
  final XtreamSource? _xtreamSource;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  List<Channel>? _channels;
  List<Category>? _categories;
  String? _headerEpgUrl;

  M3uSource({
    required this.playlistUrl,
    this.epgUrl,
    this.userAgent,
    this.displayName,
  }) : _xtreamSource = _xtreamSourceFromPlaylist(playlistUrl, displayName);

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  @override
  String get id => 'm3u:$playlistUrl';

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'M3U · ${Uri.tryParse(playlistUrl)?.host ?? 'playlist'}';

  @override
  Future<void> connect() async {
    if (_xtreamSource != null) {
      await _xtreamSource!.connect();
    }
  }

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
    if (url != null) {
      final map = <String, String>{};
      for (final c in channels) {
        final tvg = c.extra['tvgId']?.toString();
        if (tvg != null && tvg.isNotEmpty) map[tvg] = c.id;
      }
      if (map.isNotEmpty) {
        final bytes = await _download(Uri.parse(url));
        return parseXmltv(bytes, map);
      }
    }
    if (_xtreamSource != null) {
      return _xtreamSource!.epg(channels);
    }
    return const [];
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async {
    if (_xtreamSource != null) {
      return _xtreamSource!.mediaCategories(kind);
    }
    return const [];
  }

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    if (_xtreamSource != null) {
      return _xtreamSource!.mediaItems(
        kind,
        categoryId: categoryId,
        parent: parent,
        maxPages: maxPages,
      );
    }
    return const [];
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (_xtreamSource != null) {
      return _xtreamSource!.mediaItemsPage(
        kind,
        categoryId: categoryId,
        parent: parent,
        page: page,
      );
    }
    return MediaPage(items: const [], page: page, totalPages: page);
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    if (_xtreamSource != null) {
      return _xtreamSource!.searchMedia(
        kind,
        query,
        categoryId: categoryId,
      );
    }
    return const [];
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    if (_xtreamSource != null) {
      return _xtreamSource!.mediaDetails(item);
    }
    return item;
  }

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (_xtreamSource != null) {
      return _xtreamSource!.resolveMedia(item);
    }
    throw UnsupportedError('M3U source only exposes playlist channels');
  }

  @override
  Future<DateTime?> subscriptionExpiry() async => null;

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

  @visibleForTesting
  static _XtreamCredentials? extractXtreamCredentials(Uri uri) =>
      _extractXtreamCredentials(uri);

  static XtreamSource? _xtreamSourceFromPlaylist(
    String playlistUrl,
    String? displayName,
  ) {
    final uri = Uri.tryParse(playlistUrl);
    if (uri == null) return null;
    final creds = _extractXtreamCredentials(uri);
    if (creds == null) return null;
    return XtreamSource(
      host: creds.host,
      username: creds.username,
      password: creds.password,
      displayName: displayName,
    );
  }

  static _XtreamCredentials? _extractXtreamCredentials(Uri uri) {
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
    if (username == null || username.isEmpty || password == null || password.isEmpty) {
      return null;
    }

    final hostName = uri.host;
    if (hostName.isEmpty) return null;
    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
    final host = '$scheme://$hostName${uri.hasPort ? ':${uri.port}' : ''}';
    return _XtreamCredentials(host: host, username: username, password: password);
  }

  Future<Uint8List> _download(Uri uri) async {
    final req = await _http.getUrl(uri);
    if (userAgent != null) {
      req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
    }
    final resp = await req.close().timeout(kHttpReadTimeout);
    if (resp.statusCode != 200) {
      // redactUrl strips credentials some providers embed in the playlist URL.
      throw StateError('HTTP ${resp.statusCode} fetching ${redactUrl(uri)}');
    }
    return resp.readBytes();
  }
}

class _XtreamCredentials {
  final String host;
  final String username;
  final String password;

  const _XtreamCredentials({
    required this.host,
    required this.username,
    required this.password,
  });
}
