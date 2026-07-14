import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/app_database.dart';
import '../data/distribution_channel.dart';
import '../data/cloud_config.dart';
import '../data/local_profile_store.dart';
import '../data/metadata_config.dart';
import '../data/source_store.dart';
import '../data/update_service.dart';
import '../data/update_store.dart';
import '../sources/source_config.dart';
import '../sources/xtream_source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/tv_text_field.dart';
import 'cloud_sync_screen.dart';
import 'profile_pick_screen.dart';
import 'source_settings_screen.dart';
import 'update_flow.dart';

IconData _kindIcon(SourceKind k) {
  switch (k) {
    case SourceKind.stalker:
      return Icons.router_outlined;
    case SourceKind.xtream:
      return Icons.cloud_outlined;
    case SourceKind.m3u:
      return Icons.playlist_play;
    case SourceKind.demo:
      return Icons.play_circle_outline;
  }
}

/// Lists saved providers; lets you add, edit, delete, and pick the active one.
class SourcesScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;
  const SourcesScreen({super.key, required this.store, required this.db});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  List<SourceConfig> _sources = const [];
  String? _activeId;
  bool _loading = true;

  // One focus node per source row, so we can land focus back on a specific
  // card after returning from the edit/add route (otherwise Navigator restores
  // focus to the Edit icon the user activated).
  final Map<String, FocusNode> _cardFocus = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final node in _cardFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _focusNodeFor(String id) =>
      _cardFocus.putIfAbsent(id, () => FocusNode());

  void _focusCard(String? id) {
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cardFocus[id]?.requestFocus();
    });
  }

  Future<void> _reload() async {
    final list = await widget.store.list();
    final active = await widget.store.activeId();
    if (!mounted) return;
    setState(() {
      _sources = list;
      _activeId = active;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final before = _sources.map((s) => s.id).toSet();
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditSourceScreen(store: widget.store)),
    );
    if (saved != true) return;
    await _reload();
    // Land focus on the newly added source row (fall back to the first card).
    final added = _sources
        .map((s) => s.id)
        .firstWhere((id) => !before.contains(id), orElse: () => '');
    _focusCard(
      added.isNotEmpty
          ? added
          : (_sources.isNotEmpty ? _sources.first.id : null),
    );
  }

  Future<void> _edit(SourceConfig c) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditSourceScreen(store: widget.store, existing: c),
      ),
    );
    if (saved != true) return;
    await _reload();
    _focusCard(c.id);
  }

  Future<void> _openSettings(SourceConfig c) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SourceSettingsScreen(store: widget.store, db: widget.db, config: c),
      ),
    );
    // Settings are saved as they're toggled; refresh so the card reflects them.
    await _reload();
    _focusCard(c.id);
  }

  Future<void> _activate(SourceConfig c) async {
    await widget.store.setActive(c.id);
    await _reload();
  }

  /// Move a source one slot up (delta -1) or down (delta +1) and persist the new
  /// order. Keeps the active selection and refocuses the moved row. Note: cloud
  /// sync orders cloud-managed sources from the panel on the next pull, so this
  /// is most useful for the order among local-only sources.
  Future<void> _move(SourceConfig c, int delta) async {
    final i = _sources.indexWhere((s) => s.id == c.id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _sources.length) return;
    final list = List<SourceConfig>.of(_sources);
    list.insert(j, list.removeAt(i));
    await widget.store.setAll(list);
    await _reload();
    _focusCard(c.id);
  }

  Future<void> _delete(SourceConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: const Text('Delete source?'),
        content: Text('Remove "${c.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.delete(c.id);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sources'),
        actions: [
          IconButton(
            tooltip: 'Profiles',
            icon: const Icon(Icons.switch_account_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) => ProfilePickScreen(
                    db: widget.db,
                    store: widget.store,
                    onDone: () => Navigator.of(ctx).pop(),
                  ),
                ),
              );
              // Switching profiles replaces the source list; refresh.
              await _reload();
            },
          ),
          if (CloudConfig.isConfigured)
            IconButton(
              tooltip: 'Cloud sync',
              icon: const Icon(Icons.cloud_sync_outlined),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        CloudSyncScreen(store: widget.store, db: widget.db),
                  ),
                );
                // A pull may have changed the source list; refresh on return.
                await _reload();
              },
            ),
          IconButton(
            tooltip: 'Metadata',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    MetadataSettingsScreen(store: widget.store, db: widget.db),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      // A FilledButton (rather than a FAB) so it shows the same accent/white
      // focus ring as the "Save source" / "Save" buttons under a D-pad.
      floatingActionButton: FilledButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add source'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: _PickerStartupCard(),
                ),
                if (DistributionConfig.directUpdaterEnabled) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: _UpdateTrackCard(),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: _UpdateCard(),
                  ),
                ],
                Expanded(
                  child: _sources.isEmpty
                      ? const Center(
                          child: Text(
                            'No sources yet — add one',
                            style: TextStyle(color: AppColors.textLo),
                          ),
                        )
                      : _buildSourceList(),
                ),
              ],
            ),
    );
  }

  Widget _buildSourceList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      itemCount: _sources.length,
      itemBuilder: (context, i) {
        final c = _sources[i];
        return _SourceCard(
          key: ValueKey(c.id),
          config: c,
          active: c.id == _activeId,
          autofocus: i == 0,
          focusNode: _focusNodeFor(c.id),
          canMoveUp: i > 0,
          canMoveDown: i < _sources.length - 1,
          onActivate: () => _activate(c),
          onMoveUp: () => _move(c, -1),
          onMoveDown: () => _move(c, 1),
          onSettings: () => _openSettings(c),
          onEdit: () => _edit(c),
          onDelete: () => _delete(c),
        );
      },
    );
  }
}

