import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../data/load_token.dart';
import '../data/diagnostics_log.dart';
import '../data/net.dart';
import 'expiry.dart';
import 'source.dart';
import 'source_identity.dart';
import 'xmltv.dart';

/// A [Source] backed by an extended M3U/M3U8 playlist (URL).
///
/// Stream URLs are static, so resolving needs no network. EPG comes from an
/// XMLTV guide — either an explicit [epgUrl] or the playlist's own
/// `url-tvg`/`x-tvg-url` header attribute.
class M3uSource implements Source, BatchedEpgSource, CatchupSource {
  final String sourceId;
  final String playlistUrl;
  final String? epgUrl;
  final String? userAgent;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;

  List<Channel>? _channels;
  List<Category>? _categories;
  String? _headerEpgUrl;
  CatchupCapability _catchupCapability = CatchupCapability.unsupported;

  M3uSource({
    required this.sourceId,
    required this.playlistUrl,
    this.epgUrl,
    this.userAgent,
    this.displayName,
  });

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  @override
  String get id => sourceId;

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'M3U · ${Uri.tryParse(playlistUrl)?.host ?? 'playlist'}';

  @override
  CatchupCapability get catchupCapability => _catchupCapability;

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
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    final template =
        channel.extra['catchupSource']?.toString() ??
        catchupCapability.template;
    if (template == null || template.isEmpty) {
      throw UnsupportedError('M3U channel does not advertise catch-up');
    }
    final start = programme.start.toUtc().millisecondsSinceEpoch ~/ 1000;
    final end = programme.stop.toUtc().millisecondsSinceEpoch ~/ 1000;
    final url = template
        .replaceAll('{start}', '$start')
        .replaceAll('{end}', '$end')
        .replaceAll('%START%', '$start')
        .replaceAll('%END%', '$end');
    return StreamInfo(
      url: url,
      headers: userAgent == null ? const {} : {'User-Agent': userAgent!},
      isLive: false,
    );
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final url = epgUrl ?? _headerEpgUrl;
    if (url == null) return const [];
    final map = _tvgIdMap(channels);
    if (map.isEmpty) return const [];
    final bytes = await _download(Uri.parse(url), kEpgWorkload);
    return parseXmltv(bytes, map);
  }

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) {
    final url = epgUrl ?? _headerEpgUrl;
    if (url == null) return null;
    final map = _tvgIdMap(channels);
    if (map.isEmpty) return null;
    return _streamEpg(url, map, token);
  }

  Map<String, String> _tvgIdMap(List<Channel> channels) {
    final map = <String, String>{};
    for (final c in channels) {
      final tvg = c.extra['tvgId']?.toString();
      if (tvg != null && tvg.isNotEmpty) map[tvg] = c.id;
    }
    return map;
  }

  Stream<List<Programme>> _streamEpg(
    String url,
    Map<String, String> map,
    LoadToken? token,
  ) async* {
    final bytes = await _download(Uri.parse(url), kEpgWorkload);
    yield* parseXmltvBatched(bytes, map, token: token);
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
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('M3U source only exposes playlist channels');

  @override
  Future<DateTime?> subscriptionExpiry() async =>
      expiryFromPlaylistUrl(playlistUrl);

  @override
  Future<void> dispose() async => _http.close(force: true);

  // ── parsing ────────────────────────────────────────────────────────────

  // Small playlists parse fast enough inline; isolate spawn overhead would
  // dominate. Mirrors XtreamSource's `_isolateJsonThreshold`.
  static const _isolateM3uThreshold = 256 * 1024;

  Future<void> _ensureParsed() async {
    if (_channels != null) return;
    final bytes = await _download(Uri.parse(playlistUrl), kPlaylistWorkload);
    // Decode + parse on a background isolate: a large playlist (tens of MB,
    // tens of thousands of channels) would otherwise stall the UI thread for
    // hundreds of ms while building Channel objects.
    final parsed = bytes.length < _isolateM3uThreshold
        ? _parseM3uBytes(bytes)
        : await compute(_parseM3uBytes, bytes);
    _channels = parsed.channels;
    _categories = parsed.categories;
    _headerEpgUrl = parsed.headerEpgUrl;
    _catchupCapability = parsed.catchupCapability;
    DiagnosticsLog.instance.add(
      'parse:m3u',
      'rejected_rows=${parsed.rejectedRows}',
    );
  }

  Future<Uint8List> _download(Uri uri, HttpWorkloadPolicy policy) async {
    final operation = HttpOperation(
      policy,
      onReadMetrics: (m) => DiagnosticsLog.instance.add(
        'http:${policy.name}',
        'compressed_bytes=${m.compressedBytes} decoded_bytes=${m.decodedBytes}',
      ),
    );
    final req = await operation.wait(_http.getUrl(uri));
    if (userAgent != null) {
      req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
    }
    final resp = await operation.wait(req.close());
    if (resp.statusCode != 200) {
      // redactUrl strips credentials some providers embed in the playlist URL.
      throw StateError('HTTP ${resp.statusCode} fetching ${redactUrl(uri)}');
    }
    return operation.readBytes(resp);
  }
}

