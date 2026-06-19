import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'data/app_database.dart';
import 'data/source_store.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final db = await AppDatabase.open();
  final store = SourceStore();
  runApp(IptvApp(db: db, store: store));
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
      home: HomeShell(db: db, store: store),
    );
  }
}
