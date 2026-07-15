import 'dart:convert';
import 'dart:io';

import '../sources/source.dart';
import 'metadata_provider.dart';
import 'net.dart';

class TvdbClient implements MetadataProvider {
  final String apiKey;
  final String pin;
  final HttpClient _http;
  String? _token;

  TvdbClient({required this.apiKey, this.pin = '', HttpClient? http})
    : _http =
          http ??
          (HttpClient()
            ..connectionTimeout = _connectTimeout
            ..autoUncompress = false);

  static const _connectTimeout = Duration(seconds: 15);

  static const providerKey = 'tvdb';
  static const _base = 'https://api4.thetvdb.com/v4';

  @override
  String get provider => providerKey;

  @override
  String get authMode => 'bearer-login';

  @override
  bool get ratingsOnly => false;

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    final title = _cleanTitle(item.title);
    if (title.isEmpty) return null;
    final type = item.kind == ContentKind.movie ? 'movie' : 'series';
    final results = await _get('/search', {
      'query': title,
      'type': type,
      if (item.year != null && item.year!.length >= 4) 'year': item.year!,
      'limit': '5',
    });
    final list = results is Map && results['data'] is List
        ? results['data'] as List
        : const [];
    final best = _bestSearchResult(list, item);
    if (best == null) return null;
    return _mapSearchResult(best, item);
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async {
    final seasonId = _tvdbSeasonId(season);
    if (seasonId != null) {
      final details = await _get('/seasons/$seasonId/extended');
      if (details is Map && details['data'] is Map) {
        return _mapSeasonDetails(
          Map<String, dynamic>.from(details['data'] as Map),
          series,
          season,
        );
      }
    }
    final seriesId = _tvdbSeriesId(series);
    final seasonNumber = season.seasonNumber;
    if (seriesId == null || seasonNumber == null) return null;
    final episodes = await _seriesEpisodes(
      seriesId,
      season: seasonNumber,
      episodeNumber: 1,
    );
    final first = episodes.isEmpty ? null : episodes.first;
    final seasons = first == null
        ? const <Map<String, dynamic>>[]
        : _seasonsFromEpisode(first);
    final match = seasons
        .where((entry) => _readInt(entry['number']) == seasonNumber)
        .cast<Map<String, dynamic>?>()
        .firstWhere((entry) => entry != null, orElse: () => null);
    if (match == null) return null;
    return _mapSeasonDetails(match, series, season);
  }

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async {
    final directId = _tvdbEpisodeId(episode);
    if (directId != null) {
      final details = await _get('/episodes/$directId/extended');
      if (details is Map && details['data'] is Map) {
        return _mapEpisodeDetails(
          Map<String, dynamic>.from(details['data'] as Map),
          season,
          episode,
        );
      }
    }
    final seriesId = _tvdbSeriesId(season);
    final seasonNumber = episode.seasonNumber ?? season.seasonNumber;
    final episodeNumber = episode.episodeNumber;
    if (seriesId == null || seasonNumber == null || episodeNumber == null) {
      return null;
    }
    final episodes = await _seriesEpisodes(
      seriesId,
      season: seasonNumber,
      episodeNumber: episodeNumber,
    );
    final match = episodes
        .where(
          (entry) =>
              _readInt(entry['seasonNumber']) == seasonNumber &&
              _readInt(entry['number']) == episodeNumber,
        )
        .cast<Map<String, dynamic>?>()
        .firstWhere((entry) => entry != null, orElse: () => null);
    if (match == null) return null;
    return _mapEpisodeDetails(match, season, episode);
  }

