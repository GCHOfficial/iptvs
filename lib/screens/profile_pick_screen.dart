import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/app_database.dart';
import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/local_profile_store.dart';
import '../data/source_store.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import 'cloud_sync_screen.dart';
import 'home_shell.dart';

// Cycling palette â€” shared with channel_list_screen.dart's avatar widget.
const _kAvatarColors = [
  Color(0xFF2D6BE4),
  Color(0xFFE34040),
  Color(0xFF2DBE8C),
  Color(0xFFE87C26),
  Color(0xFF8B5CF6),
  Color(0xFFE84393),
];

enum _ProfileSource { cloud, local }

/// A unified entry shown in the profile grid â€” can be a cloud profile or a
/// locally-stored profile.
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

/// Boot-time "Who's watching?" screen. Shows cloud profiles (when paired) and
/// local profiles side-by-side, plus a "+" circle to create a new local
/// profile. Always shown when [CloudConfig.isConfigured].
///
/// Navigates to [HomeShell] (or calls [onDone]) when a profile is chosen or
/// the user taps Skip.
class ProfilePickScreen extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;

  /// Injectable for tests; defaults to the live Supabase-backed [CloudSync].
  final CloudSync? sync;

  /// Called instead of navigating to [HomeShell] when provided. Use this when
  /// pushing the picker on top of an already-running home screen (e.g. from
  /// the avatar dropdown) so the caller controls the exit route.
  final VoidCallback? onDone;

  const ProfilePickScreen({
    super.key,
    required this.db,
    required this.store,
    this.sync,
    this.onDone,
  });

  @override
  State<ProfilePickScreen> createState() => _ProfilePickScreenState();
}

class _ProfilePickScreenState extends State<ProfilePickScreen> {
  late final CloudSync _sync = widget.sync ?? CloudSync(db: widget.db);
  final _localStore = LocalProfileStore();

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
    // â”€â”€ Cloud profiles â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    List<CloudProfile> cloudProfiles = [];
    bool isPaired = false;
    String? cloudActiveId;
    if (CloudConfig.isConfigured) {
      try {
        await _sync.ensureAnonSession();
        isPaired = await _sync.isPaired();
        if (isPaired) {
          cloudProfiles = await _sync.listProfiles();
          cloudActiveId = await _sync.activeProfileId();
        }
      } catch (_) {
        // Network error â€” still show local profiles.
      }
    }

    // â”€â”€ Local profiles â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    final localProfiles = await _localStore.loadAll();
    final localActiveId = await _localStore.activeId();

    if (!mounted) return;

    // Build combined entry list: cloud first, then local.
    final entries = <_ProfileEntry>[
      for (var i = 0; i < cloudProfiles.length; i++)
        _ProfileEntry(
          id: cloudProfiles[i].id,
          name: cloudProfiles[i].name,
          colorIndex: i,
          source: _ProfileSource.cloud,
        ),
      for (var i = 0; i < localProfiles.length; i++)
        _ProfileEntry(
          id: localProfiles[i].id,
          name: localProfiles[i].name,
          colorIndex: cloudProfiles.length + i,
          source: _ProfileSource.local,
        ),
    ];

    // Determine the active profile (local takes precedence if set).
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

