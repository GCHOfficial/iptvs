// The LAN diagnostics share: the pure host/label/Host-header helpers, and the
// real socket behaviour of the throwaway server — what it serves on the one
// token path, and the four ways it refuses everything else (wrong path, wrong
// method, non-IP `Host:`, and the window simply closing).
//
// Requests go out over a raw `Socket` rather than through `HttpClient` because
// `HttpClient` derives `Host:` from the URI it was given, and the rebinding
// defence is precisely a test *of* that header — writing the request line by
// hand is the only way to put an attacker's hostname on the wire against a
// loopback connection.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/diagnostics_share_server.dart';
import 'package:iptvs/player/resource_counters.dart';

class _RawResponse {
  final int status;
  final Map<String, String> headers;
  final String body;

  const _RawResponse(this.status, this.headers, this.body);
}

/// One request, written by hand, read to EOF (`Connection: close` makes the
/// server hang up, which is what ends the read).
Future<_RawResponse> _request(
  int port,
  String path, {
  String method = 'GET',
  String? hostHeader,
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final host = hostHeader ?? '127.0.0.1:$port';
  socket.write(
    '$method $path HTTP/1.1\r\n'
    'Host: $host\r\n'
    'Connection: close\r\n'
    '\r\n',
  );
  await socket.flush();
  final chunks = <int>[];
  await socket.forEach(chunks.addAll);
  socket.destroy();

  final text = utf8.decode(chunks, allowMalformed: true);
  final split = text.indexOf('\r\n\r\n');
  final head = split < 0 ? text : text.substring(0, split);
  final body = split < 0 ? '' : text.substring(split + 4);
  final lines = head.split('\r\n');
  final status = int.parse(lines.first.split(' ')[1]);
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return _RawResponse(status, headers, body);
}

void main() {
  late DiagnosticsShareServer server;

  setUp(() {
    ResourceCounters.resetForTest();
    server = DiagnosticsShareServer();
  });

  tearDown(() async {
    await server.stop();
  });

  group('rankShareHosts', () {
    test('drops loopback and link-local', () {
      expect(
        rankShareHosts([
          '127.0.0.1',
          '127.1.2.3',
          '169.254.10.20',
          '192.168.1.42',
        ]),
        ['192.168.1.42'],
      );
    });

    test('private space ranks ahead of a public address', () {
      expect(
        rankShareHosts([
          '203.0.113.9',
          '192.168.1.42',
          '8.8.8.8',
          '10.0.0.5',
          '172.16.3.4',
        ]),
        ['192.168.1.42', '10.0.0.5', '172.16.3.4', '203.0.113.9', '8.8.8.8'],
      );
    });

    test('172.15/172.32 are not private, 172.16-31 are', () {
      expect(rankShareHosts(['172.15.0.1', '172.31.0.1']), [
        '172.31.0.1',
        '172.15.0.1',
      ]);
      expect(rankShareHosts(['172.32.0.1', '172.16.0.1']), [
        '172.16.0.1',
        '172.32.0.1',
      ]);
    });

    test('incoming order is the tie-break within a rank', () {
      expect(rankShareHosts(['192.168.9.9', '10.1.1.1', '192.168.1.1']), [
        '192.168.9.9',
        '10.1.1.1',
        '192.168.1.1',
      ]);
    });

    test('duplicates collapse to the first occurrence', () {
      expect(rankShareHosts(['10.0.0.5', '192.168.1.1', '10.0.0.5']), [
        '10.0.0.5',
        '192.168.1.1',
      ]);
    });

    test('anything that is not a dotted quad is dropped', () {
      expect(
        rankShareHosts(['', 'fe80::1', '192.168.1', '192.168.1.256', 'nope']),
        isEmpty,
      );
    });
  });

  group('shareInterfaceLabel', () {
    test('wireless names', () {
      expect(shareInterfaceLabel('wlan0'), 'Wi-Fi');
      expect(shareInterfaceLabel('wlp2s0'), 'Wi-Fi');
      expect(shareInterfaceLabel('Wi-Fi'), 'Wi-Fi');
      expect(shareInterfaceLabel('Wi-Fi 2'), 'Wi-Fi');
    });

    test('wired names', () {
      expect(shareInterfaceLabel('eth0'), 'Ethernet');
      expect(shareInterfaceLabel('enp0s3'), 'Ethernet');
      expect(shareInterfaceLabel('en0'), 'Ethernet');
      expect(shareInterfaceLabel('Ethernet 2'), 'Ethernet');
    });

    test('an unknown name is returned verbatim', () {
      expect(shareInterfaceLabel('usb0'), 'usb0');
      expect(shareInterfaceLabel('tun0'), 'tun0');
      expect(shareInterfaceLabel('docker0'), 'docker0');
    });
  });

  group('isIpLiteralHost', () {
    test('IP literals and localhost pass', () {
      expect(isIpLiteralHost('192.168.1.5'), isTrue);
      expect(isIpLiteralHost('192.168.1.5:8080'), isTrue);
      expect(isIpLiteralHost('127.0.0.1'), isTrue);
      expect(isIpLiteralHost('localhost'), isTrue);
      expect(isIpLiteralHost('localhost:1234'), isTrue);
      expect(isIpLiteralHost('[::1]:80'), isTrue);
      expect(isIpLiteralHost('[fe80::1]'), isTrue);
    });

    test('names, junk and absence fail closed', () {
      expect(isIpLiteralHost('evil.example.com'), isFalse);
      expect(isIpLiteralHost('foo.local:8080'), isFalse);
      expect(isIpLiteralHost('192.168.1.5.evil.example.com'), isFalse);
      expect(isIpLiteralHost('192.168.1.5:notaport'), isFalse);
      expect(isIpLiteralHost('[::1'), isFalse);
      expect(isIpLiteralHost(''), isFalse);
      expect(isIpLiteralHost('   '), isFalse);
      expect(isIpLiteralHost(null), isFalse);
    });
  });

  group('serving', () {
    const body = 'iptvs diagnostics\nentries=2\n[share] hello';

    test('serves the snapshot on the token path', () async {
      final handle = await server.start(body);
      expect(server.isRunning, isTrue);
      expect(handle.token, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(handle.port, greaterThan(0));
      expect(
        handle.expiresAt.isAfter(DateTime.now()),
        isTrue,
        reason: 'the share must still be in its window right after start',
      );

      final response = await _request(handle.port, '/${handle.token}');
      expect(response.status, 200);
      expect(response.body, body);
      expect(response.headers['cache-control'], 'no-store');
      expect(response.headers['x-content-type-options'], 'nosniff');
      expect(response.headers['referrer-policy'], 'no-referrer');
      expect(response.headers['content-type'], contains('text/plain'));
      expect(
        response.headers.containsKey('access-control-allow-origin'),
        isFalse,
        reason: 'no CORS header of any kind, deliberately',
      );
    });

    test('HEAD answers the headers with no body', () async {
      final handle = await server.start(body);
      final response = await _request(
        handle.port,
        '/${handle.token}',
        method: 'HEAD',
      );
      expect(response.status, 200);
      expect(response.body, isEmpty);
      expect(
        response.headers['content-length'],
        utf8.encode(body).length.toString(),
      );
    });

    test('404s every other path and method, with no body', () async {
      final handle = await server.start(body);
      final token = handle.token;
      // Same length, one hex character different: the near miss a scanner that
      // learned the shape would try.
      final lastChar = token[token.length - 1];
      final nearMiss =
          token.substring(0, token.length - 1) + (lastChar == '0' ? '1' : '0');
      expect(nearMiss.length, token.length);
      expect(nearMiss, isNot(token));

      for (final path in ['/', '/other', '/${token}x', '/$nearMiss']) {
        final response = await _request(handle.port, path);
        expect(response.status, 404, reason: 'GET $path');
        expect(response.body, isEmpty, reason: 'GET $path');
      }

      final posted = await _request(
        handle.port,
        '/$token',
        method: 'POST',
      );
      expect(posted.status, 404);
      expect(posted.body, isEmpty);

      final options = await _request(
        handle.port,
        '/$token',
        method: 'OPTIONS',
      );
      expect(options.status, 404);
      expect(options.body, isEmpty);
    });

    test('refuses a Host header that is not an IP literal', () async {
      final handle = await server.start(body);
      final response = await _request(
        handle.port,
        '/${handle.token}',
        hostHeader: 'evil.example.com',
      );
      expect(response.status, 403);
      expect(response.body, isEmpty);
    });

    test('allows several reads inside the window', () async {
      final handle = await server.start(body);
      for (var i = 0; i < 3; i++) {
        final response = await _request(handle.port, '/${handle.token}');
        expect(response.status, 200, reason: 'read ${i + 1}');
        expect(response.body, body, reason: 'read ${i + 1}');
      }
    });

    test('stop() closes the port and clears the handle', () async {
      final handle = await server.start(body);
      final port = handle.port;
      await server.stop();

      expect(server.isRunning, isFalse);
      expect(server.handle, isNull);
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
    });

    test('stops itself when the lifetime expires', () async {
      await server.start(body, lifetime: const Duration(milliseconds: 150));
      expect(server.isRunning, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(server.isRunning, isFalse);
      expect(server.handle, isNull);
    });

    test('a lifetime over the ceiling is clamped to maxLifetime', () async {
      final before = DateTime.now();
      final handle = await server.start(
        body,
        lifetime: const Duration(hours: 1),
      );
      // Measured from just before start(), so the window is maxLifetime plus
      // however long the bind took — a second of slack, not an hour of it.
      final window = handle.expiresAt.difference(before);
      expect(
        window,
        lessThanOrEqualTo(
          DiagnosticsShareServer.maxLifetime + const Duration(seconds: 1),
        ),
      );
      expect(
        window,
        greaterThanOrEqualTo(DiagnosticsShareServer.maxLifetime),
      );
    });

    test('the resource counter balances across start/stop/stop', () async {
      expect(ResourceCounters.diagnosticsShareServers, 0);
      await server.start(body);
      expect(ResourceCounters.diagnosticsShareServers, 1);
      await server.stop();
      expect(ResourceCounters.diagnosticsShareServers, 0);
      // A redundant stop races the expiry timer in the real app; it must not
      // drive the counter negative.
      await server.stop();
      expect(ResourceCounters.diagnosticsShareServers, 0);
      expect(
        (await ResourceCounters.snapshot())['diagnosticsShareServers'],
        0,
      );
    });
  });
}