class _SourceCard extends StatefulWidget {
  final SourceConfig config;
  final bool active;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onActivate;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onSettings;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SourceCard({
    required this.config,
    required this.active,
    required this.autofocus,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onActivate,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onSettings,
    required this.onEdit,
    required this.onDelete,
    this.focusNode,
    super.key,
  });

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  // The row's action buttons are skip-traversal so automatic/directional
  // navigation (Up/Down) never lands on them — vertical arrows only ever stop
  // on the row card. Left/Right step through them explicitly, in order:
  // card → up → down → edit → delete (see _handleDirectional).
  final FocusNode _upNode = FocusNode(skipTraversal: true);
  final FocusNode _downNode = FocusNode(skipTraversal: true);
  final FocusNode _settingsNode = FocusNode(skipTraversal: true);
  final FocusNode _editNode = FocusNode(skipTraversal: true);
  final FocusNode _deleteNode = FocusNode(skipTraversal: true);

  DateTime? _expiry;
  bool _expiryLoading = true;
  bool _expiryFailed = false;

  @override
  void initState() {
    super.initState();
    _fetchExpiry();
  }

  Future<void> _fetchExpiry() async {
    if (mounted) {
      setState(() {
        _expiryLoading = true;
        _expiryFailed = false;
      });
    }
    final source = widget.config.build();
    try {
      final value = await source.subscriptionExpiry();
      if (!mounted) return;
      setState(() {
        _expiry = value;
        _expiryLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _expiryFailed = true;
        _expiryLoading = false;
      });
    } finally {
      await source.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant _SourceCard old) {
    super.didUpdateWidget(old);
    if (old.config.fields.toString() != widget.config.fields.toString() ||
        old.config.kind != widget.config.kind) {
      _fetchExpiry();
    }
  }

  @override
  void dispose() {
    _upNode.dispose();
    _downNode.dispose();
    _settingsNode.dispose();
    _editNode.dispose();
    _deleteNode.dispose();
    super.dispose();
  }

  String get _subtitle {
    switch (widget.config.kind) {
      case SourceKind.stalker:
        return 'Stalker · ${widget.config.fields['portal'] ?? ''}';
      case SourceKind.xtream:
        return 'Xtream · ${widget.config.fields['host'] ?? ''}';
      case SourceKind.m3u:
        return 'M3U · ${widget.config.fields['playlistUrl'] ?? ''}';
      case SourceKind.demo:
        return 'Demo streams';
    }
  }

  // Left/Right walk this ordered chain; Up/Down leave the row (buttons are
  // skip-traversal, so vertical movement only finds adjacent row cards).
  List<FocusNode?> get _chain => [
    widget.focusNode,
    _upNode,
    _downNode,
    _settingsNode,
    _editNode,
    _deleteNode,
  ];

  Object? _handleDirectional(DirectionalFocusIntent intent) {
    final focused = FocusManager.instance.primaryFocus;
    final chain = _chain;
    final idx = chain.indexOf(focused);
    switch (intent.direction) {
      case TraversalDirection.right:
        if (idx >= 0 && idx < chain.length - 1) {
          chain[idx + 1]?.requestFocus();
        }
        // On the last button there is nothing further right — consume.
        return null;
      case TraversalDirection.left:
        if (idx > 0) {
          chain[idx - 1]?.requestFocus();
        } else {
          // On the card (or unknown): leave the row leftwards.
          focused?.focusInDirection(intent.direction);
        }
        return null;
      case TraversalDirection.up:
      case TraversalDirection.down:
        focused?.focusInDirection(intent.direction);
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: _handleDirectional,
        ),
      },
      child: FocusableCard(
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onTap: widget.onActivate,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final icon = Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.panelHi,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _kindIcon(widget.config.kind),
                  color: widget.active ? AppColors.accent : AppColors.textLo,
                ),
              );
              final info = Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.config.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (widget.active) ...[
                          const SizedBox(width: 8),
                          const _ActivePill(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _ExpiryBadge(
                      loading: _expiryLoading,
                      failed: _expiryFailed,
                      expiry: _expiry,
                    ),
                  ],
                ),
              );
              // Move up/down are always enabled so they stay in the Left/Right
              // focus chain on every row; the parent clamps at the ends and the
              // icon dims when there's nowhere to go.
              final actions = <Widget>[
                IconButton(
                  focusNode: _upNode,
                  icon: Icon(
                    Icons.keyboard_arrow_up,
                    color: widget.canMoveUp ? AppColors.textLo : AppColors.line,
                  ),
                  tooltip: 'Move up',
                  onPressed: widget.onMoveUp,
                ),
                IconButton(
                  focusNode: _downNode,
                  icon: Icon(
                    Icons.keyboard_arrow_down,
                    color: widget.canMoveDown
                        ? AppColors.textLo
                        : AppColors.line,
                  ),
                  tooltip: 'Move down',
                  onPressed: widget.onMoveDown,
                ),
                IconButton(
                  focusNode: _settingsNode,
                  icon: const Icon(Icons.tune, color: AppColors.textLo),
                  tooltip: 'Settings',
                  onPressed: widget.onSettings,
                ),
                IconButton(
                  focusNode: _editNode,
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: AppColors.textLo,
                  ),
                  tooltip: 'Edit',
                  onPressed: widget.onEdit,
                ),
                IconButton(
                  focusNode: _deleteNode,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.textLo,
                  ),
                  tooltip: 'Delete',
                  onPressed: widget.onDelete,
                ),
              ];
              // On phones the four action buttons crush the text if kept on the
              // same row, so drop them onto a second row beneath the content.
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [icon, const SizedBox(width: 14), info]),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: actions,
                    ),
                  ],
                );
              }
              return Row(
                children: [icon, const SizedBox(width: 14), info, ...actions],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ExpiryBadge extends StatelessWidget {
  final bool loading;
  final bool failed;
  final DateTime? expiry;
  const _ExpiryBadge({
    required this.loading,
    required this.failed,
    required this.expiry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        height: 16,
        width: 90,
        decoration: BoxDecoration(
          color: AppColors.line.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    if (failed) {
      return _chip(Icons.error_outline, 'Expiry unavailable', AppColors.textLo);
    }
    final e = expiry;
    if (e == null) {
      return _chip(Icons.help_outline, 'Expiry unknown', AppColors.textLo);
    }
    final expired = e.isBefore(DateTime.now());
    final label =
        '${expired ? 'Expired' : 'Expires'} ${e.year}-${e.month.toString().padLeft(2, '0')}-${e.day.toString().padLeft(2, '0')}';
    return _chip(
      expired ? Icons.warning_amber_rounded : Icons.event_available,
      label,
      expired ? Colors.redAccent : AppColors.textLo,
    );
  }

  Widget _chip(IconData icon, String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 12),
        ),
      ),
    ],
  );
}

