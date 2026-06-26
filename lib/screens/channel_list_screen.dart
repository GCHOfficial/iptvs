import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart' show KeyRepeatEvent;

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/source_hint_parser.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/tv_text_field.dart';
import '../player/player_screen.dart';
import 'diagnostics_screen.dart';

const _toolbarControlHeight = 40.0;
const _autoMetadataEnrichmentLimit = 40;

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
  final Map<ContentKind, bool> _mediaEnriching = {};
  final Map<ContentKind, int> _mediaEnrichmentGeneration = {};
  final Map<ContentKind, ({int done, int total})> _mediaEnrichmentProgress = {};
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
  // One controller for whichever list/grid is mounted (only one exists per tab),
  // so a tab/category change can jump it back to the top.
  final ScrollController _scrollController = ScrollController();

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
    _scrollController.dispose();
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
      DiagnosticsLog.instance.add(
        'library',
        'loaded live source=${widget.repo.source.name} channels=${snap.channels.length} force=$forceRefresh cache=${snap.fromCache}',
      );
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
      _cancelMediaEnrichment(kind);
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
      DiagnosticsLog.instance.add(
        'library',
        'loaded ${kind.name} source=${widget.repo.source.name} items=${snap.items.length} category=${categoryId ?? '<all>'} force=$forceRefresh cache=${snap.fromCache} pages=${snap.loadedPages}/${snap.totalPages}',
      );
      setState(() {
        _media[kind] = snap;
        _mediaLoading[kind] = false;
      });
      if (widget.repo.autoEnrichMetadata) {
        unawaited(_autoEnrichMediaItems(kind, snap.items));
      }
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
    final existingIds = {
      for (final item in _media[kind]?.items ?? const <MediaItem>[]) item.id,
    };
    setState(() {
      _cancelMediaEnrichment(kind);
      _mediaLoadingMore[kind] = true;
      _mediaError[kind] = null;
    });
    try {
      final snap = await widget.repo.loadMoreMedia(
        kind,
        categoryId: categoryId,
      );
      if (!mounted) return;
      DiagnosticsLog.instance.add(
        'library',
        'load more ${kind.name} source=${widget.repo.source.name} items=${snap.items.length} category=${categoryId ?? '<all>'} pages=${snap.loadedPages}/${snap.totalPages}',
      );
      setState(() {
        _media[kind] = snap;
        _mediaLoadingMore[kind] = false;
      });
      if (widget.repo.autoEnrichMetadata) {
        final newlyLoaded = snap.items
            .where((item) => !existingIds.contains(item.id))
            .toList();
        unawaited(_autoEnrichMediaItems(kind, newlyLoaded));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mediaError[kind] = '$e';
        _mediaLoadingMore[kind] = false;
      });
    }
  }

  Future<void> _enrichVisibleMedia(ContentKind kind) =>
      _enrichMediaItems(kind, _visibleMedia(kind), showErrors: true);

  Future<void> _autoEnrichMediaItems(ContentKind kind, List<MediaItem> items) =>
      _enrichMediaItems(kind, items, maxItems: _autoMetadataEnrichmentLimit);

  void _cancelMediaEnrichment(ContentKind kind) {
    _mediaEnrichmentGeneration[kind] =
        (_mediaEnrichmentGeneration[kind] ?? 0) + 1;
    _mediaEnriching[kind] = false;
    _mediaEnrichmentProgress.remove(kind);
  }

  Future<void> _enrichMediaItems(
    ContentKind kind,
    List<MediaItem> items, {
    bool showErrors = false,
    int? maxItems,
  }) async {
    final generation = (_mediaEnrichmentGeneration[kind] ?? 0) + 1;
    _mediaEnrichmentGeneration[kind] = generation;
    final targets = items
        .where(
          (item) =>
              item.kind == ContentKind.movie ||
              item.kind == ContentKind.series ||
              item.kind == ContentKind.episode,
        )
        .take(maxItems ?? items.length)
        .toList();
    if (targets.isEmpty) return;
    setState(() {
      _mediaEnriching[kind] = true;
      _mediaEnrichmentProgress[kind] = (done: 0, total: targets.length);
    });
    var done = 0;
    try {
      const chunkSize = 20;
      for (var start = 0; start < targets.length; start += chunkSize) {
        if (_mediaEnrichmentGeneration[kind] != generation) return;
        final chunk = targets.skip(start).take(chunkSize).toList();
        final enriched = await widget.repo.enrichMediaMetadata(chunk);
        if (!mounted || _mediaEnrichmentGeneration[kind] != generation) return;
        done += chunk.length;
        final enrichedById = {for (final item in enriched) item.id: item};
        setState(() {
          _replaceMediaItemsInState(kind, enrichedById);
          _mediaEnrichmentProgress[kind] = (done: done, total: targets.length);
        });
        await Future<void>.delayed(Duration.zero);
      }
      if (!mounted || _mediaEnrichmentGeneration[kind] != generation) return;
      setState(() {
        _mediaEnriching[kind] = false;
        _mediaEnrichmentProgress.remove(kind);
      });
    } catch (e) {
      if (!mounted) return;
      if (_mediaEnrichmentGeneration[kind] != generation) return;
      setState(() => _mediaEnriching[kind] = false);
      if (showErrors) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Metadata enrichment failed: $e')),
        );
      }
    }
  }

  void _replaceMediaItemsInState(
    ContentKind kind,
    Map<String, MediaItem> replacements,
  ) {
    if (replacements.isEmpty) return;
    final snapshot = _media[kind];
    if (snapshot != null) {
      _media[kind] = snapshot.copyWith(
        items: [
          for (final item in snapshot.items) replacements[item.id] ?? item,
        ],
      );
    }
    final searchResults = _mediaSearchResults[kind];
    if (searchResults != null) {
      _mediaSearchResults[kind] = [
        for (final item in searchResults) replacements[item.id] ?? item,
      ];
    }
  }

  void _setQuery(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    if (_tab == ContentKind.live) return;
    _cancelMediaEnrichment(_tab);
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _cancelMediaEnrichment(_tab);
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
      _cancelMediaEnrichment(kind);
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
      DiagnosticsLog.instance.add(
        'library',
        'search ${kind.name} source=${widget.repo.source.name} query="$query" results=${results.length} category=${categoryId ?? '<all>'}',
      );
      setState(() {
        _mediaSearchResults[kind] = results;
        _mediaSearchQuery[kind] = query;
        _mediaSearching[kind] = false;
      });
      if (widget.repo.autoEnrichMetadata) {
        unawaited(_autoEnrichMediaItems(kind, results));
      }
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
      DiagnosticsLog.instance.add(
        'library',
        'resolve live source=${widget.repo.source.name} channel=${channel.name} id=${channel.id}',
      );
      final stream = await widget.repo.resolve(channel);
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: channel.name,
            stream: stream,
            sourceName: widget.repo.source.name,
            epgNow: _now[channel.id],
            epgNext: _next[channel.id],
          ),
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
      DiagnosticsLog.instance.add(
        'library',
        'open ${item.kind.name} source=${widget.repo.source.name} title=${item.title} id=${item.id}',
      );
      final detailed = await widget.repo.mediaDetails(item);
      if (!mounted) return;
      _replaceMediaItem(detailed);
      _showMediaDetails(detailed);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    }
  }

  void _replaceMediaItem(MediaItem replacement) {
    setState(() {
      _replaceMediaItemsInState(replacement.kind, {
        replacement.id: replacement,
      });
    });
  }

  Future<void> _playMedia(MediaItem item) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      DiagnosticsLog.instance.add(
        'library',
        'resolve ${item.kind.name} source=${widget.repo.source.name} title=${item.title} id=${item.id}',
      );
      final stream = await widget.repo.resolveMedia(item);
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: item.title,
            stream: stream,
            sourceName: widget.repo.source.name,
          ),
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
        onChanged: _replaceMediaItem,
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

  // Jump the active list/grid back to the top after a tab/category change so the
  // new content isn't shown scrolled to the previous position. Post-frame so the
  // new list has attached before we move it.
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
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
      _cancelMediaEnrichment(previous);
    });
    DiagnosticsLog.instance.add(
      'library',
      'tab source=${widget.repo.source.name} ${previous.name}->${kind.name}',
    );
    if (kind != ContentKind.live && !_media.containsKey(kind)) {
      _loadMedia(kind);
    }
    _scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.repo.source.name),
        // Group the actions so D-pad traversal treats them as one cluster (reached
        // by going up to the bar), rather than the toolbar's "right" jumping
        // straight to the rightmost icon.
        actions: [
          FocusTraversalGroup(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onManageSources != null)
                  IconButton(
                    tooltip: 'Sources',
                    icon: const Icon(Icons.dns_outlined),
                    onPressed: widget.onManageSources,
                  ),
                IconButton(
                  tooltip: 'Diagnostics',
                  icon: const Icon(Icons.bug_report_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DiagnosticsScreen(),
                    ),
                  ),
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
            ),
          ),
        ],
        bottom: _resolving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      // Keep D-pad traversal within the body (tabs → toolbar → list) instead of
      // arrowing sideways into the AppBar's action cluster.
      body: FocusTraversalGroup(
        child: Column(
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
                      onChanged: (v) {
                        setState(() => _categoryId = v);
                        _scrollToTop();
                      },
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
                        _scrollToTop();
                        if (_query.trim().length >= 2) {
                          _searchTimer?.cancel();
                          _searchTimer = Timer(
                            const Duration(milliseconds: 250),
                            () => _searchMedia(_tab, _query.trim()),
                          );
                        }
                      },
                    ),
              actionControl:
                  _tab == ContentKind.live || !widget.repo.canEnrichMetadata
                  ? null
                  : _ToolbarIconButton(
                      tooltip: _mediaEnriching[_tab] == true
                          ? 'Cancel metadata refresh'
                          : 'Refresh displayed metadata',
                      busy: _mediaEnriching[_tab] == true,
                      icon: _mediaEnriching[_tab] == true
                          ? Icons.stop_rounded
                          : Icons.auto_awesome_outlined,
                      onPressed:
                          _mediaLoading[_tab] == true ||
                              _mediaSearching[_tab] == true
                          ? null
                          : _mediaEnriching[_tab] == true
                          ? () => setState(() => _cancelMediaEnrichment(_tab))
                          : () => _enrichVisibleMedia(_tab),
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
              child: _tab == ContentKind.live
                  ? _body(visible)
                  : _mediaBody(_tab),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText(int visibleLiveCount) {
    if (_tab == ContentKind.live) {
      return _loading ? '' : _statusLine(visibleLiveCount);
    }
    if (_mediaLoading[_tab] == true) return '';
    if (_mediaSearching[_tab] == true) return 'Searching provider...';
    if (_mediaEnriching[_tab] == true) {
      final progress = _mediaEnrichmentProgress[_tab];
      if (progress != null) {
        return 'Refreshing metadata ${_fmt(progress.done)}/${_fmt(progress.total)} · press stop to cancel';
      }
      return 'Refreshing metadata · press stop to cancel';
    }
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
      controller: _scrollController,
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
            controller: _scrollController,
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
          controller: _scrollController,
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
    // A focusable chip strip (not a SegmentedButton): it's the natural top of the
    // D-pad focus order, left/right moves between Live/Movies/Series, and OK/tap
    // selects. Grouped so directional traversal stays within the strip.
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _TabChip(
              icon: Icons.live_tv_rounded,
              label: 'Live',
              selected: value == ContentKind.live,
              autofocus: value == ContentKind.live,
              onTap: () => onChanged(ContentKind.live),
            ),
            const SizedBox(width: 8),
            _TabChip(
              icon: Icons.movie_outlined,
              label: 'Movies',
              selected: value == ContentKind.movie,
              autofocus: value == ContentKind.movie,
              onTap: () => onChanged(ContentKind.movie),
            ),
            const SizedBox(width: 8),
            _TabChip(
              icon: Icons.tv_outlined,
              label: 'Series',
              selected: value == ContentKind.series,
              autofocus: value == ContentKind.series,
              onTap: () => onChanged(ContentKind.series),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  const _TabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final bg = active
        ? AppColors.accent
        : (_focused ? AppColors.panelHi : AppColors.panel);
    final fg = active ? Colors.white : AppColors.textHi;
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _toolbarControlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            // Always show a focus ring under the D-pad — including on the
            // already-selected tab, where a white ring reads clearly against
            // the accent fill (an accent ring there would be invisible).
            border: Border.all(
              color: _focused
                  ? (active ? Colors.white : AppColors.accent)
                  : AppColors.line,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
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
  final Widget? actionControl;

  const _Toolbar({
    required this.searchController,
    required this.query,
    required this.hintText,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.categoryControl,
    this.actionControl,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        final search = TvTextField(
          controller: searchController,
          hintText: hintText,
          height: _toolbarControlHeight,
          onChanged: onQueryChanged,
          textInputAction: TextInputAction.search,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: onClearQuery,
                ),
        );
        final action = actionControl;

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
                        child: action == null
                            ? categoryControl
                            : Row(
                                children: [
                                  Expanded(child: categoryControl),
                                  const SizedBox(width: 8),
                                  action,
                                ],
                              ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 12),
                    categoryControl,
                    if (action != null) ...[const SizedBox(width: 8), action],
                  ],
                ),
        );
      },
    );
  }
}

