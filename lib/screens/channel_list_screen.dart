import 'dart:async';

import 'package:flutter/material.dart';

import '../data/library_repository.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../player/player_screen.dart';

/// Lists a source's channels with in-memory search + category filtering, plus
/// now/next EPG (when the source provides it).
class ChannelListScreen extends StatefulWidget {
  final LibraryRepository repo;
  final VoidCallback? onManageSources;
  const ChannelListScreen({super.key, required this.repo, this.onManageSources});

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  final _searchController = TextEditingController();

  List<Category> _categories = const [];
  List<Channel> _all = const [];
  Map<String, Programme> _now = const {};
  Map<String, Programme> _next = const {};
  String? _categoryId;
  String _query = '';

  bool _loading = true;
  bool _resolving = false;
  String? _error;
  DateTime? _syncedAt;
  bool _fromCache = false;
  Timer? _epgTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _epgTimer =
        Timer.periodic(const Duration(minutes: 1), (_) => _refreshNowNext());
  }

  @override
  void dispose() {
    _epgTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await widget.repo.load(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _categories = snap.categories;
        _all = snap.channels;
        _syncedAt = snap.syncedAt;
        _fromCache = snap.fromCache;
        _loading = false;
      });
      await _refreshNowNext();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _refreshNowNext() async {
    try {
      final nn = await widget.repo.nowNext();
      if (!mounted) return;
      setState(() {
        _now = nn.now;
        _next = nn.next;
      });
    } catch (_) {}
  }

  List<Channel> get _visible {
    final q = _query.trim().toLowerCase();
    return _all.where((c) {
      if (_categoryId != null && c.categoryId != _categoryId) return false;
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  Future<void> _play(Channel channel) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stream = await widget.repo.resolve(channel);
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(title: channel.name, stream: stream),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not play: $e')));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  String _fmt(int n) => n
      .toString()
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  String _statusLine(int count) {
    final b = StringBuffer('${_fmt(count)} channels');
    if (_syncedAt != null) {
      b.write(_fromCache
          ? ' · cached, synced ${_ago(_syncedAt!)}'
          : ' · synced ${_ago(_syncedAt!)}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.repo.source.name),
        actions: [
          if (widget.onManageSources != null)
            IconButton(
              tooltip: 'Sources',
              icon: const Icon(Icons.dns_outlined),
              onPressed: widget.onManageSources,
            ),
          IconButton(
            tooltip: 'Refresh from source',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(forceRefresh: true),
          ),
          const SizedBox(width: 4),
        ],
        bottom: _resolving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search channels',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _CategoryDropdown(
                  categories: _categories,
                  value: _categoryId,
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _loading ? '' : _statusLine(visible.length),
                style: const TextStyle(color: AppColors.textLo, fontSize: 12),
              ),
            ),
          ),
          Expanded(child: _body(visible)),
        ],
      ),
    );
  }

  Widget _body(List<Channel> visible) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Couldn\'t load this source.\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textLo)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _load(forceRefresh: true),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return const Center(
        child: Text('No channels match',
            style: TextStyle(color: AppColors.textLo)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final c = visible[i];
        return _ChannelTile(
          channel: c,
          now: _now[c.id],
          next: _next[c.id],
          enabled: !_resolving,
          onTap: () => _play(c),
        );
      },
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final Programme? now;
  final Programme? next;
  final bool enabled;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    required this.now,
    required this.next,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final current = now;
    double? progress;
    if (current != null) {
      final total = current.stop.difference(current.start).inSeconds;
      final elapsed = DateTime.now().difference(current.start).inSeconds;
      progress = total <= 0 ? null : (elapsed / total).clamp(0.0, 1.0);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.tile),
          hoverColor: AppColors.panelHi,
          focusColor: AppColors.panelHi,
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Logo(channel: channel),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (current != null) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const _LivePill(),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                current.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.textLo, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                              value: progress, minHeight: 3),
                        ),
                        if (next != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Next · ${next!.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.textLo, fontSize: 12),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.play_arrow_rounded,
                    color: enabled ? AppColors.accent : AppColors.textLo),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final Channel channel;
  const _Logo({required this.channel});

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        channel.number?.toString() ??
            (channel.name.isEmpty ? '?' : channel.name.characters.first),
        style: const TextStyle(
            color: AppColors.textLo, fontWeight: FontWeight.w600),
      ),
    );

    final logo = channel.logo;
    if (logo == null || logo.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        logo,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (_, child, p) => p == null ? child : fallback,
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  const _LivePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.live.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
                color: AppColors.live, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          const Text('LIVE',
              style: TextStyle(
                  color: AppColors.live,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

class _CategoryDropdown extends StatelessWidget {
  final List<Category> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const _CategoryDropdown({
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: value,
          dropdownColor: AppColors.panelHi,
          borderRadius: BorderRadius.circular(AppRadius.control),
          icon: const Icon(Icons.expand_more, color: AppColors.textLo),
          hint: const Text('All categories',
              style: TextStyle(color: AppColors.textLo)),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('All categories')),
            ...categories.map(
              (c) => DropdownMenuItem<String?>(
                value: c.id,
                child:
                    Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}