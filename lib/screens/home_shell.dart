import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../data/library_repository.dart';
import '../data/mdblist_client.dart';
import '../data/metadata_config.dart';
import '../data/metadata_provider.dart';
import '../data/source_store.dart';
import '../data/tmdb_client.dart';
import '../data/tvdb_client.dart';
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
  List<MetadataProvider> _metadataProviders = const [];
  LibraryRepository? _repo;
  bool _loading = true;
  bool Function(KeyEvent event)? _keyboardLogger;

  @override
  void initState() {
    super.initState();
    assert(() {
      _installKeyboardLogger();
      return true;
    }());
    _loadActive();
  }

  @override
  void dispose() {
    if (_keyboardLogger case final logger?) {
      HardwareKeyboard.instance.removeHandler(logger);
      _keyboardLogger = null;
    }
    _source?.dispose();
    for (final provider in _metadataProviders) {
      provider.close();
    }
    super.dispose();
  }

  void _installKeyboardLogger() {
    bool logger(KeyEvent event) {
      final focus = FocusManager.instance.primaryFocus;
      final focusLabel = focus?.debugLabel ?? focus?.context?.widget.runtimeType.toString() ?? 'none';
      final keyLabel = event.logicalKey.keyLabel.isNotEmpty
          ? event.logicalKey.keyLabel
          : (event.logicalKey.debugName ?? event.logicalKey.keyId.toString());
      debugPrint(
        '[iptvs.keys] type=${event.runtimeType} logical=$keyLabel '
        'physical=${event.physicalKey.debugName ?? event.physicalKey.usbHidUsage.toString()} '
        'focus=$focusLabel',
      );
      return false;
    }

    _keyboardLogger = logger;
    HardwareKeyboard.instance.addHandler(logger);
  }

  Future<void> _loadActive() async {
    if (mounted) setState(() => _loading = true);
    final cfg = await widget.store.activeConfig();
    await _source?.dispose();
    for (final provider in _metadataProviders) {
      provider.close();
    }
    final metadata = await widget.store.metadataConfig();
    final providers = _buildMetadataProviders(metadata);
    debugPrint(
      '[iptvs.metadata] providers=${providers.map((p) => '${p.provider}:${p.authMode}').join(',')}',
    );
    final src = cfg?.build();
    if (!mounted) {
      for (final provider in providers) {
        provider.close();
      }
      return;
    }
    setState(() {
      _config = cfg;
      _source = src;
      _metadataProviders = providers;
      _repo = src == null
          ? null
          : LibraryRepository(
              source: src,
              db: widget.db,
              metadataProviders: providers,
              autoEnrichMetadata: metadata.autoEnrich,
            );
      _loading = false;
    });
  }

  List<MetadataProvider> _buildMetadataProviders(MetadataConfig metadata) {
    final visual = <MetadataProvider>[];
    if (metadata.preferredVisualProvider == 'tvdb') {
      if (metadata.hasTvdb) {
        visual.add(
          TvdbClient(apiKey: metadata.tvdbApiKey, pin: metadata.tvdbPin),
        );
      }
      if (metadata.hasTmdb) visual.add(TmdbClient(apiKey: metadata.tmdbApiKey));
    } else {
      if (metadata.hasTmdb) visual.add(TmdbClient(apiKey: metadata.tmdbApiKey));
      if (metadata.hasTvdb) {
        visual.add(
          TvdbClient(apiKey: metadata.tvdbApiKey, pin: metadata.tvdbPin),
        );
      }
    }
    return [
      ...visual,
      if (metadata.hasMdblist) MdblistClient(apiKey: metadata.mdblistApiKey),
    ];
  }

  Future<void> _manageSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SourcesScreen(store: widget.store, db: widget.db),
      ),
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
      config: _config!,
      onManageSources: _manageSources,
    );
  }
}