class _ToolbarIconButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool busy;
  final VoidCallback? onPressed;

  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });

  @override
  State<_ToolbarIconButton> createState() => _ToolbarIconButtonState();
}

class _ToolbarIconButtonState extends State<_ToolbarIconButton> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox.square(
        dimension: _toolbarControlHeight,
        child: IconButton.filledTonal(
          focusNode: _node,
          style: IconButton.styleFrom(
            backgroundColor: _focused ? AppColors.panelHi : AppColors.panel,
            foregroundColor: AppColors.textHi,
            disabledBackgroundColor: AppColors.panel,
            disabledForegroundColor: AppColors.textLo,
            // Match the accent ring/lift of the search field and category
            // dropdown rather than the default focus disc.
            overlayColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(
                color: _focused ? AppColors.accent : AppColors.line,
                width: _focused ? 2 : 1,
              ),
            ),
          ),
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: 20),
        ),
      ),
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

/// The bordered shell shared by the category dropdowns. Reflects the focus of
/// the [DropdownButton] it hosts with the same accent ring/lift as
/// [FocusableCard], so the control is clearly visible under a D-pad.
class _DropdownFrame extends StatefulWidget {
  final Widget Function(FocusNode focusNode) builder;

  const _DropdownFrame({required this.builder});

