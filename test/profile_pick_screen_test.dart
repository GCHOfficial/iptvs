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
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/profile_pin.dart';
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

    SourceConfig cfg(String id) => SourceConfig(
      id: id,
      kind: SourceKind.demo,
      label: id,
      fields: const {},
    );

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
      bool bootMode = false,
    }) async {
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ProfilePickScreen(
            db: db,
            store: store,
            bootMode: bootMode,
            onDone: () => done = true,
          ),
        ),
      );
      await pumpFor(tester);
      // Returned via a getter closure so callers can read it after the flow.
      _doneFlags[tester] = () => done;
      return done;
    }

    testWidgets(
      'deleting a non-active profile leaves the active one untouched',
      (tester) async {
        final store = SourceStore();
        await localStore.createProfile('Bravo', 0, snapshot: snap('src-b'));
        final a = await localStore.createProfile(
          'Alice',
          1,
          snapshot: snap('src-a'),
        );
        await localStore.setActive(a.id);
        await store.setAll([cfg('src-a')]);
        await store.setActive('src-a');

        await pumpPicker(tester, store: store);

        // Delete Bravo (not the active profile).
        await tester.tap(find.text('Manage profiles'));
        await pumpFor(tester);
        await tester.tap(find.text('Bravo'));
        await pumpFor(tester);
        // Manage mode opens a menu now (PIN actions live there too), so delete
        // is two steps: the menu entry, then the confirmation.
        await tester.tap(find.text('Delete profile'));
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
      },
    );

    testWidgets(
      'deleting the last (active) profile drops to an empty baseline, no active',
      (tester) async {
        final store = SourceStore();
        final a = await localStore.createProfile(
          'Alice',
          0,
          snapshot: snap('src-a'),
        );
        await localStore.setActive(a.id);
        await store.setAll([cfg('src-a')]);
        await store.setActive('src-a');

        await pumpPicker(tester, store: store);

        await tester.tap(find.text('Manage profiles'));
        await pumpFor(tester);
        await tester.tap(find.text('Alice'));
        await pumpFor(tester);
        await tester.tap(find.text('Delete profile'));
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
        final c = await localStore.createProfile(
          'Charlie',
          0,
          snapshot: snap('src-c'),
        );
        final b = await localStore.createProfile(
          'Bravo',
          1,
          snapshot: snap('src-b'),
        );
        final a = await localStore.createProfile(
          'Alice',
          2,
          snapshot: snap('src-a'),
        );
        await localStore.setActive(a.id);
        await store.setAll([cfg('src-a')]);
        await store.setActive('src-a');

        await pumpPicker(tester, store: store);

        // Delete the active profile (Alice).
        await tester.tap(find.text('Manage profiles'));
        await pumpFor(tester);
        await tester.tap(find.text('Alice'));
        await pumpFor(tester);
        await tester.tap(find.text('Delete profile'));
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

    testWidgets('deleting the active profile adopts the sole survivor', (
      tester,
    ) async {
      // The reported dead end: with one profile left, `auto` never opens the
      // picker again, so the survivor — the only thing that can restore a
      // snapshot — was never reached and the library stayed empty across
      // restarts. Deleting the active profile must hand the device to it.
      final store = SourceStore();
      final b = await localStore.createProfile(
        'Bravo',
        0,
        snapshot: snap('src-b'),
      );
      final a = await localStore.createProfile(
        'Alice',
        1,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete profile'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete'));
      await pumpFor(tester);

      expect(await localStore.activeId(), b.id);
      final live = await store.list();
      expect(live.map((c) => c.id), ['src-b']);
      expect(await store.activeId(), 'src-b');
      // Bravo's own snapshot is what was restored — never Alice's leftovers.
      expect(
        (await localStore.loadAll()).single.snapshot.sourcesJson.single['id'],
        'src-b',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a locked sole survivor is not adopted, and holds the boot', (
      tester,
    ) async {
      // Adopting it would put its sources one Skip away with no PIN asked. It
      // stays ownerless instead — and the ownerless boot check keeps the
      // picker open so it can still be entered with the PIN.
      final store = SourceStore();
      final b = await localStore.createProfile(
        'Bravo',
        0,
        snapshot: snap('src-b'),
      );
      await localStore.setPin(b.id, hashProfilePin('4821'));
      final a = await localStore.createProfile(
        'Alice',
        1,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete profile'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete'));
      await pumpFor(tester);

      expect(await localStore.activeId(), isNull);
      expect(await store.list(), isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an ownerless device opens the picker at boot', (tester) async {
      // One profile and nothing active: `auto` would normally short-circuit on
      // the count alone, booting into a library no profile owns and that no
      // restart can repair. This is also the shape an install left in by the
      // *older* build carries — no mark was ever written for it, so the boot
      // check has to infer ownerless-ness from an unpaired device with no
      // active id at all.
      final store = SourceStore();
      await localStore.createProfile('Alice', 0, snapshot: snap('src-a'));
      await localStore.setActive(null);

      await pumpPicker(tester, store: store, bootMode: true);

      expect(_doneFlags[tester]!(), isFalse, reason: 'the picker must show');
      expect(find.text('Alice'), findsOneWidget);

      // And picking it hands the device over.
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Switch profile'));
      await pumpFor(tester);

      expect(_doneFlags[tester]!(), isTrue);
      expect((await store.list()).map((c) => c.id), ['src-a']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a stale cloud active id cannot claim the empty baseline', (
      tester,
    ) async {
      // Switching to a local profile never clears the cloud
      // `active_profile_id`, and there is no RPC that can. So after deleting
      // the active *local* profile the stale cloud pointer was left as the one
      // "active" profile — the boot short-circuited into it and a tap on it
      // took the identity shortcut, both landing in the empty baseline. The
      // ownerless mark is what stops it claiming anything.
      final store = SourceStore();
      final b = await localStore.createProfile(
        'Bravo',
        0,
        snapshot: snap('src-b'),
      );
      final a = await localStore.createProfile(
        'Alice',
        1,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete profile'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete'));
      await pumpFor(tester);

      // Bravo is the sole survivor, so it is adopted — and adoption is exactly
      // what clears the mark again.
      expect(await localStore.ownerless(), isFalse);
      expect(await localStore.activeId(), b.id);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the ownerless mark survives a relaunch and clears on select', (
      tester,
    ) async {
      // Two survivors, so nothing is adopted: the device stays ownerless and
      // the mark has to still be there on the next launch, or the boot check
      // has nothing to read.
      final store = SourceStore();
      await localStore.createProfile('Charlie', 0, snapshot: snap('src-c'));
      final b = await localStore.createProfile(
        'Bravo',
        1,
        snapshot: snap('src-b'),
      );
      final a = await localStore.createProfile(
        'Alice',
        2,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete profile'));
      await pumpFor(tester);
      await tester.tap(find.text('Delete'));
      await pumpFor(tester);
      await tester.pumpWidget(const SizedBox());

      expect(await localStore.ownerless(), isTrue);

      // Relaunch: `auto` with two profiles would open the picker anyway, so
      // assert the mark's own effect — nothing is drawn as active, and picking
      // a profile clears it.
      await pumpPicker(tester, store: store, bootMode: true);
      expect(_doneFlags[tester]!(), isFalse);

      await tester.tap(find.text('Bravo'));
      await pumpFor(tester);
      await tester.tap(find.text('Switch profile'));
      await pumpFor(tester);

      expect(_doneFlags[tester]!(), isTrue);
      expect(await localStore.ownerless(), isFalse);
      expect(await localStore.activeId(), b.id);
      expect((await store.list()).map((c) => c.id), ['src-b']);

      await tester.pumpWidget(const SizedBox());
    });

    // -- PIN gate --------------------------------------------------------

    /// Tap [pin] on the dialog's keypad. `flutter_test` reports Android, so the
    /// pad is the surface under test — the desktop key-entry path is covered in
    /// `pin_entry_test.dart`.
    Future<void> typePin(WidgetTester tester, String pin) async {
      for (var i = 0; i < pin.length; i++) {
        // The digit's own `Text`, which is the pad button's only label — the
        // enclosing `SizedBox` finder matches the dialog's content box too.
        await tester.tap(find.text(pin[i]));
        await pumpFor(tester, frames: 4);
      }
      await pumpFor(tester);
    }

    testWidgets('a locked profile is not entered without its PIN', (
      tester,
    ) async {
      final store = SourceStore();
      final b = await localStore.createProfile(
        'Bravo',
        0,
        snapshot: snap('src-b'),
      );
      await localStore.setPin(b.id, hashProfilePin('4821'));
      final a = await localStore.createProfile(
        'Alice',
        1,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Bravo'));
      await pumpFor(tester);

      // The PIN is asked *before* anything about the switch is decided — the
      // snapshot-restore confirmation must not even have been offered yet.
      expect(find.text('Switch profile'), findsNothing);

      await typePin(tester, '1111');
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      expect(await localStore.activeId(), a.id, reason: 'still Alice');

      await typePin(tester, '4821');
      await tester.tap(find.text('Switch profile'));
      await pumpFor(tester);

      expect(_doneFlags[tester]!(), isTrue);
      expect(await localStore.activeId(), b.id);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('cancelling the PIN leaves the active profile alone', (
      tester,
    ) async {
      final store = SourceStore();
      final b = await localStore.createProfile(
        'Bravo',
        0,
        snapshot: snap('src-b'),
      );
      await localStore.setPin(b.id, hashProfilePin('4821'));
      final a = await localStore.createProfile(
        'Alice',
        1,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Bravo'));
      await pumpFor(tester);
      await tester.tap(find.text('Cancel'));
      await pumpFor(tester);

      expect(_doneFlags[tester]!(), isFalse);
      expect(await localStore.activeId(), a.id);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a locked active profile holds the boot, Skip included', (
      tester,
    ) async {
      // `off` would normally boot straight past this screen. A locked profile
      // overrides that — and Skip, the other way past it, is withdrawn.
      await localStore.setPickerStartup(ProfilePickerStartup.off);
      final store = SourceStore();
      final a = await localStore.createProfile(
        'Alice',
        0,
        snapshot: snap('src-a'),
      );
      await localStore.setPin(a.id, hashProfilePin('4821'));
      await localStore.setActive(a.id);

      await pumpPicker(tester, store: store, bootMode: true);

      expect(_doneFlags[tester]!(), isFalse, reason: 'the picker must show');
      expect(find.text('Skip'), findsNothing);

      // Even the *active* profile has to be unlocked here: it is the one the
      // app would otherwise have booted straight into.
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      expect(find.text('Cancel'), findsOneWidget, reason: 'the PIN was asked');
      await typePin(tester, '4821');

      expect(_doneFlags[tester]!(), isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a declined switch at a locked boot does not reopen Skip', (
      tester,
    ) async {
      // Verifying a PIN is not entering a profile. Unlock *Bravo*, then decline
      // the restore confirmation: the screen is back where it started, with
      // Alice's sources still the ones loaded — so Skip must still be gone, or
      // it would walk straight into the profile the boot was being held for.
      await localStore.setPickerStartup(ProfilePickerStartup.off);
      final store = SourceStore();
      final b = await localStore.createProfile(
        'Bravo',
        0,
        snapshot: snap('src-b'),
      );
      await localStore.setPin(b.id, hashProfilePin('1234'));
      final a = await localStore.createProfile(
        'Alice',
        1,
        snapshot: snap('src-a'),
      );
      await localStore.setPin(a.id, hashProfilePin('4821'));
      await localStore.setActive(a.id);
      await store.setAll([cfg('src-a')]);
      await store.setActive('src-a');

      await pumpPicker(tester, store: store, bootMode: true);
      expect(find.text('Skip'), findsNothing);

      await tester.tap(find.text('Bravo'));
      await pumpFor(tester);
      await typePin(tester, '1234');

      // The restore confirmation: decline it.
      expect(find.text('Switch profile'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpFor(tester);

      expect(_doneFlags[tester]!(), isFalse);
      expect(find.text('Skip'), findsNothing, reason: 'the gate still holds');
      expect(await localStore.activeId(), a.id);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an open profile still boots straight through', (tester) async {
      await localStore.setPickerStartup(ProfilePickerStartup.off);
      final store = SourceStore();
      final a = await localStore.createProfile(
        'Alice',
        0,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);

      await pumpPicker(tester, store: store, bootMode: true);
      expect(_doneFlags[tester]!(), isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('manage mode sets and clears a local profile PIN', (
      tester,
    ) async {
      final store = SourceStore();
      final a = await localStore.createProfile(
        'Alice',
        0,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Set a PIN'));
      await pumpFor(tester);
      await typePin(tester, '4821');
      await typePin(tester, '4821'); // confirmation
      await pumpFor(tester);

      final stored = (await localStore.loadAll()).single;
      expect(stored.locked, isTrue);
      expect(verifyProfilePin('4821', stored.pin!), isTrue);
      expect(
        stored.pin,
        isNot(contains('4821')),
        reason: 'the verifier is stored, never the PIN',
      );

      // Removing it asks for the current PIN first.
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Remove PIN'));
      await pumpFor(tester);
      await typePin(tester, '4821');
      await pumpFor(tester);

      expect((await localStore.loadAll()).single.locked, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the manage menu is operable with OK alone', (tester) async {
      // The manage flow is new focus surface on a screen whose primary input is
      // a remote: the menu's first row has to take focus when it opens, or the
      // first OK press is spent giving it focus and the dialog looks dead.
      final store = SourceStore();
      final a = await localStore.createProfile(
        'Alice',
        0,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFor(tester);
      // "Delete profile" is the menu's alone — the PIN dialog that replaced it
      // is titled "Set a PIN", the same words as the row that opened it.
      expect(find.text('Delete profile'), findsNothing, reason: 'menu closed');
      expect(find.textContaining('4-digit PIN'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await pumpFor(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a mismatched confirmation does not set a PIN', (tester) async {
      final store = SourceStore();
      final a = await localStore.createProfile(
        'Alice',
        0,
        snapshot: snap('src-a'),
      );
      await localStore.setActive(a.id);

      await pumpPicker(tester, store: store);
      await tester.tap(find.text('Manage profiles'));
      await pumpFor(tester);
      await tester.tap(find.text('Alice'));
      await pumpFor(tester);
      await tester.tap(find.text('Set a PIN'));
      await pumpFor(tester);
      await typePin(tester, '4821');
      await typePin(tester, '4822');
      await pumpFor(tester);

      expect(find.textContaining('did not match'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpFor(tester);

      expect((await localStore.loadAll()).single.locked, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'a select failure renders friendlyCloudError, not the raw error',
      (tester) async {
        // Seed the live store via a plain store, then hand the picker a store
        // whose setAll throws a PostgrestException with credential-bearing
        // details — the shape a cloud pull/setProfile can throw. The catch must
        // route through friendlyCloudError so those details never reach the UI.
        final seed = SourceStore();
        await seed.setAll([cfg('src-a')]);
        await seed.setActive('src-a');
        await localStore.createProfile('Bravo', 0, snapshot: snap('src-b'));
        final a = await localStore.createProfile(
          'Alice',
          1,
          snapshot: snap('src-a'),
        );
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
      },
    );
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
