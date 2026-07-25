import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_crypto.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/secret_keys.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('cloudRowToConfig', () {
    test('maps a well-formed Xtream row to a SourceConfig', () {
      final config = cloudRowToConfig({
        'id': 'abc-123',
        'kind': 'xtream',
        'label': 'My provider',
        'fields': {
          'host': 'http://host:8080',
          'username': 'u',
          'password': 'p',
        },
      });

      expect(config.id, 'abc-123');
      expect(config.kind, SourceKind.xtream);
      expect(config.label, 'My provider');
      expect(config.fields['host'], 'http://host:8080');
      // The mapped config builds a live Source without throwing.
      expect(config.build, returnsNormally);
    });

    test('coerces non-string field values to strings', () {
      final config = cloudRowToConfig({
        'id': 'id1',
        'kind': 'm3u',
        'label': '',
        'fields': {'playlistUrl': 'http://x/list.m3u', 'port': 8080},
      });

      expect(config.fields['port'], '8080');
      expect(config.label, '');
    });

    test('tolerates a missing label and empty fields', () {
      final config = cloudRowToConfig({
        'id': 'id2',
        'kind': 'demo',
        'fields': {},
      });

      expect(config.label, '');
      expect(config.fields, isEmpty);
      expect(config.kind, SourceKind.demo);
    });

    test('reads per-source settings (hidden categories) when present', () {
      final config = cloudRowToConfig({
        'id': 'id3',
        'kind': 'xtream',
        'label': 'P',
        'fields': {'host': 'h', 'username': 'u', 'password': 'p'},
        'settings': {
          'hiddenCategories': {
            'live': ['c1', 'c2'],
          },
        },
      });

      expect(config.hiddenCategoryIds(ContentKind.live), {'c1', 'c2'});
      expect(config.hiddenCategoryIds(ContentKind.movie), isEmpty);
    });

    test('defaults settings to empty when the column is absent (legacy row)', () {
      final config = cloudRowToConfig({
        'id': 'id4',
        'kind': 'm3u',
        'label': '',
        'fields': {'playlistUrl': 'http://x/list.m3u'},
      });

      expect(config.settings, isEmpty);
      expect(config.hiddenCategoryIds(ContentKind.live), isEmpty);
    });

    test('throws on an unknown kind (defends against bad cloud data)', () {
      expect(
        () => cloudRowToConfig({'id': 'x', 'kind': 'bogus', 'fields': {}}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // Phase 1 non-destructive push: the cloud row now carries the full fields
  // (credentials included) in both directions — a pull mirrors them verbatim
  // and a push sends `config.fields` as-is (no credential strip). These pin the
  // mapping the pull/push paths in cloud_sync.dart rely on.
  group('full-fields round-trip (post credential-strip removal)', () {
    test('pull mirrors a Stalker row with its MAC credential', () {
      final config = cloudRowToConfig({
        'id': '123e4567-e89b-42d3-a456-426614174000',
        'kind': 'stalker',
        'label': 'Portal',
        'fields': {'portal': 'http://portal.example', 'mac': '00:1A:79:AB:CD:EF'},
      });
      expect(config.fields['portal'], 'http://portal.example');
      expect(config.fields['mac'], '00:1A:79:AB:CD:EF');
    });

    test('pull mirrors an Xtream row with username/password', () {
      final config = cloudRowToConfig({
        'id': '123e4567-e89b-42d3-a456-426614174001',
        'kind': 'xtream',
        'label': 'X',
        'fields': {
          'host': 'http://host:8080',
          'username': 'u',
          'password': 'p',
        },
      });
      expect(config.fields['username'], 'u');
      expect(config.fields['password'], 'p');
    });

    test('pull mirrors an m3u row with its playlist locator', () {
      final config = cloudRowToConfig({
        'id': '123e4567-e89b-42d3-a456-426614174002',
        'kind': 'm3u',
        'label': 'List',
        'fields': {
          'playlistUrl': 'https://example.invalid/get.php',
        },
      });
      expect(
        config.fields['playlistUrl'],
        'https://example.invalid/get.php',
      );
    });

    test('push payload sends the full fields (config.fields verbatim)', () {
      // pushSources builds each payload entry's `fields` from `config.fields`
      // directly (no cloud-safe strip). This locks that credentials are carried.
      const config = SourceConfig(
        id: '123e4567-e89b-42d3-a456-426614174003',
        kind: SourceKind.xtream,
        label: 'X',
        fields: {
          'host': 'http://host:8080',
          'username': 'u',
          'password': 'p',
        },
      );
      final payloadFields = config.fields;
      expect(payloadFields, containsPair('username', 'u'));
      expect(payloadFields, containsPair('password', 'p'));
      expect(payloadFields, containsPair('host', 'http://host:8080'));
    });
  });

  // pullMetadata now takes the cloud config wholesale (MetadataConfig.fromJson);
  // pushMetadata sends config.toJson(). Both carry the API keys.
  group('metadata full round-trip', () {
    test('pull mirrors cloud API keys (fromJson reads them)', () {
      final cloud = MetadataConfig.fromJson({
        'provider': 'tvdb',
        'tmdbApiKey': 'tmdb-key',
        'tvdbApiKey': 'tvdb-key',
        'tvdbPin': 'pin-123',
        'mdblistApiKey': 'mdb-key',
        'autoEnrich': false,
      });
      expect(cloud.provider, 'tvdb');
      expect(cloud.tmdbApiKey, 'tmdb-key');
      expect(cloud.tvdbApiKey, 'tvdb-key');
      expect(cloud.tvdbPin, 'pin-123');
      expect(cloud.mdblistApiKey, 'mdb-key');
      expect(cloud.autoEnrich, isFalse);
    });

    test('push payload (toJson) carries the API keys', () {
      const config = MetadataConfig(
        provider: 'tmdb',
        tmdbApiKey: 'tmdb-key',
        tvdbApiKey: 'tvdb-key',
        tvdbPin: 'pin-123',
        mdblistApiKey: 'mdb-key',
      );
      final json = config.toJson();
      expect(json['tmdbApiKey'], 'tmdb-key');
      expect(json['tvdbApiKey'], 'tvdb-key');
      expect(json['tvdbPin'], 'pin-123');
      expect(json['mdblistApiKey'], 'mdb-key');
    });
  });

  group('source ids (push round-trip)', () {
    test('newSourceId is a canonical v4 UUID', () {
      final id = newSourceId();
      expect(isUuid(id), isTrue);
      // Version nibble is 4, variant nibble is 8/9/a/b.
      expect(id[14], '4');
      expect('89ab'.contains(id[19]), isTrue);
    });

    test('newSourceId yields distinct ids', () {
      final ids = {for (var i = 0; i < 100; i++) newSourceId()};
      expect(ids.length, 100);
    });

    test('isUuid rejects legacy timestamp ids and accepts UUIDs', () {
      // The old id scheme (microsecond timestamps) is not a UUID, so push
      // rewrites it before sending to the uuid-typed cloud column.
      expect(isUuid('1719500000000000'), isFalse);
      expect(isUuid('not-a-uuid'), isFalse);
      expect(isUuid('123E4567-E89B-42D3-A456-426614174000'), isTrue);
    });
  });

  group('friendlyCloudError', () {
    test(
      'strips the server prefix from a PostgrestException and never leaks '
      'details',
      () {
        final e = PostgrestException(
          message: 'iptvs: too many favorites (max 200000)',
          code: '23514',
          details:
              'Failing row contains (http://user:pass@host/live/user/pass/1.ts).',
        );
        final message = friendlyCloudError(e);
        expect(message, 'too many favorites (max 200000)');
        expect(message.contains('Failing row'), isFalse);
        expect(message.contains('pass'), isFalse);
      },
    );

    test('uses the AuthException message as-is', () {
      final e = AuthException('Invalid login credentials');
      expect(friendlyCloudError(e), 'Invalid login credentials');
    });

    test('falls back to a generic message for anything else', () {
      expect(
        friendlyCloudError(Exception('SocketException: some raw detail')),
        'Cloud sync failed. Check your connection and try again.',
      );
    });

    test('redacts a credentialed URL embedded in the message', () {
      final e = PostgrestException(
        message: 'iptvs: could not reach '
            'http://panel.example.com/live/someuser12345/s3cretp4ssw0rd/1.ts',
      );
      final message = friendlyCloudError(e);
      expect(message.contains('someuser12345'), isFalse);
      expect(message.contains('s3cretp4ssw0rd'), isFalse);
      expect(message.contains('<redacted>'), isTrue);
      expect(message.contains('panel.example.com'), isTrue);
    });
  });

  // ── Phase-2/3 isolated secrets + E2EE (pure helpers) ───────────────────────

  group('splitFields / mergeFields (secret_keys)', () {
    test('splits source fields into broad + non-empty secret', () {
      final (broad, secret) = splitFields({
        'host': 'http://h:8080',
        'username': 'u',
        'password': 'p',
        'playlistExpiryHint': '2026-01-01',
      }, kSourceSecretKeys);
      expect(broad, {'host': 'http://h:8080', 'playlistExpiryHint': '2026-01-01'});
      expect(secret, {'username': 'u', 'password': 'p'});
    });

    test('drops empty secret values so they read as absent', () {
      final (broad, secret) = splitFields({
        'host': 'http://h',
        'username': 'u',
        'password': '',
      }, kSourceSecretKeys);
      expect(broad, {'host': 'http://h'});
      expect(secret, {'username': 'u'});
      expect(secret.containsKey('password'), isFalse);
    });

    test('mergeFields overlays secret onto broad', () {
      expect(
        mergeFields({'host': 'h'}, {'username': 'u', 'password': 'p'}),
        {'host': 'h', 'username': 'u', 'password': 'p'},
      );
    });

    test('fillGapsFromLocal keeps a local secret only where cloud is empty', () {
      // Cloud has username but not password; local has both → password filled.
      final out = fillGapsFromLocal(
        {'host': 'h', 'username': 'cloud-u'},
        {'username': 'local-u', 'password': 'local-p'},
        kSourceSecretKeys,
      );
      expect(out['username'], 'cloud-u'); // cloud non-empty wins
      expect(out['password'], 'local-p'); // local fills the gap
    });
  });

  group('isMissingFunctionError', () {
    test('true for PostgREST "could not find the function" (PGRST202)', () {
      expect(
        isMissingFunctionError(
          PostgrestException(
            message: 'Could not find the function public.get_secrets',
            code: 'PGRST202',
          ),
        ),
        isTrue,
      );
    });

    test('true for a 42883 undefined_function', () {
      expect(
        isMissingFunctionError(
          PostgrestException(message: 'function does not exist', code: '42883'),
        ),
        isTrue,
      );
    });

    test('false for an ordinary constraint error', () {
      expect(
        isMissingFunctionError(
          PostgrestException(message: 'iptvs: too many sources', code: '23514'),
        ),
        isFalse,
      );
      expect(isMissingFunctionError(Exception('nope')), isFalse);
    });
  });

  group('buildSecretElement (push)', () {
    final aad = sourceSecretAad('p', 's', 1);
    final ck = List<int>.filled(32, 7);

    test('absent (null) when the device does not know the secret', () async {
      final el = await buildSecretElement(
        secret: const {},
        status: CloudCryptoStatus.off,
        contentKey: null,
        ckVersion: 1,
        aad: aad,
      );
      expect(el, isNull);
    });

    test('format 0 (plaintext) when E2EE is off', () async {
      final el = await buildSecretElement(
        secret: const {'username': 'u', 'password': 'p'},
        status: CloudCryptoStatus.off,
        contentKey: null,
        ckVersion: 1,
        aad: aad,
      );
      expect(el, isNotNull);
      expect(el!['format'], 0);
      expect(el['payload'], {'username': 'u', 'password': 'p'});
    });

    test('format 1 (encrypted) when E2EE is ready, and round-trips', () async {
      final el = await buildSecretElement(
        secret: const {'username': 'u', 'password': 'p'},
        status: CloudCryptoStatus.ready,
        contentKey: ck,
        ckVersion: 1,
        aad: aad,
        ivOverride: List<int>.generate(12, (i) => i),
      );
      expect(el!['format'], 1);
      final payload = el['payload'] as Map<String, dynamic>;
      expect(payload['v'], 1);
      expect(payload['ckv'], 1);
      // The plaintext credential must not appear anywhere in the envelope.
      expect(payload.toString().contains('password'), isFalse);
      final back = await decodeSecretEntry(
        entry: el,
        status: CloudCryptoStatus.ready,
        contentKey: ck,
        ckVersion: 1,
        aad: aad,
      );
      expect(back, {'username': 'u', 'password': 'p'});
    });
  });

  group('decodeSecretEntry (pull)', () {
    final aad = sourceSecretAad('p', 's', 1);
    final ck = List<int>.filled(32, 9);

    test('null entry → empty (overlay fills gaps)', () async {
      expect(
        await decodeSecretEntry(
          entry: null,
          status: CloudCryptoStatus.off,
          contentKey: null,
          ckVersion: 1,
          aad: aad,
        ),
        isEmpty,
      );
    });

    test('format 0 → plaintext map', () async {
      final map = await decodeSecretEntry(
        entry: const {
          'format': 0,
          'payload': {'username': 'u'},
        },
        status: CloudCryptoStatus.off,
        contentKey: null,
        ckVersion: 1,
        aad: aad,
      );
      expect(map, {'username': 'u'});
    });

    test('format 1 while locked (no CK) → empty, not a throw', () async {
      final el = await buildSecretElement(
        secret: const {'password': 'p'},
        status: CloudCryptoStatus.ready,
        contentKey: ck,
        ckVersion: 1,
        aad: aad,
        ivOverride: List<int>.filled(12, 1),
      );
      final map = await decodeSecretEntry(
        entry: el,
        status: CloudCryptoStatus.locked,
        contentKey: null,
        ckVersion: 1,
        aad: aad,
      );
      expect(map, isEmpty);
    });

    test('format 1 with the wrong CK fails closed (throws)', () async {
      final el = await buildSecretElement(
        secret: const {'password': 'p'},
        status: CloudCryptoStatus.ready,
        contentKey: ck,
        ckVersion: 1,
        aad: aad,
        ivOverride: List<int>.filled(12, 2),
      );
      await expectLater(
        decodeSecretEntry(
          entry: el,
          status: CloudCryptoStatus.ready,
          contentKey: List<int>.filled(32, 3),
          ckVersion: 1,
          aad: aad,
        ),
        throwsA(isA<CloudCryptoException>()),
      );
    });
  });

  group('MetadataConfig cloud split + merge', () {
    test('broad projection carries no API keys; secret projection carries them', () {
      const config = MetadataConfig(
        provider: 'tvdb',
        tmdbApiKey: 'tk',
        tvdbApiKey: 'vk',
        tvdbPin: 'pin',
        mdblistApiKey: 'mk',
        autoEnrich: false,
      );
      final broad = config.cloudBroadJson();
      expect(broad, {'provider': 'tvdb', 'autoEnrich': false});
      expect(broad.containsKey('tmdbApiKey'), isFalse);
      expect(config.cloudSecretFields(), {
        'tmdbApiKey': 'tk',
        'tvdbApiKey': 'vk',
        'tvdbPin': 'pin',
        'mdblistApiKey': 'mk',
      });
    });

    test('fromCloudParts merges broad + secret and falls back to local', () {
      const local = MetadataConfig(tmdbApiKey: 'local-tmdb', mdblistApiKey: 'local-mdb');
      final merged = MetadataConfig.fromCloudParts(
        broad: const {'provider': 'tmdb', 'autoEnrich': true},
        // Cloud knows tvdb key but not tmdb → tmdb falls back to local.
        secret: const {'tvdbApiKey': 'cloud-tvdb'},
        local: local,
      );
      expect(merged.provider, 'tmdb');
      expect(merged.tvdbApiKey, 'cloud-tvdb');
      expect(merged.tmdbApiKey, 'local-tmdb'); // defensive fallback
      expect(merged.mdblistApiKey, 'local-mdb'); // defensive fallback
    });
  });

  group('sourceCredentialsMissing (fail-closed activation / badge)', () {
    test('xtream without password is missing; with it is not', () {
      const locked = SourceConfig(
        id: 'x',
        kind: SourceKind.xtream,
        label: 'X',
        fields: {'host': 'http://h', 'username': 'u'},
      );
      expect(sourceCredentialsMissing(locked), isTrue);
      expect(
        sourceCredentialsMissing(
          locked.copyWith(fields: {'host': 'http://h', 'username': 'u', 'password': 'p'}),
        ),
        isFalse,
      );
    });

    test('stalker without mac is missing; demo never is', () {
      const stalker = SourceConfig(
        id: 's',
        kind: SourceKind.stalker,
        label: 'S',
        fields: {'portal': 'http://p'},
      );
      expect(sourceCredentialsMissing(stalker), isTrue);
      expect(
        sourceCredentialsMissing(
          const SourceConfig(id: 'd', kind: SourceKind.demo, label: 'D', fields: {}),
        ),
        isFalse,
      );
    });
  });
}
