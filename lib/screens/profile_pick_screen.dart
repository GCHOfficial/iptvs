import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/cloud_sync.dart';
import '../data/source_store.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import 'home_shell.dart';

/// Shown at boot when cloud sync is configured and the device is paired with
/// more than one profile. Lets the user choose which profile to sync before the
/// home screen loads, replacing the need to navigate Sources → Cloud Sync every
/// time. Navigates to [HomeShell] when the user picks a profile or taps Skip.
///
/// Short-circuits directly to [HomeShell] (with no visible UI) when:
///   - the device is not paired, or
///   - the account has only one profile (nothing to choose).
class ProfilePickScreen extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;

  /// Injectable for tests; defaults to the live Supabase-backed [CloudSync].
  final CloudSync? sync;

  const ProfilePickScreen({
    super.key,
    required this.db,
    required this.store,
    this.sync,
  });

  @override
  State<ProfilePickScreen> createState() => _ProfilePickScreenState();
}

class _ProfilePickScreenState extends State<ProfilePickScreen> {
  late final CloudSync _sync = widget.sync ?? CloudSync(db: widget.db);

  bool _checking = true;
  bool _busy = false;
  List<CloudProfile> _profiles = const [];
  String? _activeProfileId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      await _sync.ensureAnonSession();
      if (!await _sync.isPaired()) {
        if (mounted) _goHome();
        return;
      }
      final profiles = await _sync.listProfiles();
      if (!mounted) return;
      if (profiles.length <= 1) {
        // Nothing to choose — proceed directly.
        _goHome();
        return;
      }
      final active = await _sync.activeProfileId();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _activeProfileId = active ?? profiles.first.id;
        _checking = false;
      });
    } catch (_) {
      // Network / cloud error — don't block the user; proceed to home.
      if (mounted) _goHome();
    }
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => HomeShell(db: widget.db, store: widget.store),
      ),
    );
  }

  Future<void> _selectProfile(String id) async {
    if (_busy) return;
    final changed = id != _activeProfileId;
    setState(() {
      _activeProfileId = id;
      _busy = true;
      _error = null;
    });
    try {
      if (changed) {
        await _sync.setProfile(id);
        await _sync.pullSources(widget.store, id);
        await _sync.pullMetadata(widget.store, id);
        await _sync.pullFavorites(widget.store, id);
      }
      if (mounted) _goHome();
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select profile'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _goHome,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Pick which profile this device syncs.',
              style: TextStyle(color: AppColors.textLo),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _profiles.length; i++)
              _ProfileRow(
                name: _profiles[i].name.isEmpty ? 'Profile' : _profiles[i].name,
                selected: _profiles[i].id == _activeProfileId,
                autofocus: _profiles[i].id == _activeProfileId,
                onTap: _busy ? null : () => _selectProfile(_profiles[i].id),
              ),
            if (_busy) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 20),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFE5484D)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final String name;
  final bool selected;
  final bool autofocus;
  final VoidCallback? onTap;

  const _ProfileRow({
    required this.name,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap ?? () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.accent : AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.textHi : AppColors.textLo,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
