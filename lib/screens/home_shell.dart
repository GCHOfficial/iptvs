import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/library_repository.dart';
import '../data/source_store.dart';
import '../data/tmdb_client.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import 'channel_list_screen.dart';
import 'sources_screen.dart';

/// Top-level shell: resolves the active source, builds its repository, and
/// shows the channel list — or an empty state when nothing is configured.
class HomeShell extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;
  const HomeShell({super.key, required this.db, required this.store});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  SourceConfig? _config;
  Source? _source;
  TmdbClient? _tmdb;
  LibraryRepository? _repo;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadActive();
  }

  @override
  void dispose() {
    _source?.dispose();
    _tmdb?.close();
    super.dispose();
  }

  Future<void> _loadActive() async {
    if (mounted) setState(() => _loading = true);
    final cfg = await widget.store.activeConfig();
    await _source?.dispose();
    _tmdb?.close();
    final metadata = await widget.store.metadataConfig();
    final tmdb = metadata.hasTmdb
        ? TmdbClient(apiKey: metadata.tmdbApiKey)
        : null;
    debugPrint(
      '[iptvs.metadata] TMDB enabled=${tmdb != null} auth=${tmdb?.authMode ?? 'none'} keyLength=${metadata.normalizedTmdbCredential.length}',
    );
    final src = cfg?.build();
    if (!mounted) {
      tmdb?.close();
      return;
    }
    setState(() {
      _config = cfg;
      _source = src;
      _tmdb = tmdb;
      _repo = src == null
          ? null
          : LibraryRepository(
              source: src,
              db: widget.db,
              metadataProvider: tmdb,
              autoEnrichMetadata: metadata.autoEnrich,
            );
      _loading = false;
    });
  }

  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SourcesScreen(store: widget.store)),
    );
    await _loadActive(); // active selection may have changed
  }

  Future<void> _useDemo() async {
    await widget.store.save(
      const SourceConfig(
        id: 'demo',
        kind: SourceKind.demo,
        label: 'Demo',
        fields: {},
      ),
    );
    await widget.store.setActive('demo');
    await _loadActive();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final repo = _repo;
    if (repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('IPTV Player')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No source configured'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _manageSources,
                icon: const Icon(Icons.add),
                label: const Text('Add a source'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _useDemo,
                child: const Text('Use demo streams'),
              ),
            ],
          ),
        ),
      );
    }

    return ChannelListScreen(
      key: ValueKey(_config!.id), // reset list state when the source changes
      repo: repo,
      onManageSources: _manageSources,
    );
  }
}
