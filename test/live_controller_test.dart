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
}
