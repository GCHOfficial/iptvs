import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/local_profile_store.dart';
import '../data/metadata_config.dart';
import '../data/source_store.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/profile_avatar.dart';
import 'cloud_sync_screen.dart';
import 'home_shell.dart';

enum _ProfileSource { cloud, local }

@visibleForTesting
String profileSelectionHint(NavigationMode mode) =>
    mode == NavigationMode.directional
    ? 'Use D-pad to choose a profile'
    : 'Choose a profile to continue';

/// A unified entry shown in the profile grid — a cloud profile (when the
/// device is paired) or a locally-stored profile.
class _ProfileEntry {
  final String id;
  final String name;
  final int colorIndex;
  final _ProfileSource source;

  const _ProfileEntry({
    required this.id,
    required this.name,
    required this.colorIndex,
    required this.source,
  });

  bool get isCloud => source == _ProfileSource.cloud;
}

/// "Who's watching?" screen. Local profiles work with no cloud account; cloud
/// profiles appear alongside them when the build has Supabase config and the
/// device is paired. A "+" circle creates a new local profile.
///
/// At boot ([bootMode]) the screen decides for itself whether to appear: the
/// startup-mode setting ([LocalProfileStore.pickerStartup]) and the profile
/// count feed [shouldShowPickerAtStartup]; when the answer is no it navigates
/// straight to [HomeShell] without painting the grid, so the app boots exactly
/// as before for single-profile users.
///
/// Navigates to [HomeShell] (or calls [onDone]) when a profile is chosen or
/// the user taps Skip.
class ProfilePickScreen extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;

  /// True when this screen is the app's `home` at startup — enables the
  /// show-or-skip decision. False when pushed from the avatar menu, where the
  /// user explicitly asked for it.
  final bool bootMode;

  /// Injectable for tests; defaults to the live Supabase-backed [CloudSync]
  /// (only constructed when [CloudConfig.isConfigured]).
  final CloudSync? sync;

  /// Called instead of navigating to [HomeShell] when provided. Use this when
  /// pushing the picker on top of an already-running home screen (e.g. from
  /// the avatar dropdown) so the caller controls the exit route.
  final VoidCallback? onDone;

  const ProfilePickScreen({
    super.key,
    required this.db,
    required this.store,
    this.bootMode = false,
    this.sync,
    this.onDone,
  });

  @override
  State<ProfilePickScreen> createState() => _ProfilePickScreenState();
}

class _ProfilePickScreenState extends State<ProfilePickScreen> {
  CloudSync? _syncCached;

  /// Null when the build has no cloud config — every cloud call is skipped.
  CloudSync? get _sync {
    if (widget.sync != null) return widget.sync;
    if (!CloudConfig.isConfigured) return null;
    return _syncCached ??= CloudSync(db: widget.db);
  }

  final _localStore = const LocalProfileStore();

  bool _checking = true;
  bool _busy = false;
  bool _isPaired = false;
  bool _manageMode = false;
  List<_ProfileEntry> _profiles = const [];
  String? _activeProfileId;
  _ProfileSource? _activeSource;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _reload() async {
    setState(() => _checking = true);
    await _check();
  }

