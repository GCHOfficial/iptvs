// Compressed + conditional guide downloads: the `Accept-Encoding: gzip` that
// `autoUncompress = false` suppressed, the per-guide body cache behind
// `If-None-Match`/`If-Modified-Since`, and the EPG contract holding still
// across a 304. Driven through a real loopback `HttpServer` so the dart:io
// header handling (which is where a conditional request can quietly go wrong)
// is the thing under test, not a mock of it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/epg_guide_cache.dart';
import 'package:iptvs/sources/epg_guides.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xmltv.dart';

/// One request the fake guide server saw.
class _Seen {
  _Seen(this.path, this.acceptEncoding, this.ifNoneMatch, this.ifModifiedSince);
  final String path;
  final String? acceptEncoding;
  final String? ifNoneMatch;
  final String? ifModifiedSince;
}

/// How the fake server should answer the next request for a path.
class _Reply {
  _Reply({
    required this.body,
    this.etag,
    this.lastModified,
    this.contentEncoding,
  });

  final List<int> body;
  final String? etag;
  final String? lastModified;
  final String? contentEncoding;
}

class _GuideServer {
  _GuideServer(this._server) {
    _server.listen((request) async {
      seen.add(
        _Seen(
          request.uri.path,
          request.headers.value(HttpHeaders.acceptEncodingHeader),
          request.headers.value(HttpHeaders.ifNoneMatchHeader),
          request.headers.value(HttpHeaders.ifModifiedSinceHeader),
        ),
      );
      final reply = replies[request.uri.path];
      if (reply == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      // A conditional request whose validator still matches is answered 304,
      // exactly as a real origin would.
      final matches =
          reply.etag != null &&
          request.headers.value(HttpHeaders.ifNoneMatchHeader) == reply.etag;
      if (matches) {
        request.response.statusCode = HttpStatus.notModified;
        request.response.headers.set(HttpHeaders.etagHeader, reply.etag!);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      if (reply.etag != null) {
        request.response.headers.set(HttpHeaders.etagHeader, reply.etag!);
      }
      if (reply.lastModified != null) {
        request.response.headers.set(
          HttpHeaders.lastModifiedHeader,
          reply.lastModified!,
        );
      }
      if (reply.contentEncoding != null) {
        request.response.headers.set(
          HttpHeaders.contentEncodingHeader,
          reply.contentEncoding!,
        );
      }
      request.response.headers.contentLength = reply.body.length;
      request.response.add(reply.body);
      await request.response.close();
    });
  }

  static Future<_GuideServer> start() async =>
      _GuideServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, _Reply> replies = {};
  final List<_Seen> seen = [];

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';

  Future<void> stop() => _server.close(force: true);
}

Uint8List _xmltv(List<String> channelIds) {
  final out = StringBuffer('<?xml version="1.0"?><tv>');
  for (final id in channelIds) {
    out.write('<channel id="$id"><display-name>$id</display-name></channel>');
  }
  for (final id in channelIds) {
    out.write(
      '<programme channel="$id" start="20260101120000 +0000" '
      'stop="20260101130000 +0000"><title>$id now</title></programme>',
    );
  }
  out.write('</tv>');
  return Uint8List.fromList(utf8.encode(out.toString()));
}

void main() {
  late _GuideServer server;
  late Directory cacheDir;
  late HttpClient client;
  late EpgGuideCache cache;

  setUp(() async {
    server = await _GuideServer.start();
    cacheDir = Directory.systemTemp.createTempSync('iptvs_guide_cache_test');
    // The real sources all set this; it is exactly what suppressed dart:io's
    // own default Accept-Encoding, so the test client must match them.
    client = HttpClient()..autoUncompress = false;
    cache = EpgGuideCache(cacheDir);
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  EpgGuideFeed feedFor(
    String path, {
    Map<String, String> map = const {'a': 'chA'},
    EpgGuideCache? withCache,
    void Function(int bytes)? onDownloaded,
  }) => xmltvGuideFeed(
    url: server.url(path),
    download: (uri, destination, {ifNoneMatch, ifModifiedSince}) =>
        downloadXmltvGuide(
          client: client,
          uri: uri,
          destination: destination,
          ifNoneMatch: ifNoneMatch,
          ifModifiedSince: ifModifiedSince,
        ),
    tvgIdToChannelId: map,
    nameToChannelIds: const {},
    openCache: () async => withCache ?? cache,
    onDownloaded: onDownloaded,
  );

  Future<List<Programme>> drain(EpgGuideFeed feed) async =>
      (await feed.open().toList()).expand((b) => b).toList();

  group('gzip', () {
    test('asks for gzip and parses a Content-Encoding: gzip body', () async {
      server.replies['/epg.xml'] = _Reply(
        body: gzip.encode(_xmltv(['a'])),
        contentEncoding: 'gzip',
        etag: '"v1"',
      );

      final got = await drain(feedFor('/epg.xml'));

      expect(got.map((p) => p.channelId), ['chA']);
      expect(server.seen.single.acceptEncoding, 'gzip');
    });

    test('parses a .xml.gz served as-is, with no Content-Encoding', () async {
      server.replies['/epg.xml.gz'] = _Reply(
        body: gzip.encode(_xmltv(['a'])),
        etag: '"v1"',
      );

      expect((await drain(feedFor('/epg.xml.gz'))).map((p) => p.channelId), [
        'chA',
      ]);
    });

    test('a server that ignores the header still works', () async {
      server.replies['/plain.xml'] = _Reply(body: _xmltv(['a']));

      expect((await drain(feedFor('/plain.xml'))).map((p) => p.channelId), [
        'chA',
      ]);
    });

    test('a body compressed twice still parses', () async {
      // A `.xml.gz` the server *also* gzips for transport. Only reachable now
      // that guide requests ask for gzip, which is why the parser takes a
      // second inflation pass.
      server.replies['/double.xml.gz'] = _Reply(
        body: gzip.encode(gzip.encode(_xmltv(['a']))),
        contentEncoding: 'gzip',
      );

      expect((await drain(feedFor('/double.xml.gz'))).map((p) => p.channelId), [
        'chA',
      ]);
    });
  });

  group('conditional GET', () {
    test('stores the ETag and sends it on the next refresh', () async {
      server.replies['/epg.xml'] = _Reply(
        body: gzip.encode(_xmltv(['a'])),
        contentEncoding: 'gzip',
        etag: '"v1"',
        lastModified: 'Thu, 01 Jan 2026 12:00:00 GMT',
      );

      await drain(feedFor('/epg.xml'));
      await drain(feedFor('/epg.xml'));

      expect(server.seen, hasLength(2));
      expect(server.seen.first.ifNoneMatch, isNull);
      expect(server.seen.last.ifNoneMatch, '"v1"');
      expect(server.seen.last.ifModifiedSince, 'Thu, 01 Jan 2026 12:00:00 GMT');
    });

    test(
      'a 304 reuses the cached body and yields the same programmes',
      () async {
        server.replies['/epg.xml'] = _Reply(
          body: gzip.encode(_xmltv(['a', 'b'])),
          contentEncoding: 'gzip',
          etag: '"v1"',
        );
        final map = {'a': 'chA', 'b': 'chB'};

        final first = await drain(feedFor('/epg.xml', map: map));
        int? reusedBytes;
        final second = await drain(
          feedFor('/epg.xml', map: map, onDownloaded: (b) => reusedBytes = b),
        );

        expect(
          second.map((p) => '${p.channelId}|${p.start}|${p.title}'),
          first.map((p) => '${p.channelId}|${p.start}|${p.title}'),
        );
        expect(second, isNotEmpty, reason: 'a 304 is never an empty guide');
        // The ingestion line reports the reused body's bytes, not zero.
        expect(reusedBytes, greaterThan(0));
        expect(
          reusedBytes,
          server.replies['/epg.xml']!.body.length,
          reason: 'stored as received, i.e. still compressed',
        );
      },
    );

    test('a missing cached body falls back to a full download', () async {
      server.replies['/epg.xml'] = _Reply(body: _xmltv(['a']), etag: '"v1"');
      await drain(feedFor('/epg.xml'));
      for (final file in cacheDir.listSync()) {
        if (file.path.endsWith('.body')) file.deleteSync();
      }

      final got = await drain(feedFor('/epg.xml'));

      expect(got.map((p) => p.channelId), ['chA']);
      expect(
        server.seen.last.ifNoneMatch,
        isNull,
        reason: 'no body means nothing to revalidate',
      );
    });

    test('a corrupt cached body falls back to a full download', () async {
      server.replies['/epg.xml'] = _Reply(body: _xmltv(['a']), etag: '"v1"');
      await drain(feedFor('/epg.xml'));
      // Truncate the body behind the sidecar's back — the length mismatch is
      // the corruption test.
      final body = cacheDir.listSync().firstWhere(
        (f) => f.path.endsWith('.body'),
      );
      File(body.path).writeAsBytesSync(const [0x1f, 0x8b, 0x00]);

      final got = await drain(feedFor('/epg.xml'));

      expect(got.map((p) => p.channelId), ['chA']);
      expect(server.seen.last.ifNoneMatch, isNull);
      expect(server.seen, hasLength(2));
    });

    test('an unhonourable 304 re-requests unconditionally rather than '
        'failing', () async {
      // A server that answers 304 to a request that carried no validator at
      // all: the cache has nothing to serve, so the feed must ask again.
      var hits = 0;
      final feed = xmltvGuideFeed(
        url: server.url('/weird.xml'),
        download: (uri, destination, {ifNoneMatch, ifModifiedSince}) async {
          hits++;
          if (hits == 1) {
            return (statusCode: 304, etag: null, lastModified: null);
          }
          await destination.writeAsBytes(_xmltv(['a']));
          return (statusCode: 200, etag: null, lastModified: null);
        },
        tvgIdToChannelId: const {'a': 'chA'},
        nameToChannelIds: const {},
        openCache: () async => cache,
      );

      expect((await drain(feed)).map((p) => p.channelId), ['chA']);
      expect(hits, 2);
    });

    test('a guide with no validators is never cached', () async {
      server.replies['/epg.xml'] = _Reply(body: _xmltv(['a']));

      await drain(feedFor('/epg.xml'));
      await drain(feedFor('/epg.xml'));

      expect(
        cacheDir.listSync(),
        isEmpty,
        reason: 'a body that can never be revalidated is pure disk cost',
      );
      expect(server.seen, hasLength(2));
    });

    test('no cache at all keeps every download unconditional', () async {
      server.replies['/epg.xml'] = _Reply(body: _xmltv(['a']), etag: '"v1"');

      await drain(feedFor('/epg.xml', withCache: null));
      final feed = xmltvGuideFeed(
        url: server.url('/epg.xml'),
        download: (uri, destination, {ifNoneMatch, ifModifiedSince}) =>
            downloadXmltvGuide(
              client: client,
              uri: uri,
              destination: destination,
              ifNoneMatch: ifNoneMatch,
              ifModifiedSince: ifModifiedSince,
            ),
        tvgIdToChannelId: const {'a': 'chA'},
        nameToChannelIds: const {},
        openCache: () async => null,
      );
      expect((await drain(feed)).map((p) => p.channelId), ['chA']);
      expect(server.seen.last.ifNoneMatch, isNull);
    });
  });

  group('multi-guide', () {
    test('one guide 304s while another is re-sent, and the merge is '
        'unchanged', () async {
      server.replies['/primary.xml'] = _Reply(
        body: gzip.encode(_xmltv(['a'])),
        contentEncoding: 'gzip',
        etag: '"primary-1"',
      );
      server.replies['/extra.xml'] = _Reply(
        body: gzip.encode(_xmltv(['a', 'b'])),
        contentEncoding: 'gzip',
      );
      final map = {'a': 'chA', 'b': 'chB'};

      Future<List<Programme>> refresh() async {
        final out = <Programme>[];
        await for (final batch in mergeEpgGuides([
          feedFor('/primary.xml', map: map),
          feedFor('/extra.xml', map: map),
        ])) {
          out.addAll(batch);
        }
        return out;
      }

      final first = await refresh();
      final second = await refresh();

      // The primary claims chA in both runs; the extra only ever contributes
      // chB. A 304 on one guide must not disturb that.
      expect(first.map((p) => p.channelId), ['chA', 'chB']);
      expect(second.map((p) => p.channelId), ['chA', 'chB']);
      final primaryHits = server.seen.where((s) => s.path == '/primary.xml');
      expect(primaryHits.last.ifNoneMatch, '"primary-1"');
      // The extra guide sends no ETag, so it is never cached and never 304s.
      expect(
        server.seen.where((s) => s.path == '/extra.xml').last.ifNoneMatch,
        isNull,
      );
    });
  });

  group('secrets', () {
    test(
      'cache file names carry neither the URL nor its credentials',
      () async {
        const user = 'alice';
        const pass = 'hunter2';
        server.replies['/xmltv.php'] = _Reply(
          body: _xmltv(['a']),
          etag: '"v1"',
        );
        final feed = xmltvGuideFeed(
          url: '${server.url('/xmltv.php')}?username=$user&password=$pass',
          download: (uri, destination, {ifNoneMatch, ifModifiedSince}) =>
              downloadXmltvGuide(
                client: client,
                uri: uri,
                destination: destination,
                ifNoneMatch: ifNoneMatch,
                ifModifiedSince: ifModifiedSince,
              ),
          tvgIdToChannelId: const {'a': 'chA'},
          nameToChannelIds: const {},
          openCache: () async => cache,
        );

        await drain(feed);

        final names = cacheDir
            .listSync()
            .map((f) => f.uri.pathSegments.last)
            .toList();
        expect(names, isNotEmpty);
        for (final name in names) {
          expect(name, matches(RegExp(r'^[0-9a-f]{64}\.(body|meta)$')));
          for (final secret in [user, pass, 'xmltv', '127.0.0.1', 'username']) {
            expect(name, isNot(contains(secret)));
          }
        }
        // The sidecar holds validators only — never the URL it belongs to.
        final meta = File(
          cacheDir.listSync().firstWhere((f) => f.path.endsWith('.meta')).path,
        ).readAsStringSync();
        for (final secret in [user, pass, 'http', '127.0.0.1']) {
          expect(meta, isNot(contains(secret)));
        }
      },
    );
  });

  group('eviction', () {
    test('the size cap evicts the least recently used body', () async {
      final body = _xmltv(['a']);
      // Room for exactly one guide body.
      final tiny = EpgGuideCache(cacheDir, maximumBytes: body.length + 16);
      server.replies['/one.xml'] = _Reply(body: body, etag: '"one"');
      server.replies['/two.xml'] = _Reply(body: body, etag: '"two"');

      await drain(feedFor('/one.xml', withCache: tiny));
      await drain(feedFor('/two.xml', withCache: tiny));

      // Both bodies together exceed the cap, so the older one is gone and its
      // guide simply downloads again — never an error.
      expect(
        cacheDir.listSync().where((f) => f.path.endsWith('.body')),
        hasLength(1),
      );
      await drain(feedFor('/one.xml', withCache: tiny));
      expect(
        server.seen.where((s) => s.path == '/one.xml').last.ifNoneMatch,
        isNull,
      );
    });

    test(
      'a body bigger than the whole cache is parsed but not cached',
      () async {
        final tiny = EpgGuideCache(cacheDir, maximumBytes: 32);
        server.replies['/big.xml'] = _Reply(body: _xmltv(['a']), etag: '"v1"');

        expect(
          (await drain(feedFor('/big.xml', withCache: tiny)))
              .map((p) => p.channelId),
          ['chA'],
        );
        expect(cacheDir.listSync(), isEmpty);
      },
    );
  });

  group('the path a real source takes', () {
    // The sources resolve the cache themselves rather than being handed one,
    // so the wiring only exists if the process-wide instance is the one they
    // reach. Everything else here injects `openCache`, which would not catch a
    // source that forgot to call `xmltvGuideFeed` at all.
    tearDown(() => debugSetEpgGuideCache(null));

    test('M3uSource asks for gzip, then revalidates its guide', () async {
      debugSetEpgGuideCache(cache);
      server.replies['/playlist.m3u'] = _Reply(
        body: utf8.encode(
          '#EXTM3U url-tvg="${server.url('/epg.xml')}"\n'
          '#EXTINF:-1 tvg-id="a",Channel A\n'
          'http://stream.example.invalid/a.ts\n',
        ),
      );
      server.replies['/epg.xml'] = _Reply(
        body: gzip.encode(_xmltv(['a'])),
        contentEncoding: 'gzip',
        etag: '"v1"',
      );

      Future<List<Programme>> refresh() async {
        final source = M3uSource(
          sourceId: 'm3u',
          playlistUrl: server.url('/playlist.m3u'),
        );
        final channels = await source.channels();
        final batches = source.epgBatched(channels);
        final out = <Programme>[];
        await for (final batch in batches!) {
          out.addAll(batch);
        }
        expect(source.lastEpgCompressedBytes, greaterThan(0));
        return out;
      }

      expect((await refresh()).map((p) => p.title), ['a now']);
      expect((await refresh()).map((p) => p.title), ['a now']);

      final guideHits = server.seen.where((s) => s.path == '/epg.xml').toList();
      expect(guideHits, hasLength(2));
      expect(guideHits.every((s) => s.acceptEncoding == 'gzip'), isTrue);
      expect(guideHits.first.ifNoneMatch, isNull);
      expect(guideHits.last.ifNoneMatch, '"v1"');
    });

    test('an unusable cache directory still downloads the guide', () async {
      // A "directory" that is really a file: `slotFor` must hand back null and
      // the feed must fall through to its own scratch file.
      final blocker = File('${cacheDir.path}/blocked')..writeAsStringSync('x');
      debugSetEpgGuideCache(EpgGuideCache(Directory(blocker.path)));
      server.replies['/epg.xml'] = _Reply(body: _xmltv(['a']), etag: '"v1"');

      final feed = xmltvGuideFeed(
        url: server.url('/epg.xml'),
        download: (uri, destination, {ifNoneMatch, ifModifiedSince}) =>
            downloadXmltvGuide(
              client: client,
              uri: uri,
              destination: destination,
              ifNoneMatch: ifNoneMatch,
              ifModifiedSince: ifModifiedSince,
            ),
        tvgIdToChannelId: const {'a': 'chA'},
        nameToChannelIds: const {},
      );

      expect((await drain(feed)).map((p) => p.channelId), ['chA']);
    });
  });

  group('workload limits', () {
    test('the decoded ceiling still bounds a gzip bomb', () async {
      final bomb = File('${cacheDir.path}/bomb.gz')
        ..writeAsBytesSync(gzip.encode(Uint8List(16 * 1024 * 1024)));

      await expectLater(
        parseXmltvFileBatched(
          bomb,
          const {'a': 'chA'},
          // Production passes kEpgWorkload.maximumDecodedBytes here.
          maxDecodedBytes: 1024 * 1024,
        ).toList(),
        throwsA(
          predicate(
            (Object? e) => '$e'.contains('over the') && '$e'.contains('limit'),
          ),
        ),
      );
    });
  });
}