    setState(() {
      _isPaired = isPaired;
      _profiles = entries;
      _activeProfileId = activeId;
      _activeSource = activeSource;
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

  Future<void> _selectProfile(_ProfileEntry entry) async {
    if (_busy) return;
    // Capture BEFORE setState so the changed-check below isn't comparing
    // entry.id against itself (setState runs synchronously).
    final previousId = _activeProfileId;
    final previousSource = _activeSource;
    setState(() {
      _activeProfileId = entry.id;
      _activeSource = entry.source;
      _busy = true;
      _error = null;
    });
    try {
      // When leaving a local profile, snapshot its current source list so we
      // can restore it when the user switches back.
      if (previousSource == _ProfileSource.local && previousId != null) {
        final currentSources = await widget.store.list();
        final currentActiveId = await widget.store.activeId();
        final allLocal = await _localStore.loadAll();
        final prevIdx = allLocal.indexWhere((p) => p.id == previousId);
        if (prevIdx >= 0) {
          final prev = allLocal[prevIdx];
          await _localStore.save(LocalProfile(
            id: prev.id,
            name: prev.name,
            colorIndex: prev.colorIndex,
            sourcesJson: currentSources.map((c) => c.toJson()).toList(),
            activeSourceId: currentActiveId,
          ));
        }
      }

      if (entry.isCloud) {
        // Always pull when the selection changed or when switching away from a
        // local profile, so each cloud profile's sources are always fresh.
        final changed =
            entry.id != previousId || previousSource != _ProfileSource.cloud;
        if (changed) {
          await _sync.setProfile(entry.id);
          await _sync.pullSources(widget.store, entry.id);
          await _sync.pullMetadata(widget.store, entry.id);
          await _sync.pullFavorites(widget.store, entry.id);
        }
        await _localStore.setActive(null);
      } else {
        // Restore this local profile's saved source list.
        final allLocal = await _localStore.loadAll();
        final target = allLocal.firstWhere(
          (p) => p.id == entry.id,
          orElse: () => throw StateError('profile not found'),
        );
        if (target.sourcesJson.isNotEmpty) {
          final sources = target.sourcesJson
              .map((j) => SourceConfig.fromJson(j))
              .toList();
          await widget.store.setAll(sources);
          if (target.activeSourceId != null) {
            await widget.store.setActive(target.activeSourceId);
          }
        }
        await _localStore.setActive(entry.id);
      }
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

  Future<void> _createLocalProfile() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateProfileDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final colorIndex = _profiles.length; // next slot in palette
      const demoConfig = SourceConfig(
        id: 'demo',
        kind: SourceKind.demo,
        label: 'Demo',
        fields: {},
      );
      // Create the profile with only the demo source so it starts isolated.
      final profile = await _localStore.createProfile(
        name.trim(),
        colorIndex,
        initialSourcesJson: [demoConfig.toJson()],
        initialActiveSourceId: 'demo',
      );
      await _localStore.setActive(profile.id);
      // Apply the profile's source list to the global store.
      await widget.store.setAll([demoConfig]);
      await widget.store.setActive('demo');
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
    // Only local profiles can be deleted from the app.
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
            child: Column(
              children: [
                const SizedBox(height: 40),
                _AppLogo(),
                const SizedBox(height: 40),
                Text(
                  "Who's watching?",
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textHi,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Select a profile to continue',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textLo,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 52),
                // â”€â”€ Profile grid â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
                              autofocus: _profiles[i].id == _activeProfileId,
                              busy: _busy,
                              manageMode: _manageMode,
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
                            if (_profiles.isNotEmpty) const SizedBox(width: 32),
                            _AddProfileCircle(
                              autofocus: _profiles.isEmpty,
                              busy: _busy,
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
                    'Use D-pad to choose a profile',
                    style: TextStyle(
                      color: AppColors.textLo.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                const SizedBox(height: 12),
                // â”€â”€ Link-to-cloud banner â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// â”€â”€ Logo â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
          style: GoogleFonts.spaceGrotesk(
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

// â”€â”€ Profile circle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _ProfileCircle extends StatefulWidget {
  final _ProfileEntry entry;
  final bool isActive;
  final bool autofocus;
  final bool busy;
  final bool manageMode;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const _ProfileCircle({
    required this.entry,
    required this.isActive,
    required this.autofocus,
    required this.busy,
    required this.manageMode,
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
    final color =
        _kAvatarColors[widget.entry.colorIndex % _kAvatarColors.length];
    final ringColor = _focused
        ? Colors.white
        : widget.isActive
            ? AppColors.accent
            : Colors.transparent;
    final ringWidth = _focused ? 3.0 : widget.isActive ? 3.5 : 0.0;

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
          width: 120,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 100,
                height: 100,
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
                      width: 94,
                      height: 94,
                      decoration: BoxDecoration(
                        color: widget.manageMode && widget.entry.isCloud
                            ? color.withValues(alpha: 0.4)
                            : color,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 38,
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
                    // Cloud lock badge (manage mode, cloud profiles — not deletable here)
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
                            border: Border.all(
                              color: AppColors.line,
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            Icons.lock_outline_rounded,
                            color: AppColors.textLo,
                            size: 14,
                          ),
                        ),
                      ),
                    // Green checkmark badge for active profile (hidden in manage mode)
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
                          border: Border.all(
                            color: AppColors.line,
                            width: 1,
                          ),
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
              const SizedBox(height: 14),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:
                      widget.isActive ? AppColors.textHi : AppColors.textLo,
                  fontSize: 15,
                  fontWeight:
                      widget.isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// â”€â”€ Add-profile "+" circle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _AddProfileCircle extends StatefulWidget {
  final bool autofocus;
  final bool busy;
  final VoidCallback onTap;

  const _AddProfileCircle({
    required this.autofocus,
    required this.busy,
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
          width: 120,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 100,
                height: 100,
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
                  size: 40,
                  color: _focused ? AppColors.accent : AppColors.textLo,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Add profile',
                maxLines: 1,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textLo,
                  fontSize: 15,
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

// â”€â”€ Create-profile dialog â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
          onPressed: () =>
              Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