  Future<void> _check() async {
    // Cloud profiles — only when configured; a network error still shows the
    // local profiles.
    List<CloudProfile> cloudProfiles = [];
    bool isPaired = false;
    String? cloudActiveId;
    final sync = _sync;
    if (sync != null) {
      try {
        await sync.ensureAnonSession();
        isPaired = await sync.isPaired();
        if (isPaired) {
          cloudProfiles = await sync.listProfiles();
          cloudActiveId = await sync.activeProfileId();
        }
      } catch (_) {
        // Offline / backend unreachable — behave as unpaired for this visit.
      }
    }

    final localProfiles = await _localStore.loadAll();
    final localActiveId = await _localStore.activeId();

    if (!mounted) return;

    // Combined entry list: cloud first, then local. Cloud colours are derived
    // from the profile id so they don't shift when the panel reorders.
    final entries = <_ProfileEntry>[
      for (final p in cloudProfiles)
        _ProfileEntry(
          id: p.id,
          name: p.name,
          colorIndex: profileColorIndexFor(p.id),
          source: _ProfileSource.cloud,
        ),
      for (final p in localProfiles)
        _ProfileEntry(
          id: p.id,
          name: p.name,
          colorIndex: p.colorIndex,
          source: _ProfileSource.local,
        ),
    ];

    // Determine the active profile (an active local profile takes precedence:
    // it's the most recent explicit selection).
    String? activeId;
    _ProfileSource? activeSource;
    if (localActiveId != null &&
        entries.any((e) => e.id == localActiveId && !e.isCloud)) {
      activeId = localActiveId;
      activeSource = _ProfileSource.local;
    } else if (cloudActiveId != null &&
        entries.any((e) => e.id == cloudActiveId && e.isCloud)) {
      activeId = cloudActiveId;
      activeSource = _ProfileSource.cloud;
    } else if (entries.isNotEmpty) {
      activeId = entries.first.id;
      activeSource = entries.first.source;
    }

    if (widget.bootMode) {
      final mode = await _localStore.pickerStartup();
      if (!mounted) return;
      if (!shouldShowPickerAtStartup(mode, entries.length)) {
        _goHome();
        return;
      }
    }

    setState(() {
      _isPaired = isPaired;
      _profiles = entries;
      _activeProfileId = activeId;
      _activeSource = activeSource;
      // Manage mode is meaningless with zero profiles — and while it's on the
      // build hides the "+" add button, Skip, and the Manage/Done toggle, which
      // is exactly the empty-screen dead-end you'd hit after deleting the last
      // profile. Drop out of it whenever the list empties.
      _manageMode = entries.isEmpty ? false : _manageMode;
      _checking = false;
    });
  }

