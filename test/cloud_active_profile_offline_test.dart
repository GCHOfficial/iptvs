// CloudSync.activeProfileId on an offline device.
//
// IPTVS-H: HomeShell fires `_startCloudAutoSync` unawaited from every
// `_loadActive`, and `activeProfileId` let a transport failure (failed host
// lookup, wrapped by package:http in a ClientException) escape — an unhandled
// async error for a question the cached profile id answers. The server here is
// a closed local port, so the failure is a real connection refusal rather than
// a mock of one.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int closedPort;

  setUpAll(() async {
    // flutter_test answers every HttpClient request with a canned 400, which
    // postgrest reads as the server answering. Restore the real client so the
    // request meets an actual refused connection.
    HttpOverrides.global = null;
    // Bind and release a port so nothing is listening on it.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    closedPort = socket.port;
    await socket.close();
  });

  Future<SupabaseClient> pairedClientAt(String url) async {
    final client = SupabaseClient(url, 'anon-key-for-tests');
    final expiresAt =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    await client.auth.setInitialSession(
      jsonEncode({
        'access_token': 'test-access-token',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': expiresAt,
        'refresh_token': 'test-refresh-token',
        'user': {
          'id': '00000000-0000-4000-8000-000000000001',
          'aud': 'authenticated',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'created_at': '2026-11-01T00:00:00Z',
        },
      }),
    );
    return client;
  }

  test('an unreachable server falls back to the cached profile id', () async {
    FlutterSecureStorage.setMockInitialValues({
      'cloud_profile_id': 'cached-profile',
    });
    final client = await pairedClientAt('http://127.0.0.1:$closedPort');
    addTearDown(client.dispose);
    final sync = CloudSync(client: client);
    expect(sync.deviceId, isNotNull, reason: 'the lookup path needs a session');

    expect(await sync.activeProfileId(), 'cached-profile');
  });

  test('and returns null, not an error, when nothing was cached', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final client = await pairedClientAt('http://127.0.0.1:$closedPort');
    addTearDown(client.dispose);

    expect(await CloudSync(client: client).activeProfileId(), isNull);
  });

  test('a server that answers with an error is still an error', () async {
    // The fallback is for "the server never answered", never for "the server
    // said no" — callers such as the cloud screen must see a refusal.
    FlutterSecureStorage.setMockInitialValues({
      'cloud_profile_id': 'cached-profile',
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'message': 'denied', 'code': '42501'}))
        ..close();
    });
    final client = await pairedClientAt('http://127.0.0.1:${server.port}');
    addTearDown(client.dispose);

    await expectLater(
      CloudSync(client: client).activeProfileId(),
      throwsA(isA<PostgrestException>()),
    );
  });
}
