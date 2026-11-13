// The opt-in "live cut" test channels (tool/live_cut_server.py), gated by the
// compile-time `IPTVS_LIVE_CUT_URL` define (lib/sources/demo_source.dart
// kLiveCutServerUrl). `flutter test` never sets that define, so the first
// group pins the shipped default: with no base URL, DemoSource does not
// surface the category or channels at all. The rest use the package-private
// `liveCutBaseUrl` constructor seam (the same role the define plays in a real
// build) against a local loopback `HttpServer`, so the resolve/re-resolve
// path is driven through real dart:io rather than mocked.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/demo_source.dart';

void main() {
  test('kLiveCutServerUrl is empty by default (no define passed)', () {
    // This is the shipped-build invariant: every real APK/exe is built
    // without --dart-define=IPTVS_LIVE_CUT_URL, so the channels must not
    // exist unless a test (or the emulator CI build) opts in explicitly.
    expect(kLiveCutServerUrl, isEmpty);
  });

  group('with no live-cut base URL (the default)', () {
    late DemoSource source;
    setUp(() => source = DemoSource());

    test('no "Live cut test" category and no live-cut channels', () async {
      final categories = await source.categories();
      expect(categories.any((c) => c.id == 'live-cut-test'), isFalse);

      final channels = await source.channels();
      expect(channels.any((c) => c.id == 'live_cut_rotating'), isFalse);
      expect(channels.any((c) => c.id == 'live_cut_stable'), isFalse);
    });
  });

  group('with a live-cut base URL configured', () {
    late HttpServer server;
    late int resolveCalls;
    late String nextResolveBody;
    late List<String> requestedPaths;
    late DemoSource source;

    setUp(() async {
      resolveCalls = 0;
      nextResolveBody = 'http://127.0.0.1:0/live.ts?token=1';
      requestedPaths = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requestedPaths.add(request.uri.path);
        if (request.uri.path == '/resolve') {
          resolveCalls++;
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.text;
          request.response.write(nextResolveBody);
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      source = DemoSource(liveCutBaseUrl: 'http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('adds the "Live cut test" category with both channels', () async {
      final categories = await source.categories();
      expect(categories.map((c) => c.id), contains('live-cut-test'));

      final channels = await source.channels(categoryId: 'live-cut-test');
      expect(channels.map((c) => c.id), [
        'live_cut_rotating',
        'live_cut_stable',
      ]);
      expect(channels.every((c) => c.extra['isLive'] == true), isTrue);
    });

    test(
      'resolving the rotating channel fetches /resolve and returns its body '
      'as the stream URL, fresh on every call',
      () async {
        final channels = await source.channels(categoryId: 'live-cut-test');
        final rotating = channels.firstWhere(
          (c) => c.id == 'live_cut_rotating',
        );

        nextResolveBody =
            'http://127.0.0.1:${server.port}/live.ts?token=1';
        final first = await source.resolve(rotating);
        expect(first.url, nextResolveBody);
        expect(first.isLive, isTrue);

        // A second resolve — standing in for the handoff's own re-resolve —
        // must hit the server again and can get a different token. Nothing
        // in DemoSource may cache the first StreamInfo across calls, or the
        // re-resolve path this channel exists to exercise would be dead.
        nextResolveBody =
            'http://127.0.0.1:${server.port}/live.ts?token=2';
        final second = await source.resolve(rotating);
        expect(second.url, nextResolveBody);
        expect(resolveCalls, 2);
        expect(requestedPaths.where((p) => p == '/resolve').length, 2);
      },
    );

    test(
      'resolving the stable channel never calls /resolve and always returns '
      'the same /stable.ts URL',
      () async {
        final channels = await source.channels(categoryId: 'live-cut-test');
        final stable = channels.firstWhere((c) => c.id == 'live_cut_stable');

        final first = await source.resolve(stable);
        final second = await source.resolve(stable);

        expect(first.url, 'http://127.0.0.1:${server.port}/stable.ts');
        expect(second.url, first.url);
        expect(first.isLive, isTrue);
        expect(resolveCalls, 0);
      },
    );

    test('a non-200 /resolve response surfaces as a thrown error', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      source = DemoSource(liveCutBaseUrl: 'http://127.0.0.1:${server.port}');

      final channels = await source.channels(categoryId: 'live-cut-test');
      final rotating = channels.firstWhere(
        (c) => c.id == 'live_cut_rotating',
      );
      await expectLater(source.resolve(rotating), throwsStateError);
    });
  });
}