  void _goHome() {
    if (!mounted) return;
    if (widget.onDone != null) {
      widget.onDone!();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => HomeShell(db: widget.db, store: widget.store),
      ),
    );
  }

  /// Save the device state (sources, active source, metadata config, and the
  /// cloud-managed ids) into the profile that owned it, so switching back
  /// restores it exactly.
  Future<void> _snapshotCurrent() async {
    final id = _activeProfileId;
    final source = _activeSource;
    if (id == null || source == null) return;
    final sources = await widget.store.list();
    final snapshot = ProfileSnapshot(
      sourcesJson: [for (final c in sources) c.toJson()],
      activeSourceId: await widget.store.activeId(),
      metadataJson: (await widget.store.metadataConfig()).toJson(),
      // Only a cloud profile can own cloud-managed sources.
      managedIds: source == _ProfileSource.cloud
          ? (await _sync?.managedSourceIds())?.toList() ?? const []
          : const [],
    );
    if (source == _ProfileSource.local) {
      final all = await _localStore.loadAll();
      final idx = all.indexWhere((p) => p.id == id);
      if (idx >= 0) await _localStore.save(all[idx].withSnapshot(snapshot));
    } else {
      await _localStore.saveCloudSnapshot(id, snapshot);
    }
  }

  /// Replace the device state with [snapshot] — the whole list (even when
  /// empty: an emptied profile must come back empty, not inherit the previous
  /// profile's sources), the metadata config, and the managed-ids set.
  Future<void> _restoreSnapshot(ProfileSnapshot snapshot) async {
    final sources = [
      for (final j in snapshot.sourcesJson) SourceConfig.fromJson(j),
    ];
    await widget.store.setAll(sources);
    final active = snapshot.activeSourceId;
    if (active != null && sources.any((c) => c.id == active)) {
      await widget.store.setActive(active);
    }
    final metadata = snapshot.metadataJson;
    if (metadata != null) {
      await widget.store.saveMetadataConfig(MetadataConfig.fromJson(metadata));
    }
    await _sync?.setManagedSourceIds(snapshot.managedIds.toSet());
  }

  Future<void> _selectProfile(_ProfileEntry entry) async {
    if (_busy) return;
    // Re-selecting the active profile: the store already holds its state.
    if (entry.id == _activeProfileId && entry.source == _activeSource) {
      _goHome();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _snapshotCurrent();
      if (entry.isCloud) {
        final sync = _sync!;
        final snapshot = await _localStore.cloudSnapshot(entry.id);
        if (snapshot != null) {
          // Bring back this profile's device-local extras + managed ids so the
          // pull below prunes/refreshes the right set.
          await _restoreSnapshot(snapshot);
        } else {
          // First visit: start from a clean slate so the previous profile's
          // sources can't survive the pull as "device-local" leftovers.
          await widget.store.setAll(const []);
          await sync.setManagedSourceIds(const {});
        }
        await sync.setProfile(entry.id);
        await sync.pullSources(widget.store, entry.id);
        await sync.pullMetadata(widget.store, entry.id);
        await sync.pullFavorites(widget.store, entry.id);
        await _localStore.setActive(null);
      } else {
        final all = await _localStore.loadAll();
        final target = all.firstWhere(
          (p) => p.id == entry.id,
          orElse: () => throw StateError('profile not found'),
        );
        await _restoreSnapshot(target.snapshot);
        await _localStore.setActive(entry.id);
      }
      setState(() {
        _activeProfileId = entry.id;
        _activeSource = entry.source;
      });
      _goHome();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _createLocalProfile() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateProfileDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Park the current state with its owner before the new profile takes
      // over the store.
      await _snapshotCurrent();
      const demoConfig = SourceConfig(
        id: 'demo',
        kind: SourceKind.demo,
        label: 'Demo',
        fields: {},
      );
      // Seed with only the demo source so the profile starts clean, with no
      // inherited IPTV providers.
      final seed = ProfileSnapshot(
        sourcesJson: [demoConfig.toJson()],
        activeSourceId: 'demo',
        metadataJson: (await widget.store.metadataConfig()).toJson(),
      );
      final profile = await _localStore.createProfile(
        name.trim(),
        _profiles.length, // next palette slot
        snapshot: seed,
      );
      await _restoreSnapshot(seed);
      await _localStore.setActive(profile.id);
      _activeProfileId = profile.id;
      _activeSource = _ProfileSource.local;
      if (mounted) _goHome();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _deleteProfile(_ProfileEntry entry) async {
    // Only local profiles can be deleted from the app; cloud profiles are
    // managed in the web panel.
    if (entry.isCloud) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Delete profile?'),
        content: Text(
          'Delete “${entry.name}”? This cannot be undone.',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _localStore.delete(entry.id);
    if (_activeProfileId == entry.id) {
      _activeProfileId = null;
      _activeSource = null;
    }
    await _reload();
  }

  Future<void> _goToCloudSync() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CloudSyncScreen(store: widget.store, db: widget.db),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1220),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.1),
                  radius: 1.2,
                  colors: [
                    AppColors.accent.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // TV logical heights run ~540–720dp — the roomy phone/desktop
                // spacing overflows the grid area there and paints over the
                // footer. Scale the fixed chrome down with available height.
                final compact = constraints.maxHeight < 640;
                final tight = constraints.maxHeight < 520;
                final avatarSize = tight
                    ? 64.0
                    : compact
                    ? 80.0
                    : 100.0;
                return Column(
                  children: [
                    SizedBox(height: compact ? 16 : 40),
                    _AppLogo(),
                    SizedBox(height: compact ? 14 : 40),
                    Text(
                      "Who's watching?",
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: compact ? 28 : 38,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textHi,
                        letterSpacing: -0.5,
                      ),
                    ),
                    SizedBox(height: compact ? 6 : 10),
                    Text(
                      'Select a profile to continue',
                      style: TextStyle(
                        fontSize: compact ? 13 : 15,
                        color: AppColors.textLo,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    SizedBox(height: compact ? 18 : 52),
                    // Profile grid
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < _profiles.length; i++) ...[
                                if (i > 0) const SizedBox(width: 32),
                                _ProfileCircle(
                                  entry: _profiles[i],
                                  isActive: _profiles[i].id == _activeProfileId,
                                  autofocus:
                                      _profiles[i].id == _activeProfileId,
                                  busy: _busy,
                                  manageMode: _manageMode,
                                  avatarSize: avatarSize,
                                  compact: compact,
                                  onTap: _manageMode
                                      ? null
                                      : () => _selectProfile(_profiles[i]),
                                  onDelete: _profiles[i].isCloud
                                      ? null
                                      : () => _deleteProfile(_profiles[i]),
                                ),
                              ],
                              // "+" button — always last
                              if (!_manageMode) ...[
                                if (_profiles.isNotEmpty)
                                  const SizedBox(width: 32),
                                _AddProfileCircle(
                                  autofocus: _profiles.isEmpty,
                                  busy: _busy,
                                  avatarSize: avatarSize,
                                  compact: compact,
                                  onTap: _createLocalProfile,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFE5484D),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_busy)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Text(
                        profileSelectionHint(
                          MediaQuery.navigationModeOf(context),
                        ),
                        style: TextStyle(
                          color: AppColors.textLo.withValues(alpha: 0.6),
                          fontSize: 13,
                        ),
                      ),
                    SizedBox(height: compact ? 4 : 12),
                    // Link-to-cloud banner (configured builds that aren't
                    // paired)
                    if (!_isPaired && CloudConfig.isConfigured && !_manageMode)
                      TextButton.icon(
                        onPressed: _busy ? null : _goToCloudSync,
                        icon: const Icon(Icons.cloud_outlined, size: 16),
                        label: const Text('Link to cloud account'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textLo,
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                      ),
                    // Manage / Done toggle
                    if (_profiles.isNotEmpty)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _manageMode = !_manageMode),
                        child: Text(
                          _manageMode ? 'Done' : 'Manage profiles',
                          style: TextStyle(
                            color: _manageMode
                                ? AppColors.accent
                                : AppColors.textLo.withValues(alpha: 0.6),
                            fontSize: 13,
                            fontWeight: _manageMode
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    if (!_manageMode)
                      TextButton(
                        onPressed: _busy ? null : _goHome,
                        child: Text(
                          'Skip',
                          style: TextStyle(
                            color: AppColors.textLo.withValues(alpha: 0.5),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    SizedBox(height: compact ? 10 : 24),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Logo ─────────────────────────────────────────────────────────────────────

class _AppLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, const Color(0xFF4F8FF7)],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            color: Colors.white,
            size: 28,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'iptvs',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: AppColors.textHi,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

// ── Profile circle ───────────────────────────────────────────────────────────

class _ProfileCircle extends StatefulWidget {
  final _ProfileEntry entry;
  final bool isActive;
  final bool autofocus;
  final bool busy;
  final bool manageMode;

  /// Outer circle diameter — scaled down by the screen on short viewports.
  final double avatarSize;

  /// The screen's short-viewport decision (drives label gap/font, so the
  /// threshold lives in one place — the screen's LayoutBuilder).
  final bool compact;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const _ProfileCircle({
    required this.entry,
    required this.isActive,
    required this.autofocus,
    required this.busy,
    required this.manageMode,
    required this.avatarSize,
    required this.compact,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_ProfileCircle> createState() => _ProfileCircleState();
}

class _ProfileCircleState extends State<_ProfileCircle> {
  bool _focused = false;
  late final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.entry.name.isEmpty ? 'Profile' : widget.entry.name;
    final initial = name[0].toUpperCase();
    final color = profileAvatarColor(widget.entry.colorIndex);
    // White focus ring (always visible over any avatar colour); accent ring
    // marks the active profile when unfocused.
    final ringColor = _focused
        ? Colors.white
        : widget.isActive
        ? AppColors.accent
        : Colors.transparent;
    final ringWidth = _focused
        ? 3.0
        : widget.isActive
        ? 3.5
        : 0.0;

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      focusNode: _focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (!widget.busy) {
              if (widget.manageMode) {
                widget.onDelete?.call();
              } else {
                widget.onTap?.call();
              }
            }
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.busy
            ? null
            : widget.manageMode
            ? widget.onDelete
            : widget.onTap,
        child: SizedBox(
          width: widget.avatarSize + 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: widget.avatarSize,
                height: widget.avatarSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor, width: ringWidth),
                  boxShadow: widget.isActive
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.35),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: widget.avatarSize - 6,
                      height: widget.avatarSize - 6,
                      decoration: BoxDecoration(
                        color: widget.manageMode && widget.entry.isCloud
                            ? color.withValues(alpha: 0.4)
                            : color,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: widget.avatarSize * 0.38,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    // Delete badge (manage mode, local profiles only)
                    if (widget.manageMode && !widget.entry.isCloud)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                            color: Color(0xFFE5484D),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    // Cloud lock badge (manage mode, cloud profiles — deleted
                    // from the web panel, not here)
                    if (widget.manageMode && widget.entry.isCloud)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: AppColors.panel,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.line, width: 1),
                          ),
                          child: Icon(
                            Icons.lock_outline_rounded,
                            color: AppColors.textLo,
                            size: 14,
                          ),
                        ),
                      ),
                    // Green checkmark badge for the active profile
                    if (widget.isActive && !widget.manageMode)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: const BoxDecoration(
                            color: Color(0xFF22C55E),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 15,
                          ),
                        ),
                      ),
                    // Cloud / device badge
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: AppColors.panel,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.line, width: 1),
                        ),
                        child: Icon(
                          widget.entry.isCloud
                              ? Icons.cloud_outlined
                              : Icons.phone_android_outlined,
                          color: AppColors.textLo,
                          size: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: widget.compact ? 8 : 14),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.isActive ? AppColors.textHi : AppColors.textLo,
                  fontSize: widget.compact ? 13 : 15,
                  fontWeight: widget.isActive
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Add-profile "+" circle ───────────────────────────────────────────────────

class _AddProfileCircle extends StatefulWidget {
  final bool autofocus;
  final bool busy;
  final double avatarSize;
  final bool compact;
  final VoidCallback onTap;

  const _AddProfileCircle({
    required this.autofocus,
    required this.busy,
    required this.avatarSize,
    required this.compact,
    required this.onTap,
  });

  @override
  State<_AddProfileCircle> createState() => _AddProfileCircleState();
}

class _AddProfileCircleState extends State<_AddProfileCircle> {
  bool _focused = false;
  late final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      focusNode: _focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (!widget.busy) widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.busy ? null : widget.onTap,
        child: SizedBox(
          width: widget.avatarSize + 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: widget.avatarSize,
                height: widget.avatarSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _focused ? AppColors.accent : AppColors.line,
                    width: _focused ? 2.5 : 1.5,
                  ),
                  color: AppColors.panel.withValues(alpha: _focused ? 1 : 0.6),
                  boxShadow: _focused
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.2),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.add_rounded,
                  size: widget.avatarSize * 0.4,
                  color: _focused ? AppColors.accent : AppColors.textLo,
                ),
              ),
              SizedBox(height: widget.compact ? 8 : 14),
              Text(
                'Add profile',
                maxLines: 1,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textLo,
                  fontSize: widget.compact ? 13 : 15,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Create-profile dialog ────────────────────────────────────────────────────

class _CreateProfileDialog extends StatefulWidget {
  const _CreateProfileDialog();

  @override
  State<_CreateProfileDialog> createState() => _CreateProfileDialogState();
}

class _CreateProfileDialogState extends State<_CreateProfileDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: const Text('New profile'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Profile name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
