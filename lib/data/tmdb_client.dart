import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../sources/source.dart';
import 'metadata_config.dart';
import 'metadata_provider.dart';

class TmdbClient implements MetadataProvider {
  final String apiKey;
  final HttpClient _http;

  TmdbClient({required String apiKey, HttpClient? http})
    : apiKey = MetadataConfig.normalizeTmdbCredential(apiKey),
      _http = http ?? HttpClient();

  static const providerKey = 'tmdb';
  static const _base = 'https://api.themoviedb.org/3';
  static const _imageBase = 'https://image.tmdb.org/t/p/w500';
  static const _backdropBase = 'https://image.tmdb.org/t/p/w1280';

  bool get usesBearerToken =>
      apiKey.startsWith('eyJ') || apiKey.split('.').length == 3;

  @override
  String get provider => providerKey;

  @override
  String get authMode => usesBearerToken ? 'bearer' : 'api_key';

  @override
  bool get ratingsOnly => false;

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    final type = item.kind == ContentKind.movie ? 'movie' : 'tv';
    final directId = _tmdbId(item);
    if (directId != null) {
      final details = await _get('/$type/$directId');
      if (details is Map) {
        return _mapDetails(Map<String, dynamic>.from(details), item, type);
      }
    }

    final title = _cleanTitle(item.title);
    if (title.isEmpty) return null;
    final results = await _get('/search/$type', {
      'query': title,
      if (item.year != null && item.year!.length >= 4)
        type == 'movie' ? 'year' : 'first_air_date_year': item.year!,
    });
    final list = results is Map && results['results'] is List
        ? results['results'] as List
        : const [];
    final best = _bestSearchResult(list, item, type);
    if (best == null) return null;
    return _mapDetails(best, item, type);
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async {
    final seriesId = _tmdbId(series);
    final seasonNumber = season.seasonNumber;
    if (seriesId == null || seasonNumber == null) return null;
    final details = await _get('/tv/$seriesId/season/$seasonNumber');
    if (details is! Map) return null;
    return _mapSeasonDetails(
      Map<String, dynamic>.from(details),
      series,
      season,
    );
  }

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async {
    final seriesId = _seriesTmdbId(season);
    final seasonNumber = episode.seasonNumber ?? season.seasonNumber;
    final episodeNumber = episode.episodeNumber;
    if (seriesId == null || seasonNumber == null || episodeNumber == null) {
      return null;
    }
    final details = await _get(
      '/tv/$seriesId/season/$seasonNumber/episode/$episodeNumber',
    );
    if (details is! Map) return null;
    return _mapEpisodeDetails(
      Map<String, dynamic>.from(details),
      season,
      episode,
      seriesId,
    );
  }

  Future<dynamic> _get(String path, [Map<String, String> query = const {}]) {
    final uri = Uri.parse('$_base$path').replace(
      queryParameters: {
        if (!usesBearerToken) 'api_key': apiKey,
        'language': 'en-US',
        ...query,
      },
    );
    return _download(
      uri,
    ).then((bytes) => jsonDecode(utf8.decode(bytes, allowMalformed: true)));
  }

  Future<Uint8List> _download(Uri uri) async {
    final request = await _http.getUrl(uri);
    if (usesBearerToken) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('TMDB HTTP ${response.statusCode} auth=$authMode');
    }
    final builder = BytesBuilder();
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  ExternalMetadata _mapDetails(
    Map<String, dynamic> data,
    MediaItem item,
    String type,
  ) {
    final id = data['id']?.toString() ?? '';
    final title = _firstString(data, [
      type == 'movie' ? 'title' : 'name',
      'original_title',
      'original_name',
    ]);
    final date = _firstString(data, [
      type == 'movie' ? 'release_date' : 'first_air_date',
    ]);
    final posterPath = _firstString(data, ['poster_path']);
    final backdropPath = _firstString(data, ['backdrop_path']);
    return ExternalMetadata(
      provider: providerKey,
      providerKey: id,
      title: title,
      overview: _firstString(data, ['overview']),
      poster: posterPath == null ? null : '$_imageBase$posterPath',
      backdrop: backdropPath == null ? null : '$_backdropBase$backdropPath',
      year: date != null && date.length >= 4 ? date.substring(0, 4) : item.year,
      rating: _readDouble(data['vote_average']),
      payload: data,
      refreshedAt: DateTime.now(),
    );
  }

  ExternalMetadata _mapSeasonDetails(
    Map<String, dynamic> data,
    MediaItem series,
    MediaItem season,
  ) {
    final seriesId = _tmdbId(series) ?? '';
    final seasonNumber = season.seasonNumber;
    final id = data['id']?.toString() ?? '$seriesId:s$seasonNumber';
    final posterPath = _firstString(data, ['poster_path']);
    final airDate = _firstString(data, ['air_date']);
    final title = _firstString(data, ['name']) ?? season.title;
    return ExternalMetadata(
      provider: providerKey,
      providerKey: id,
      title: title,
      overview: _firstString(data, ['overview']),
      poster: posterPath == null ? null : '$_imageBase$posterPath',
      year: airDate != null && airDate.length >= 4
          ? airDate.substring(0, 4)
          : season.year,
      payload: {
        ...data,
        'series_tmdb_id': seriesId,
        if (seasonNumber != null) ...{'season_number': seasonNumber},
      },
      refreshedAt: DateTime.now(),
    );
  }

