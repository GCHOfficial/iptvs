import 'package:flutter/material.dart';

import '../data/source_store.dart';
import '../sources/source_config.dart';

/// Lists saved providers; lets you add, edit, delete, and pick the active one.
class SourcesScreen extends StatefulWidget {
  final SourceStore store;
  const SourcesScreen({super.key, required this.store});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  List<SourceConfig> _sources = const [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
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
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditSourceScreen(store: widget.store)),
    );
    if (saved == true) await _reload();
  }

  Future<void> _edit(SourceConfig c) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditSourceScreen(store: widget.store, existing: c),
      ),
    );
    if (saved == true) await _reload();
  }

  Future<void> _activate(SourceConfig c) async {
    await widget.store.setActive(c.id);
    await _reload();
  }

  Future<void> _delete(SourceConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete source?'),
        content: Text('Remove "${c.label}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.delete(c.id);
      await _reload();
    }
  }

  String _subtitle(SourceConfig c) {
    switch (c.kind) {
      case SourceKind.stalker:
        return 'Stalker · ${c.fields['portal'] ?? ''}';
      case SourceKind.xtream:
        return 'Xtream · ${c.fields['host'] ?? ''}';
      case SourceKind.m3u:
        return 'M3U · ${c.fields['playlistUrl'] ?? ''}';
      case SourceKind.demo:
        return 'Demo streams';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sources')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add source'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sources.isEmpty
              ? const Center(child: Text('No sources yet — add one'))
              : ListView.separated(
                  itemCount: _sources.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = _sources[i];
                    final active = c.id == _activeId;
                    return ListTile(
                      leading: Icon(active
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked),
                      title: Text(c.label),
                      subtitle: Text(_subtitle(c),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _activate(c),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) =>
                            v == 'edit' ? _edit(c) : _delete(c),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    );
                  },
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
  const _FieldSpec(this.key, this.label,
      {this.hint, this.required = true, this.obscure = false});
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
      key, () => TextEditingController(text: widget.existing?.fields[key] ?? ''));

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
          _FieldSpec('playlistUrl', 'Playlist URL', hint: 'http://.../list.m3u'),
          _FieldSpec('epgUrl', 'EPG / XMLTV URL (optional)', required: false),
          _FieldSpec('userAgent', 'User-Agent (optional)', required: false),
        ];
      case SourceKind.demo:
        return const [];
    }
  }

  void _save() {
    final specs = _specs(_kind);
    for (final s in specs) {
      if (s.required && _controller(s.key).text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${s.label} is required')),
        );
        return;
      }
    }
    final fields = <String, String>{
      for (final s in specs) s.key: _controller(s.key).text.trim(),
    };
    final label = _label.text.trim().isEmpty ? _kind.name : _label.text.trim();
    final config = SourceConfig(
      id: widget.existing?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      kind: _kind,
      label: label,
      fields: fields,
    );
    widget.store.save(config).then((_) {
      if (mounted) Navigator.of(context).pop(true);
    });
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
            decoration: const InputDecoration(
                labelText: 'Type', border: OutlineInputBorder()),
            items: SourceKind.values
                .map((k) =>
                    DropdownMenuItem(value: k, child: Text(k.name.toUpperCase())))
                .toList(),
            onChanged: (k) => setState(() => _kind = k ?? _kind),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _label,
            decoration: const InputDecoration(
                labelText: 'Label (optional)', border: OutlineInputBorder()),
          ),
          for (final s in _specs(_kind)) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _controller(s.key),
              obscureText: s.obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: s.label,
                hintText: s.hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}