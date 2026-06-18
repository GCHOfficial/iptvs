import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/library_repository.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../player/player_screen.dart';

const _toolbarControlHeight = 40.0;

/// Lists a source's channels with in-memory search + category filtering, plus
/// now/next EPG (when the source provides it).
class ChannelListScreen extends StatefulWidget {
  final LibraryRepository repo;
  final VoidCallback? onManageSources;
  const ChannelListScreen({
    super.key,
    required this.repo,
    this.onManageSources,
  });

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  final _searchController = TextEditingController();

  ContentKind _tab = ContentKind.live;
  List<Category> _categories = const [];
  List<Channel> _all = const [];
  final Map<ContentKind, MediaLibrarySnapshot> _media = {};
  final Map<ContentKind, String?> _mediaCategoryId = {};
  final Map<ContentKind, bool> _mediaLoading = {};
  final Map<ContentKind, bool> _mediaLoadingMore = {};
  final Map<ContentKind, bool> _mediaSearching = {};
  final Map<ContentKind, String?> _mediaError = {};
  final Map<ContentKind, List<MediaItem>> _mediaSearchResults = {};
  final Map<ContentKind, String> _mediaSearchQuery = {};
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
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _epgTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshNowNext(),
    );
  }

  @override
  void dispose() {
    _epgTimer?.cancel();
    _searchTimer?.cancel();
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

  Future<void> _loadMedia(ContentKind kind, {bool forceRefresh = false}) async {
    final categoryId = _mediaCategoryId[kind];
    setState(() {
      _mediaLoading[kind] = true;
      _mediaError[kind] = null;
    });
    try {
      final snap = await widget.repo.loadMedia(
        kind,
        categoryId: categoryId,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _media[kind] = snap;
        _mediaLoading[kind] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mediaError[kind] = '$e';
        _mediaLoading[kind] = false;
      });
    }
  }

  Future<void> _loadMoreMedia(ContentKind kind) async {
    if (_mediaLoadingMore[kind] == true) return;
    final categoryId = _mediaCategoryId[kind];
    setState(() {
      _mediaLoadingMore[kind] = true;
      _mediaError[kind] = null;
    });
    try {
      final snap = await widget.repo.loadMoreMedia(
        kind,
        categoryId: categoryId,
      );
      if (!mounted) return;
      setState(() {
        _media[kind] = snap;
        _mediaLoadingMore[kind] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mediaError[kind] = '$e';
        _mediaLoadingMore[kind] = false;
      });
    }
  }

  void _setQuery(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    if (_tab == ContentKind.live) return;
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _mediaSearching[_tab] = false;
        _mediaSearchResults.remove(_tab);
        _mediaSearchQuery.remove(_tab);
      });
      return;
    }
    _searchTimer = Timer(
      const Duration(milliseconds: 450),
      () => _searchMedia(_tab, query),
    );
  }

  Future<void> _searchMedia(ContentKind kind, String query) async {
    final categoryId = _mediaCategoryId[kind];
    setState(() {
      _mediaSearching[kind] = true;
      _mediaError[kind] = null;
    });
    try {
      final results = await widget.repo.searchMedia(
        kind,
        query,
        categoryId: categoryId,
      );
      if (!mounted || _tab != kind || _query.trim() != query) return;
      setState(() {
        _mediaSearchResults[kind] = results;
        _mediaSearchQuery[kind] = query;
        _mediaSearching[kind] = false;
      });
    } catch (e) {
      if (!mounted || _tab != kind || _query.trim() != query) return;
      setState(() {
        _mediaError[kind] = '$e';
        _mediaSearching[kind] = false;
      });
    }
  }

  List<Channel> get _visible {
    final q = _query.trim().toLowerCase();
    return _all.where((c) {
      if (_categoryId != null && c.categoryId != _categoryId) return false;
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  List<MediaItem> _visibleMedia(ContentKind kind) {
    final q = _query.trim().toLowerCase();
    if (q.length >= 2 && _mediaSearchQuery[kind] == _query.trim()) {
      return _mediaSearchResults[kind] ?? const <MediaItem>[];
    }
    final items = _media[kind]?.items ?? const <MediaItem>[];
    return items.where((item) {
      if (q.isNotEmpty && !item.title.toLowerCase().contains(q)) return false;
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

  Future<void> _openMedia(MediaItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final detailed = await widget.repo.mediaDetails(item);
      if (!mounted) return;
      _showMediaDetails(detailed);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    }
  }

  Future<void> _playMedia(MediaItem item) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stream = await widget.repo.resolveMedia(item);
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(title: item.title, stream: stream),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not play: $e')));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _showMediaDetails(MediaItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.panel,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (context) => _MediaDetailsSheet(
        repo: widget.repo,
        item: item,
        onPlay:
            item.kind == ContentKind.movie || item.kind == ContentKind.episode
            ? () {
                Navigator.of(context).pop();
                _playMedia(item);
              }
            : null,
      ),
    );
  }

  String _fmt(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  );

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
      b.write(
        _fromCache
            ? ' · cached, synced ${_ago(_syncedAt!)}'
            : ' · synced ${_ago(_syncedAt!)}',
      );
    }
    return b.toString();
  }

  String _mediaStatusLine(ContentKind kind, int count) {
    final snap = _media[kind];
    final label = kind == ContentKind.movie ? 'movies' : 'series';
    final searching = _query.trim().length >= 2;
    final b = StringBuffer(
      searching
          ? 'Found ${_fmt(count)} $label'
          : 'Showing ${_fmt(count)} $label',
    );
    final categoryId = _mediaCategoryId[kind];
    if (categoryId != null) {
      MediaCategory? category;
      for (final candidate in snap?.categories ?? const <MediaCategory>[]) {
        if (candidate.id == categoryId) {
          category = candidate;
          break;
        }
      }
      if (category != null) b.write(' in ${category.title}');
    }
    if (snap != null && snap.totalPages > 1) {
      b.write(' · pages ${snap.loadedPages}/${snap.totalPages}');
    }
    if (snap?.syncedAt != null) {
      b.write(
        snap!.fromCache
            ? ' · cached, synced ${_ago(snap.syncedAt!)}'
            : ' · synced ${_ago(snap.syncedAt!)}',
      );
    }
    return b.toString();
  }

  void _selectTab(ContentKind kind) {
    if (_tab == kind) return;
    final previous = _tab;
    setState(() {
      _tab = kind;
      _query = '';
      _searchController.clear();
      _searchTimer?.cancel();
      _mediaSearchResults.remove(previous);
      _mediaSearchQuery.remove(previous);
      _mediaSearching[previous] = false;
    });
    if (kind != ContentKind.live && !_media.containsKey(kind)) {
      _loadMedia(kind);
    }
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
            onPressed: _loading || _mediaLoading[_tab] == true
                ? null
                : () => _tab == ContentKind.live
                      ? _load(forceRefresh: true)
                      : _loadMedia(_tab, forceRefresh: true),
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
          _ContentTabs(value: _tab, onChanged: _selectTab),
          _Toolbar(
            searchController: _searchController,
            query: _query,
            hintText: _tab == ContentKind.live
                ? 'Search channels'
                : _tab == ContentKind.movie
                ? 'Search movies'
                : 'Search series',
            onQueryChanged: _setQuery,
            onClearQuery: () {
              _searchController.clear();
              _setQuery('');
            },
            categoryControl: _tab == ContentKind.live
                ? _CategoryDropdown(
                    categories: _categories,
                    value: _categoryId,
                    onChanged: (v) => setState(() => _categoryId = v),
                  )
                : _MediaCategoryDropdown(
                    categories: _media[_tab]?.categories ?? const [],
                    value: _mediaCategoryId[_tab],
                    onChanged: (v) {
                      setState(() {
                        _mediaCategoryId[_tab] = v;
                        _mediaSearchResults.remove(_tab);
                        _mediaSearchQuery.remove(_tab);
                      });
                      _loadMedia(_tab);
                      if (_query.trim().length >= 2) {
                        _searchTimer?.cancel();
                        _searchTimer = Timer(
                          const Duration(milliseconds: 250),
                          () => _searchMedia(_tab, _query.trim()),
                        );
                      }
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _statusText(visible.length),
                style: const TextStyle(color: AppColors.textLo, fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: _tab == ContentKind.live ? _body(visible) : _mediaBody(_tab),
          ),
        ],
      ),
    );
  }

  String _statusText(int visibleLiveCount) {
    if (_tab == ContentKind.live) {
      return _loading ? '' : _statusLine(visibleLiveCount);
    }
    if (_mediaLoading[_tab] == true) return '';
    if (_mediaSearching[_tab] == true) return 'Searching provider...';
    return _mediaStatusLine(_tab, _visibleMedia(_tab).length);
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
              Text(
                'Couldn\'t load this source.\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textLo),
              ),
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
        child: Text(
          'No channels match',
          style: TextStyle(color: AppColors.textLo),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      scrollCacheExtent: const ScrollCacheExtent.pixels(
        120,
      ), // keep nearby rows built for D-pad without over-prefetching logos
      itemExtent: 124,
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final c = visible[i];
        return _ChannelTile(
          channel: c,
          now: _now[c.id],
          next: _next[c.id],
          enabled: !_resolving,
          autofocus: i == 0,
          onTap: () => _play(c),
        );
      },
    );
  }

  Widget _mediaBody(ContentKind kind) {
    final loading = _mediaLoading[kind] == true;
    final loadingMore = _mediaLoadingMore[kind] == true;
    final error = _mediaError[kind];
    final visible = _visibleMedia(kind);
    final showingSearch = _query.trim().length >= 2;
    final showLoadMore =
        !showingSearch && (loadingMore || _media[kind]?.hasMore == true);
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Couldn\'t load ${kind == ContentKind.movie ? 'movies' : 'series'}.\n$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textLo),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _loadMedia(kind, forceRefresh: true),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          'No ${kind == ContentKind.movie ? 'movies' : 'series'} match',
          style: const TextStyle(color: AppColors.textLo),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        if (!wide) {
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            itemCount: visible.length + (showLoadMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == visible.length) {
                return _MediaLoadMoreTile(
                  snapshot: _media[kind],
                  loading: loadingMore,
                  onPressed: () => _loadMoreMedia(kind),
                );
              }
              return _MediaListTile(
                item: visible[i],
                autofocus: i == 0,
                onTap: () => _openMedia(visible[i]),
              );
            },
          );
        }
        final columns = constraints.maxWidth >= 1280 ? 6 : 4;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
          scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.64,
          ),
          itemCount: visible.length + (showLoadMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == visible.length) {
              return _MediaLoadMoreCard(
                snapshot: _media[kind],
                loading: loadingMore,
                onPressed: () => _loadMoreMedia(kind),
              );
            }
            return _MediaGridTile(
              item: visible[i],
              autofocus: i == 0,
              onTap: () => _openMedia(visible[i]),
            );
          },
        );
      },
    );
  }
}

