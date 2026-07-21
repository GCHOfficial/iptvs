// Tests for LibraryRepository.enrichMediaMetadata's bounded-concurrency
// fan-out: a fixed worker pool pulls from a shared queue instead of a plain
// serial loop (CLAUDE.md "Async publishes are generation-guarded" area,
// perf/tier0 fix). Uses a fake MetadataProvider that tracks concurrent calls
// and a real AppDatabase (via AppDatabase.openAt) so the cache-hit
// short-circuit and the final updateMediaDisplayFields write are exercised
// for real — no network involved.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

/// Fake provider that records concurrency (in-flight/max-in-flight counts)
/// and every id it was asked to search, and can be told to throw for
/// specific ids to exercise the fan-out's error handling.
class _FakeMetadataProvider implements MetadataProvider {
  _FakeMetadataProvider({this.failFor = const {}});

  @override
  String get provider => 'fake';

  @override
  String get authMode => 'none';

  @override
  bool get ratingsOnly => false;

  /// Item ids that should throw instead of resolving.
  final Set<String> failFor;

  int inFlight = 0;
  int maxInFlight = 0;
  final List<String> searched = [];

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    inFlight++;
    maxInFlight = maxInFlight < inFlight ? inFlight : maxInFlight;
    searched.add(item.id);
    try {
      // Yield a few times so overlapping calls actually interleave, the way
      // real HTTP round trips would.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      if (failFor.contains(item.id)) {
        throw Exception('boom:${item.id}');
      }
      return ExternalMetadata(
        provider: provider,
        providerKey: 'fake:${item.id}',
        title: 'Enriched ${item.id}',
        overview: 'overview-${item.id}',
        refreshedAt: DateTime.now(),
      );
    } finally {
      inFlight--;
    }
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async => null;

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async => null;

  @override
  void close() {}
}

MediaItem _movie(String id) =>
    MediaItem(id: id, title: 'title-$id', kind: ContentKind.movie);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_enrich_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'enrichMediaMetadata fans out with bounded concurrency and preserves order',
    () async {
      final provider = _FakeMetadataProvider();
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );

      final items = List.generate(19, (i) => _movie('m$i'));
      final result = await repo.enrichMediaMetadata(items);

      expect(result.length, items.length);
      // Every item enriched, in the same order as the input.
      for (var i = 0; i < items.length; i++) {
        expect(result[i].id, items[i].id);
        expect(result[i].title, 'Enriched m$i');
        expect(result[i].description, 'overview-m$i');
      }
      // All items were actually looked up.
      expect(provider.searched.toSet(), items.map((e) => e.id).toSet());
      // Never exceeded the pool's cap, but did overlap (fan-out happened).
      expect(provider.maxInFlight, greaterThan(1));
      expect(provider.maxInFlight, lessThanOrEqualTo(4));
    },
  );

  test(
    'one item failing does not prevent the others from being enriched',
    () async {
      final provider = _FakeMetadataProvider(failFor: {'m2', 'm5'});
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );

      final items = List.generate(8, (i) => _movie('m$i'));
      final result = await repo.enrichMediaMetadata(items);

      expect(result.length, items.length);
      for (var i = 0; i < items.length; i++) {
        if (items[i].id == 'm2' || items[i].id == 'm5') {
          // Failed lookups leave the item untouched rather than aborting.
          expect(result[i].title, items[i].title);
        } else {
          expect(result[i].title, 'Enriched ${items[i].id}');
        }
      }
      expect(provider.searched.toSet(), items.map((e) => e.id).toSet());
    },
  );

  test('cache hits short-circuit the provider call', () async {
    final provider = _FakeMetadataProvider();
    final repo = LibraryRepository(
      source: DemoSource(),
      db: db,
      metadataProvider: provider,
    );

    final cached = _movie('cached-1');
    await db.cacheExternalMetadata(
      'demo',
      cached,
      ExternalMetadata(
        provider: 'fake',
        providerKey: 'fake:cached-1',
        title: 'From cache',
        refreshedAt: DateTime.now(),
      ),
    );

    final result = await repo.enrichMediaMetadata([cached]);

    expect(result.single.title, 'From cache');
    expect(provider.searched, isEmpty);
  });

  test(
    'respects the limit parameter, scanning only the first N matches',
    () async {
      final provider = _FakeMetadataProvider();
      final repo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProvider: provider,
      );

      final items = List.generate(10, (i) => _movie('m$i'));
      final result = await repo.enrichMediaMetadata(items, limit: 3);

      expect(provider.searched.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(result[i].title, 'Enriched m$i');
      }
      for (var i = 3; i < items.length; i++) {
        expect(result[i].title, items[i].title);
      }
    },
  );
}
