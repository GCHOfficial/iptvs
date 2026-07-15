// Unit tests for MediaTabController's async generation guards: a monotonic
// `_loadGeneration` that only the ops which write `snapshot` — `load`
// (incl. forceRefresh) and `setCategory` (via `load`) — bump, so a later
// load/setCategory always supersedes an older in-flight one. `loadMore`
// reads the generation without bumping (extends the existing dataset, never
// replaces it). `search`/`clearSearch` are subordinate to `snapshot`: they
// publish to `searchResults`/`searchQuery` instead, are superseded by any
// load/setCategory via the same generation check, and by a newer keystroke
// via `_pendingSearch` — but must never themselves drop a still-in-flight
// load's terminal update. Uses a real AppDatabase (via AppDatabase.openAt)
// plus a Completer-gated LibraryRepository subclass so test code controls
// exactly when each "network" operation resolves, following the pattern in
// test/favorites_controller_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/media_tab_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

/// [LibraryRepository] subclass whose media-fetching methods return
/// Completer-gated futures instead of touching a [Source]. Each call looks up
/// (or lazily creates) a completer keyed by the request it answers, so a test
/// can resolve requests in whatever order it wants to force a specific
/// interleaving.
class _GatedRepo extends LibraryRepository {
  _GatedRepo({
    required super.source,
    required super.db,
    super.autoEnrichMetadata,
  });

  // Keyed by request; each key holds a queue of completers, one per call, so
  // a key can be requested more than once in a single test (e.g. an initial
  // "prime the snapshot" load and a later load racing against something
  // else) without a stale, already-completed future being handed back.
  final Map<String, List<Completer<MediaLibrarySnapshot>>> _loadGates = {};
  final Map<String, List<Completer<MediaLibrarySnapshot>>> _loadMoreGates = {};
  final Map<String, List<Completer<List<MediaItem>>>> _searchGates = {};
  final Map<String, List<Completer<List<MediaItem>>>> _enrichGates = {};

  int loadMoreCallCount = 0;

  Completer<T> _next<T>(Map<String, List<Completer<T>>> gates, String key) {
    final completer = Completer<T>();
    (gates[key] ??= []).add(completer);
    return completer;
  }

  /// The most recently issued (typically still-pending) completer for [key]
  /// — call this right after triggering the matching controller call.
  Completer<MediaLibrarySnapshot> loadGate(String key) => _loadGates[key]!.last;

  Completer<MediaLibrarySnapshot> loadMoreGate(String key) =>
      _loadMoreGates[key]!.last;

  Completer<List<MediaItem>> searchGate(String key) => _searchGates[key]!.last;

  Completer<List<MediaItem>> enrichGate(String key) => _enrichGates[key]!.last;

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
  }) {
    final key = '${categoryId ?? '<all>'}${forceRefresh ? '|refresh' : ''}';
    return _next(_loadGates, key).future;
  }

  @override
  Future<MediaLibrarySnapshot> loadMoreMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
  }) {
    loadMoreCallCount++;
    return _next(_loadMoreGates, categoryId ?? '<all>').future;
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) {
    return _next(_searchGates, query).future;
  }

  @override
  Future<List<MediaItem>> enrichMediaMetadata(
    List<MediaItem> items, {
    int? limit,
  }) {
    if (items.isEmpty) return Future.value(items);
    return _next(_enrichGates, items.first.id).future;
  }
}

MediaItem _item(String id, {String? categoryId, String? description}) =>
    MediaItem(
      id: id,
      title: id,
      kind: ContentKind.movie,
      categoryId: categoryId,
      description: description,
    );

MediaLibrarySnapshot _snapshot(List<MediaItem> items, {String? categoryId}) =>
    MediaLibrarySnapshot(
      kind: ContentKind.movie,
      categoryId: categoryId,
      categories: const [],
      items: items,
      fromCache: false,
      syncedAt: DateTime.now(),
    );

