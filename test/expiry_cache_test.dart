import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/expiry_cache.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SourceConfig cfg({
    String id = 'src-1',
    String portal = 'http://portal.example/c/',
    String mac = '00:1A:79:AA:BB:CC',
    String label = 'Portal',
    Map<String, dynamic> settings = const {},
  }) => SourceConfig(
    id: id,
    kind: SourceKind.stalker,
    label: label,
    fields: {'portal': portal, 'mac': mac},
    settings: settings,
  );

  group('expiryConfigFingerprint', () {
    test('changes when a credential does', () {
      expect(
        expiryConfigFingerprint(cfg()),
        isNot(expiryConfigFingerprint(cfg(mac: '00:1A:79:11:22:33'))),
      );
      expect(
        expiryConfigFingerprint(cfg()),
        isNot(expiryConfigFingerprint(cfg(portal: 'http://other.example/c/'))),
      );
    });

    test('ignores things that do not change whose account it is', () {
      // Renaming a source or hiding a category must not throw away a perfectly
      // good cached answer.
      expect(
        expiryConfigFingerprint(cfg()),
        expiryConfigFingerprint(cfg(label: 'Renamed')),
      );
      expect(
        expiryConfigFingerprint(cfg()),
        expiryConfigFingerprint(cfg(settings: const {'catchupMaxDays': 7})),
      );
    });

    test('carries no credential material', () {
      final fp = expiryConfigFingerprint(cfg());
      expect(fp, isNot(contains('79')));
      expect(fp, isNot(contains('portal.example')));
    });
  });

  group('isStale', () {
    final now = DateTime(2026, 8, 10, 12);
    CachedExpiry entry(SubscriptionExpiry expiry, Duration age) => CachedExpiry(
      expiry: expiry,
      fetchedAt: now.subtract(age),
      fingerprint: 'fp',
    );

    // Comfortably outside the renewal window, so only the TTL is under test.
    final farOff = SubscriptionExpiry.dated(DateTime(2026, 12, 1));

    test('a definite answer is trusted for the full TTL', () {
      expect(isStale(entry(farOff, const Duration(hours: 1)), now: now), isFalse);
      expect(
        isStale(entry(farOff, kExpiryCacheTtl - const Duration(minutes: 1)), now: now),
        isFalse,
      );
      expect(isStale(entry(farOff, kExpiryCacheTtl), now: now), isTrue);
    });

    test('unlimited is a definite answer too', () {
      expect(
        isStale(
          entry(const SubscriptionExpiry.unlimited(), const Duration(hours: 6)),
          now: now,
        ),
        isFalse,
      );
    });

    test('unknown expires much sooner', () {
      // Unknown is as often a portal that was briefly unreachable as a panel
      // that genuinely publishes nothing; pinning it for half a day would make
      // a recovered portal look permanently broken.
      const unknown = SubscriptionExpiry.unknown();
      expect(
        isStale(entry(unknown, kExpiryCacheUnknownTtl - const Duration(minutes: 1)), now: now),
        isFalse,
      );
      expect(isStale(entry(unknown, kExpiryCacheUnknownTtl), now: now), isTrue);
      expect(isStale(entry(unknown, const Duration(hours: 1)), now: now), isTrue);
    });

    test('a date inside the renewal window is never cached', () {
      // The one time the user is watching this badge and expecting it to move.
      final soon = SubscriptionExpiry.dated(now.add(const Duration(hours: 5)));
      expect(isStale(entry(soon, const Duration(minutes: 1)), now: now), isTrue);
      final passed = SubscriptionExpiry.dated(now.subtract(const Duration(days: 2)));
      expect(isStale(entry(passed, const Duration(minutes: 1)), now: now), isTrue);
      final justOutside = SubscriptionExpiry.dated(
        now.add(kExpiryCacheRenewalWindow + const Duration(hours: 1)),
      );
      expect(isStale(entry(justOutside, const Duration(minutes: 1)), now: now), isFalse);
    });

    test('a timestamp from the future is stale, not trusted forever', () {
      // A restored backup or an NTP correction can leave one behind.
      expect(isStale(entry(farOff, const Duration(hours: -5)), now: now), isTrue);
    });
  });

  group('canServeCachedExpiry', () {
    final now = DateTime(2026, 8, 10, 12);
    CachedExpiry entry(SubscriptionExpiry expiry, Duration age) => CachedExpiry(
      expiry: expiry,
      fetchedAt: now.subtract(age),
      fingerprint: 'fp',
    );
    final farOff = SubscriptionExpiry.dated(DateTime(2026, 12, 1));

    test('a fresh entry answers without touching the provider', () {
      expect(
        canServeCachedExpiry(
          entry(farOff, const Duration(hours: 1)),
          force: false,
          now: now,
        ),
        isTrue,
      );
    });

    test('nothing cached means ask', () {
      expect(canServeCachedExpiry(null, force: false, now: now), isFalse);
    });

    test('force beats freshness', () {
      // The only lever the UI has: saving a source re-checks it. Without this a
      // cached answer could not be dislodged early at all, because an edit that
      // leaves the credentials alone keeps the same fingerprint.
      expect(
        canServeCachedExpiry(
          entry(farOff, const Duration(minutes: 1)),
          force: true,
          now: now,
        ),
        isFalse,
      );
    });

    test('a cached unknown is still forceable', () {
      // The case that matters: serving unknown from cache also skips the
      // provider's own explanation of why, so an unknown badge stayed unknown
      // *and* unexplained until the entry aged out.
      expect(
        canServeCachedExpiry(
          entry(const SubscriptionExpiry.unknown(), const Duration(minutes: 1)),
          force: false,
          now: now,
        ),
        isTrue,
      );
      expect(
        canServeCachedExpiry(
          entry(const SubscriptionExpiry.unknown(), const Duration(minutes: 1)),
          force: true,
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('ExpiryCache', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    const cache = ExpiryCache();

    test('round-trips a dated answer', () async {
      final expiry = SubscriptionExpiry.dated(DateTime(2026, 12, 1));
      await cache.write(cfg(), expiry);
      final read = await cache.readAny(cfg());
      expect(read, isNotNull);
      expect(read!.expiry.kind, SubscriptionExpiryKind.dated);
      expect(read.expiry.date, DateTime(2026, 12, 1));
    });

    test('round-trips unlimited and unknown distinctly', () async {
      await cache.write(cfg(), const SubscriptionExpiry.unlimited());
      expect(
        (await cache.readAny(cfg()))!.expiry.kind,
        SubscriptionExpiryKind.unlimited,
      );
      await cache.write(cfg(), const SubscriptionExpiry.unknown());
      expect(
        (await cache.readAny(cfg()))!.expiry.kind,
        SubscriptionExpiryKind.unknown,
      );
    });

    test('refuses an entry written for different credentials', () async {
      // Editing a source must never leave the previous account's date on the
      // badge — the fingerprint is what catches it, since the id doesn't move.
      await cache.write(cfg(), SubscriptionExpiry.dated(DateTime(2026, 12, 1)));
      expect(await cache.readAny(cfg(mac: '00:1A:79:11:22:33')), isNull);
      expect(await cache.readAny(cfg()), isNotNull);
    });

    test('keeps sources apart', () async {
      await cache.write(cfg(), SubscriptionExpiry.dated(DateTime(2026, 12, 1)));
      await cache.write(
        cfg(id: 'src-2', portal: 'http://second.example/c/'),
        const SubscriptionExpiry.unlimited(),
      );
      expect((await cache.readAny(cfg()))!.expiry.date, DateTime(2026, 12, 1));
      expect(
        (await cache.readAny(cfg(id: 'src-2', portal: 'http://second.example/c/')))!
            .expiry
            .kind,
        SubscriptionExpiryKind.unlimited,
      );
    });

    test('a stale entry is still returned, for the caller to revalidate', () async {
      // The screen's contract: show what we have, refresh behind it. So the
      // store hands back an aged entry and `isStale` decides what to do with
      // it, rather than the read silently returning nothing.
      final aged = CachedExpiry(
        expiry: const SubscriptionExpiry.unknown(),
        fetchedAt: DateTime.now().subtract(const Duration(hours: 4)),
        fingerprint: expiryConfigFingerprint(cfg()),
      );
      await const FlutterSecureStorage().write(
        key: 'source_expiry_cache',
        value: '{"src-1":${_json(aged)}}',
      );
      final read = await cache.readAny(cfg());
      expect(read, isNotNull);
      expect(isStale(read!), isTrue);
    });

    test('forget drops one source without touching the others', () async {
      await cache.write(cfg(), SubscriptionExpiry.dated(DateTime(2026, 12, 1)));
      await cache.write(
        cfg(id: 'src-2', portal: 'http://second.example/c/'),
        const SubscriptionExpiry.unlimited(),
      );
      await cache.forget('src-1');
      expect(await cache.readAny(cfg()), isNull);
      expect(
        await cache.readAny(cfg(id: 'src-2', portal: 'http://second.example/c/')),
        isNotNull,
      );
    });

    test('a corrupt blob reads as empty rather than throwing', () async {
      await const FlutterSecureStorage().write(
        key: 'source_expiry_cache',
        value: 'not json at all',
      );
      expect(await cache.readAny(cfg()), isNull);
      // ...and is recoverable by the next write.
      await cache.write(cfg(), const SubscriptionExpiry.unlimited());
      expect(await cache.readAny(cfg()), isNotNull);
    });

    test('a write prunes entries too old to be worth keeping', () async {
      final ancient = CachedExpiry(
        expiry: const SubscriptionExpiry.unlimited(),
        fetchedAt: DateTime.now().subtract(const Duration(days: 400)),
        fingerprint: expiryConfigFingerprint(cfg(id: 'gone')),
      );
      await const FlutterSecureStorage().write(
        key: 'source_expiry_cache',
        value: '{"gone":${_json(ancient)}}',
      );
      await cache.write(cfg(), const SubscriptionExpiry.unlimited());
      final raw = await const FlutterSecureStorage().read(
        key: 'source_expiry_cache',
      );
      expect(raw, isNot(contains('gone')));
      expect(raw, contains('src-1'));
    });
  });
}

String _json(CachedExpiry entry) {
  final j = entry.toJson();
  final parts = j.entries.map((e) => '"${e.key}":"${e.value}"').join(',');
  return '{$parts}';
}
