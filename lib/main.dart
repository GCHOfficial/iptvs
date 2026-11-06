import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/app_database.dart';
import 'data/cloud_config.dart';
import 'data/crash_reporter.dart';
import 'data/device_class.dart';
import 'data/diagnostics_log.dart';
import 'data/renderer_class.dart';
import 'data/secure_local_storage.dart';
import 'data/source_identity_migration.dart';
import 'data/source_store.dart';
import 'screens/profile_pick_screen.dart';
import 'theme.dart';

/// Decoded-image cache ceiling applied on Android (phone and TV).
///
/// Flutter's default is 100 MB / 1000 images. On a 1 GB Android TV box that is
/// a large slice of the whole heap, and browsing a poster grid fills it — the
/// resulting GC pressure shows up as dropped frames on weak silicon, and on the
/// smallest boxes as an OOM kill. Images are already decoded at display size
/// (`imageCacheSize`, DPR clamped to 3), so 32 MB is roughly four screenfuls of
/// the grid's ~180 px posters: the visible page never has to re-decode itself,
/// which is the failure mode a too-small cap would cause (continuous re-decode
/// is worse than the pressure it saves). Desktop deliberately keeps Flutter's
/// default — RAM is plentiful there and the bigger cache genuinely pays off
/// when scrolling back through a large catalogue.
const int kAndroidImageCacheBytes = 32 << 20;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        kAndroidImageCacheBytes;
  }
  MediaKit.ensureInitialized();
  // Crash reporting, started **beside** the boot reads rather than in front of
  // them. `SentryFlutter.init` awaits its integration list — including the
  // native SDK's own init — before it returns, so awaiting it here would put a
  // JNI `SentryAndroid.init` (and `sentry_init` on desktop) on the path to the
  // first frame. Everything it does is keychain / platform-channel I/O, so
  // left un-awaited it interleaves with the tuple below and costs the first
  // frame nothing. It is also a complete no-op unless a DSN was compiled in
  // *and* the user's "Send crash reports" switch is on, so development builds,
  // forks and the test suite never start an SDK at all. See
  // `data/crash_reporter.dart`.
  unawaited(CrashReporter.instance.start());
  // Two facts every exported diagnostics log should carry, neither of which
  // anything on the first-frame path waits for:
  //  * which build produced the export (`app=<version>+<build>`), and
  //  * which Flutter renderer the Android engine started with, and why
  //    (`renderer=… reason=…`, resolved in Kotlin before this isolate
  //    existed — `data/renderer_class.dart`).
  unawaited(_recordBuildIdentity());
  unawaited(reportRenderer());
  final store = SourceStore();
  // Cloud init, opening the database and reading the source list are mutually
  // independent — only the identity migration below needs the database and the
  // sources together. Starting them at once costs the longest of the three
  // keychain/disk round trips instead of their sum, all of which is on the path
  // to the first frame. A failure here still aborts boot; it arrives wrapped in
  // a ParallelWaitError rather than on its own.
  // `detectDeviceClass` joins the tuple for the same reason as the rest: it is
  // one platform round trip with no dependency on the others, and it must
  // settle before the first frame because it decides the *layout* (a television
  // is the wide two-pane UI regardless of the logical width its density
  // reports — `isWideLayout`). Awaiting it ahead of this group added its
  // latency to time-to-first-frame for nothing.
  final (db, sources, _, _) = await (
    AppDatabase.open(),
    store.list(),
    detectDeviceClass(),
    _initialiseCloud(),
  ).wait;
  await migrateAllSourceIdentities(db, sources);
  runApp(IptvApp(db: db, store: store));
}

/// Stamps the running build's version onto the exportable diagnostics log's
/// header (`app=<version>+<build>`).
///
/// Un-awaited and failure-tolerant: the header already has a word for "not
/// resolved" (`app=unknown`), and a platform-channel hiccup here must not be
/// the reason the app does not boot. `PackageInfo.fromPlatform` memoizes, so
/// this shares its round trip with the crash reporter's.
Future<void> _recordBuildIdentity() async {
  try {
    final info = await PackageInfo.fromPlatform();
    DiagnosticsLog.instance.appBuild = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // Leaves `app=unknown`, which is accurate.
  }
}

/// Optional cloud source panel: only initialised when build-time Supabase
/// config is present, otherwise the app runs fully offline as before.
Future<void> _initialiseCloud() async {
  if (!CloudConfig.isConfigured) return;
  await Supabase.initialize(
    url: CloudConfig.url,
    publishableKey: CloudConfig.anonKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureLocalStorage()),
  );
}

class IptvApp extends StatelessWidget {
  final AppDatabase db;
  final SourceStore store;
  const IptvApp({super.key, required this.db, required this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // The picker itself decides whether to appear (startup-mode setting +
      // profile count) and silently short-circuits to HomeShell otherwise.
      home: ProfilePickScreen(db: db, store: store, bootMode: true),
    );
  }
}