/// Lets any already-scheduled microtasks (the continuations past a completed
/// gate's `await`) run before assertions.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late _GatedRepo repo;
  late MediaTabController controller;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_media_tab_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    repo = _GatedRepo(source: DemoSource(), db: db, autoEnrichMetadata: false);
    controller = MediaTabController(kind: ContentKind.movie, repo: repo);
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'a category load returning after a newer one cannot replace it',
    () async {
      unawaited(controller.setCategory('A'));
      unawaited(controller.setCategory('B'));

      // B is now current; complete it first, then let the stale A land late.
      repo.loadGate('B').complete(_snapshot([_item('b1')], categoryId: 'B'));
      await _flush();
      repo.loadGate('A').complete(_snapshot([_item('a1')], categoryId: 'A'));
      await _flush();

      expect(controller.categoryId, 'B');
      expect(controller.snapshot!.items.map((i) => i.id), ['b1']);
    },
  );

  test('refresh supersedes an outstanding pagination', () async {
    // Prime a snapshot.
    unawaited(controller.load());
    await _flush();
    repo.loadGate('<all>').complete(_snapshot([_item('p1')]));
    await _flush();

    unawaited(controller.loadMore());
    await _flush();
    unawaited(controller.load(forceRefresh: true));
    await _flush();

    // Complete the refresh first, then let the superseded pagination land.
    repo.loadGate('<all>|refresh').complete(_snapshot([_item('r1')]));
    await _flush();
    repo.loadMoreGate('<all>').complete(_snapshot([_item('p1'), _item('lm1')]));
    await _flush();

    expect(controller.snapshot!.items.map((i) => i.id), ['r1']);
    expect(controller.loadingMore, isFalse);

    // While a fresh load is in flight, loadMore must refuse to even start.
    final callsBefore = repo.loadMoreCallCount;
    unawaited(controller.load());
    await _flush();
    expect(controller.loading, isTrue);

    await controller.loadMore();
    expect(repo.loadMoreCallCount, callsBefore);

    // Drain the outstanding gate so nothing dangles past the test.
    repo.loadGate('<all>').complete(_snapshot(const []));
    await _flush();
  });

  test(
    'dispose during an in-flight load causes no notification or exception',
    () async {
      var notifications = 0;
      controller.addListener(() => notifications++);

      unawaited(controller.load());
      await _flush();
      final countBeforeDispose = notifications;

      controller.dispose();

      repo.loadGate('<all>').complete(_snapshot([_item('x1')]));
      await _flush();

      expect(notifications, countBeforeDispose);

      // Swap in a fresh, never-disposed instance so the shared tearDown's
      // dispose() call is safe (this controller is already disposed).
      controller = MediaTabController(kind: ContentKind.movie, repo: repo);
    },
  );

  test('old enrichment cannot mutate a newer category\'s result', () async {
    controller.dispose(); // swap in a repo with auto-enrichment enabled
    repo = _GatedRepo(source: DemoSource(), db: db, autoEnrichMetadata: true);
    controller = MediaTabController(kind: ContentKind.movie, repo: repo);

    unawaited(controller.setCategory('A'));
    await _flush();
    repo.loadGate('A').complete(_snapshot([_item('a1', categoryId: 'A')]));
    await _flush(); // let the auto-enrich for A start (and block on its gate)

    unawaited(controller.setCategory('B'));
    await _flush();
    repo.loadGate('B').complete(_snapshot([_item('b1', categoryId: 'B')]));
    await _flush();

    // Late-arriving enrichment for the abandoned A load must not land.
    repo.enrichGate('a1').complete([
      _item('a1', categoryId: 'A', description: 'STALE-ENRICHMENT'),
    ]);
    await _flush();

    expect(controller.categoryId, 'B');
    expect(controller.snapshot!.items.single.id, 'b1');
    expect(controller.snapshot!.items.single.description, isNull);
  });

  test('a stale search cannot land in a different category', () async {
    unawaited(controller.search('x'));
    await _flush();

    unawaited(controller.setCategory('B'));
    await _flush();
    repo.loadGate('B').complete(_snapshot([_item('b1')], categoryId: 'B'));
    await _flush();

    // The search resolves after the category switch superseded it.
    repo.searchGate('x').complete([_item('s1')]);
    await _flush();

    expect(controller.categoryId, 'B');
    expect(controller.snapshot!.items.map((i) => i.id), ['b1']);
    expect(controller.searchQuery, isNull);
  });

  test('load superseded by a transient search still populates snapshot and '
      'clears loading', () async {
    unawaited(controller.load());
    await _flush();
    unawaited(controller.search('ab'));
    await _flush();

    // The in-flight load's terminal update must land even though a search
    // started after it — search no longer bumps the load generation.
    repo.loadGate('<all>').complete(_snapshot([_item('l1')]));
    await _flush();

    expect(controller.loading, isFalse);
    expect(controller.snapshot!.items.map((i) => i.id), ['l1']);

    repo.searchGate('ab').complete([_item('s1')]);
    await _flush();

    expect(controller.searchQuery, 'ab');
    expect(controller.searchResults.map((i) => i.id), ['s1']);
  });

  test('cold-load plus search plus clearSearch leaves snapshot populated, '
      'not empty', () async {
    expect(controller.snapshot, isNull);

    unawaited(controller.load());
    await _flush();
    unawaited(controller.search('ab'));
    await _flush();

    repo.loadGate('<all>').complete(_snapshot([_item('l1')]));
    await _flush();

    expect(controller.snapshot!.items.map((i) => i.id), ['l1']);
    expect(controller.loading, isFalse);

    controller.clearSearch();

    expect(controller.searchResults, isEmpty);
    expect(controller.snapshot!.items.map((i) => i.id), ['l1']);
  });
}
