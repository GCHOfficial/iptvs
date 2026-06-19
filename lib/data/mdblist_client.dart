import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../sources/source.dart';
import 'metadata_provider.dart';

class MdblistClient implements MetadataProvider {
  final String apiKey;
  final HttpClient _http;

  MdblistClient({required this.apiKey, HttpClient? http})
    : _http = http ?? HttpClient();

  static const providerKey = 'mdblist';
  static const _base = 'https://api.mdblist.com';

  @override
  String get provider => providerKey;

  @override
  String get authMode => 'api_key';

  @override
  bool get ratingsOnly => true;

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    final id = _providerId(item);
    if (id == null) return null;
    final mediaType = item.kind == ContentKind.series ? 'show' : 'movie';
    final uri = Uri.parse(
      '$_base/${id.provider}/$mediaType/${Uri.encodeComponent(id.value)}/',
    ).replace(queryParameters: {'apikey': apiKey});
    final data = await _get(uri);
    if (data is! Map) return null;
    final map = Map<String, dynamic>.from(data);
    return ExternalMetadata(
      provider: providerKey,
      providerKey: _firstString(map, ['id', 'imdb_id', 'title']) ?? id.value,
      rating: _rating(map),
      payload: map,
      refreshedAt: DateTime.now(),
    );
  }

  Future<dynamic> _get(Uri uri) async {
    final request = await _http.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('MDBList HTTP ${response.statusCode}');
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

  ({String provider, String value})? _providerId(MediaItem item) {
    final imdb = _firstString(item.extra, ['imdb_id', 'imdbId']);
    if (imdb != null) return (provider: 'imdb', value: imdb);
    final metadata = item.extra['metadata'];
    if (metadata is Map) {
      for (final provider in ['tmdb', 'tvdb']) {
        final payload = metadata[provider];
        if (payload is Map) {
          final imdbFromPayload = _firstString(payload, ['imdb_id', 'imdbId']);
          if (imdbFromPayload != null) {
            return (provider: 'imdb', value: imdbFromPayload);
          }
          final id = _firstString(payload, ['id', 'tvdb_id', 'tvdbId']);
          if (id != null && RegExp(r'^\d+$').hasMatch(id)) {
            return (provider: provider, value: id);
          }
        }
      }
    }
    final direct = item.providerId;
    if (direct != null && RegExp(r'^\d+$').hasMatch(direct)) {
      return (provider: 'tmdb', value: direct);
    }
    return null;
  }

  double? _rating(Map<String, dynamic> map) {
    final score = _readDouble(map['score']);
    if (score != null) return score > 10 ? score / 10 : score;
    final ratings = map['ratings'];
    if (ratings is List) {
      for (final row in ratings.whereType<Map>()) {
        final rating = _readDouble(
          row['value'] ?? row['rating'] ?? row['score'],
        );
        if (rating != null) return rating > 10 ? rating / 10 : rating;
      }
    }
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

  double? _readDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value == null) return null;
    return double.tryParse(value.toString());
  }

  @override
  void close() => _http.close(force: true);
}
