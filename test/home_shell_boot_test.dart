// HomeShell boot with an active source that cannot be built.
//
// IPTVS-K/M/N (0.1.80, one MiBox): the active source was an M3U config with no
// `playlistUrl` — most likely a cloud pull on an E2EE-locked device, which
// strips secrets — and `_loadActive` called `SourceConfig.build()`, whose
// `fields['playlistUrl']!` threw on every launch. Since the active source is
// re-read at each start, the device could not get past boot. The shell must
// instead land on a needs-attention body whose one focusable action opens the
// sources screen.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('iptvs_home_shell_boot');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
  });

  tearDownAll(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> settle(WidgetTester tester, {int frames = 40}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  for (final entry in <String, SourceConfig>{
    'm3u': const SourceConfig(
      id: 'locked-m3u',
      kind: SourceKind.m3u,
      label: 'My playlist',
      fields: {'epgUrl': 'http://guide.invalid/x.xml'},
    ),
    'stalker': const SourceConfig(
      id: 'locked-stalker',
      kind: SourceKind.stalker,
      label: 'My portal',
      fields: {'portal': 'http://portal.invalid/c/'},
    ),
    'xtream': const SourceConfig(
      id: 'locked-xtream',
      kind: SourceKind.xtream,
      label: 'My panel',
      fields: {'host': 'http://h.invalid:80', 'username': 'u'},
    ),
  }.entries) {
    testWidgets(
      'a credential-less active ${entry.key} source shows needs-attention '
      'instead of crashing boot',
      (tester) async {
        final store = SourceStore();
        await store.setAll([entry.value]);
        await store.setActive(entry.value.id);

        await tester.pumpWidget(
          MaterialApp(
            home: HomeShell(db: db, store: store),
          ),
        );
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('${entry.value.label} needs attention'), findsOne);
        expect(find.text('Manage sources'), findsOne);
        // The first-run copy would read as if the source had been deleted.
        expect(find.text('No source configured'), findsNothing);

        // The remote must land on the one action that leads out of here.
        expect(
          Focus.of(tester.element(find.text('Manage sources'))).hasPrimaryFocus,
          isTrue,
        );
      },
    );
  }

  testWidgets('no active source still shows the first-run body', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(db: db, store: SourceStore()),
      ),
    );
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('No source configured'), findsOne);
    expect(find.text('Add a source'), findsOne);
  });
}
