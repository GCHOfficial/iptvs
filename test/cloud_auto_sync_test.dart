// CloudAutoSync: the debounce/coalesce/retry behaviour that decides how often
// an auto-pushing device talks to the server, and whether a change can be lost.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/cloud_auto_sync.dart';

void main() {
  late StreamController<void> changes;
  late int pulls;
  late int pushes;

  setUp(() {
    changes = StreamController<void>.broadcast();
    pulls = 0;
    pushes = 0;
  });

  tearDown(() => changes.close());

  CloudAutoSync build({
    Future<void> Function()? pull,
    Future<bool> Function()? push,
    Duration debounce = const Duration(seconds: 5),
    Duration retryDelay = const Duration(seconds: 30),
  }) => CloudAutoSync(
    pull: pull ?? () async => pulls++,
    push:
        push ??
        () async {
          pushes++;
          return true;
        },
    changes: changes.stream,
    debounce: debounce,
    retryDelay: retryDelay,
  );

  test('start pulls once, then pushes anything already queued', () {
    fakeAsync((async) {
      final sync = build();
      sync.start();
      async.flushMicrotasks();
      expect(pulls, 1);

      // The trailing push is debounced, not immediate.
      expect(pushes, 0);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1);
      sync.dispose();
    });
  });

  test('several rapid changes coalesce into one push', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      for (var i = 0; i < 5; i++) {
        changes.add(null);
        async.elapse(const Duration(milliseconds: 200));
      }
      async.flushMicrotasks();
      // Still inside the debounce window: nothing sent yet.
      expect(pushes, 0);

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'five toggles is one round trip, not five');
      sync.dispose();
    });
  });

  test('a change during an in-flight push is not lost', () {
    fakeAsync((async) {
      final completers = <Completer<bool>>[];
      final sync = build(
        push: () {
          pushes++;
          final c = Completer<bool>();
          completers.add(c);
          return c.future;
        },
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();

      changes.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1);

      // Toggled while the first push is still in flight.
      changes.add(null);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'no second push stacked behind the first');

      completers.first.complete(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 2, reason: 'the change made mid-push is sent afterwards');
      sync.dispose();
    });
  });

  test('a failed push retries and does not throw', () {
    fakeAsync((async) {
      var attempts = 0;
      final sync = build(
        push: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return true;
        },
        retryDelay: const Duration(seconds: 30),
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();

      changes.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(attempts, 1);

      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(attempts, 2, reason: 'the queued change is retried');
      sync.dispose();
    });
  });

  test('a failing pull never propagates to the caller', () {
    fakeAsync((async) {
      final sync = build(pull: () async => throw StateError('no network'));
      // start() awaits pullNow(); an unswallowed throw here would take the app
      // launch (or a profile switch) down with it.
      var completed = false;
      sync.start().then((_) => completed = true);
      async.flushMicrotasks();
      expect(completed, isTrue);
      sync.dispose();
    });
  });

  test('flush bypasses the debounce', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      async.elapse(const Duration(milliseconds: 100));
      sync.flush();
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'backgrounding must not wait out the timer');
      sync.dispose();
    });
  });

  test('nothing fires after dispose', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      sync.dispose();
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(pushes, 0);
    });
  });
}
