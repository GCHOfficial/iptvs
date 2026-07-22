import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/app_database.dart';
import 'data/cloud_config.dart';
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
  final store = SourceStore();
  // Cloud init, opening the database and reading the source list are mutually
  // independent — only the identity migration below needs the database and the
  // sources together. Starting them at once costs the longest of the three
  // keychain/disk round trips instead of their sum, all of which is on the path
  // to the first frame. A failure here still aborts boot; it arrives wrapped in
  // a ParallelWaitError rather than on its own.
  final (db, sources, _) = await (
    AppDatabase.open(),
    store.list(),
    _initialiseCloud(),
  ).wait;
  await migrateAllSourceIdentities(db, sources);
  runApp(IptvApp(db: db, store: store));
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