/// Result of parsing a playlist, sent back from the parse isolate.
class M3uParsed {
  final List<Channel> channels;
  final List<Category> categories;
  final String? headerEpgUrl;
  final CatchupCapability catchupCapability;
  final int rejectedRows;
  const M3uParsed(
    this.channels,
    this.categories,
    this.headerEpgUrl, [
    this.catchupCapability = CatchupCapability.unsupported,
    this.rejectedRows = 0,
  ]);
}

/// Isolate entrypoint: decodes [bytes] and parses the playlist. Kept top-level
/// and pure so it can run under [compute] (no access to instance state).
M3uParsed _parseM3uBytes(Uint8List bytes) =>
    parseM3uPlaylist(utf8.decode(bytes, allowMalformed: true));

/// Parses an extended M3U playlist. Public only for tests — production code
/// goes through [M3uSource], which runs this on a background isolate.
@visibleForTesting
M3uParsed parseM3uPlaylist(String content) {
  final channels = <Channel>[];
  final categoryTitles = <String>{};
  String? headerEpgUrl;
  CatchupCapability capability = CatchupCapability.unsupported;

  String? name, group, logo, tvgId;
  String? catchupSource;
  var catchupDays = 0;
  var rejectedRows = 0;

  for (final raw in const LineSplitter().convert(content)) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTM3U')) {
      headerEpgUrl = _attr(line, 'url-tvg') ?? _attr(line, 'x-tvg-url');
      final catchup = _attr(line, 'catchup');
      final days = int.tryParse(_attr(line, 'catchup-days') ?? '');
      if (catchup != null && catchup.toLowerCase() != 'none') {
        capability = CatchupCapability(
          mode: CatchupUrlMode.m3uTemplate,
          maxArchiveWindow: days == null ? null : Duration(days: days),
          template: _attr(line, 'catchup-source'),
        );
      }
      catchupSource = _attr(line, 'catchup-source');
      catchupDays = int.tryParse(_attr(line, 'catchup-days') ?? '') ?? 0;
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
          // The stream URL is the only per-entry unique key. tvg-id must NOT
          // be the id: playlists commonly reuse one tvg-id across quality
          // variants (HD/FHD/4K of the same channel), and the SQLite cache's
          // (source_id, id) primary key would silently drop all but one.
          // tvg-id stays in extra for the XMLTV EPG mapping.
          id: stableM3uChannelId(line),
          name: name,
          number: channels.length + 1,
          logo: (logo != null && logo.isNotEmpty) ? logo : null,
          categoryId: g,
          archiveDays: catchupSource == null
              ? 0
              : (catchupDays > 0 ? catchupDays : kDefaultArchiveDays),
          extra: {
            'url': line,
            if (tvgId != null && tvgId.isNotEmpty) 'tvgId': tvgId,
            ...?catchupSource == null
                ? null
                : <String, dynamic>{'catchupSource': catchupSource},
          },
        ),
      );
      name = group = logo = tvgId = catchupSource = null;
      catchupDays = 0;
    }
  }
  if (name != null) rejectedRows++;

  final categories = (categoryTitles.toList()..sort())
      .map((t) => Category(id: t, title: t))
      .toList();
  return M3uParsed(
    channels,
    categories,
    headerEpgUrl,
    capability,
    rejectedRows,
  );
}

String? _attr(String line, String key) =>
    RegExp('$key="([^"]*)"').firstMatch(line)?.group(1);

String _name(String extinf) {
  final lastQuote = extinf.lastIndexOf('"');
  final comma = extinf.indexOf(',', lastQuote == -1 ? 0 : lastQuote);
  return comma == -1 ? '' : extinf.substring(comma + 1).trim();
}
