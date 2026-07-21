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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