  Future<String> _bearerToken() async {
    final existing = _token;
    if (existing != null) return existing;
    final uri = Uri.parse('$_base/login');
    final operation = HttpOperation(kMetadataJsonWorkload);
    final request = await operation.wait(_http.postUrl(uri));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({'apikey': apiKey, if (pin.isNotEmpty) 'pin': pin}),
    );
    final response = await operation.wait(request.close());
    if (response.statusCode != 200) {
      throw StateError('TVDB HTTP ${response.statusCode} auth=login');
    }
    final body = jsonDecode(
      utf8.decode(await operation.readBytes(response), allowMalformed: true),
    );
    final token = body is Map && body['data'] is Map
        ? (body['data'] as Map)['token']?.toString()
        : null;
    if (token == null || token.isEmpty) {
      throw StateError('TVDB login returned no token');
    }
    _token = token;
    return token;
  }

  Future<dynamic> _get(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: query);
    final operation = HttpOperation(kMetadataJsonWorkload);
    final request = await operation.wait(_http.getUrl(uri));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${await _bearerToken()}',
    );
    final response = await operation.wait(request.close());
    if (response.statusCode != 200) {
      throw StateError('TVDB HTTP ${response.statusCode} path=$path');
    }
    return jsonDecode(
      utf8.decode(await operation.readBytes(response), allowMalformed: true),
    );
  }

  Future<List<Map<String, dynamic>>> _seriesEpisodes(
    String seriesId, {
    required int season,
    required int episodeNumber,
  }) async {
    final data = await _get('/series/$seriesId/episodes/default', {
      'page': '0',
      'season': '$season',
      'episodeNumber': '$episodeNumber',
    });
    final list = data is Map && data['data'] is Map
        ? (data['data'] as Map)['episodes']
        : null;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  Map<String, dynamic>? _bestSearchResult(
    List<dynamic> results,
    MediaItem item,
  ) {
    final target = _normalizeTitle(_cleanTitle(item.title));
    var bestScore = 0.0;
    Map<String, dynamic>? best;
    for (final entry in results.whereType<Map>()) {
      final row = Map<String, dynamic>.from(entry);
      final candidate = _normalizeTitle(
        _firstString(row, ['name', 'title', 'slug']) ?? '',
      );
      if (candidate.isEmpty) continue;
      var score = _titleScore(target, candidate);
      final year = _firstString(row, ['year', 'first_air_time']);
      if (item.year != null && year != null && year.length >= 4) {
        score += item.year == year.substring(0, 4) ? 0.2 : -0.1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = row;
      }
    }
    return bestScore >= 0.62 ? best : null;
  }

  ExternalMetadata _mapSearchResult(Map<String, dynamic> data, MediaItem item) {
    final id = _firstString(data, ['tvdb_id', 'id', 'objectID']) ?? '';
    final year = _firstString(data, ['year', 'first_air_time']);
    return ExternalMetadata(
      provider: providerKey,
      providerKey: id,
      title: _firstString(data, ['name', 'title']),
      overview: _firstString(data, ['overview']),
      poster: _firstString(data, ['image_url', 'image']),
      year: year != null && year.length >= 4 ? year.substring(0, 4) : item.year,
      payload: data,
      refreshedAt: DateTime.now(),
    );
  }

  ExternalMetadata _mapSeasonDetails(
    Map<String, dynamic> data,
    MediaItem series,
    MediaItem season,
  ) {
    final id =
        _firstString(data, ['id']) ??
        '${series.providerId}:s${season.seasonNumber}';
    final year = _firstString(data, ['year']);
    return ExternalMetadata(
      provider: providerKey,
      providerKey: id,
      title: _firstString(data, ['name']) ?? season.title,
      overview: _firstString(data, ['overview']),
      poster: _firstString(data, ['image']),
      year: year != null && year.length >= 4
          ? year.substring(0, 4)
          : season.year,
      payload: {...data, ..._seriesPayload(series)},
      refreshedAt: DateTime.now(),
    );
  }

  ExternalMetadata _mapEpisodeDetails(
    Map<String, dynamic> data,
    MediaItem season,
    MediaItem episode,
  ) {
    final id = _firstString(data, ['id']) ?? episode.id;
    final year = _firstString(data, ['year', 'aired']);
    return ExternalMetadata(
      provider: providerKey,
      providerKey: id,
      title: _firstString(data, ['name']) ?? episode.title,
      overview: _firstString(data, ['overview']),
      poster: _firstString(data, ['image']),
      year: year != null && year.length >= 4
          ? year.substring(0, 4)
          : episode.year,
      payload: {...data, ..._seriesPayload(season)},
      refreshedAt: DateTime.now(),
    );
  }

  List<Map<String, dynamic>> _seasonsFromEpisode(Map<String, dynamic> episode) {
    final seasons = episode['seasons'];
    if (seasons is! List) return const [];
    return seasons
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  Map<String, dynamic> _seriesPayload(MediaItem item) {
    final seriesId = _tvdbSeriesId(item);
    return seriesId == null ? const {} : {'series_tvdb_id': seriesId};
  }

  String? _tvdbSeriesId(MediaItem item) {
    final direct = item.providerId;
    if (direct != null && RegExp(r'^\d+$').hasMatch(direct)) return direct;
    for (final key in const ['tvdb_id', 'tvdbId', 'series_tvdb_id']) {
      final value = item.extra[key]?.toString();
      if (value != null && RegExp(r'^\d+$').hasMatch(value)) return value;
    }
    final metadata = item.extra['metadata'];
    if (metadata is Map) {
      final tvdb = metadata[providerKey];
      if (tvdb is Map) {
        final id = _firstString(tvdb, [
          'series_tvdb_id',
          'seriesId',
          'series_id',
          'id',
          'tvdb_id',
        ]);
        if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
      }
    }
    final details = item.extra['details'];
    if (details is Map) {
      final id = _firstString(details, [
        'series_tvdb_id',
        'tvdb_id',
        'seriesId',
      ]);
      if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
    }
    return null;
  }

  String? _tvdbSeasonId(MediaItem item) {
    for (final key in const ['tvdb_season_id', 'tvdbSeasonId']) {
      final value = item.extra[key]?.toString();
      if (value != null && RegExp(r'^\d+$').hasMatch(value)) return value;
    }
    final metadata = item.extra['metadata'];
    if (metadata is Map) {
      final tvdb = metadata[providerKey];
      if (tvdb is Map) {
        final id = _firstString(tvdb, ['id', 'season_id', 'seasonId']);
        if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
      }
    }
    return null;
  }

  String? _tvdbEpisodeId(MediaItem item) {
    for (final key in const ['tvdb_episode_id', 'tvdbEpisodeId']) {
      final value = item.extra[key]?.toString();
      if (value != null && RegExp(r'^\d+$').hasMatch(value)) return value;
    }
    final metadata = item.extra['metadata'];
    if (metadata is Map) {
      final tvdb = metadata[providerKey];
      if (tvdb is Map) {
        final id = _firstString(tvdb, ['id', 'episode_id', 'episodeId']);
        if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
      }
    }
    return null;
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  double _titleScore(String target, String candidate) {
    if (target == candidate) return 1;
    if (target.isEmpty || candidate.isEmpty) return 0;
    if (target.contains(candidate) || candidate.contains(target)) return 0.78;
    final targetWords = target.split(' ').where((w) => w.length > 1).toSet();
    final candidateWords = candidate
        .split(' ')
        .where((w) => w.length > 1)
        .toSet();
    if (targetWords.isEmpty || candidateWords.isEmpty) return 0;
    return targetWords.intersection(candidateWords).length /
        targetWords.union(candidateWords).length;
  }

  String _cleanTitle(String title) => title
      .replaceAll(RegExp(r'^[A-Z]{2,4}\s*[\-|:]\s*'), ' ')
      .replaceAll(RegExp(r'^\s*\d+\s*[\-|.]\s*'), ' ')
      .replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _normalizeTitle(String value) => value
      .toLowerCase()
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return null;
  }

  @override
  void close() => _http.close(force: true);
}
