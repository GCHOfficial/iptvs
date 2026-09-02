import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/local_profile_store.dart';
import '../data/metadata_config.dart';
import '../data/profile_pin.dart';
import '../data/source_store.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/pin_entry.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/tv_text_field.dart';
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

  /// The profile's PIN verifier, or null when it is open. Local profiles carry
  /// theirs in the keychain; cloud profiles carry theirs in the cloud row (with
  /// a device-side mirror for when the network is down — see
  /// [LocalProfileStore.cloudPins]).
  final String? pin;

  const _ProfileEntry({
    required this.id,
    required this.name,
    required this.colorIndex,
    required this.source,
    this.pin,
  });

  bool get isCloud => source == _ProfileSource.cloud;

  bool get locked => pin != null && pin!.isNotEmpty;
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

  /// The app booted into a PIN-locked profile and has not been let past yet.
  /// While this holds, Skip is hidden and re-selecting the active profile still
  /// asks for its PIN — otherwise the gate would be one tap wide.
  bool _lockedBoot = false;
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
    bool pairingKnown = false;
    bool cloudListed = false;
    String? cloudActiveId;
    final sync = _sync;
    if (sync != null) {
      try {
        // Deliberately does **not** create a session. This runs on the boot
        // path, for every install, and `ensureAnonSession()` here minted an
        // anonymous cloud account for each one — whether or not the user ever
        // opened Cloud sync. Opening that screen is what opts a device in.
        //
        // Skipping it loses nothing: a device with no session cannot be paired
        // (pairing goes through `requestPairingCode`, which creates one and
        // persists it), so `hasSession == false` *is* the answer, and
        // `pairingKnown` stays true because we know it definitively rather than
        // having failed to ask.
        if (sync.hasSession) {
          isPaired = await sync.isPaired();
        }
        pairingKnown = true;
        if (isPaired) {
          cloudProfiles = await sync.listProfiles();
          cloudActiveId = await sync.activeProfileId();
          cloudListed = true;
        }
      } catch (_) {
        // Offline / backend unreachable — behave as unpaired for this visit.
      }
      // The cached fallback is for "the server never answered", never for "the
      // server said no". A device the panel unpaired answers *not paired*
      // definitively, and its stale cache would then conjure a locked cloud
      // profile it can no longer sync — holding the boot screen on a profile
      // that no longer exists for this device.
      if (!cloudListed && !(pairingKnown && !isPaired)) {
        try {
          cloudActiveId = await sync.cachedProfileId();
        } catch (_) {}
      }
    }

    // Mirror the locked cloud profiles device-side on every successful listing,
    // and read the mirror back for the offline case.
    if (cloudListed) {
      await _localStore.saveCloudPins({
        for (final p in cloudProfiles)
          if (p.locked) p.id: CloudProfileLock(verifier: p.pin!, name: p.name),
      });
    }
    final cachedLocks = await _localStore.cloudPins();

    final localProfiles = await _localStore.loadAll();
    final localActiveId = await _localStore.activeId();
    // Is the live device state owned by any profile?
    //
    // The mark is the authority (it is the only thing that can see a *stale*
    // cloud pointer), but it is joined by an inference for the installs that
    // already hit this bug on an older build: they have profiles, no local
    // active id, and no cloud pairing to explain it, and nothing will ever
    // write the mark for them retroactively. The inference deliberately stops
    // at `cloudActiveId != null` — a merely offline device can't draw its
    // active cloud profile either, and its store does hold that profile's
    // sources.
    //
    // A local active id proves a mark is stale — only a real selection writes
    // one — so that direction self-heals too.
    var ownerless = await _localStore.ownerless();
    if (ownerless && localActiveId != null) {
      await _localStore.setOwnerless(false);
      ownerless = false;
    }
    ownerless =
        ownerless ||
        (localProfiles.isNotEmpty &&
            localActiveId == null &&
            cloudActiveId == null);

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
          pin: p.pin,
        ),
      // The device is offline and its cloud profile was locked. Without this
      // the screen would gate the boot (below) on a profile it isn't drawing —
      // a "Who's watching?" with nothing to watch with. The entry is built from
      // the cached lock alone: selecting it is the identity short-circuit, so
      // no cloud call is needed to enter it once the PIN is right.
      if (!cloudListed && cloudActiveId != null)
        if (cachedLocks[cloudActiveId] case final lock?)
          _ProfileEntry(
            id: cloudActiveId,
            name: lock.name.isEmpty ? 'Cloud profile' : lock.name,
            colorIndex: profileColorIndexFor(cloudActiveId),
            source: _ProfileSource.cloud,
            pin: lock.verifier,
          ),
      for (final p in localProfiles)
        _ProfileEntry(
          id: p.id,
          name: p.name,
          colorIndex: p.colorIndex,
          source: _ProfileSource.local,
          pin: p.pin,
        ),
    ];

    // Determine the active profile (an active local profile takes precedence:
    // it's the most recent explicit selection).
    //
    // Unless the device is *ownerless* — the active profile was deleted, so
    // the live store is the empty baseline and belongs to nobody. A persisted
    // cloud `active_profile_id` can outlive that (see
    // `LocalProfileStore.ownerless`), and letting it claim the baseline is how
    // the boot short-circuit and the identity shortcut in `_selectProfile`
    // both end up in an empty library.
    String? activeId;
    _ProfileSource? activeSource;
    if (ownerless) {
      // Nothing is active. Falls through to the checks below with both null.
    } else if (localActiveId != null &&
        entries.any((e) => e.id == localActiveId && !e.isCloud)) {
      activeId = localActiveId;
      activeSource = _ProfileSource.local;
    } else if (cloudActiveId != null &&
        entries.any((e) => e.id == cloudActiveId && e.isCloud)) {
      activeId = cloudActiveId;
      activeSource = _ProfileSource.cloud;
    }
    // No fallback to `entries.first`: a profile is "active" only when a genuine
    // persisted selection (local or cloud) points at it. Auto-promoting the
    // first entry would make the identity shortcut in `_selectProfile` and the
    // parking write in `_snapshotCurrent` trust the live store as that
    // profile's — which is false right after the active profile was deleted
    // (the live store still holds the deleted profile's leftovers, or the empty
    // baseline). Trusting it there overwrites the promoted profile's stored
    // snapshot on the next switch. Leaving `activeId` null keeps
    // `_snapshotCurrent` a no-op until the user explicitly picks a profile,
    // which restores that profile's snapshot through the normal path.

    // A locked active profile turns the boot short-circuit off and holds the
    // screen: the app has not been handed over until the PIN is right, so Skip
    // is withdrawn too (see [_lockedBoot]).
    _ProfileEntry? activeEntry;
    for (final e in entries) {
      if (e.id == activeId && e.source == activeSource) {
        activeEntry = e;
        break;
      }
    }
    final lockedBoot = widget.bootMode && (activeEntry?.locked ?? false);

    if (widget.bootMode) {
      final mode = await _localStore.pickerStartup();
      if (!mounted) return;
      if (!shouldShowPickerAtStartup(
        mode,
        entries.length,
        activeProfileLocked: lockedBoot,
        // Nothing owns the device state — the active profile was deleted and
        // the live store is the empty baseline. Booting past this screen would
        // load an empty library that no restart can fix, because the picker is
        // the only thing that restores a snapshot and with one profile left
        // `auto` never opens it again.
        //
        // Read from the mark, not from `activeId`: a device that is merely
        // *offline* can't draw its active cloud profile either, and its store
        // does still hold that profile's sources. Inferring ownership from the
        // entry list would put "Who's watching?" in front of that user on
        // every launch with no network.
        hasActiveProfile: !ownerless,
      )) {
        _goHome();
        return;
      }
    }

    setState(() {
      _lockedBoot = lockedBoot;
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
  Future<ProfileSnapshot> _captureCurrentSnapshot() async {
    final sources = await widget.store.list();
    return ProfileSnapshot(
      sourcesJson: [for (final c in sources) c.toJson()],
      activeSourceId: await widget.store.activeId(),
      metadataJson: (await widget.store.metadataConfig()).toJson(),
      managedIds: _activeSource == _ProfileSource.cloud
          ? (await _sync?.managedSourceIds())?.toList() ?? const []
          : const [],
    );
  }

  Future<void> _snapshotCurrent([ProfileSnapshot? captured]) async {
    final id = _activeProfileId;
    final source = _activeSource;
    if (id == null || source == null) return;
    final snapshot = captured ?? await _captureCurrentSnapshot();
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

  Future<bool> _confirmSnapshotRestore(
    _ProfileEntry entry,
    ProfileSnapshot current,
    ProfileSnapshot target,
  ) async {
    final preview = previewSnapshotRestore(current, target);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text('Switch to ${entry.name}?'),
        content: Text(
          '${preview.sourcesAdded} source${preview.sourcesAdded == 1 ? '' : 's'} '
          'will be added, ${preview.sourcesRemoved} removed, and '
          '${preview.sourcesRetained} kept.\n'
          'Active source: ${preview.activeSourceLabel ?? 'none'}.\n'
          'Metadata settings: ${preview.metadataChanges ? 'replaced' : 'unchanged'}.\n'
          'Cloud-managed sources: ${preview.managedSources}.'
          '${entry.isCloud ? '\nThe latest panel state will then be pulled.' : ''}',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            // See the note in sources_screen: a D-pad dialog with nothing
            // focused eats the first OK press.
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Switch profile'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Ask for [entry]'s PIN, if it has one. True when the caller may proceed.
  ///
  /// A profile with an unreadable verifier (one written by a newer build) can
  /// never return true — see [verifyProfilePin]. That is deliberate: the only
  /// alternative is opening a profile whose owner asked for it to be shut.
  Future<bool> _passesPin(_ProfileEntry entry) async {
    if (!entry.locked) return true;
    return promptUnlockProfile(
      context,
      profileName: entry.name.isEmpty ? 'Profile' : entry.name,
      verifier: entry.pin!,
    );
  }

  Future<void> _selectProfile(_ProfileEntry entry) async {
    if (_busy) return;
    final isActive =
        entry.id == _activeProfileId && entry.source == _activeSource;
    // The active profile is the one already loaded behind this screen, so
    // re-entering it asks for nothing — *except* at a locked boot, which is
    // precisely the case where the app hasn't been handed over yet.
    //
    // A correct PIN deliberately does **not** clear [_lockedBoot]. Verifying is
    // not entering: the switch below can still be declined at the restore
    // confirmation, or fail on the cloud pull, and leave the user back on this
    // screen. Clearing here would bring Skip back at that point — and Skip goes
    // home into the profile that is *still loaded*, which is the locked one the
    // boot was being held for. The flag only ever ends by leaving the screen.
    if (entry.locked && (!isActive || _lockedBoot)) {
      if (!await _passesPin(entry)) return;
      if (!mounted) return;
    }
    // Re-selecting the active profile: the store already holds its state.
    if (isActive) {
      _goHome();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = await _captureCurrentSnapshot();
      ProfileSnapshot target;
      if (entry.isCloud) {
        target =
            await _localStore.cloudSnapshot(entry.id) ??
            const ProfileSnapshot();
      } else {
        final all = await _localStore.loadAll();
        target = all
            .firstWhere(
              (p) => p.id == entry.id,
              orElse: () => throw StateError('profile not found'),
            )
            .snapshot;
      }
      if (!mounted || !await _confirmSnapshotRestore(entry, current, target)) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await _snapshotCurrent(current);
      if (entry.isCloud) {
        final sync = _sync!;
        final snapshot = target.sourcesJson.isEmpty
            ? await _localStore.cloudSnapshot(entry.id)
            : target;
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
      await _localStore.setOwnerless(false);
      setState(() {
        _activeProfileId = entry.id;
        _activeSource = entry.source;
      });
      _goHome();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          // A cloud call here can throw a PostgrestException whose details/hint
          // may embed row data (credentials in a provider URL). friendlyCloudError
          // shows only the safe, redacted message and never `$e`.
          _error = friendlyCloudError(e);
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
      await _localStore.setOwnerless(false);
      _activeProfileId = profile.id;
      _activeSource = _ProfileSource.local;
      if (mounted) _goHome();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          // Snapshotting the outgoing (possibly cloud) profile can hit a cloud
          // call that throws a PostgrestException with credential-bearing
          // details; render only the safe, redacted message.
          _error = friendlyCloudError(e);
        });
      }
    }
  }

  // ── Manage mode ───────────────────────────────────────────────────────────

  /// The manage-mode menu for one profile.
  ///
  /// It opens **without** the PIN, and that is a deliberate asymmetry: the two
  /// PIN actions inside each ask for the current one, while Delete does not.
  /// Deleting reveals nothing — it only destroys — and it is the one way out of
  /// a forgotten PIN on a device-local profile, which has no panel to clear it
  /// from. Putting delete behind the PIN would trade a gate for a profile that
  /// can neither be opened nor removed.
  Future<void> _manageProfile(_ProfileEntry entry) async {
    if (_busy) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.panel,
        title: Text(entry.name.isEmpty ? 'Profile' : entry.name),
        // `ListTile`, not `SimpleDialogOption`: on a remote every row has to be
        // a focus target, and the first has to take focus when it opens.
        children: [
          ListTile(
            autofocus: true,
            leading: const Icon(Icons.pin_outlined),
            title: Text(entry.locked ? 'Change PIN' : 'Set a PIN'),
            onTap: () => Navigator.of(ctx).pop('pin'),
          ),
          if (entry.locked)
            ListTile(
              leading: const Icon(Icons.lock_open_rounded),
              title: const Text('Remove PIN'),
              onTap: () => Navigator.of(ctx).pop('unpin'),
            ),
          if (!entry.isCloud)
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.danger,
              ),
              title: const Text(
                'Delete profile',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Cancel'),
            onTap: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'pin':
        await _setPin(entry);
      case 'unpin':
        await _setPin(entry, remove: true);
      case 'delete':
        await _deleteProfile(entry);
    }
  }

  /// Set, change, or (with [remove]) clear [entry]'s PIN.
  ///
  /// Changing or clearing an existing PIN requires the current one — otherwise
  /// the gate would be removable by whoever it was meant to keep out.
  Future<void> _setPin(_ProfileEntry entry, {bool remove = false}) async {
    if (entry.locked && !await _passesPin(entry)) return;
    if (!mounted) return;
    String? verifier;
    if (!remove) {
      final pin = await promptNewProfilePin(
        context,
        profileName: entry.name.isEmpty ? 'Profile' : entry.name,
      );
      if (pin == null || !mounted) return;
      verifier = hashProfilePin(pin);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (entry.isCloud) {
        final sync = _sync;
        if (sync == null) throw StateError('cloud is not configured');
        await sync.setProfilePin(entry.id, verifier);
        // Mirror it immediately rather than waiting for the next listing: the
        // gate has to hold on the very next boot, network or not.
        await _localStore.setCloudPin(entry.id, verifier, name: entry.name);
      } else {
        await _localStore.setPin(entry.id, verifier);
      }
      if (!mounted) return;
      // `_check` does not clear `_busy` — it only ever runs while the screen is
      // idle — so the reload below would otherwise leave every circle inert.
      setState(() => _busy = false);
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          // A cloud RPC failure can carry Postgres details that echo row data;
          // render only the safe, redacted message.
          _error = friendlyCloudError(e);
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
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _localStore.delete(entry.id);
    if (_activeProfileId == entry.id && _activeSource == entry.source) {
      // Deleting the profile we're currently "in". Its device state is still
      // live in the store; drop to a neutral empty baseline so those leftovers
      // can neither be shown after a Skip nor be parked into another profile on
      // the next switch. No profile is marked active — the user must explicitly
      // pick one, which restores its snapshot the normal way. This is the
      // invariant that guarantees no profile's stored snapshot is ever
      // overwritten with state that isn't its own.
      await _restoreSnapshot(const ProfileSnapshot());
      await _localStore.setOwnerless(true);
      _activeProfileId = null;
      _activeSource = null;
      await _adoptSoleSurvivor(entry);
    }
    await _reload();
  }

  /// After deleting the profile that was active, the device holds the neutral
  /// empty baseline and *no* profile owns it. When exactly one profile is
  /// left, adopt it here — restoring its snapshot the same way a switch would.
  ///
  /// Without this the survivor is only reachable by finding the profile
  /// switcher by hand: the boot check does force the picker open now, but the
  /// user who deletes a profile and walks away (Skip, or straight into the
  /// app) sits in an empty library until the next launch, and every earlier
  /// build shipped that dead end permanently. Adopting is safe precisely
  /// because nothing is active: [_snapshotCurrent] is a no-op, so the
  /// survivor's stored snapshot cannot be overwritten with state that isn't
  /// its own before it is read back.
  ///
  /// A locked survivor is deliberately left unadopted — its sources would then
  /// sit one Skip away with no PIN ever asked. It is entered through the
  /// picker, which the ownerless boot check now always opens.
  Future<void> _adoptSoleSurvivor(_ProfileEntry deleted) async {
    final survivors = [
      for (final e in _profiles)
        if (e.id != deleted.id || e.source != deleted.source) e,
    ];
    if (survivors.length != 1) return;
    final survivor = survivors.single;
    // Cloud entries stay out: entering one is a pull, not a restore.
    if (survivor.isCloud || survivor.locked) return;
    final all = await _localStore.loadAll();
    final idx = all.indexWhere((p) => p.id == survivor.id);
    if (idx < 0) return;
    await _restoreSnapshot(all[idx].snapshot);
    await _localStore.setActive(survivor.id);
    await _localStore.setOwnerless(false);
    _activeProfileId = survivor.id;
    _activeSource = _ProfileSource.local;
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
        backgroundColor: AppColors.ink,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.ink,
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
                                  // Cloud profiles are manageable here too now
                                  // — their PIN is one of the few things the
                                  // app can change about them (deleting one is
                                  // still the panel's job).
                                  onManage: () => _manageProfile(_profiles[i]),
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
                            color: AppColors.danger,
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
                    // Skip is withdrawn while a locked profile is holding the
                    // boot: it is a way past the picker, and past the picker is
                    // exactly where the PIN is meant to stop you.
                    if (!_manageMode && !_lockedBoot)
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

  /// Manage-mode activation: opens the profile's menu (PIN, delete).
  final VoidCallback? onManage;

  const _ProfileCircle({
    required this.entry,
    required this.isActive,
    required this.autofocus,
    required this.busy,
    required this.manageMode,
    required this.avatarSize,
    required this.compact,
    required this.onTap,
    required this.onManage,
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
                widget.onManage?.call();
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
            ? widget.onManage
            : widget.onTap,
        child: SizedBox(
          width: widget.avatarSize + 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: appMotion(context, const Duration(milliseconds: 150)),
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
                    // Manage badge. One badge for both kinds now that manage
                    // mode opens a menu rather than deleting on the spot — the
                    // menu is where the two kinds differ (a cloud profile is
                    // still deleted from the web panel, not here).
                    if (widget.manageMode)
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
                          child: const Icon(
                            Icons.more_horiz_rounded,
                            color: AppColors.textHi,
                            size: 16,
                          ),
                        ),
                      ),
                    // PIN badge — shown in every mode, because "this profile
                    // will ask for a PIN" is information you want *before*
                    // choosing it, not only while managing.
                    if (widget.entry.locked)
                      Positioned(
                        left: 0,
                        top: 0,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: AppColors.panel,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.line, width: 1),
                          ),
                          child: const Icon(
                            Icons.lock_rounded,
                            color: AppColors.accent,
                            size: 13,
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
                            color: AppColors.success,
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
                duration: appMotion(context, const Duration(milliseconds: 150)),
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
      // TvTextField, not a bare TextField: on a TV remote a plain TextField
      // traps D-pad focus (the editor eats the arrow keys), leaving no way out.
      // This wraps it in the "OK to edit" cell the rest of the app uses.
      content: TvTextField(
        controller: _controller,
        label: 'Profile name',
        hintText: 'e.g. Living room',
        autofocus: true,
        textInputAction: TextInputAction.done,
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
