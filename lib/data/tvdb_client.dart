import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../sources/source.dart';
import 'metadata_provider.dart';

class TvdbClient implements MetadataProvider {
  final String apiKey;
  final String pin;
  final HttpClient _http;
  String? _token;

  TvdbClient({required this.apiKey, this.pin = '', HttpClient? http})
    : _http = http ?? HttpClient();

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

  Future<String> _bearerToken() async {
    final existing = _token;
    if (existing != null) return existing;
    final uri = Uri.parse('$_base/login');
    final request = await _http.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({'apikey': apiKey, if (pin.isNotEmpty) 'pin': pin}),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('TVDB HTTP ${response.statusCode} auth=login');
    }
    final body = jsonDecode(
      utf8.decode(await _readBytes(response), allowMalformed: true),
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
    final request = await _http.getUrl(uri);
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${await _bearerToken()}',
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('TVDB HTTP ${response.statusCode} path=$path');
    }
    return jsonDecode(
      utf8.decode(await _readBytes(response), allowMalformed: true),
    );
  }

  Future<Uint8List> _readBytes(HttpClientResponse response) async {
    final builder = BytesBuilder();
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
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
