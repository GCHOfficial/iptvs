import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/source_settings_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
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

    testWidgets('removing every guide clears the stored field', (tester) async {
      final store = await mount(
        tester,
        config.copyWith(
          fields: {...config.fields, 'epgUrls': 'http://a/g.xml'},
        ),
      );
      await tester.tap(find.byTooltip('Remove guide 2'));
      await tester.pump();

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
}