  @override
  State<_DropdownFrame> createState() => _DropdownFrameState();
}

class _DropdownFrameState extends State<_DropdownFrame> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _toolbarControlHeight,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _focused ? AppColors.panelHi : AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: _focused ? AppColors.accent : AppColors.line,
          width: _focused ? 2 : 1,
        ),
      ),
      // A held (or rapidly mashed) OK on a TV remote arrives as key-repeat
      // events; the framework turns each into an ActivateIntent, so the menu
      // flickers open/closed with a click sound on every repeat. Swallow repeats
      // here (ancestor of the DropdownButton's focus node, below the app-level
      // shortcuts) so one discrete press maps to exactly one open.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) =>
            event is KeyRepeatEvent ? KeyEventResult.handled : KeyEventResult.ignored,
        child: DropdownButtonHideUnderline(child: widget.builder(_node)),
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
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
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
              child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
        onChanged: onChanged,
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
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
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
              child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
        onChanged: onChanged,
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
                  if (item.year != null || _hasRating(item)) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (item.year != null)
                          Flexible(
                            child: Text(
                              item.year!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textLo,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        if (item.year != null && _hasRating(item))
                          const SizedBox(width: 10),
                        _RatingBadge(rating: item.rating),
                      ],
                    ),
                  ],
                  if (sourceHintLabels(item).isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _SourceHints(item: item),
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Poster(
                      item: item,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                    if (_hasRating(item))
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _RatingBadge(rating: item.rating, compact: true),
                        ),
                      ),
                  ],
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
            if (sourceHintLabels(item).isNotEmpty) ...[
              const SizedBox(height: 5),
              _SourceHints(item: item, compact: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceHints extends StatelessWidget {
  final MediaItem item;
  final bool compact;

  const _SourceHints({required this.item, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final hints = sourceHintLabels(item);
    if (hints.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final hint in hints.take(compact ? 2 : 4))
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 5 : 6,
              vertical: compact ? 2 : 3,
            ),
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.line),
            ),
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textLo,
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

/// Whether an item has a real (non-zero) score worth showing. Many items come
/// back with `rating == 0.0`, which means "unrated", not a literal zero.
bool _hasRating(MediaItem item) => (item.rating ?? 0) > 0;

/// A small `★ 8.5` rating chip, shown when an item carries a non-zero 0–10
/// score (TMDB or MDBList). Renders nothing otherwise.
class _RatingBadge extends StatelessWidget {
  final double? rating;
  final bool compact;

  const _RatingBadge({required this.rating, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final value = rating;
    if (value == null || value <= 0) return const SizedBox.shrink();
    final fontSize = compact ? 11.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: fontSize + 3, color: AppColors.accent),
        const SizedBox(width: 3),
        Text(
          value.toStringAsFixed(1),
          style: TextStyle(
            color: AppColors.textHi,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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
    final nextPage = snapshot == null ? null : snapshot!.loadedPages + 1;
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
                ? nextPage == null
                      ? 'Load more'
                      : 'Load page $nextPage'
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
    final nextPage = snapshot == null ? null : snapshot!.loadedPages + 1;
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
                  ? nextPage == null
                        ? 'Load more'
                        : 'Load page $nextPage'
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
  final ValueChanged<MediaItem>? onChanged;

  const _MediaDetailsSheet({
    required this.repo,
    required this.item,
    required this.onPlay,
    this.onChanged,
  });

  @override
  State<_MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends State<_MediaDetailsSheet> {
  late MediaItem _item = widget.item;
  late Future<ExternalMetadata?> _metadataFuture = _loadMetadata();
  late final Future<List<MediaItem>>? _seasonsFuture = _loadSeasonsIfNeeded();
  final Map<String, Future<List<MediaItem>>> _episodeFutures = {};
  bool _refreshingMetadata = false;

  @override
  void initState() {
    super.initState();
    // Movies/episodes autofocus their Play button directly. A series has no
    // top-level Play button, so once the seasons load, nudge focus onto the
    // first season tile (ExpansionTile exposes no autofocus of its own).
    if (widget.onPlay == null) {
      _seasonsFuture?.whenComplete(() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) FocusScope.of(context).nextFocus();
        });
      });
    }
  }

  Future<List<MediaItem>>? _loadSeasonsIfNeeded() {
    if (_item.kind != ContentKind.series) return null;
    return widget.repo
        .loadMedia(ContentKind.season, parent: _item)
        .then((snapshot) => snapshot.items);
  }

  Future<List<MediaItem>> _episodes(MediaItem season) =>
      _episodeFutures.putIfAbsent(
        season.id,
        () => widget.repo
            .loadMedia(ContentKind.episode, parent: season)
            .then((snapshot) => snapshot.items),
      );

  Future<ExternalMetadata?> _loadMetadata() =>
      widget.repo.cachedExternalMetadata(_item, 'tmdb');

  Future<void> _refreshMetadata() async {
    if (_refreshingMetadata) return;
    setState(() => _refreshingMetadata = true);
    try {
      final metadata = await widget.repo.refreshExternalMetadata(_item);
      if (!mounted) return;
      setState(() {
        if (metadata != null) {
          _item = widget.repo.mergeExternalMetadata(_item, metadata);
          widget.onChanged?.call(_item);
        }
        _metadataFuture = _loadMetadata();
        _refreshingMetadata = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _refreshingMetadata = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Metadata refresh failed: $error')),
      );
    }
  }

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
            final poster = _Poster(item: _item, width: 124, height: 180);
            final seasonsFuture = _seasonsFuture;
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (_item.year != null || _hasRating(_item)) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (_item.year != null)
                        Text(
                          _item.year!,
                          style: const TextStyle(color: AppColors.textLo),
                        ),
                      if (_item.year != null && _hasRating(_item))
                        const SizedBox(width: 12),
                      _RatingBadge(rating: _item.rating),
                    ],
                  ),
                ],
                if (sourceHintLabels(_item).isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _SourceHints(item: _item),
                ],
                if (providerSourceTitle(_item) case final sourceTitle?) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Source title: $sourceTitle',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_item.description != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _item.description!,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textLo),
                  ),
                ],
                const SizedBox(height: 16),
                if (widget.onPlay != null)
                  FilledButton.icon(
                    autofocus: true,
                    onPressed: widget.onPlay,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play'),
                  ),
                const SizedBox(height: 12),
                _MetadataStatus(
                  metadata: _metadataFuture,
                  refreshing: _refreshingMetadata,
                  onRefresh: _refreshMetadata,
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

class _MetadataStatus extends StatelessWidget {
  final Future<ExternalMetadata?> metadata;
  final bool refreshing;
  final VoidCallback onRefresh;

  const _MetadataStatus({
    required this.metadata,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ExternalMetadata?>(
      future: metadata,
      builder: (context, snapshot) {
        final value = snapshot.data;
        final label = value == null
            ? 'Provider metadata'
            : '${value.provider.toUpperCase()} · ${_ago(value.refreshedAt)}';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.panelHi,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              Icon(
                value == null
                    ? Icons.auto_awesome_outlined
                    : Icons.check_circle_outline,
                color: value == null ? AppColors.textLo : AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Refresh metadata',
                visualDensity: VisualDensity.compact,
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        );
      },
    );
  }

  String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
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
                subtitle:
                    season.seasonNumber == null ||
                        season.title.trim().toLowerCase() ==
                            'season ${season.seasonNumber}'.toLowerCase()
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
          return PlayerScreen(
            title: widget.item.title,
            stream: snapshot.data!,
            sourceName: widget.repo.source.name,
          );
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
