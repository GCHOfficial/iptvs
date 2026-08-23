// Unit tests for LiveController's async generation guards: a monotonic
// counter so a slow/stale load() or refreshNowNext() can never clobber a
// newer one's result, and dispose() never triggers a post-dispose
// notification (ChangeNotifier asserts on that).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/live_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

/// A repository whose `load`/`nowNext` are driven by test-controlled
/// completers, so interleaving between two overlapping calls is
/// deterministic instead of racing on real I/O.
class _GatedRepo extends LibraryRepository {
  _GatedRepo({required super.source, required super.db});

  final List<Completer<LibrarySnapshot>> loadCompleters = [];
  final List<Completer<({Map<String, Programme> now, Map<String, Programme> next})>>
  nowNextCompleters = [];

  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) {
    final completer = Completer<LibrarySnapshot>();
    loadCompleters.add(completer);
    return completer.future;
  }

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})>
  nowNext() {
    final completer =
        Completer<({Map<String, Programme> now, Map<String, Programme> next})>();
    nowNextCompleters.add(completer);
    return completer.future;
  }
}

/// A repository whose *guide* refresh the test drives, rather than its load.
///
/// `load` returns immediately — these tests are about what the controller does
/// with the refresh running behind the returned snapshot, which is the whole
/// shape of the change: the channel list is on screen and the guide is not.
class _EpgRepo extends LibraryRepository {
  _EpgRepo({required super.source, required super.db});

  final Completer<void> guide = Completer<void>();
  bool failed = false;
  ({Map<String, Programme> now, Map<String, Programme> next}) guideRows = (
    now: const <String, Programme>{},
    next: const <String, Programme>{},
  );

  @override
  Future<void>? get pendingEpgRefresh => guide.future;

  @override
  bool get lastEpgRefreshFailed => failed;

  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) async =>
      _snapshot('loaded');

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})>
  nowNext() async => guideRows;
}

/// A source that will not say whether it carries a guide — the
/// M3U-without-an-EPG-URL case, which reports `unknown`.
class _UnknownCapabilitySource extends DemoSource {
  @override
  SourceCapabilities get sourceCapabilities => const SourceCapabilities(
    epg: CapabilityAvailability.unknown,
    catchup: CapabilityAvailability.unknown,
    resolution: ResolutionCapability.unknown,
  );
}

LibrarySnapshot _snapshot(String marker) => LibrarySnapshot(
  categories: const [],
  channels: [Channel(id: marker, name: marker)],
  fromCache: false,
  syncedAt: DateTime(2024),
);

