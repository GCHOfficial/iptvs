import 'dart:convert';
import 'dart:io';

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
    final cmd = channel.extra['cmd']?.toString();
    if (cmd == null || cmd.isEmpty) {
      throw StalkerException('Channel "${channel.name}" has no cmd to resolve');
    }
    final r = await _call({
      'type': 'itv',
      'action': 'create_link',
      'cmd': cmd,
      'forced_storage': '0',
      'disable_ad': '0',
    });
    final js = r['js'];
    final raw = (js is Map && js['cmd'] is String) ? js['cmd'] as String : null;
    if (raw == null) throw StalkerException('create_link returned no cmd');
    return StreamInfo(
      url: _stripStreamPrefix(raw),
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
        out.add(Programme(
          channelId: '$chId',
          start: start,
          stop: stop,
          title: '${m['name'] ?? ''}',
          description: m['descr']?.toString(),
        ));
      }
    });
    return out;
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
    final r = await _call({'type': 'itv', 'action': 'get_all_channels'});
    final js = r['js'];
    final list = (js is Map && js['data'] is List)
        ? js['data'] as List
        : (js is List ? js : const []);
    return list.map((e) => _mapChannel(Map<String, dynamic>.from(e))).toList();
  }

  Channel _mapChannel(Map<String, dynamic> ch) => Channel(
        id: '${ch['id']}',
        name: '${ch['name']}',
        number: int.tryParse('${ch['number']}'),
        logo: (ch['logo'] is String && (ch['logo'] as String).isNotEmpty)
            ? ch['logo'] as String
            : null,
        categoryId: ch['tv_genre_id'] != null ? '${ch['tv_genre_id']}' : null,
        extra: {'cmd': ch['cmd']},
      );

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
          return candidate;
        }
      } on StalkerException catch (e) {
        last = e;
      } catch (e) {
        last = StalkerException(e.toString());
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
    await _call({
      'type': 'stb',
      'action': 'get_profile',
      'hd': '1',
      'num_banks': '2',
      'stb_type': profile.model,
      'image_version': '218',
      'video_out': 'hdmi',
      // Strict portals validate these: device_id = SHA1(uppercase MAC),
      // device_id2 = same, signature = SHA256(...). Add package:crypto then.
      'device_id': '',
      'device_id2': '',
      'signature': '',
      'auth_second_step': '0',
      'hw_version': '1.7-BD-00',
      'not_valid': '0',
      'timestamp': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'api_signature': '262',
      'prehash': '',
    });
  }

  /// Calls the resolved endpoint, re-handshaking once if the token expired.
  Future<Map<String, dynamic>> _call(Map<String, String> params,
      {bool retry = true}) async {
    final ep = await _resolveEndpoint();
    final r = await _request(ep, params);
    if (retry && r['js'] == null) {
      // Stale token → re-auth and try once more.
      _token = null;
      _endpoint = null;
      await _resolveEndpoint();
      await _getProfile();
      return _call(params, retry: false);
    }
    return r;
  }

  Future<Map<String, dynamic>> _request(
      String endpoint, Map<String, String> params) async {
    final uri = Uri.parse(endpoint)
        .replace(queryParameters: {...params, 'JsHttpRequest': '1-xml'});
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
    if (resp.statusCode != 200) {
      throw StalkerException('HTTP ${resp.statusCode} from $endpoint');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw StalkerException('Non-JSON response (wrong endpoint?)');
    }
    if (decoded is! Map) throw StalkerException('Unexpected response shape');
    return Map<String, dynamic>.from(decoded);
  }

  String _stripStreamPrefix(String cmd) {
    var s = cmd.trim();
    for (final p in ['ffmpeg ', 'ffrt3 ', 'ffrt2 ', 'ffrt ', 'auto ']) {
      if (s.startsWith(p)) {
        s = s.substring(p.length).trim();
        break;
      }
    }
    final idx = s.indexOf('http');
    if (idx > 0) s = s.substring(idx);
    return s;
  }
}