class _ActivePill extends StatelessWidget {
  const _ActivePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'ACTIVE',
        style: TextStyle(
          color: AppColors.accent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _FieldSpec {
  final String key;
  final String label;
  final String? hint;
  final bool required;
  final bool obscure;
  const _FieldSpec(
    this.key,
    this.label, {
    this.hint,
    this.required = true,
    this.obscure = false,
  });
}

/// Add or edit a single source.
class EditSourceScreen extends StatefulWidget {
  final SourceStore store;
  final SourceConfig? existing;
  const EditSourceScreen({super.key, required this.store, this.existing});

  @override
  State<EditSourceScreen> createState() => _EditSourceScreenState();
}

class _EditSourceScreenState extends State<EditSourceScreen> {
  late SourceKind _kind;
  late final TextEditingController _label;
  final Map<String, TextEditingController> _fields = {};

  @override
  void initState() {
    super.initState();
    _kind = widget.existing?.kind ?? SourceKind.stalker;
    _label = TextEditingController(text: widget.existing?.label ?? '');
  }

  @override
  void dispose() {
    _label.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String key) => _fields.putIfAbsent(
    key,
    () => TextEditingController(text: widget.existing?.fields[key] ?? ''),
  );

  List<_FieldSpec> _specs(SourceKind kind) {
    switch (kind) {
      case SourceKind.stalker:
        return const [
          _FieldSpec('portal', 'Portal URL', hint: 'http://host:port/c/'),
          _FieldSpec('mac', 'MAC address', hint: '00:1A:79:..:..:..'),
        ];
      case SourceKind.xtream:
        return const [
          _FieldSpec('host', 'Host', hint: 'http://host:port'),
          _FieldSpec('username', 'Username'),
          _FieldSpec('password', 'Password', obscure: true),
        ];
      case SourceKind.m3u:
        return const [
          _FieldSpec(
            'playlistUrl',
            'Playlist URL',
            hint: 'http://.../list.m3u',
          ),
          _FieldSpec('epgUrl', 'EPG / XMLTV URL (optional)', required: false),
          _FieldSpec('userAgent', 'User-Agent (optional)', required: false),
        ];
      case SourceKind.demo:
        return const [];
    }
  }

  Future<void> _save() async {
    final specs = _specs(_kind);
    for (final s in specs) {
      if (s.required && _controller(s.key).text.trim().isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${s.label} is required')));
        return;
      }
    }
    final fields = <String, String>{
      for (final s in specs) s.key: _controller(s.key).text.trim(),
    };
    final label = _label.text.trim().isEmpty ? _kind.name : _label.text.trim();
    var config = SourceConfig(
      id: widget.existing?.id ?? newSourceId(),
      kind: _kind,
      label: label,
      fields: fields,
    );
    if (_kind == SourceKind.m3u) {
      final converted = await _maybeConvertM3uToXtream(config);
      if (converted != null) config = converted;
    }
    await widget.store.save(config);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// If the M3U playlist URL is really an Xtream panel (`get.php`) whose
  /// `player_api.php` authenticates, return an equivalent Xtream config so the
  /// user gets Movies/Series. Returns null to keep the source as a flat M3U.
  Future<SourceConfig?> _maybeConvertM3uToXtream(SourceConfig m3u) async {
    final uri = Uri.tryParse(m3u.fields['playlistUrl'] ?? '');
    if (uri == null) return null;
    final creds = xtreamCredentialsFromUrl(uri);
    if (creds == null) return null;
    final probe = XtreamSource(
      host: creds.host,
      username: creds.username,
      password: creds.password,
    );
    try {
      await probe.connect(); // player_api auth check; throws on failure
    } catch (_) {
      return null; // not a working Xtream panel → keep as M3U
    } finally {
      await probe.dispose();
    }
    return SourceConfig(
      id: m3u.id,
      kind: SourceKind.xtream,
      label: m3u.label,
      fields: {
        'host': creds.host,
        'username': creds.username,
        'password': creds.password,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add source' : 'Edit source'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<SourceKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Type'),
            dropdownColor: AppColors.panelHi,
            items: SourceKind.values
                .map(
                  (k) => DropdownMenuItem(
                    value: k,
                    child: Row(
                      children: [
                        Icon(_kindIcon(k), size: 18, color: AppColors.textLo),
                        const SizedBox(width: 10),
                        Text(k.name.toUpperCase()),
                      ],
                    ),
                  ),
                )
                .toList(),
            onChanged: (k) => setState(() => _kind = k ?? _kind),
          ),
          const SizedBox(height: 16),
          TvTextField(
            controller: _label,
            label: 'Label (optional)',
            hintText: 'e.g. Living room IPTV',
            autofocus: widget.existing == null,
            textInputAction: TextInputAction.next,
          ),
          for (final s in _specs(_kind)) ...[
            const SizedBox(height: 16),
            TvTextField(
              controller: _controller(s.key),
              label: s.label,
              hintText: s.hint ?? '',
              obscureText: s.obscure,
              textInputAction: TextInputAction.next,
            ),
          ],
          const SizedBox(height: 28),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _save,
              child: const Text('Save source'),
            ),
          ),
        ],
      ),
    );
  }
}

class MetadataSettingsScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;

  const MetadataSettingsScreen({
    super.key,
    required this.store,
    required this.db,
  });

  @override
  State<MetadataSettingsScreen> createState() => _MetadataSettingsScreenState();
}

class _MetadataSettingsScreenState extends State<MetadataSettingsScreen> {
  final _tmdb = TextEditingController();
  final _tvdb = TextEditingController();
  final _tvdbPin = TextEditingController();
  final _mdblist = TextEditingController();
  String _provider = 'tmdb';
  bool _autoEnrich = true;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tmdb.dispose();
    _tvdb.dispose();
    _tvdbPin.dispose();
    _mdblist.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await widget.store.metadataConfig();
    if (!mounted) return;
    setState(() {
      _provider = config.preferredVisualProvider;
      _tmdb.text = config.tmdbApiKey;
      _tvdb.text = config.tvdbApiKey;
      _tvdbPin.text = config.tvdbPin;
      _mdblist.text = config.mdblistApiKey;
      _autoEnrich = config.autoEnrich;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.store.saveMetadataConfig(
      MetadataConfig(
        provider: _provider,
        tmdbApiKey: MetadataConfig.normalizeTmdbCredential(_tmdb.text),
        tvdbApiKey: _tvdb.text.trim(),
        tvdbPin: _tvdbPin.text.trim(),
        mdblistApiKey: _mdblist.text.trim(),
        autoEnrich: _autoEnrich,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Metadata settings saved')));
  }

  Future<void> _clearMetadataCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: const Text('Clear metadata cache?'),
        content: const Text(
          'This removes cached external metadata. Refresh the source afterward if you want provider titles/posters restored before re-enrichment.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.db.clearExternalMetadata();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Metadata cache cleared')));
  }

