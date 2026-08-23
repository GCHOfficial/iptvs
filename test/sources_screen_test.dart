// SourcesScreen / EditSourceScreen behaviour.
//
// This is the app's highest-stakes path — every new install goes through it —
// and it had no widget coverage at all. Two regressions are pinned here:
//
//   * **A confirmation dialog must land with something focused.** On a D-pad an
//     unfocused dialog swallows the first OK press entirely: nothing responds,
//     and the user has to blind-hunt with arrows to discover a button exists.
//     Focus goes on the *non*-destructive action, so the reflexive first press
//     cancels rather than deletes.
//   * **The username field is not obscured.** `TvTextField`'s show/hide toggle
//     exists precisely because you cannot spot a typo without a physical
//     keyboard — so defaulting a non-secret field to hidden costs a toggle
//     press per source on the exact input method where verifying text is
//     hardest.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/sources_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('iptvs_sources_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDownAll(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // Fresh keychain per test so sources never bleed across cases.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  SourceConfig xtream(String id) => SourceConfig(
    id: id,
    kind: SourceKind.xtream,
    label: id,
    fields: const {
      'host': 'http://example.test:8080',
      'username': 'someone',
      'password': 'secret',
    },
  );

  /// Pumps until the screen's async `_reload` has settled. `pumpAndSettle` is
  /// avoided: the list cards autofocus, and a focus highlight animation can
  /// keep the frame loop busy.
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  group('delete confirmation', () {
    testWidgets('lands focused on Cancel, so the first OK press is safe', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);

      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);

      await tester.tap(find.byTooltip('Delete').first);
      await settle(tester);
      expect(find.text('Delete source?'), findsOneWidget);

      // The reflexive first press on a remote. If nothing were focused this
      // would do nothing at all; because Cancel holds focus it dismisses.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(
        find.text('Delete source?'),
        findsNothing,
        reason: 'the first OK press must reach a focused action',
      );
      expect(
        (await store.list()).map((s) => s.id),
        ['one'],
        reason: 'and that action must be the non-destructive one',
      );
    });

    testWidgets('the destructive action still works when chosen', (
      tester,
    ) async {
      final store = SourceStore();
      await store.setAll([xtream('one')]);

      await tester.pumpWidget(
        MaterialApp(
          home: SourcesScreen(store: store, db: db),
        ),
      );
      await settle(tester);

      await tester.tap(find.byTooltip('Delete').first);
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await settle(tester);

      expect(await store.list(), isEmpty);
    });
  });

  group('credential fields', () {
    testWidgets('username is readable; password is masked', (tester) async {
      final store = SourceStore();

      // Editing an existing Xtream source renders that kind's field spec
      // directly — no dropdown choreography, so this stays green regardless of
      // how the Type selector is built.
      await tester.pumpWidget(
        MaterialApp(
          home: EditSourceScreen(store: store, existing: xtream('one')),
        ),
      );
      await settle(tester);

      TvTextField fieldFor(String label) => tester.widget<TvTextField>(
        find.byWidgetPredicate((w) => w is TvTextField && w.label == label),
      );

      expect(
        fieldFor('Username').obscureText,
        isFalse,
        reason:
            'a username is not shoulder-surfing sensitive, and hiding it '
            'makes typos undetectable on a remote',
      );
      expect(fieldFor('Password').obscureText, isTrue);
    });
  });

  group('editing a source preserves fields the form does not render', () {
    testWidgets('an unrendered field survives an unrelated edit', (
      tester,
    ) async {
      // `EditSourceScreen._save` rebuilds `fields` from its own controllers, so
      // a key with no `_FieldSpec` is destroyed by any edit — change the label,
      // press Save, and it is gone. `epgUrls` (extra EPG guides, edited in
      // SourceSettingsScreen) is exactly such a key: it lives in `fields`
      // rather than `settings` because it is credential-bearing and travels to
      // the cloud as a secret.
      final store = SourceStore();
      final existing = xtream('one').copyWith(
        fields: {
          ...xtream('one').fields,
          'epgUrls': 'http://a/g.xml\nhttp://b/g.xml',
        },
      );
      await store.setAll([existing]);

      await tester.pumpWidget(
        MaterialApp(home: EditSourceScreen(store: store, existing: existing)),
      );
      await settle(tester);

      await tester.tap(find.text('Save source'));
      await settle(tester);

      final saved = (await store.list()).single;
      expect(saved.extraEpgUrls, ['http://a/g.xml', 'http://b/g.xml']);
      // The rendered fields still come from the form.
      expect(saved.fields['username'], 'someone');
    });
  });
}
