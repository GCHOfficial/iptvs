import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/source_settings_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/focusable_card.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  sqfliteFfiInit();
  group('bulkToggleHidden', () {
    test('hide adds the affected ids to the current set (union)', () {
      final next = bulkToggleHidden({'a'}, ['b', 'c'], hide: true);
      expect(next, {'a', 'b', 'c'});
    });

    test('show removes the affected ids (difference)', () {
      final next = bulkToggleHidden({'a', 'b', 'c'}, ['b', 'c'], hide: false);
      expect(next, {'a'});
    });

    test('hide leaves off-screen (unaffected) ids untouched', () {
      // 'x' is hidden but not in the filtered subset — must survive.
      final next = bulkToggleHidden({'x'}, ['a', 'b'], hide: true);
      expect(next, {'x', 'a', 'b'});
    });

    test('show only reveals ids in the affected subset', () {
      final next = bulkToggleHidden({'x', 'a'}, ['a'], hide: false);
      expect(next, {'x'});
    });

    test('does not mutate the input set', () {
      final current = {'a'};
      bulkToggleHidden(current, ['b'], hide: true);
      expect(current, {'a'});
    });

    test('empty affected is a no-op for both directions', () {
      expect(bulkToggleHidden({'a'}, const [], hide: true), {'a'});
      expect(bulkToggleHidden({'a'}, const [], hide: false), {'a'});
    });
  });

  group('nextStreamExtension', () {
    test('cycles unset -> ts -> m3u8 -> unset', () {
      expect(nextStreamExtension(null), 'ts');
      expect(nextStreamExtension('ts'), 'm3u8');
      expect(nextStreamExtension('m3u8'), null);
    });

    test('an unrecognised stored value is treated as unset', () {
      // Same fallback resolveXtreamStreamExtension applies — anything outside
      // {null, 'ts', 'm3u8'} starts the cycle over rather than getting stuck.
      expect(nextStreamExtension('mkv'), 'ts');
    });
  });
  group('the category list is built on demand', () {
    // The reported bug: on a TV box this screen took seconds to answer the
    // D-pad. Its body was `ListView(children: [...])`, which is **not lazy** —
    // every category was built up front, and again on every keystroke and every
    // toggle, since each one rebuilds the screen.
    //
    // This asserts the property rather than the widget type: a row far down a
    // long list must not be in the tree at all. An eager list builds it (off
    // screen, but built), which is exactly the cost being avoided — so a revert
    // to `ListView(children:)` fails here.
    //
    // Every database call is wrapped in `runAsync`: this is a `testWidgets`
    // body, so it runs in a fake-async zone where the real file I/O behind
    // `AppDatabase` never completes.
    late Directory tempDir;
    AppDatabase? db;

    const config = SourceConfig(
      id: 'src1',
      kind: SourceKind.m3u,
      label: 'Panel One',
      fields: {'playlistUrl': 'http://example.test/list.m3u'},
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iptvs_srcsettings');
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      await db?.close();
      db = null;
      await tempDir.delete(recursive: true);
    });

    testWidgets('a category far down the list is not built', (tester) async {
      // Tall enough that the first categories clear the fixed header block
      // (description, search, bulk buttons, the catch-up fields) — and still
      // nowhere near tall enough to hold 400 rows.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 3000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      late SourceStore store;
      await tester.runAsync(() async {
        db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
        await db!.replaceLibrary(config.id, 'One', [
          for (var i = 0; i < 400; i++)
            Category(id: 'c$i', title: 'Category $i'),
        ], const []);
        store = SourceStore();
        await store.setAll(const [config]);
        await tester.pumpWidget(
          MaterialApp(
            home: SourceSettingsScreen(store: store, db: db!, config: config),
          ),
        );
        // Let `initState`'s category read finish before the frame that matters.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(find.text('Category 0'), findsOneWidget);
      expect(
        find.text('Category 399'),
        findsNothing,
        reason:
            'an eager list builds every row up front — the whole cost this '
            'screen was rebuilt to avoid',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SourceConfig.extraEpgUrls', () {
    SourceConfig withEpgUrls(String? raw) => SourceConfig(
      id: 'src1',
      kind: SourceKind.m3u,
      label: 'One',
      fields: {
        'playlistUrl': 'http://example.test/list.m3u',
        'epgUrls': ?raw,
      },
    );

    test('absent or empty reads as no extra guides', () {
      expect(withEpgUrls(null).extraEpgUrls, isEmpty);
      expect(withEpgUrls('').extraEpgUrls, isEmpty);
    });

    test('one URL per line, in order', () {
      expect(withEpgUrls('http://a/g.xml\nhttp://b/g.xml').extraEpgUrls, [
        'http://a/g.xml',
        'http://b/g.xml',
      ]);
    });

    test('blank lines and surrounding whitespace are dropped', () {
      expect(
        withEpgUrls('  http://a/g.xml \n\n  \nhttp://b/g.xml\n').extraEpgUrls,
        ['http://a/g.xml', 'http://b/g.xml'],
      );
    });

    test('a single URL with no newline still parses', () {
      expect(withEpgUrls('http://a/g.xml').extraEpgUrls, ['http://a/g.xml']);
    });
  });

  group('the EPG guides editor', () {
    late Directory tempDir;
    AppDatabase? db;

    const config = SourceConfig(
      id: 'src1',
      kind: SourceKind.m3u,
      label: 'Panel One',
      fields: {'playlistUrl': 'http://example.test/list.m3u'},
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iptvs_epgui');
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      await db?.close();
      db = null;
      await tempDir.delete(recursive: true);
    });

    /// Mounts the screen with [initial] as the stored config and returns the
    /// store, so a test can read back what a save actually persisted.
    Future<SourceStore> mount(WidgetTester tester, SourceConfig initial) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 3000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      late SourceStore store;
      await tester.runAsync(() async {
        db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
        await db!.replaceLibrary(initial.id, 'One', const [], const []);
        store = SourceStore();
        await store.setAll([initial]);
        await tester.pumpWidget(
          MaterialApp(
            home: SourceSettingsScreen(store: store, db: db!, config: initial),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      return store;
    }

    /// Types [text] into the last guide row. A [TvTextField] holds an edit
    /// barrier — it is only typeable once activated — so this taps it first,
    /// exactly as `tv_text_field_test.dart` does.
    Future<void> typeIntoLastGuide(WidgetTester tester, String text) async {
      await tester.tap(find.byType(TvTextField).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump();
    }

    testWidgets('stored guides are seeded into the editor', (tester) async {
      await mount(
        tester,
        config.copyWith(
          fields: {
            ...config.fields,
            'epgUrls': 'http://a/g.xml\nhttp://b/g.xml',
          },
        ),
      );
      expect(find.text('http://a/g.xml'), findsOneWidget);
      expect(find.text('http://b/g.xml'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adding a guide, typing and saving persists it',
        (tester) async {
      final store = await mount(tester, config);
      expect(find.text('http://a/g.xml'), findsNothing);

      await tester.tap(find.text('Add guide'));
      await tester.pump();
      await typeIntoLastGuide(tester, 'http://a/g.xml');

      await tester.runAsync(() async {
        await tester.tap(find.text('Save EPG guides'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      final saved = (await store.list()).single;
      expect(saved.extraEpgUrls, ['http://a/g.xml']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a malformed URL is rejected and nothing is saved',
        (tester) async {
      final store = await mount(tester, config);
      await tester.tap(find.text('Add guide'));
      await tester.pump();
      await typeIntoLastGuide(tester, 'not a url');

      await tester.runAsync(() async {
        await tester.tap(find.text('Save EPG guides'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(
        find.textContaining('valid URL starting with http'),
        findsOneWidget,
      );
      expect((await store.list()).single.extraEpgUrls, isEmpty);
    });

    testWidgets('a duplicate is rejected rather than silently dropped',
        (tester) async {
      // The merge would skip the second copy anyway (every channel is already
      // claimed), so saving it would look like it did something.
      final store = await mount(tester, config);
      await tester.tap(find.text('Add guide'));
      await tester.pump();
      await typeIntoLastGuide(tester, 'http://a/g.xml');
      await tester.tap(find.text('Add guide'));
      await tester.pump();
      await typeIntoLastGuide(tester, 'http://a/g.xml');

      await tester.runAsync(() async {
        await tester.tap(find.text('Save EPG guides'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(find.textContaining('already in the list'), findsOneWidget);
      expect((await store.list()).single.extraEpgUrls, isEmpty);
    });

    testWidgets('clearing a guide and saving removes it', (tester) async {
      // Removal is "clear the row, then Save" — the clear affordance is
      // TvTextField's own, which is a proper D-pad stop, rather than a Material
      // icon button beside it that would need its own focus handling.
      final store = await mount(
        tester,
        config.copyWith(
          fields: {...config.fields, 'epgUrls': 'http://a/g.xml'},
        ),
      );
      expect(find.text('http://a/g.xml'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text('Save EPG guides'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      final saved = (await store.list()).single;
      expect(saved.extraEpgUrls, isEmpty);
      expect(
        saved.fields.containsKey('epgUrls'),
        isFalse,
        reason: 'an empty list should remove the key, not store an empty blob',
      );
      // The row itself stays — deliberately. `_saveEpgGuides` also runs from a
      // row's own Done key, so pruning empties here deleted a blank row the
      // user had just added and was about to type into. An empty row is
      // skipped on save and costs nothing.
      expect(find.text('Guide 2'), findsOneWidget);
    });

    testWidgets('the clear affordance appears only once a row has text', (
      tester,
    ) async {
      await mount(tester, config);
      await tester.tap(find.text('Add guide'));
      await tester.pump();
      expect(find.byIcon(Icons.clear), findsNothing);

      await typeIntoLastGuide(tester, 'http://a/g.xml');
      expect(find.byIcon(Icons.clear), findsOneWidget);
    });

    testWidgets('Add guide is disabled once the cap is reached',
        (tester) async {
      // kMaxEpgGuides counts the built-in guide, so an M3U source with one
      // offers three editable rows.
      await mount(
        tester,
        config.copyWith(
          fields: {
            ...config.fields,
            'epgUrl': 'http://provider/epg.xml',
            'epgUrls': 'http://a/g.xml\nhttp://b/g.xml\nhttp://c/g.xml',
          },
        ),
      );
      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Add guide'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('the buffer preset tile', () {
    late Directory tempDir;
    AppDatabase? db;

    const config = SourceConfig(
      id: 'src1',
      kind: SourceKind.m3u,
      label: 'Panel One',
      fields: {'playlistUrl': 'http://example.test/list.m3u'},
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iptvs_bufferui');
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      await db?.close();
      db = null;
      await tempDir.delete(recursive: true);
    });

    Future<SourceStore> mount(WidgetTester tester, SourceConfig initial) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 3000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      late SourceStore store;
      await tester.runAsync(() async {
        db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
        await db!.replaceLibrary(initial.id, 'One', const [], const []);
        store = SourceStore();
        await store.setAll([initial]);
        await tester.pumpWidget(
          MaterialApp(
            home: SourceSettingsScreen(store: store, db: db!, config: initial),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      return store;
    }

    Future<void> tapTile(WidgetTester tester, SourceStore store) async {
      await tester.runAsync(() async {
        await tester.tap(find.textContaining('Buffer size:'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    testWidgets('starts on Normal for a source that never set it', (
      tester,
    ) async {
      await mount(tester, config);
      expect(find.text('Buffer size: Normal'), findsOneWidget);
    });

    testWidgets('one activation advances the preset and persists it', (
      tester,
    ) async {
      final store = await mount(tester, config);
      await tapTile(tester, store);

      expect(find.text('Buffer size: Large'), findsOneWidget);
      expect((await store.list()).single.bufferPresetName, 'high');
    });

    testWidgets('cycling back to Normal removes the stored key', (
      tester,
    ) async {
      // Normal is the default, so a source that returns to it must serialize
      // exactly as it did before the setting existed.
      final store = await mount(tester, config);
      await tapTile(tester, store); // normal -> high
      await tapTile(tester, store); // high -> low
      expect((await store.list()).single.bufferPresetName, 'low');

      await tapTile(tester, store); // low -> normal
      final saved = (await store.list()).single;
      expect(saved.bufferPresetName, 'normal');
      expect(
        saved.settings.containsKey('bufferPreset'),
        isFalse,
        reason: 'the default should store nothing',
      );
    });

    testWidgets('a stored preset is shown on arrival', (tester) async {
      await mount(
        tester,
        config.copyWith(settings: const {'bufferPreset': 'low'}),
      );
      expect(find.text('Buffer size: Small'), findsOneWidget);
    });
  });
  group('the new settings are D-pad operable', () {
    // Everything this screen added is on a TV-facing surface, so each control
    // has to be a real focus target that OK activates — not merely something a
    // pointer can hit. The repo's rule is that lists/grids use `FocusableCard`
    // and text inputs use `TvTextField`; these assert both the primitive and
    // the behaviour, because using the right widget is what brings the focus
    // ring, the scroll-into-view and the Back-ladder rung with it.
    late Directory tempDir;
    AppDatabase? db;

    const config = SourceConfig(
      id: 'src1',
      kind: SourceKind.m3u,
      label: 'Panel One',
      fields: {'playlistUrl': 'http://example.test/list.m3u'},
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iptvs_dpad');
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      await db?.close();
      db = null;
      await tempDir.delete(recursive: true);
    });

    Future<SourceStore> mount(WidgetTester tester, SourceConfig initial) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 3000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      late SourceStore store;
      await tester.runAsync(() async {
        db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
        await db!.replaceLibrary(initial.id, 'One', const [], const []);
        store = SourceStore();
        await store.setAll([initial]);
        await tester.pumpWidget(
          MaterialApp(
            home: SourceSettingsScreen(store: store, db: db!, config: initial),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      return store;
    }

    testWidgets('the buffer tile is a FocusableCard, not a bare tappable', (
      tester,
    ) async {
      // What this proves and what it does not. It proves the tile is built on
      // the shared focusable primitive — which is what supplies the focus ring
      // (painted from `hasFocus`, not from `FocusManager.highlightMode`, which
      // starts as `touch` on Android and would otherwise leave a TV with no
      // visible cursor), scroll-into-view on focus, and OK/Enter/Select/Space
      // activation via `ActivateIntent`. It does not re-prove those behaviours;
      // `FocusableCard` owns them, and a raw `GestureDetector` here would be
      // the actual regression — reachable by pointer, invisible to a remote.
      final store = await mount(tester, config);
      expect(
        find.ancestor(
          of: find.text('Buffer size: Normal'),
          matching: find.byType(FocusableCard),
        ),
        findsOneWidget,
      );

      final card = tester.widget<FocusableCard>(
        find.ancestor(
          of: find.text('Buffer size: Normal'),
          matching: find.byType(FocusableCard),
        ),
      );
      expect(card.onTap, isNotNull, reason: 'must be an activation target');
      // The label a screen reader (and the TV accessibility layer) announces —
      // the tile's visual halves would otherwise read as fragments.
      expect(card.semanticsLabel, contains('Playback buffer'));

      await tester.runAsync(() async {
        await tester.tap(find.text('Buffer size: Normal'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.text('Buffer size: Large'), findsOneWidget);
      expect((await store.list()).single.bufferPresetName, 'high');
    });

    testWidgets('a guide row is a TvTextField, so it never traps the D-pad', (
      tester,
    ) async {
      // A bare TextField would swallow the arrow keys — the whole reason
      // TvTextField's "OK to edit" barrier exists.
      await mount(
        tester,
        config.copyWith(
          fields: {...config.fields, 'epgUrls': 'http://a/g.xml'},
        ),
      );
      expect(
        find.ancestor(
          of: find.text('Guide 2'),
          matching: find.byType(TvTextField),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the guide clear is reachable without entering edit mode', (
      tester,
    ) async {
      // It is TvTextField's own clear — a sibling stop *outside* the edit
      // barrier. Anything inside the barrier (a suffixIcon, a Material
      // IconButton the field owns) can never be a D-pad target, because
      // entering edit hands focus to the editor and the editor eats arrows.
      await mount(
        tester,
        config.copyWith(
          fields: {...config.fields, 'epgUrls': 'http://a/g.xml'},
        ),
      );
      final clear = find.byIcon(Icons.clear);
      expect(clear, findsOneWidget);

      Focus.of(tester.element(clear), scopeOk: true).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.text('http://a/g.xml'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no bare TextField is ever added to this screen', (
      tester,
    ) async {
      // The screen-wide invariant behind all of the above: every editable field
      // here must be wrapped by TvTextField. A raw TextField would be a focus
      // trap on a remote, and it is an easy thing to add by accident.
      await mount(
        tester,
        config.copyWith(
          fields: {...config.fields, 'epgUrls': 'http://a/g.xml'},
        ),
      );
      final wrapped = find.descendant(
        of: find.byType(TvTextField),
        matching: find.byType(TextField),
      );
      expect(
        find.byType(TextField).evaluate().length,
        wrapped.evaluate().length,
        reason: 'every TextField on this screen must live inside a TvTextField',
      );
    });
  });
}