  Future<void> _resetMetadataAndDisplay() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: const Text('Reset enriched display?'),
        content: const Text(
          'This clears external metadata and restores cached movie/series display fields from source-provided data where possible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.db.clearExternalMetadata();
    await widget.db.resetEnrichedMediaDisplayFields();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Metadata display reset')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Metadata')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Metadata provider',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Pick the preferred poster/details provider. The other configured visual provider is used as fallback; MDBList adds ratings when possible.',
                  style: TextStyle(color: AppColors.textLo),
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'tmdb', label: Text('TMDB')),
                    ButtonSegment(value: 'tvdb', label: Text('TVDB')),
                  ],
                  selected: {_provider},
                  onSelectionChanged: (value) =>
                      setState(() => _provider = value.first),
                ),
                const SizedBox(height: 16),
                TvTextField(
                  controller: _tmdb,
                  label: 'TMDB API credential',
                  hintText: 'Paste a v3 API key or v4 Read Access Token',
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TvTextField(
                  controller: _tvdb,
                  label: 'TVDB API key',
                  hintText: 'Used as preferred or fallback visual provider',
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TvTextField(
                  controller: _tvdbPin,
                  label: 'TVDB PIN',
                  hintText: 'Optional user-supported key PIN',
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TvTextField(
                  controller: _mdblist,
                  label: 'MDBList API key',
                  hintText: 'Optional ratings enrichment',
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Changes apply after returning to the library.',
                  style: TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  value: _autoEnrich,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-enrich loaded lists'),
                  subtitle: const Text(
                    'Fetch metadata in the background after movies or series load.',
                    style: TextStyle(color: AppColors.textLo),
                  ),
                  onChanged: (value) => setState(() => _autoEnrich = value),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _clearMetadataCache,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear metadata cache'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _resetMetadataAndDisplay,
                  icon: const Icon(Icons.restore_outlined),
                  label: const Text('Reset enriched display'),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving' : 'Save'),
                  ),
                ),
              ],
            ),
    );
  }
}

