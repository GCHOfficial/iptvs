import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/distribution_channel.dart';
import '../data/library_repository.dart';
import '../data/local_profile_store.dart';
import '../data/mdblist_client.dart';
import '../data/metadata_config.dart';
import '../data/metadata_provider.dart';
import '../data/source_store.dart';
import '../data/source_identity_migration.dart';
import '../data/tmdb_client.dart';
import '../data/tvdb_client.dart';
import '../data/update_installer.dart';
import '../data/update_service.dart';
import '../data/update_store.dart';
import '../sources/m3u_upgrade.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/profile_avatar.dart';
import 'channel_list_screen.dart';
import 'cloud_sync_screen.dart';
import 'legal_screen.dart';
import 'profile_pick_screen.dart';
import 'sources_screen.dart';
import 'update_flow.dart';

/// Top-level shell: resolves the active source, builds its repository, and
/// shows the channel list — or an empty state when nothing is configured.
class HomeShell extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;
  const HomeShell({super.key, required this.db, required this.store});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  SourceConfig? _config;
  Source? _source;
  List<MetadataProvider> _metadataProviders = const [];
  LibraryRepository? _repo;
  bool _loading = true;
  bool Function(KeyEvent event)? _keyboardLogger;
  bool _updateResumeActive = false;

  // Active profile info for the avatar — loaded after the main source load.
  // Local profile first (most-recently-selected), cloud profile as fallback.
  String? _profileName;
  int _profileColorIndex = 0;
  int _loadActiveGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    assert(() {
      _installKeyboardLogger();
      return true;
    }());
    _loadActive();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _resumePendingThenCheck(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumePendingUpdate());
  }

  Future<void> _resumePendingThenCheck() async {
    final handled = await _resumePendingUpdate();
    if (!handled && mounted) await _maybeCheckForUpdate();
  }

  Future<bool> _resumePendingUpdate() async {
    if (_updateResumeActive) return true;
    if (!mounted) return false;
    _updateResumeActive = true;
    try {
      return await resumePendingUpdate(context);
    } finally {
      _updateResumeActive = false;
    }
  }

  /// Throttled boot-time update check. Runs only on the release platforms
  /// (Android/Windows/Linux AppImage) where an in-app install is possible, and only if we
  /// haven't checked recently. [runUpdateCheck] prompts (respecting the
  /// skipped-version preference) and records the check time.
  Future<void> _maybeCheckForUpdate() async {
    if (!DistributionConfig.directUpdaterEnabled) return;
    if (!UpdateInstaller.isSupported) return;
    const store = UpdateStore();
    if (!shouldAutoCheck(await store.lastCheck(), DateTime.now())) return;
    if (!mounted) return;
    await runUpdateCheck(context, manual: false, store: store);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      final focusLabel =
          focus?.debugLabel ??
          focus?.context?.widget.runtimeType.toString() ??
          'none';
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
    final gen = ++_loadActiveGeneration;
    if (mounted) setState(() => _loading = true);
    final cfg = await widget.store.activeConfig();
    if (cfg != null) await migrateSourceIdentity(widget.db, cfg);
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
    if (!mounted || gen != _loadActiveGeneration) {
      await src?.dispose();
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
    _loadProfileInfo();
    if (cfg != null) unawaited(_maybeUpgradeM3uSource(cfg));
  }

  /// Upgrades an active M3U source that is really an Xtream panel, in the
  /// background.
  ///
  /// The edit screen has offered this since the feature existed, but only on
  /// *save* — so a source added once and never touched again stayed a flat
  /// playlist forever: live channels only, no Movies, no Series, no expiry,
  /// while the same credentials would have answered for all three. That is not
  /// a hypothetical; it is how the M3U source in the field report got there.
  ///
  /// **Deliberately not awaited, and deliberately after the UI is up.** It ends
  /// in a `player_api.php` round trip, and putting that on the boot path would
  /// let a slow or dead panel hold the whole app on a spinner. The cost when it
  /// does nothing is one small background request per app start, and only for a
  /// source whose URL actually carries credentials — [couldBeXtreamPanel] is
  /// what keeps a plain playlist from paying anything at all.
  ///
  /// On success the config is saved and [_loadActive] re-runs against it. That
  /// recursion terminates by construction: the saved config is `xtream`, so the
  /// second pass fails [couldBeXtreamPanel] immediately.
  Future<void> _maybeUpgradeM3uSource(SourceConfig cfg) async {
    if (!couldBeXtreamPanel(cfg)) return;
    // A cloud-managed source's shape belongs to the panel. `pullSources`
    // replaces every managed source wholesale from its cloud row
    // (`store.setAll`), and a pull runs on profile switch as well as on demand
    // — so converting one here would be undone by the next pull and attempted
    // again on the load after it: the source flipping between kinds, a panel
    // probe and a library reload each time, and the upgrade never reaching the
    // cloud anyway, because pushing is a deliberate user action this must not
    // take on their behalf. Saving the source in the edit screen still converts
    // it; that *is* an explicit act, and the user can push it.
    if (await _isCloudManagedSource(cfg.id)) return;
    final gen = _loadActiveGeneration;
    final upgraded = await upgradeM3uToXtream(cfg);
    // The user switched sources (or left) while the panel was answering — that
    // newer load owns the screen now, and saving here would fight it.
    if (upgraded == null || !mounted || gen != _loadActiveGeneration) return;
    await widget.store.save(upgraded);
    if (!mounted || gen != _loadActiveGeneration) return;
    // Same id, so the SQLite cache, favorites and positions all carry over —
    // this reload is a rebuild on the better config, not a re-ingestion.
    await _loadActive();
  }

  /// Whether [id] is a source the cloud panel owns.
  ///
  /// **Fails closed**: anything that stops us answering (no Supabase build, an
  /// unreadable keychain) reports *managed*, so the upgrade is skipped. The
  /// cost of skipping is a source that stays a flat M3U until the user saves
  /// it; the cost of guessing wrong is a source that flips kind on every pull.
  Future<bool> _isCloudManagedSource(String id) async {
    if (!CloudConfig.isConfigured) return false;
    try {
      final managed = await CloudSync(db: widget.db).managedSourceIds();
      return managed.contains(id);
    } catch (_) {
      return true;
    }
  }

  Future<void> _loadProfileInfo() async {
    final gen = _loadActiveGeneration;
    try {
      // Local profile takes precedence (it's the most-recently-selected).
      final localStore = LocalProfileStore();
      final localActiveId = await localStore.activeId();
      if (localActiveId != null) {
        final locals = await localStore.loadAll();
        final local = locals.where((p) => p.id == localActiveId).firstOrNull;
        if (local != null && mounted && gen == _loadActiveGeneration) {
          setState(() {
            _profileName = local.name;
            _profileColorIndex = local.colorIndex;
          });
          return;
        }
      }
      // Fall back to cloud profile.
      if (CloudConfig.isConfigured) {
        final sync = CloudSync(db: widget.db);
        final profiles = await sync.listProfiles();
        final activeId = await sync.activeProfileId();
        if (!mounted || gen != _loadActiveGeneration) return;
        final idx = profiles.indexWhere((p) => p.id == activeId);
        final profile = idx >= 0
            ? profiles[idx]
            : (profiles.isNotEmpty ? profiles.first : null);
        if (profile != null && mounted && gen == _loadActiveGeneration) {
          setState(() {
            _profileName = profile.name;
            _profileColorIndex = profileColorIndexFor(profile.id);
          });
        }
      }
    } catch (_) {
      // Best-effort — avatar falls back to the person icon.
    }
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
    await _loadActive();
  }

  Future<void> _changeProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfilePickScreen(
          db: widget.db,
          store: widget.store,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
    await _loadActive();
  }

  Future<void> _profileSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CloudSyncScreen(store: widget.store, db: widget.db),
      ),
    );
    await _loadActive();
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
        appBar: AppBar(
          title: const Text('IPTV Player'),
          actions: [
            IconButton(
              tooltip: 'Help & about',
              icon: const Icon(Icons.help_outline),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LegalScreen())),
            ),
          ],
        ),
        // Edge-to-edge (targetSdk 35+): centred content can still reach the
        // system bar on a short landscape viewport.
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'No source configured',
                      style: TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Bring your own IPTV provider — a Stalker portal, an Xtream '
                      'account, or an M3U playlist. No account is needed to try '
                      'the Demo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textLo),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      autofocus: true,
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
            ),
          ),
        ),
      );
    }

    return ChannelListScreen(
      key: ValueKey(_config!.id), // reset list state when the source changes
      repo: repo,
      config: _config!,
      onManageSources: _manageSources,
      profileName: _profileName,
      profileColorIndex: _profileColorIndex,
      onChangeProfile: _changeProfile,
      // Profile settings = the cloud-sync screen; only meaningful when the
      // build has cloud config.
      onProfileSettings: CloudConfig.isConfigured ? _profileSettings : null,
    );
  }
}
