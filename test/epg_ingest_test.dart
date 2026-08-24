// One slot, app-wide. These pin the two properties the refresh depends on:
// a superseded ingest is *finished*, not merely cancelled, before its
// replacement starts; and nothing here ever rejects, because the future is
// routinely dropped.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/epg_ingest.dart';
import 'package:iptvs/data/load_token.dart';

void main() {
  test('runs a refresh and clears the slot afterwards', () async {
    final coordinator = EpgIngestCoordinator();
    var ran = false;
    await coordinator.start('a', (_) async => ran = true);
    expect(ran, isTrue);
    expect(coordinator.isBusy, isFalse);
  });

  test('a second start cancels the first and waits for it to finish', () async {
    final coordinator = EpgIngestCoordinator();
    final firstStarted = Completer<void>();
    final release = Completer<void>();
    final order = <String>[];
    var firstSawCancel = false;

    final first = coordinator.start('first', (token) async {
      firstStarted.complete();
      await release.future;
      firstSawCancel = token.isCancelled;
      order.add('first done');
    });
    await firstStarted.future;

    final second = coordinator.start('second', (_) async {
      order.add('second started');
    });

    // The point of the whole class: the replacement has *not* begun while the
    // outgoing one is still inside its transaction.
    await pumpEventQueue();
    expect(order, isEmpty);

    release.complete();
    await Future.wait([first, second]);

    expect(firstSawCancel, isTrue, reason: 'the outgoing token is cancelled');
    expect(order, ['first done', 'second started']);
  });

  test('a refresh superseded before it ever ran does not run', () async {
    // Three deep: the middle one would be writing a guide the third has already
    // replaced, so it is skipped outright rather than run and discarded.
    final coordinator = EpgIngestCoordinator();
    final release = Completer<void>();
    final ran = <String>[];

    final first = coordinator.start('first', (_) async {
      ran.add('first');
      await release.future;
    });
    await pumpEventQueue();
    final second = coordinator.start('second', (_) async => ran.add('second'));
    final third = coordinator.start('third', (_) async => ran.add('third'));

    release.complete();
    await Future.wait([first, second, third]);

    expect(ran, ['first', 'third']);
  });

  test('a failing refresh never rejects the returned future', () async {
    // It is routinely dropped with `unawaited`, where a rejection becomes an
    // unhandled asynchronous error and fails whatever test is running.
    final coordinator = EpgIngestCoordinator();
    await expectLater(
      coordinator.start('boom', (_) async => throw StateError('nope')),
      completes,
    );
    expect(coordinator.isBusy, isFalse);
  });

  test('a failing refresh still frees the slot for the next one', () async {
    final coordinator = EpgIngestCoordinator();
    await coordinator.start('boom', (_) async => throw StateError('nope'));
    var ran = false;
    await coordinator.start('after', (_) async => ran = true);
    expect(ran, isTrue);
  });

  test('cancelAndWait returns only once the refresh has stopped', () async {
    final coordinator = EpgIngestCoordinator();
    final started = Completer<void>();
    final release = Completer<void>();
    var finished = false;

    unawaited(
      coordinator.start('slow', (_) async {
        started.complete();
        await release.future;
        finished = true;
      }),
    );
    await started.future;

    final waited = coordinator.cancelAndWait();
    await pumpEventQueue();
    expect(finished, isFalse);

    release.complete();
    await waited;
    expect(finished, isTrue);
    expect(coordinator.isBusy, isFalse);
  });

  test('cancelAndWait on an idle coordinator is a no-op', () async {
    await expectLater(EpgIngestCoordinator().cancelAndWait(), completes);
  });

  test('cancelAndWait does not rethrow the refresh failure', () async {
    // Its callers are foreground paths that must not be broken by a background
    // guide.
    final coordinator = EpgIngestCoordinator();
    final release = Completer<void>();
    unawaited(
      coordinator.start('boom', (_) async {
        await release.future;
        throw StateError('nope');
      }),
    );
    await pumpEventQueue();
    final waited = coordinator.cancelAndWait();
    release.complete();
    await expectLater(waited, completes);
  });

  test('shutdown refuses new refreshes and cancels the running one', () async {
    final coordinator = EpgIngestCoordinator();
    final started = Completer<void>();
    final release = Completer<void>();
    LoadToken? seen;

    unawaited(
      coordinator.start('running', (token) async {
        seen = token;
        started.complete();
        await release.future;
      }),
    );
    await started.future;

    final done = coordinator.shutdown();
    expect(seen!.isCancelled, isTrue);
    release.complete();
    await done;

    var ranAfterShutdown = false;
    await coordinator.start('after', (_) async => ranAfterShutdown = true);
    expect(ranAfterShutdown, isFalse);
  });

  test('shutdown waits for the running refresh to stop', () async {
    // `AppDatabase.close` awaits this. An ingest mid-transaction does not stop
    // because the connection closed — `_db.close()` would block on it instead,
    // with no cancellation and nothing in the log, which is exactly how a
    // widget test ended up hanging for its full ten-minute timeout.
    final coordinator = EpgIngestCoordinator();
    final started = Completer<void>();
    final release = Completer<void>();
    var finished = false;
    unawaited(
      coordinator.start('running', (_) async {
        started.complete();
        await release.future;
        finished = true;
      }),
    );
    await started.future;

    final done = coordinator.shutdown();
    await pumpEventQueue();
    expect(finished, isFalse, reason: 'still inside its transaction');

    release.complete();
    await done;
    expect(finished, isTrue);
  });
}