/// "OK to cycle" tri-state row for when the boot-time profile picker appears
/// (see [ProfilePickerStartup]). A single focus stop, so the D-pad passes over
/// it like any list row; OK/tap cycles Auto → Always → Never.
class _PickerStartupCard extends StatefulWidget {
  const _PickerStartupCard();

  @override
  State<_PickerStartupCard> createState() => _PickerStartupCardState();
}

class _PickerStartupCardState extends State<_PickerStartupCard> {
  static const _store = LocalProfileStore();
  ProfilePickerStartup? _mode; // null while loading

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mode = await _store.pickerStartup();
    if (mounted) setState(() => _mode = mode);
  }

  Future<void> _cycle() async {
    final current = _mode ?? ProfilePickerStartup.auto;
    final next = ProfilePickerStartup
        .values[(current.index + 1) % ProfilePickerStartup.values.length];
    setState(() => _mode = next);
    await _store.setPickerStartup(next);
  }

  String get _valueLabel => switch (_mode) {
    ProfilePickerStartup.always => 'Always',
    ProfilePickerStartup.off => 'Never',
    _ => 'Auto',
  };

  String get _hint => switch (_mode) {
    ProfilePickerStartup.always => 'Shown on every launch',
    ProfilePickerStartup.off => 'Never shown at startup',
    _ => 'Shown when more than one profile exists',
  };

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _cycle,
      scrollOnFocus: false,
      debugLabel: 'sources.pickerStartup',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.switch_account_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Profile picker at startup'),
                  Text(
                    _hint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _valueLabel,
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateTrackCard extends StatefulWidget {
  const _UpdateTrackCard();

  @override
  State<_UpdateTrackCard> createState() => _UpdateTrackCardState();
}

class _UpdateTrackCardState extends State<_UpdateTrackCard> {
  UpdateTrack _track = UpdateTrack.stable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final track = await const UpdateStore().track();
    if (mounted) setState(() => _track = track);
  }

  Future<void> _choose() async {
    final selected = await showDialog<UpdateTrack>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: const Text('GitHub update track'),
        content: const Text(
          'Stable receives normal releases. Beta also receives signed GitHub '
          'prereleases intended for testing. Switching back to Stable never '
          'downgrades the app; it waits for a newer stable release.',
        ),
        actions: [
          TextButton(
            autofocus: _track == UpdateTrack.stable,
            onPressed: () => Navigator.pop(context, UpdateTrack.stable),
            child: const Text('Stable'),
          ),
          FilledButton(
            autofocus: _track == UpdateTrack.beta,
            onPressed: () => Navigator.pop(context, UpdateTrack.beta),
            child: const Text('Beta'),
          ),
        ],
      ),
    );
    if (selected == null || selected == _track) return;
    await const UpdateStore().setTrack(selected);
    if (mounted) setState(() => _track = selected);
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _choose,
      scrollOnFocus: false,
      debugLabel: 'sources.updateTrack',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.science_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('GitHub update track'),
                  Text(
                    _track.displayName,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: AppColors.textLo),
          ],
        ),
      ),
    );
  }
}

/// "Check for updates" row. A single focus stop (like [_PickerStartupCard]);
/// OK/tap runs a manual GitHub check and drives the update flow. The hint shows
/// the running version (see [appVersion]).
class _UpdateCard extends StatefulWidget {
  const _UpdateCard();

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  String? _version; // null while loading
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final version = await appVersion();
      if (mounted) setState(() => _version = version);
    } catch (_) {
      // Leave the generic label if the platform version is unavailable.
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await runUpdateCheck(context, manual: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _check,
      scrollOnFocus: false,
      debugLabel: 'sources.checkUpdate',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.system_update_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Check for updates'),
                  Text(
                    _version == null ? 'Current version' : 'Version $_version',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            if (_checking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textLo,
              ),
          ],
        ),
      ),
    );
  }
}
