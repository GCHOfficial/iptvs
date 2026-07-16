// Real-hardware resource-leak soak test for the player lifecycle.
//
// NOT run by CI or plain `flutter test` — files under integration_test/ are
// not picked up by the default `flutter test` glob, only by an explicit
// invocation with a device attached, e.g.:
//   flutter test integration_test/player_soak_test.dart -d windows
//   flutter test integration_test/player_soak_test.dart -d <android-device>
//
// Repeatedly opens and closes PlayerScreen (and, best-effort, the live
// preview controller) against DemoSource's public test streams, then asserts
// every ResourceCounters.snapshot() entry is back to zero — the documented
// invariant in lib/player/resource_counters.dart: a nonzero count after
// everything has settled means a Player/Timer/channel handler leaked.
//
// Deliberately never asserts anything about playback itself (title, position,
// errors, …) — the soak device's network may not reach DemoSource's test
// streams at all, and that's not what this test checks.

import 'dart:io' show Directory, Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/player/resource_counters.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/demo_source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  const cycles = int.fromEnvironment('SOAK_CYCLES', defaultValue: 100);

  testWidgets('player open/close cycles leave every resource counter at zero', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'iptvs_player_soak_test',
    );
    final db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    addTearDown(() async {
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final demo = DemoSource();
    final channels = await demo.channels();
    final channel = channels.first;
    final stream = await demo.resolve(channel);

    // Debug-only: makes the Android native Activity self-finish each cycle
    // instead of relying on a real Back press (see PlayerScreen's doc
    // comment on debugSoakAutoCloseMs). No-op off Android.
    if (Platform.isAndroid) {
      PlayerScreen.debugSoakAutoCloseMs = 1500;
    }
    addTearDown(() => PlayerScreen.debugSoakAutoCloseMs = null);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    for (var i = 0; i < cycles; i++) {
      navigatorKey.currentState!.push(
        MaterialPageRoute<bool>(
          builder: (_) => PlayerScreen(title: 'Soak cycle $i', stream: stream),
        ),
      );
      // Fixed pumps rather than pumpAndSettle: a live/error watchdog could
      // keep scheduling frames indefinitely if the soak device has no
      // network route to the stream, which would make pumpAndSettle hang.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Best-effort: also cycle the live preview controller's start/stop path,
    // the other real producer of media_kit Players / channel-owner claims.
    final repo = LibraryRepository(source: demo, db: db);
    final preview = LivePreviewController(repo: repo);
    for (var i = 0; i < cycles; i++) {
      await preview.start(channel, muted: true);
      await tester.pump(const Duration(milliseconds: 200));
      await preview.stop(clearSelection: true);
      await tester.pump(const Duration(milliseconds: 200));
    }
    preview.dispose();
    await tester.pump();

    final counters = await ResourceCounters.snapshot();
    for (final entry in counters.entries) {
      expect(entry.value, 0, reason: '${entry.key} did not return to zero');
    }
  });
}
