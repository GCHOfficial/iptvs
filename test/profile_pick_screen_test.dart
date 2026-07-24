// Pure-logic + widget regression tests for the boot-time profile picker.
//
// The widget tests here pin the profile-deletion contract, which had zero
// coverage and a live P1 corruption bug: deleting the *active* profile left the
// deleted profile's device state live in the store while some other profile got
// silently promoted to "active", so the next switch parked the wrong state into
// the promoted profile's snapshot slot. The fix drops to a neutral empty
// baseline and marks *no* profile active on delete-of-active, so the parking
// write (`_snapshotCurrent`) stays a no-op until the user explicitly picks a
// profile. The invariant asserted: no profile's stored snapshot is ever
// overwritten with state that isn't its own.
//
// Harness notes:
//  * flutter_secure_storage runs on its in-memory mock, so LocalProfileStore /
//    SourceStore back onto the same keychain the widget uses.
//  * The AppDatabase is only a required constructor arg; with no Supabase config
//    and no injected CloudSync the picker never touches it, and `onDone`
//    replaces the HomeShell navigation so nothing off-screen is built.
//  * We never pumpAndSettle: a successful switch leaves the busy spinner
//    animating forever. `_pumpFor` pumps a bounded number of frames instead,
//    which also flushes the secure-storage channel futures.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/profile_pick_screen.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('profile hint follows the platform navigation mode', () {
    expect(
      profileSelectionHint(NavigationMode.directional),
      'Use D-pad to choose a profile',
    );
    expect(
      profileSelectionHint(NavigationMode.traditional),
      'Choose a profile to continue',
    );
  });

  group('profile deletion', () {
    late Directory tempDir;
    late AppDatabase db;

    setUpAll(() async {
      FlutterSecureStorage.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('iptvs_picker_test');
      db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    });

    tearDownAll(() async {
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // Fresh keychain per test so profiles/sources never bleed across cases.
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    const localStore = LocalProfileStore();

    SourceConfig cfg(String id) =>
        SourceConfig(id: id, kind: SourceKind.demo, label: id, fields: const {});

    ProfileSnapshot snap(String srcId) => ProfileSnapshot(
      sourcesJson: [cfg(srcId).toJson()],
      activeSourceId: srcId,
    );

    Future<void> pumpFor(WidgetTester tester, {int frames = 40}) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<bool> pumpPicker(
      WidgetTester tester, {
      required SourceStore store,
    }) async {
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ProfilePickScreen(
            db: db,
            store: store,
            onDone: () => done = true,
          ),
        ),
      );
      await pumpFor(tester);
      // Returned via a getter closure so callers can read it after the flow.
      _doneFlags[tester] = () => done;
      return done;
    }

    testWidgets('deleting a non-active profile leaves the active one untouched', (
      tester,
    ) async {
      final store = SourceStore();
      await localStore.createProfile('Bravo', 0, snapshot: snap('src-b'));
      final a = await localStore.createProfile('Alice', 1, snapshot: snap('src-a'));
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store);

      // Delete Bravo (not the active profile).
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Bravo'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete'));
      await pumpFor(tester);

      // Active profile + its live state are completely untouched.
      expect(await localStore.activeId(), a.id);
      final live = await store.list();
      expect(live.map((c) => c.id), ['src-a']);
      final remaining = await localStore.loadAll();
      expect(remaining.map((p) => p.id), [a.id]);
      final storedA = remaining.single;
      expect(storedA.snapshot.sourcesJson.single['id'], 'src-a');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'deleting the last (active) profile drops to an empty baseline, no active',
      (tester) async {
        final store = SourceStore();
        final a =
            await localStore.createProfile('Alice', 0, snapshot: snap('src-a'));
        await localStore.setActive(a.id);
        await store.setAll([cfg('src-a')]);
        await store.setActive('src-a');

        await pumpPicker(tester, store: store);

        await tester.tap(find.text('Manage profiles'));
        await pumpFor(tester);
        await tester.tap(find.text('Alice'));
        await pumpFor(tester);
        await tester.tap(find.text('Delete'));
        await pumpFor(tester);

        // No profiles, no active marker, and the live store is reset to empty
        // so a Skip into HomeShell can't show the deleted profile's sources.
        expect(await localStore.loadAll(), isEmpty);
        expect(await localStore.activeId(), isNull);
        expect(await store.list(), isEmpty);
        expect(await store.activeId(), isNull);
        // The manage-mode toggle is gone (nothing to manage); the add circle
        // remains so the user can create a new profile.
        expect(find.text('Add profile'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'deleting the active profile does not corrupt another profile on the next switch',
      (tester) async {
        // Three local profiles, in creation (list) order Charlie, Bravo, Alice.
        // Alice is active and loaded into the live store.
        final store = SourceStore();
        final c =
            await localStore.createProfile('Charlie', 0, snapshot: snap('src-c'));
        final b =
            await localStore.createProfile('Bravo', 1, snapshot: snap('src-b'));
        final a =
            await localStore.createProfile('Alice', 2, snapshot: snap('src-a'));
        await localStore.setActive(a.id);
        await store.setAll([cfg('src-a')]);
        await store.setActive('src-a');

        await pumpPicker(tester, store: store);

        // Delete the active profile (Alice).
        await tester.tap(find.text('Manage profiles'));
        await pumpFor(tester);
        await tester.tap(find.text('Alice'));
        await pumpFor(tester);
        await tester.tap(find.text('Delete'));
        await pumpFor(tester);

        // Now switch to Bravo — NOT the profile that would have been auto-promoted
        // (Charlie, the new first entry). Before the fix, Charlie was silently
        // marked active while the store still held Alice's leftovers, so this
        // switch parked Alice's state into Charlie's snapshot slot.
        await tester.tap(find.text('Done')); // leave manage mode
        await pumpFor(tester);
        await tester.tap(find.text('Bravo'));
        await pumpFor(tester);
        await tester.tap(find.text('Switch profile'));
        await pumpFor(tester);

        expect(_doneFlags[tester]!(), isTrue, reason: 'switch should complete');

        // Charlie's stored snapshot is untouched — never overwritten with
        // Alice's leftovers or the empty baseline.
        final profiles = await localStore.loadAll();
        final storedC = profiles.firstWhere((p) => p.id == c.id);
        expect(storedC.snapshot.sourcesJson.single['id'], 'src-c');

        // Bravo really was restored into the live store.
        final live = await store.list();
        expect(live.map((s) => s.id), ['src-b']);
        expect(await store.activeId(), 'src-b');
        // Bravo is now the persisted active profile.
        expect(await localStore.activeId(), b.id);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('a select failure renders friendlyCloudError, not the raw error', (
      tester,
    ) async {
      // Seed the live store via a plain store, then hand the picker a store
      // whose setAll throws a PostgrestException with credential-bearing
      // details — the shape a cloud pull/setProfile can throw. The catch must
      // route through friendlyCloudError so those details never reach the UI.
      final seed = SourceStore();
      await seed.setAll([cfg('src-a')]);
      await seed.setActive('src-a');
      await localStore.createProfile('Bravo', 0, snapshot: snap('src-b'));
      final a = await localStore.createProfile('Alice', 1, snapshot: snap('src-a'));
      await localStore.setActive(a.id);

      final store = _ThrowOnSetAllStore();
      await pumpPicker(tester, store: store);

      await tester.tap(find.text('Bravo'));
      await pumpFor(tester);
      await tester.tap(find.text('Switch profile'));
      await pumpFor(tester);

      // The safe, prefix-stripped message shows; the raw details never do.
      expect(find.text('could not switch profile'), findsOneWidget);
      expect(find.textContaining('Failing row'), findsNothing);
      expect(find.textContaining('sekret'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Per-tester accessor for the `onDone` flag captured inside `pumpPicker`.
final Map<WidgetTester, bool Function()> _doneFlags = {};

/// A [SourceStore] whose `setAll` fails the way a cloud write does — a
/// [PostgrestException] carrying credential-bearing `details`. Everything else
/// (list/activeId/metadataConfig) reads the real mock keychain.
class _ThrowOnSetAllStore extends SourceStore {
  _ThrowOnSetAllStore() : super();

  @override
  Future<void> setAll(List<SourceConfig> ordered) => throw PostgrestException(
    message: 'iptvs: could not switch profile',
    code: '23514',
    details: 'Failing row contains (http://user:sekret@host/live/1.ts).',
  );
}