class _ContentTabs extends StatelessWidget {
  final ContentKind value;
  final ValueChanged<ContentKind> onChanged;

  const _ContentTabs({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<ContentKind>(
        segments: const [
          ButtonSegment(
            value: ContentKind.live,
            icon: Icon(Icons.live_tv_rounded),
            label: Text('Live'),
          ),
          ButtonSegment(
            value: ContentKind.movie,
            icon: Icon(Icons.movie_outlined),
            label: Text('Movies'),
          ),
          ButtonSegment(
            value: ContentKind.series,
            icon: Icon(Icons.tv_outlined),
            label: Text('Series'),
          ),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (values) => onChanged(values.first),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final TextEditingController searchController;
  final String query;
  final String hintText;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final Widget categoryControl;

  const _Toolbar({
    required this.searchController,
    required this.query,
    required this.hintText,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.categoryControl,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        final search = SizedBox(
          height: _toolbarControlHeight,
          child: TextField(
            controller: searchController,
            onChanged: onQueryChanged,
            decoration: InputDecoration(
              constraints: const BoxConstraints.tightFor(
                height: _toolbarControlHeight,
              ),
              hintText: hintText,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: onClearQuery,
                    ),
            ),
          ),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: narrow
              ? Column(
                  children: [
                    search,
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: double.infinity,
                        child: categoryControl,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 12),
                    categoryControl,
                  ],
                ),
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
  final bool autofocus;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    required this.now,
    required this.next,
    required this.enabled,
    required this.autofocus,
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

    return FocusableCard(
      autofocus: autofocus,
      scrollOnFocus: false,
      onTap: onTap,
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
                              color: AppColors.textLo,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                      ),
                    ),
                    if (next != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Next · ${next!.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.play_arrow_rounded,
              color: enabled ? AppColors.accent : AppColors.textLo,
            ),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatefulWidget {
  final Channel channel;
  const _Logo({required this.channel});

  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> {
  late final DisposableBuildContext<_LogoState> _scrollContext;

  @override
  void initState() {
    super.initState();
    _scrollContext = DisposableBuildContext(this);
  }

  @override
  void dispose() {
    _scrollContext.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    final cacheSize = _imageCacheSize(context, size);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        widget.channel.number?.toString() ??
            (widget.channel.name.isEmpty
                ? '?'
                : widget.channel.name.characters.first),
        style: const TextStyle(
          color: AppColors.textLo,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    final logo = widget.channel.logo;
    if (logo == null || logo.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image(
        image: ScrollAwareImageProvider(
          context: _scrollContext,
          imageProvider: ResizeImage.resizeIfNeeded(
            cacheSize,
            cacheSize,
            NetworkImage(logo),
          ),
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => fallback,
        frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return fallback;
        },
      ),
    );
  }
}

int _imageCacheSize(BuildContext context, double logicalSize) {
  final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
  return (logicalSize * dpr).round();
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
              color: AppColors.live,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            'LIVE',
            style: TextStyle(
              color: AppColors.live,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
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
      height: _toolbarControlHeight,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isDense: true,
          isExpanded: true,
          value: value,
          dropdownColor: AppColors.panelHi,
          borderRadius: BorderRadius.circular(AppRadius.control),
          icon: const Icon(Icons.expand_more, color: AppColors.textLo),
          hint: const Text(
            'All categories',
            style: TextStyle(color: AppColors.textLo),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All categories'),
            ),
            ...categories.map(
              (c) => DropdownMenuItem<String?>(
                value: c.id,
                child: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _MediaCategoryDropdown extends StatelessWidget {
  final List<MediaCategory> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const _MediaCategoryDropdown({
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _toolbarControlHeight,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isDense: true,
          isExpanded: true,
          value: value,
          dropdownColor: AppColors.panelHi,
          borderRadius: BorderRadius.circular(AppRadius.control),
          icon: const Icon(Icons.expand_more, color: AppColors.textLo),
          hint: const Text(
            'All categories',
            style: TextStyle(color: AppColors.textLo),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All categories'),
            ),
            ...categories.map(
              (c) => DropdownMenuItem<String?>(
                value: c.id,
                child: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _MediaListTile extends StatelessWidget {
  final MediaItem item;
  final bool autofocus;
  final VoidCallback onTap;

  const _MediaListTile({
    required this.item,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _Poster(item: item, width: 58, height: 84),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (item.year != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.year!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (item.description != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              item.kind == ContentKind.movie
                  ? Icons.play_arrow_rounded
                  : Icons.chevron_right_rounded,
              color: AppColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaGridTile extends StatelessWidget {
  final MediaItem item;
  final bool autofocus;
  final VoidCallback onTap;

  const _MediaGridTile({
    required this.item,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox.expand(
                child: _Poster(
                  item: item,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (item.year != null)
              Text(
                item.year!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textLo, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaLoadMoreTile extends StatelessWidget {
  final MediaLibrarySnapshot? snapshot;
  final bool loading;
  final VoidCallback onPressed;

  const _MediaLoadMoreTile({
    required this.snapshot,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final canLoad = snapshot?.hasMore == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: FilledButton.icon(
          onPressed: canLoad && !loading ? onPressed : null,
          icon: loading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more_rounded),
          label: Text(
            loading
                ? 'Loading'
                : canLoad
                ? 'Load more'
                : 'All loaded',
          ),
        ),
      ),
    );
  }
}

class _MediaLoadMoreCard extends StatelessWidget {
  final MediaLibrarySnapshot? snapshot;
  final bool loading;
  final VoidCallback onPressed;

  const _MediaLoadMoreCard({
    required this.snapshot,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final canLoad = snapshot?.hasMore == true;
    return FocusableCard(
      autofocus: false,
      onTap: canLoad && !loading ? onPressed : () {},
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                canLoad ? Icons.expand_more_rounded : Icons.check_rounded,
                color: canLoad ? AppColors.accent : AppColors.textLo,
                size: 32,
              ),
            const SizedBox(height: 8),
            Text(
              loading
                  ? 'Loading'
                  : canLoad
                  ? 'Load more'
                  : 'All loaded',
              style: const TextStyle(color: AppColors.textLo),
            ),
          ],
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const _Poster({
    required this.item,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.panelHi,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        item.kind == ContentKind.movie
            ? Icons.movie_outlined
            : Icons.tv_outlined,
        color: AppColors.textLo,
      ),
    );
    final poster = item.poster;
    if (poster == null || poster.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        poster,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

class _MediaDetailsSheet extends StatefulWidget {
  final LibraryRepository repo;
  final MediaItem item;
  final VoidCallback? onPlay;

  const _MediaDetailsSheet({
    required this.repo,
    required this.item,
    required this.onPlay,
  });

  @override
  State<_MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends State<_MediaDetailsSheet> {
  late final Future<List<MediaItem>>? _seasonsFuture = _loadSeasonsIfNeeded();
  final Map<String, Future<List<MediaItem>>> _episodeFutures = {};

  Future<List<MediaItem>>? _loadSeasonsIfNeeded() {
    if (widget.item.kind != ContentKind.series) return null;
    return widget.repo
        .loadMedia(ContentKind.season, parent: widget.item)
        .then((snapshot) => snapshot.items);
  }

  Future<List<MediaItem>> _episodes(MediaItem season) =>
      _episodeFutures.putIfAbsent(
        season.id,
        () => widget.repo
            .loadMedia(ContentKind.episode, parent: season)
            .then((snapshot) => snapshot.items),
      );

  void _play(MediaItem item) {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DeferredMediaPlayer(repo: widget.repo, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 520;
            final poster = _Poster(item: widget.item, width: 124, height: 180);
            final seasonsFuture = _seasonsFuture;
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (widget.item.year != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.item.year!,
                    style: const TextStyle(color: AppColors.textLo),
                  ),
                ],
                if (widget.item.description != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    widget.item.description!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textLo),
                  ),
                ],
                const SizedBox(height: 16),
                if (widget.onPlay != null)
                  FilledButton.icon(
                    onPressed: widget.onPlay,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play'),
                  ),
                if (seasonsFuture != null) ...[
                  const SizedBox(height: 18),
                  _SeriesBrowser(
                    seasons: seasonsFuture,
                    episodesFor: _episodes,
                    onPlayEpisode: _play,
                  ),
                ],
              ],
            );
            if (narrow) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: poster),
                    const SizedBox(height: 14),
                    details,
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  poster,
                  const SizedBox(width: 18),
                  Expanded(child: details),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SeriesBrowser extends StatelessWidget {
  final Future<List<MediaItem>> seasons;
  final Future<List<MediaItem>> Function(MediaItem season) episodesFor;
  final ValueChanged<MediaItem> onPlayEpisode;

  const _SeriesBrowser({
    required this.seasons,
    required this.episodesFor,
    required this.onPlayEpisode,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: seasons,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return Text(
            'Could not load seasons: ${snapshot.error}',
            style: const TextStyle(color: AppColors.textLo),
          );
        }
        final seasons = snapshot.data ?? const <MediaItem>[];
        if (seasons.isEmpty) {
          return const Text(
            'No seasons found',
            style: TextStyle(color: AppColors.textLo),
          );
        }
        return Column(
          children: [
            for (final season in seasons)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text(season.title),
                subtitle: season.seasonNumber == null
                    ? null
                    : Text(
                        'Season ${season.seasonNumber}',
                        style: const TextStyle(color: AppColors.textLo),
                      ),
                children: [
                  FutureBuilder<List<MediaItem>>(
                    future: episodesFor(season),
                    builder: (context, episodeSnapshot) {
                      if (episodeSnapshot.connectionState !=
                          ConnectionState.done) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: LinearProgressIndicator(minHeight: 2),
                        );
                      }
                      if (episodeSnapshot.hasError) {
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Could not load episodes: ${episodeSnapshot.error}',
                            style: const TextStyle(color: AppColors.textLo),
                          ),
                        );
                      }
                      final episodes =
                          episodeSnapshot.data ?? const <MediaItem>[];
                      if (episodes.isEmpty) {
                        return const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'No episodes found',
                            style: TextStyle(color: AppColors.textLo),
                          ),
                        );
                      }
                      return Column(
                        children: [
                          for (final episode in episodes)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.play_arrow_rounded),
                              title: Text(
                                episode.episodeNumber == null
                                    ? episode.title
                                    : '${episode.episodeNumber}. ${episode.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: episode.description == null
                                  ? null
                                  : Text(
                                      episode.description!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              onTap: () => onPlayEpisode(episode),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _DeferredMediaPlayer extends StatefulWidget {
  final LibraryRepository repo;
  final MediaItem item;

  const _DeferredMediaPlayer({required this.repo, required this.item});

  @override
  State<_DeferredMediaPlayer> createState() => _DeferredMediaPlayerState();
}

class _DeferredMediaPlayerState extends State<_DeferredMediaPlayer> {
  late final Future<StreamInfo> _stream = widget.repo.resolveMedia(widget.item);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StreamInfo>(
      future: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return PlayerScreen(title: widget.item.title, stream: snapshot.data!);
        }
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.item.title)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Could not play: ${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textLo),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(widget.item.title)),
          body: const Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}