  ExternalMetadata _mapEpisodeDetails(
    Map<String, dynamic> data,
    MediaItem season,
    MediaItem episode,
    String seriesId,
  ) {
    final id = data['id']?.toString() ?? episode.id;
    final stillPath = _firstString(data, ['still_path']);
    final airDate = _firstString(data, ['air_date']);
    return ExternalMetadata(
      provider: providerKey,
      providerKey: id,
      title: _firstString(data, ['name']) ?? episode.title,
      overview: _firstString(data, ['overview']),
      poster: stillPath == null ? null : '$_imageBase$stillPath',
      year: airDate != null && airDate.length >= 4
          ? airDate.substring(0, 4)
          : episode.year,
      rating: _readDouble(data['vote_average']),
      payload: {
        ...data,
        'series_tmdb_id': seriesId,
        'season_metadata_id': season.providerId,
      },
      refreshedAt: DateTime.now(),
    );
  }

  Map<String, dynamic>? _bestSearchResult(
    List<dynamic> results,
    MediaItem item,
    String type,
  ) {
    final targetTitle = _normalizeTitle(_cleanTitle(item.title));
    final targetYear = _year(item.year);
    var bestScore = 0.0;
    Map<String, dynamic>? best;
    for (final entry in results.whereType<Map>()) {
      final row = Map<String, dynamic>.from(entry);
      final candidateTitle = _normalizeTitle(
        _firstString(row, [
              type == 'movie' ? 'title' : 'name',
              'original_title',
              'original_name',
            ]) ??
            '',
      );
      if (candidateTitle.isEmpty) continue;
      var score = _titleScore(targetTitle, candidateTitle);
      final candidateYear = _year(
        _firstString(row, [
          type == 'movie' ? 'release_date' : 'first_air_date',
        ]),
      );
      if (targetYear != null && candidateYear != null) {
        if (targetYear == candidateYear) {
          score += 0.25;
        } else if ((targetYear - candidateYear).abs() == 1) {
          score += 0.08;
        } else {
          score -= 0.2;
        }
      }
      final popularity = _readDouble(row['popularity']) ?? 0;
      score += popularity.clamp(0, 100) / 1000;
      if (score > bestScore) {
        bestScore = score;
        best = row;
      }
    }
    return bestScore >= 0.62 ? best : null;
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
    final shared = targetWords.intersection(candidateWords).length;
    final total = targetWords.union(candidateWords).length;
    return shared / total;
  }

  String? _tmdbId(MediaItem item) {
    final direct = item.providerId;
    if (direct != null && RegExp(r'^\d+$').hasMatch(direct)) return direct;
    for (final key in ['tmdb_id', 'tmdbId']) {
      final value = item.extra[key]?.toString();
      if (value != null && RegExp(r'^\d+$').hasMatch(value)) return value;
    }
    return null;
  }

  String? _seriesTmdbId(MediaItem season) {
    final direct = _firstString(season.extra, ['series_tmdb_id', 'tmdb_id']);
    if (direct != null && RegExp(r'^\d+$').hasMatch(direct)) return direct;
    final metadata = season.extra['metadata'];
    if (metadata is Map) {
      final tmdb = metadata[providerKey];
      if (tmdb is Map) {
        final id = _firstString(tmdb, ['series_tmdb_id']);
        if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
      }
    }
    final details = season.extra['details'];
    if (details is Map) {
      final id = _firstString(details, ['series_tmdb_id', 'tmdb_id']);
      if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
    }
    return null;
  }

  String _cleanTitle(String title) => title
      .replaceAll(RegExp(r'^[A-Z]{2,4}\s*[\-|:]\s*'), ' ')
      .replaceAll(RegExp(r'^\s*\d+\s*[\-|.]\s*'), ' ')
      .replaceAll(RegExp(r'\[[^\]]+\]|\([^)]+\)'), ' ')
      .replaceAll(
        RegExp(
          r'\b(4k|uhd|fhd|hd|sd|hdr|hdr10|dv|remux|bluray|webdl|webrip|x264|x265|h264|h265|hevc|aac|dts)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _normalizeTitle(String value) => value
      .toLowerCase()
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  int? _year(String? value) {
    if (value == null || value.length < 4) return null;
    return int.tryParse(value.substring(0, 4));
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

  double? _readDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value == null) return null;
    return double.tryParse(value.toString());
  }

  @override
  void close() => _http.close(force: true);
}