({Map<String, Programme> now, Map<String, Programme> next}) _nowNext(
  String marker,
) => (
  now: {
    marker: Programme(
      channelId: marker,
      start: DateTime(2024),
      stop: DateTime(2024, 1, 1, 1),
      title: marker,
    ),
  },
  next: <String, Programme>{},
);

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late _GatedRepo repo;
  late LiveController controller;
  var controllerDisposed = false;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_live_controller_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    repo = _GatedRepo(source: DemoSource(), db: db);
    controller = LiveController(repo: repo);
    controllerDisposed = false;
  });

  tearDown(() async {
    if (!controllerDisposed) controller.dispose();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('newer load wins over a late-completing stale load', () async {
    final first = controller.load(); // generation 1
    final second = controller.load(forceRefresh: true); // generation 2

    expect(repo.loadCompleters.length, 2);

    // Complete generation 2 first, then let generation 1 resolve late.
    repo.loadCompleters[1].complete(_snapshot('gen2'));
    // load() awaits its own refreshNowNext() internally, so give it a gated
    // now/next completer to resolve before awaiting the outer future.
    await Future<void>.delayed(Duration.zero);
    expect(repo.nowNextCompleters.length, 1);
    repo.nowNextCompleters[0].complete(_nowNext('gen2'));
    await second;

    // The stale generation-1 load never gets to its own refreshNowNext() call
    // (its generation check returns early first).
    repo.loadCompleters[0].complete(_snapshot('gen1'));
    await first;

    expect(controller.channels.map((c) => c.id), ['gen2']);
  });

  test('stale now-next result is dropped after a newer load completes', () async {
    final refresh = controller.refreshNowNext();
    expect(repo.nowNextCompleters.length, 1);

    final load = controller.load();
    expect(repo.loadCompleters.length, 1);
    repo.loadCompleters[0].complete(_snapshot('fresh'));
    // load() awaits its own refreshNowNext() internally, so give it a second
    // gated now/next completer to resolve.
    await Future<void>.delayed(Duration.zero);
    expect(repo.nowNextCompleters.length, 2);
    repo.nowNextCompleters[1].complete(_nowNext('fresh'));
    await load;

    // The stale refresh (started before the new load) resolves late.
    repo.nowNextCompleters[0].complete(_nowNext('stale'));
    await refresh;

    expect(controller.now.keys, ['fresh']);
    expect(controller.next, isEmpty);
  });

  test('dispose during load causes no notification and does not throw', () async {
    var notifications = 0;
    controller.addListener(() => notifications++);

    final future = controller.load();
    final notificationsBeforeDispose = notifications;
    controller.dispose();
    controllerDisposed = true;

    repo.loadCompleters[0].complete(_snapshot('after-dispose'));
    await expectLater(future, completes);

    expect(notifications, notificationsBeforeDispose);
  });

  test(
    'dispose during refreshNowNext causes no notification and does not throw',
    () async {
      var notifications = 0;
      controller.addListener(() => notifications++);

      final future = controller.refreshNowNext();
      final notificationsBeforeDispose = notifications;
      controller.dispose();
      controllerDisposed = true;

      repo.nowNextCompleters[0].complete(_nowNext('after-dispose'));
      await expectLater(future, completes);

      expect(notifications, notificationsBeforeDispose);
    },
  );

  group('the guide refreshing behind the channel list', () {
    late _EpgRepo epgRepo;
    late LiveController epgController;

    setUp(() {
      epgRepo = _EpgRepo(source: DemoSource(), db: db);
      epgController = LiveController(repo: epgRepo);
    });

    tearDown(() => epgController.dispose());

    test('reports the refresh as running until it ends', () async {
      await epgController.load();
      expect(epgController.epgRefreshing, isTrue);

      epgRepo.guide.complete();
      await pumpEventQueue();
      expect(epgController.epgRefreshing, isFalse);
    });

    test('expects a guide from a source that says it carries one', () async {
      // This is what holds the rows at their tall extent before the guide
      // lands. Without it a source's first load draws 72 px rows and jumps to
      // 112 px when the guide arrives.
      await epgController.load();
      expect(epgController.expectsEpg, isTrue);

      epgRepo.guide.complete();
      await pumpEventQueue();
      expect(
        epgController.expectsEpg,
        isFalse,
        reason: 'once the refresh is over the real guide decides',
      );
    });

    test('expects nothing from a source that reports unknown', () async {
      // Taking an `unknown` source at its word would size every first load's
      // rows tall and shrink them when no guide turned up — the same flip, in
      // the other direction.
      final unknown = _EpgRepo(source: _UnknownCapabilitySource(), db: db);
      final controller = LiveController(repo: unknown);
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.epgRefreshing, isTrue);
      expect(controller.expectsEpg, isFalse);
      unknown.guide.complete();
    });

    test('a failed refresh with no guide behind it is reported', () async {
      // The case the user can act on: a wrong or dead guide URL looks exactly
      // like a source that has no EPG.
      epgRepo.failed = true;
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();

      expect(epgController.epgUnavailable, isTrue);
      expect(epgController.epgRefreshing, isFalse);
    });

    test('a failed refresh with a cached guide stays quiet', () async {
      // Retaining the last good guide is the failure policy working, not
      // something to alarm anyone about.
      epgRepo
        ..failed = true
        ..guideRows = _nowNext('cached');
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();

      expect(epgController.epgUnavailable, isFalse);
    });

    test('a successful refresh reports neither state', () async {
      epgRepo.guideRows = _nowNext('fresh');
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();

      expect(epgController.epgRefreshing, isFalse);
      expect(epgController.epgUnavailable, isFalse);
      expect(epgController.now.keys, ['fresh']);
    });

    test('a newer load clears a previous failure verdict', () async {
      epgRepo.failed = true;
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();
      expect(epgController.epgUnavailable, isTrue);

      // A retry must not open still showing the previous attempt's verdict.
      final retry = _EpgRepo(source: DemoSource(), db: db);
      final controller = LiveController(repo: retry);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.epgUnavailable, isFalse);
      retry.guide.complete();
    });
  });
}
