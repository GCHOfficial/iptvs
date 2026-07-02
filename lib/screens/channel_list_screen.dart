import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        SystemNavigator;
import 'package:media_kit/media_kit.dart';

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/source_hint_parser.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/tv_text_field.dart';
import '../player/player_screen.dart';
import 'diagnostics_screen.dart';
import 'favorites_controller.dart';
import 'live_controller.dart';
import 'live_preview_controller.dart';
import 'media_tab_controller.dart';

const _toolbarControlHeight = 40.0;

enum _LiveFocusArea { category, channels, search, unknown }

class _MoveRightToChannelsIntent extends Intent {
  const _MoveRightToChannelsIntent();
}

/// Lists a source's channels with in-memory search + category filtering, plus
/// now/next EPG (when the source provides it).
class ChannelListScreen extends StatefulWidget {
  final LibraryRepository repo;

  /// The active source's config, carrying per-source preferences (e.g. hidden
  /// categories). Read for presentation only — browsing filters key off it.
  final SourceConfig config;
  final VoidCallback? onManageSources;

  /// The active profile's display name (used for the avatar initial) and its
  /// index into the avatar colour palette.
  final String? profileName;
  final int profileColorIndex;

  /// Avatar dropdown callbacks. "Profile settings" (cloud sync) is only wired
  /// when the build has cloud config; "Change profile" is always available.
  final VoidCallback? onChangeProfile;
  final VoidCallback? onProfileSettings;

  const ChannelListScreen({
    super.key,
    required this.repo,
    required this.config,
    this.onManageSources,
    this.profileName,
    this.profileColorIndex = 0,
    this.onChangeProfile,
    this.onProfileSettings,
  });

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  final _searchController = TextEditingController();

  ContentKind _tab = ContentKind.live;
  // Live channel/category/EPG data + load lifecycle live in a controller; the
  // screen keeps the live focus/D-pad state and preview player (see below).
  late final LiveController _live;
  // Movies/series browsing state + async ops live in a controller per kind;
  // both persist for the screen's lifetime so state survives tab switches.
  late final Map<ContentKind, MediaTabController> _mediaControllers;
  MediaTabController _media(ContentKind kind) => _mediaControllers[kind]!;
  // Favorited item ids per content kind (live channels / movies / series) live
  // in a controller; the "last favorite removed → fall back to All" handling
  // stays here (it's tied to _categoryId / the media controllers).
  late final FavoritesController _favorites;
  String? _categoryId;
  String _query = '';

  bool _resolving = false;
  Timer? _searchTimer;
  // One controller for whichever list/grid is mounted (only one exists per tab),
  // so a tab/category change can jump it back to the top.
  final ScrollController _scrollController = ScrollController();
  final FocusNode _liveSearchCellFocusNode = FocusNode(
    debugLabel: 'live.search.cell',
  );
  final FocusNode _firstChannelFocusNode = FocusNode(
    debugLabel: 'live.channel.first',
  );
  final Map<String, FocusNode> _liveChannelFocusNodes = {};
  bool _liveFocusPruneScheduled = false;
  final Map<String, FocusNode> _liveCategoryFocusNodes = {};
  // One stable focus node per content-kind tab chip, so a Back-key peel can jump
  // focus straight to the current tab (and detect when focus is already there)
  // instead of arrowing up item by item through a long list — see
  // _handleRootBack. Deliberately plain FocusNodes, not a FocusScope: the whole
  // screen relies on a single flat scope with FocusTraversalGroups so arrow-down
  // flows tabs → toolbar → list, and a nested scope would trap that traversal.
  final Map<ContentKind, FocusNode> _tabFocusNodes = {
    ContentKind.live: FocusNode(debugLabel: 'content.tab.live'),
    ContentKind.movie: FocusNode(debugLabel: 'content.tab.movie'),
    ContentKind.series: FocusNode(debugLabel: 'content.tab.series'),
  };
  _LiveFocusArea _lastLiveFocusArea = _LiveFocusArea.unknown;
  String? _lastPlayedLiveChannelId;
  String? _lastFocusedLiveChannelId;
  bool _downHoldFromChannels = false;
  final Map<String, String> _lastBrowsedLiveChannelByCategory = {};
  // Live preview player + its state live in a controller; the screen keeps the
  // focus-driven preview trigger (below), fullscreen playback, and the phone
  // preview sheet, which drive it.
  late final LivePreviewController _preview;
  // Focus-debounce for desktop auto-preview (stays here — it's focus timing).
  Timer? _previewTimer;

  @override
  void initState() {
    super.initState();
    _live = LiveController(repo: widget.repo)..addListener(_onLiveChanged);
    _preview = LivePreviewController(repo: widget.repo, onError: _showSnack)
      ..addListener(_onLiveChanged);
    _favorites = FavoritesController(repo: widget.repo)
      ..addListener(_onFavoritesChanged);
    _mediaControllers = {
      for (final kind in const [ContentKind.movie, ContentKind.series])
        kind: MediaTabController(
          kind: kind,
          repo: widget.repo,
          onEnrichError: _showSnack,
        )..addListener(_onMediaChanged),
    };
    HardwareKeyboard.instance.addHandler(_handleLiveGlobalKeyEvent);
    _firstChannelFocusNode.addListener(() {
      final visible = _visible;
      if (visible.isNotEmpty) {
        _onChannelFocusChanged(visible.first, _firstChannelFocusNode.hasFocus);
      }
    });
    _loadLive();
    _live.startEpgRefresh();
  }

  void _onLiveChanged() {
    if (mounted) setState(() {});
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  /// Load live channels (via the controller) plus the focus-node prune and
  /// favorites, which stay in the screen.
  Future<void> _loadLive({bool forceRefresh = false}) async {
    await _live.load(forceRefresh: forceRefresh);
    if (!mounted) return;
    _scheduleLiveFocusNodePrune();
    await _loadFavorites(ContentKind.live);
  }

  @override
  void didUpdateWidget(covariant ChannelListScreen old) {
    super.didUpdateWidget(old);
    // Source settings may have changed while we were away (the config is a fresh
    // object after a reload). If the category currently selected was just
    // disabled, fall back to "All" so we don't show an empty, unselectable view.
    if (!identical(old.config, widget.config)) {
      if (_hiddenCategories(ContentKind.live).contains(_categoryId)) {
        _categoryId = null;
      }
      for (final kind in const [ContentKind.movie, ContentKind.series]) {
        if (_hiddenCategories(kind).contains(_media(kind).categoryId)) {
          _loadMediaTab(kind, category: null, switchCategory: true);
        }
      }
    }
  }

  /// Rebuild when a media controller's state changes (load/search/enrich), so
  /// the toolbar/status line — which read the active controller — refresh. The
  /// grid also rebuilds; scope is the same as the old per-kind setState.
  void _onMediaChanged() {
    if (mounted) setState(() {});
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Load a media tab and its favorites together (favorites live in the parent,
  /// not the controller). [category] optionally switches category first.
  void _loadMediaTab(
    ContentKind kind, {
    String? category,
    bool switchCategory = false,
    bool forceRefresh = false,
  }) {
    final controller = _media(kind);
    if (switchCategory) {
      unawaited(controller.setCategory(category));
    } else {
      unawaited(controller.load(forceRefresh: forceRefresh));
    }
    unawaited(_loadFavorites(kind));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleLiveGlobalKeyEvent);
    _live.dispose();
    _preview.dispose();
    _favorites.dispose();
    _searchTimer?.cancel();
    _previewTimer?.cancel();
    _liveSearchCellFocusNode.dispose();
    _firstChannelFocusNode.dispose();
    for (final node in _tabFocusNodes.values) {
      node.dispose();
    }
    for (final node in _liveChannelFocusNodes.values) {
      node.dispose();
    }
    for (final node in _liveCategoryFocusNodes.values) {
      node.dispose();
    }
    for (final controller in _mediaControllers.values) {
      controller.dispose();
    }
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// On Android (phone + TV) previews are deliberate: started by an explicit
  /// OK press (TV split-pane) or long-press (phone), and they carry audio
  /// because the user asked for them. On desktop they auto-start muted after a
  /// short focus debounce, mouse-hover style.
  bool get _deliberatePreview => Platform.isAndroid;

  void _onChannelFocusChanged(Channel channel, bool hasFocus) {
    if (!hasFocus) {
      if (!_deliberatePreview && _preview.channelId == channel.id) {
        _previewTimer?.cancel();
      }
      return;
    }

    if (_deliberatePreview) {
      // No auto-preview on a TV remote: just let the info panel follow focus,
      // and drop any preview still playing for a different channel.
      if (_lastFocusedLiveChannelId != channel.id) {
        setState(() => _lastFocusedLiveChannelId = channel.id);
      }
      if (_preview.channelId != null && _preview.channelId != channel.id) {
        unawaited(_preview.stop(clearSelection: true));
      }
      return;
    }

    _previewTimer?.cancel();

    // Debounce for 500ms (desktop mouse/keyboard).
    _previewTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final isWide = MediaQuery.of(context).size.width >= 950;
      if (isWide && _tab == ContentKind.live) {
        _preview.start(channel);
      }
    });
  }

  Channel? _findChannelById(String id) {
    for (final c in _live.channels) {
      if (c.id == id) return c;
    }
    return null;
  }

  void _restoreListFocusAfterPlayback() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_tab == ContentKind.live) {
        if (_visible.isEmpty) return;
        final targetId = _lastPlayedLiveChannelId;
        final hasTarget =
            targetId != null &&
            _visible.any((channel) => channel.id == targetId);
        if (hasTarget) {
          if (_visible.isNotEmpty && _visible.first.id == targetId) {
            _firstChannelFocusNode.requestFocus();
          } else {
            _focusNodeForLiveChannel(targetId).requestFocus();
          }
        } else {
          _firstChannelFocusNode.requestFocus();
        }
        return;
      }
      if (_tab == ContentKind.movie || _tab == ContentKind.series) {
        if (_visibleMedia(_tab).isEmpty) return;
        _media(_tab).firstFocusNode.requestFocus();
      }
    });
  }

  void _focusChannelsFromCategory() {
    final visible = _visible;
    if (visible.isEmpty) return;
    final categoryKey = _liveCategoryKey(_categoryId);
    final resumeId = _lastBrowsedLiveChannelByCategory[categoryKey];
    final hasResume =
        resumeId != null && visible.any((channel) => channel.id == resumeId);
    final resumeIndex = hasResume
        ? visible.indexWhere((channel) => channel.id == resumeId)
        : -1;
    if (hasResume && resumeIndex > 0 && _scrollController.hasClients) {
      const estimatedChannelRowExtent = 104.0;
      final targetOffset = resumeIndex * estimatedChannelRowExtent;
      final maxOffset = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(targetOffset.clamp(0, maxOffset));
    }
    final FocusNode targetNode = hasResume && visible.first.id != resumeId
        ? _focusNodeForLiveChannel(resumeId)
        : _firstChannelFocusNode;
    targetNode.requestFocus();
    _reassertLiveFocus(
      targetNode,
      shouldRetry: (label) =>
          label.startsWith('live.category.') || label == 'Focus',
      attempts: 4,
    );
    _reassertLiveFocus(
      _firstChannelFocusNode,
      shouldRetry: (label) =>
          label.startsWith('live.category.') || label == 'Focus',
      attempts: 6,
    );
    _lastLiveFocusArea = _LiveFocusArea.channels;
  }

  String _liveCategoryKey(String? categoryId) =>
      categoryId ?? '__live.channels__';

  FocusNode _focusNodeForLiveChannel(String channelId) {
    return _liveChannelFocusNodes.putIfAbsent(channelId, () {
      final node = FocusNode(debugLabel: 'live.channel.$channelId');
      node.addListener(() {
        final channel = _findChannelById(channelId);
        if (channel != null) {
          _onChannelFocusChanged(channel, node.hasFocus);
        }
      });
      return node;
    });
  }

  /// Per-channel [FocusNode]s are created lazily as rows scroll into view. Left
  /// unbounded they'd accumulate the union of every channel browsed this
  /// session (thousands, on a large playlist). Prune back to the current
  /// working set — the filtered [_visible] list — whenever that set changes.
  /// Runs post-frame so we never dispose a node still attached to a live
  /// widget, and never disposes the focused node (belt-and-suspenders; the
  /// focused channel is normally in [_visible] anyway).
  void _scheduleLiveFocusNodePrune() {
    if (_liveFocusPruneScheduled) return;
    _liveFocusPruneScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveFocusPruneScheduled = false;
      if (!mounted) return;
      final keep = _visible.map((c) => c.id).toSet();
      _liveChannelFocusNodes.removeWhere((id, node) {
        if (keep.contains(id) || node.hasFocus) return false;
        node.dispose();
        return true;
      });
    });
  }

  void _rememberBrowsedLiveChannel(String channelId) {
    _lastBrowsedLiveChannelByCategory[_liveCategoryKey(_categoryId)] =
        channelId;
  }

  void _focusCategoryFromChannels() {
    _downHoldFromChannels = false;
    final categoryNode = _focusNodeForCategory(_categoryId);
    categoryNode.requestFocus();
    _reassertLiveFocus(
      categoryNode,
      shouldRetry: (label) =>
          label.startsWith('live.channel.') || label == 'Focus',
      attempts: 4,
    );
    _lastLiveFocusArea = _LiveFocusArea.category;
  }

  void _focusLiveChannelByIndex(List<Channel> visible, int index) {
    if (visible.isEmpty) return;
    final clamped = index.clamp(0, visible.length - 1);
    if (clamped == 0) {
      _firstChannelFocusNode.requestFocus();
      return;
    }
    final node = _focusNodeForLiveChannel(visible[clamped].id);
    if (node.context == null && _scrollController.hasClients) {
      const estimatedChannelRowExtent = 104.0;
      final maxOffset = _scrollController.position.maxScrollExtent;
      final targetOffset = (clamped * estimatedChannelRowExtent)
          .clamp(0, maxOffset)
          .toDouble();
      _scrollController.jumpTo(targetOffset);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (node.context != null) {
          node.requestFocus();
          return;
        }
        if (_scrollController.hasClients) {
          final nudged =
              (_scrollController.position.pixels + estimatedChannelRowExtent)
                  .clamp(0, _scrollController.position.maxScrollExtent)
                  .toDouble();
          _scrollController.jumpTo(nudged);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          node.requestFocus();
        });
      });
      return;
    }
    node.requestFocus();
  }

  void _moveDownInLiveChannels(String channelId) {
    final visible = _visible;
    if (visible.isEmpty) return;
    final currentIndex = visible.indexWhere(
      (channel) => channel.id == channelId,
    );
    if (currentIndex < 0) return;
    final nextIndex = (currentIndex + 1) % visible.length;
    if (nextIndex == 0) {
      _lastFocusedLiveChannelId = visible.first.id;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_firstChannelFocusNode.context != null) {
          _firstChannelFocusNode.requestFocus();
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _firstChannelFocusNode.requestFocus();
        });
      });
      return;
    }
    _lastFocusedLiveChannelId = visible[nextIndex].id;
    _focusLiveChannelByIndex(visible, nextIndex);
  }

  String? _channelIdFromFocusLabel(String label) {
    if (label == 'live.channel.first') {
      final visible = _visible;
      return visible.isEmpty ? null : visible.first.id;
    }
    const prefix = 'live.channel.';
    if (!label.startsWith(prefix)) return null;
    final id = label.substring(prefix.length);
    if (id.isEmpty || id == 'first') return null;
    return id;
  }

  void _reassertLiveFocus(
    FocusNode targetNode, {
    required bool Function(String label) shouldRetry,
    int attempts = 3,
  }) {
    if (attempts <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
      if (!shouldRetry(label)) return;
      targetNode.requestFocus();
      _reassertLiveFocus(
        targetNode,
        shouldRetry: shouldRetry,
        attempts: attempts - 1,
      );
    });
  }

  bool _handleLiveGlobalKeyEvent(KeyEvent event) {
    if (_tab != ContentKind.live) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown && event is KeyUpEvent) {
      _downHoldFromChannels = false;
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (key != LogicalKeyboardKey.arrowDown) {
      _downHoldFromChannels = false;
    }

    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    if (key == LogicalKeyboardKey.arrowRight &&
        label.startsWith('live.category.')) {
      _focusChannelsFromCategory();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final channelId = _channelIdFromFocusLabel(label);
      if (channelId != null) {
        _downHoldFromChannels = true;
        _lastFocusedLiveChannelId = channelId;
        _moveDownInLiveChannels(channelId);
        return true;
      }
      // Once a Down hold started in channels, keep all subsequent Down events
      // locked to channel navigation until key-up to avoid pane leakage.
      if (_downHoldFromChannels) {
        final visible = _visible;
        if (visible.isEmpty) return true;
        final fallbackId = _lastFocusedLiveChannelId ?? visible.first.id;
        _moveDownInLiveChannels(fallbackId);
        return true;
      }
      return false;
    }
    return false;
  }

  KeyEventResult _handleLiveSearchCellKey(FocusNode node, KeyEvent event) {
    if (_tab != ContentKind.live) return KeyEventResult.ignored;
    if (!_liveSearchCellFocusNode.hasFocus) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    _focusChannelsFromCategory();
    return KeyEventResult.handled;
  }

  _LiveFocusArea _focusAreaFromLabel(String label) {
    if (label.startsWith('live.category.')) return _LiveFocusArea.category;
    if (label.startsWith('live.channel.')) return _LiveFocusArea.channels;
    if (label == 'live.search.cell') return _LiveFocusArea.search;
    return _LiveFocusArea.unknown;
  }

  KeyEventResult _handleLivePaneFallbackKey(FocusNode node, KeyEvent event) {
    if (_tab != ContentKind.live) return KeyEventResult.ignored;
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    final area = _focusAreaFromLabel(label);
    if (area != _LiveFocusArea.unknown) {
      _lastLiveFocusArea = area;
      if (area == _LiveFocusArea.channels) {
        final focusedChannelId = _channelIdFromFocusLabel(label);
        if (focusedChannelId != null) {
          _lastFocusedLiveChannelId = focusedChannelId;
        } else if (label == 'live.channel.first' && _visible.isNotEmpty) {
          _lastFocusedLiveChannelId = _visible.first.id;
        }
      }
    }

    final key = event.logicalKey;

    if (label.startsWith('live.category.') &&
        key == LogicalKeyboardKey.arrowRight) {
      _focusChannelsFromCategory();
      return KeyEventResult.handled;
    }
    if (label.startsWith('live.channel.') &&
        key == LogicalKeyboardKey.arrowLeft) {
      _focusCategoryFromChannels();
      return KeyEventResult.handled;
    }

    if (label.startsWith('live.category.') &&
        key == LogicalKeyboardKey.arrowDown &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        _downHoldFromChannels) {
      final visible = _visible;
      if (visible.isNotEmpty) {
        _moveDownInLiveChannels(_lastFocusedLiveChannelId ?? visible.first.id);
      }
      return KeyEventResult.handled;
    }

    // If focus transiently lands on an unlabeled node, route based on the last
    // known pane so navigation stays deterministic.
    if (label == 'Focus') {
      if (key == LogicalKeyboardKey.arrowRight &&
          _lastLiveFocusArea == _LiveFocusArea.category) {
        _focusChannelsFromCategory();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft &&
          _lastLiveFocusArea == _LiveFocusArea.channels) {
        _focusCategoryFromChannels();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown &&
          _lastLiveFocusArea == _LiveFocusArea.search) {
        _focusChannelsFromCategory();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  void _setQuery(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    if (_tab == ContentKind.live) {
      _scheduleLiveFocusNodePrune();
      return;
    }
    final controller = _media(_tab);
    final query = value.trim();
    if (query.length < 2) {
      controller.clearSearch();
      return;
    }
    _searchTimer = Timer(
      const Duration(milliseconds: 450),
      () => controller.search(query),
    );
  }

  /// Category ids the user disabled for [kind] in source settings.
  Set<String> _hiddenCategories(ContentKind kind) =>
      widget.config.hiddenCategoryIds(kind);

  Set<String> _favoriteIds(ContentKind kind) => _favorites.ids(kind);

  bool _isFavorite(ContentKind kind, String id) =>
      _favorites.isFavorite(kind, id);

  Future<void> _loadFavorites(ContentKind kind) => _favorites.load(kind);

  Future<void> _toggleFavorite(ContentKind kind, String id) async {
    final nowEmpty = await _favorites.toggle(kind, id);
    if (!mounted || !nowEmpty) return;
    // Emptying the Favorites view leaves nothing to select — fall back to All.
    setState(() {
      if (kind == ContentKind.live && _categoryId == kFavoritesCategoryId) {
        _categoryId = null;
      } else if (kind != ContentKind.live) {
        _media(kind).resetFavoritesCategoryToAll();
      }
    });
  }

  /// Live categories shown in the pane/dropdown: the Favorites entry (only when
  /// something is favorited) followed by the enabled provider categories.
  List<Category> get _liveCategoriesForUi {
    final cats = _visibleCategories;
    if (_favoriteIds(ContentKind.live).isEmpty) return cats;
    return [
      const Category(id: kFavoritesCategoryId, title: 'Favorites'),
      ...cats,
    ];
  }

  List<MediaCategory> _mediaCategoriesForUi(ContentKind kind) {
    final cats = _visibleMediaCategories(kind);
    if (_favoriteIds(kind).isEmpty) return cats;
    return [
      MediaCategory(id: kFavoritesCategoryId, title: 'Favorites', kind: kind),
      ...cats,
    ];
  }

  /// Live categories with disabled ones removed (for the pane/dropdown).
  List<Category> get _visibleCategories {
    final hidden = _hiddenCategories(ContentKind.live);
    if (hidden.isEmpty) return _live.categories;
    return _live.categories.where((c) => !hidden.contains(c.id)).toList();
  }

  /// Media categories for [kind] with disabled ones removed.
  List<MediaCategory> _visibleMediaCategories(ContentKind kind) {
    final all = _media(kind).snapshot?.categories ?? const <MediaCategory>[];
    final hidden = _hiddenCategories(kind);
    if (hidden.isEmpty) return all;
    return all.where((c) => !hidden.contains(c.id)).toList();
  }

  List<Channel> get _visible {
    final q = _query.trim().toLowerCase();
    final favoritesView = _categoryId == kFavoritesCategoryId;
    final favs = favoritesView ? _favoriteIds(ContentKind.live) : null;
    final hidden = _hiddenCategories(ContentKind.live);
    return _live.channels.where((c) {
      if (favoritesView) {
        // Favorites are explicit picks, shown even from a disabled category.
        if (!favs!.contains(c.id)) return false;
      } else {
        if (hidden.contains(c.categoryId)) return false;
        if (_categoryId != null && c.categoryId != _categoryId) return false;
      }
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  List<MediaItem> _visibleMedia(ContentKind kind) {
    final controller = _media(kind);
    final q = _query.trim().toLowerCase();
    final favoritesView = controller.categoryId == kFavoritesCategoryId;
    final favs = favoritesView ? _favoriteIds(kind) : null;
    final hidden = _hiddenCategories(kind);
    if (q.length >= 2 && controller.searchQuery == _query.trim()) {
      final results = controller.searchResults;
      return results.where((item) {
        if (favoritesView) return favs!.contains(item.id);
        return !hidden.contains(item.categoryId);
      }).toList();
    }
    final items = controller.snapshot?.items ?? const <MediaItem>[];
    return items.where((item) {
      if (favoritesView) {
        if (!favs!.contains(item.id)) return false;
      } else {
        if (hidden.contains(item.categoryId)) return false;
      }
      if (q.isNotEmpty && !item.title.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  FocusNode _focusNodeForCategory(String? categoryId) {
    final key = categoryId ?? 'all';
    return _liveCategoryFocusNodes.putIfAbsent(
      key,
      () => FocusNode(debugLabel: 'live.category.$key'),
    );
  }

  Future<void> _play(Channel channel) async {
    if (_resolving) return;
    final isWide = MediaQuery.of(context).size.width >= 950;
    if (!isWide) {
      // On small screens, bypass preview and go fullscreen immediately
      setState(() => _resolving = true);
      try {
        DiagnosticsLog.instance.add(
          'library',
          'open live fullscreen source=${widget.repo.source.name} channel=${channel.name} id=${channel.id}',
        );
        final stream = await widget.repo.resolve(channel);
        if (!mounted) return;
        _lastPlayedLiveChannelId = channel.id;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
              title: channel.name,
              stream: stream,
              sourceName: widget.repo.source.name,
              epgNow: _live.now[channel.id],
              epgNext: _live.next[channel.id],
            ),
          ),
        );
        _restoreListFocusAfterPlayback();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not play: $e')));
        }
      } finally {
        if (mounted) setState(() => _resolving = false);
      }
      return;
    }

    // On wide screens, check if we're already previewing
    final samePreviewChannel = _preview.channelId == channel.id;
    if (samePreviewChannel && _preview.stream != null) {
      await _openLivePlayer(channel, _preview.stream!);
      return;
    }
    // First OK starts the preview; on a TV remote it's deliberate, so unmuted.
    await _preview.start(channel, muted: !_deliberatePreview);
  }

  /// Opens fullscreen playback for [channel]/[stream]. When [reusePreview] and
  /// the preview is already showing this exact channel, the fullscreen player
  /// *adopts* the running preview engine instead of resolving/opening fresh:
  /// on Android the native Activity takes over the shared ExoPlayer engine
  /// (only the video surface moves — audio and buffer never stop); elsewhere
  /// the same media_kit [Player] is handed to [PlayerScreen]. Seamless either
  /// way, so the preview is *not* paused around an adopted handoff.
  ///
  /// [resumePreviewOnReturn] is false for the phone sheet (no panel to return
  /// to): the preview is stopped once fullscreen exits instead of resumed.
  Future<void> _openLivePlayer(
    Channel channel,
    StreamInfo stream, {
    bool reusePreview = true,
    bool resumePreviewOnReturn = true,
  }) async {
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final adoptPreview =
        reusePreview &&
        _preview.channelId == channel.id &&
        _preview.stream != null;
    // Android + native preview engine: the fullscreen Activity adopts it.
    final adoptNative =
        adoptPreview && Platform.isAndroid && _preview.nativeActive;
    final previewWasMuted = adoptPreview && _preview.isMuted;
    try {
      DiagnosticsLog.instance.add(
        'library',
        'open live fullscreen source=${widget.repo.source.name} channel=${channel.name} id=${channel.id}',
      );
      _lastPlayedLiveChannelId = channel.id;
      // An adopted engine keeps playing straight through the handoff (that's
      // the seamless part). Only pause when the fullscreen player will open its
      // own pipeline — i.e. Android's native player over a media_kit-fallback
      // preview — so the preview's audio doesn't double up behind it.
      final seamless = adoptPreview && (adoptNative || !Platform.isAndroid);
      if (_preview.channelId == channel.id && !seamless) {
        await _preview.pause();
      }
      final hotSwapped =
          await navigator.push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => PlayerScreen(
                title: channel.name,
                stream: stream,
                sourceName: widget.repo.source.name,
                epgNow: _live.now[channel.id],
                epgNext: _live.next[channel.id],
                existingPlayer: (adoptPreview && !adoptNative)
                    ? _preview.player
                    : null,
                existingController: (adoptPreview && !adoptNative)
                    ? _preview.controller
                    : null,
                adoptNativePreview: adoptNative,
              ),
            ),
          ) ??
          false;
      if (!mounted) return;
      if (hotSwapped) {
        // The fullscreen player re-pointed this player's video output at the
        // Windows native HDR surface, which just tore down — no longer safe
        // to reuse for the preview's embedded texture.
        await _preview.discardPlayer();
      } else if (!resumePreviewOnReturn) {
        // Phone sheet handoff: nothing shows the preview after fullscreen.
        await _preview.stop(clearSelection: true);
      } else if (adoptPreview && _preview.stream != null) {
        await _preview.play();
        // Fullscreen always plays at full volume; restore a muted (desktop
        // auto-hover) preview instead of leaving it blaring once we return.
        if (previewWasMuted) await _preview.setMuted(true);
      }
      _restoreListFocusAfterPlayback();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not play: $e')));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Phone-only: open a compact, audible preview of [channel] in a bottom
  /// sheet (tap on a tile still goes straight to fullscreen). Reuses the single
  /// preview player; the sheet's Play button hands off to fullscreen.
  Future<void> _showPreviewSheet(Channel channel) async {
    if (_resolving) return;
    unawaited(_preview.start(channel, muted: false));
    // Set when Play hands the preview to fullscreen — the handoff owns the
    // preview's lifecycle from there (stopped when fullscreen exits), so the
    // post-sheet cleanup below must leave it alone.
    var handedOff = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _PhonePreviewSheet(
        preview: _preview,
        channel: channel,
        now: _live.now[channel.id],
        next: _live.next[channel.id],
        favorite: _isFavorite(ContentKind.live, channel.id),
        onToggleFavorite: () => _toggleFavorite(ContentKind.live, channel.id),
        onCatchup: channel.hasArchive ? () => _showCatchupSheet(channel) : null,
        onPlay: () {
          final stream = _preview.stream;
          Navigator.of(sheetContext).pop();
          if (stream != null && _preview.channelId == channel.id) {
            handedOff = true;
            // A native preview hands off seamlessly (the fullscreen Activity
            // adopts its engine); the media_kit fallback still opens fresh.
            // Either way there's no panel to return to, so the preview is
            // stopped when fullscreen exits rather than resumed.
            unawaited(
              _openLivePlayer(
                channel,
                stream,
                reusePreview: _preview.nativeActive,
                resumePreviewOnReturn: false,
              ),
            );
          } else {
            unawaited(_play(channel));
          }
        },
      ),
    );
    if (!handedOff) await _preview.stop(clearSelection: true);
  }

  /// Open the catch-up picker for an archive-capable [channel]: list its cached
  /// past programmes and play the chosen one via [_playCatchup].
  Future<void> _showCatchupSheet(Channel channel) async {
    if (_resolving) return;
    final messenger = ScaffoldMessenger.of(context);
    final programmes = await widget.repo.archiveProgrammes(channel);
    if (!mounted) return;
    if (programmes.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No catch-up guide cached for this channel yet'),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _CatchupSheet(
        channel: channel,
        // Most recent first.
        programmes: programmes.reversed.toList(),
        onPlay: (programme) {
          Navigator.of(sheetContext).pop();
          unawaited(_playCatchup(channel, programme));
        },
      ),
    );
  }

  /// Resolve a past [programme] to a catch-up stream and open it fullscreen.
  Future<void> _playCatchup(Channel channel, Programme programme) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _preview.pause();
      DiagnosticsLog.instance.add(
        'library',
        'open catch-up source=${widget.repo.source.name} channel=${channel.name} programme=${programme.title} start=${programme.start.toIso8601String()}',
      );
      _lastPlayedLiveChannelId = channel.id;
      final stream = await widget.repo.resolveArchive(channel, programme);
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: '${channel.name} · ${programme.title}',
            stream: stream,
            sourceName: widget.repo.source.name,
            epgNow: programme,
          ),
        ),
      );
      if (_preview.stream != null && mounted) await _preview.play();
      _restoreListFocusAfterPlayback();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not play catch-up: $e')),
      );
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
    _media(replacement.kind).replaceItems({replacement.id: replacement});
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
      if (_tab == ContentKind.movie || _tab == ContentKind.series) {
        _media(_tab).setLastPlayed(item.id);
      }
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: item.title,
            stream: stream,
            sourceName: widget.repo.source.name,
          ),
        ),
      );
      _restoreListFocusAfterPlayback();
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
        favorite: _isFavorite(item.kind, item.id),
        onToggleFavorite: () => _toggleFavorite(item.kind, item.id),
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
    if (_live.syncedAt != null) {
      b.write(
        _live.fromCache
            ? ' · cached, synced ${_ago(_live.syncedAt!)}'
            : ' · synced ${_ago(_live.syncedAt!)}',
      );
    }
    return b.toString();
  }

  String _mediaStatusLine(ContentKind kind, int count) {
    final snap = _media(kind).snapshot;
    final label = kind == ContentKind.movie ? 'movies' : 'series';
    final searching = _query.trim().length >= 2;
    final b = StringBuffer(
      searching
          ? 'Found ${_fmt(count)} $label'
          : 'Showing ${_fmt(count)} $label',
    );
    final categoryId = _media(kind).categoryId;
    if (categoryId == kFavoritesCategoryId) {
      b.write(' in Favorites');
    } else if (categoryId != null) {
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
    final controller = _tab == ContentKind.live
        ? _scrollController
        : _media(_tab).scrollController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) controller.jumpTo(0);
    });
  }

  void _selectTab(ContentKind kind) {
    if (_tab == kind) return;
    final previous = _tab;
    if (previous == ContentKind.live && kind != ContentKind.live) {
      unawaited(_preview.stop());
    }
    if (previous != ContentKind.live) {
      _media(previous).clearSearch();
    }
    setState(() {
      _tab = kind;
      _query = '';
      _searchController.clear();
      _searchTimer?.cancel();
    });
    DiagnosticsLog.instance.add(
      'library',
      'tab source=${widget.repo.source.name} ${previous.name}->${kind.name}',
    );
    if (kind != ContentKind.live && _media(kind).snapshot == null) {
      _loadMediaTab(kind);
    }
    _scrollToTop();
  }

  /// Peels one D-pad rung per Back press, keyed off what's focused, and
  /// **defaults to exiting the app** for anything above the content (search box,
  /// tabs, app-bar buttons) — so Back leaves from the toolbar too, not only the
  /// section tabs. Live (wide/TV) ladder: channel list → category sidebar (last
  /// selected) → "All channels" highlight → search box → exit.
  void _handleRootBack(bool didPop, Object? result) {
    if (didPop) return;
    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    // Flutter invokes every registered PopScope when a pop is blocked, so defer
    // entirely to TvTextField's own PopScope while its inner field is actually
    // being edited — it already exits edit mode on Back.
    if (label == 'TvTextField.field') return;

    final wideLive =
        _tab == ContentKind.live && MediaQuery.of(context).size.width >= 950;

    // Live channel list → the category sidebar (wide) or straight to search
    // (narrow, which has no sidebar).
    if (label.startsWith('live.channel.')) {
      if (wideLive) {
        _focusCategoryFromChannels();
      } else {
        _liveSearchCellFocusNode.requestFocus();
      }
      return;
    }
    // On "All channels" → the search box.
    if (label == 'live.category.all') {
      _liveSearchCellFocusNode.requestFocus();
      _lastLiveFocusArea = _LiveFocusArea.search;
      return;
    }
    // On a specific category → move the highlight to "All channels" without
    // changing the current filter (the user presses OK to actually switch).
    if (label.startsWith('live.category.')) {
      _focusNodeForCategory(null).requestFocus();
      _lastLiveFocusArea = _LiveFocusArea.category;
      return;
    }
    // Movies/series grid → the content-kind tabs.
    if (label.startsWith('media.')) {
      _tabFocusNodes[_tab]?.requestFocus();
      return;
    }
    // Search box, tabs, app-bar buttons, or anything unlabeled: nothing left to
    // peel. This screen is HomeShell's root content (not a pushed route), so
    // there may be nothing to pop to — fall back to the platform default (exit).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleRootBack,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.repo.source.name),
          leading: (widget.onChangeProfile != null ||
                  widget.onProfileSettings != null)
              ? ProfileAvatarButton(
                  profileName: widget.profileName,
                  colorIndex: widget.profileColorIndex,
                  onChangeProfile: widget.onChangeProfile,
                  onProfileSettings: widget.onProfileSettings,
                )
              : null,
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
                      onPressed: () {
                        unawaited(_preview.stop());
                        widget.onManageSources?.call();
                      },
                    ),
                  IconButton(
                    tooltip: 'Diagnostics',
                    icon: const Icon(Icons.bug_report_outlined),
                    onPressed: () async {
                      await _preview.stop();
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DiagnosticsScreen(),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Refresh from source',
                    icon: const Icon(Icons.refresh),
                    onPressed:
                        _live.loading ||
                            (_tab != ContentKind.live && _media(_tab).loading)
                        ? null
                        : () => _tab == ContentKind.live
                              ? _loadLive(forceRefresh: true)
                              : _loadMediaTab(_tab, forceRefresh: true),
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
              _ContentTabs(
                value: _tab,
                onChanged: _selectTab,
                focusNodes: _tabFocusNodes,
              ),
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
                searchCellFocusNode: _tab == ContentKind.live
                    ? _liveSearchCellFocusNode
                    : null,
                onSearchCellKeyEvent: _handleLiveSearchCellKey,
                categoryControl:
                    (_tab == ContentKind.live &&
                        MediaQuery.of(context).size.width >= 950)
                    ? null
                    : (_tab == ContentKind.live
                          ? _CategoryDropdown(
                              categories: _liveCategoriesForUi,
                              value: _categoryId,
                              onChanged: (v) {
                                setState(() => _categoryId = v);
                                _scheduleLiveFocusNodePrune();
                                _scrollToTop();
                              },
                            )
                          : _MediaCategoryDropdown(
                              categories: _mediaCategoriesForUi(_tab),
                              value: _media(_tab).categoryId,
                              onChanged: (v) {
                                final kind = _tab;
                                _loadMediaTab(
                                  kind,
                                  category: v,
                                  switchCategory: true,
                                );
                                _scrollToTop();
                                if (_query.trim().length >= 2) {
                                  _searchTimer?.cancel();
                                  _searchTimer = Timer(
                                    const Duration(milliseconds: 250),
                                    () => _media(kind).search(_query.trim()),
                                  );
                                }
                              },
                            )),
                actionControl:
                    _tab == ContentKind.live || !widget.repo.canEnrichMetadata
                    ? null
                    : _ToolbarIconButton(
                        tooltip: _media(_tab).enriching
                            ? 'Cancel metadata refresh'
                            : 'Refresh displayed metadata',
                        busy: _media(_tab).enriching,
                        icon: _media(_tab).enriching
                            ? Icons.stop_rounded
                            : Icons.auto_awesome_outlined,
                        onPressed:
                            _media(_tab).loading || _media(_tab).searching
                            ? null
                            : _media(_tab).enriching
                            ? _media(_tab).cancelEnrich
                            : () => _media(
                                _tab,
                              ).enrichVisible(_visibleMedia(_tab)),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _statusText(visible.length),
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _tab == ContentKind.live
                    ? LiveTabView(
                        loading: _live.loading,
                        error: _live.error,
                        onRetry: () => _loadLive(forceRefresh: true),
                        visible: visible,
                        previewChannel: _resolvePreviewChannel(visible),
                        now: _live.now,
                        next: _live.next,
                        deliberate: _deliberatePreview,
                        resolving: _resolving,
                        scrollController: _scrollController,
                        firstChannelFocusNode: _firstChannelFocusNode,
                        focusNodeForChannel: _focusNodeForLiveChannel,
                        lastPlayedChannelId: _lastPlayedLiveChannelId,
                        previewChannelId: _preview.channelId,
                        isFavorite: (id) => _isFavorite(ContentKind.live, id),
                        onToggleFavorite: (id) =>
                            _toggleFavorite(ContentKind.live, id),
                        onPlayChannel: _play,
                        onLongPressChannel: _showPreviewSheet,
                        onChannelMoveLeft: (id) {
                          _rememberBrowsedLiveChannel(id);
                          _focusCategoryFromChannels();
                        },
                        onChannelMoveDown: _moveDownInLiveChannels,
                        onCatchup: _showCatchupSheet,
                        categories: _liveCategoriesForUi,
                        selectedCategoryId: _categoryId,
                        focusNodeForCategory: _focusNodeForCategory,
                        onCategorySelected: (value) {
                          setState(() => _categoryId = value);
                          _scheduleLiveFocusNodePrune();
                          _scrollToTop();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            _focusNodeForCategory(_categoryId).requestFocus();
                            _lastLiveFocusArea = _LiveFocusArea.category;
                          });
                        },
                        onMoveRightToChannels: _focusChannelsFromCategory,
                        onPaneFallbackKey: _handleLivePaneFallbackKey,
                        previewVideoBuilder: () =>
                            PreviewVideo(preview: _preview),
                        previewLoading: _preview.loading,
                        previewError: _preview.error,
                      )
                    : MediaTabView(
                        kind: _tab,
                        visible: _visibleMedia(_tab),
                        snapshot: _media(_tab).snapshot,
                        loading: _media(_tab).loading,
                        loadingMore: _media(_tab).loadingMore,
                        error: _media(_tab).error,
                        showingSearch: _query.trim().length >= 2,
                        lastPlayedId: _media(_tab).lastPlayedId,
                        scrollController: _media(_tab).scrollController,
                        firstFocusNode: _media(_tab).firstFocusNode,
                        isFavorite: (id) => _isFavorite(_tab, id),
                        onOpenMedia: _openMedia,
                        onLoadMore: () => _media(_tab).loadMore(),
                        onRetry: () => _loadMediaTab(_tab, forceRefresh: true),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(int visibleLiveCount) {
    if (_tab == ContentKind.live) {
      return _live.loading ? '' : _statusLine(visibleLiveCount);
    }
    if (_media(_tab).loading) return '';
    if (_media(_tab).searching) return 'Searching provider...';
    if (_media(_tab).enriching) {
      final progress = _media(_tab).enrichmentProgress;
      if (progress != null) {
        return 'Refreshing metadata ${_fmt(progress.done)}/${_fmt(progress.total)} · press stop to cancel';
      }
      return 'Refreshing metadata · press stop to cancel';
    }
    return _mediaStatusLine(_tab, _visibleMedia(_tab).length);
  }

  /// The channel the live preview panel should show: on a TV remote it follows
  /// D-pad focus (last focused), on desktop the auto-preview selection; falls
  /// back to the last-played channel and finally the first visible one.
  Channel? _resolvePreviewChannel(List<Channel> visible) {
    if (visible.isEmpty) return null;
    Channel? byId(String? id) =>
        id == null ? null : _live.channels.where((c) => c.id == id).firstOrNull;
    if (_deliberatePreview) {
      return byId(_lastFocusedLiveChannelId) ??
          byId(_preview.channelId) ??
          byId(_lastPlayedLiveChannelId) ??
          visible.first;
    }
    return byId(_preview.channelId) ??
        byId(_lastPlayedLiveChannelId) ??
        visible.first;
  }
}

/// The live-TV browsing body: the channel list (with the category side-pane and
/// preview panel on wide layouts, plain list on phones), plus its D-pad focus
/// wiring. Extracted from `ChannelListScreen`'s State as a widget with an
/// explicit contract so it rebuilds independently; the preview player, focus
/// nodes, and D-pad handlers stay owned by the screen and are injected here.
class LiveTabView extends StatelessWidget {
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  final List<Channel> visible;

  /// Resolved preview target (null only when [visible] is empty).
  final Channel? previewChannel;
  final Map<String, Programme> now;
  final Map<String, Programme> next;

  final bool deliberate;
  final bool resolving;
  final ScrollController scrollController;

  final FocusNode firstChannelFocusNode;
  final FocusNode Function(String channelId) focusNodeForChannel;
  final String? lastPlayedChannelId;
  final String? previewChannelId;

  final bool Function(String id) isFavorite;
  final ValueChanged<String> onToggleFavorite;
  final ValueChanged<Channel> onPlayChannel;
  final ValueChanged<Channel> onLongPressChannel;
  final ValueChanged<String> onChannelMoveLeft;
  final ValueChanged<String> onChannelMoveDown;

  /// Opens catch-up for a channel (called only for archive-capable channels).
  final ValueChanged<Channel> onCatchup;

  final List<Category> categories;
  final String? selectedCategoryId;

  /// Stable focus node per category id (null → "All channels"), so Back can move
  /// the highlight to a specific entry (e.g. "All channels") without changing the
  /// filter. Each card wires up its own node.
  final FocusNode Function(String? categoryId) focusNodeForCategory;
  final ValueChanged<String?> onCategorySelected;
  final VoidCallback onMoveRightToChannels;
  final KeyEventResult Function(FocusNode, KeyEvent) onPaneFallbackKey;

  /// Built lazily (only when the wide preview panel actually renders) so no
  /// video output — native platform view or media_kit texture — is created
  /// during loading / on phones / when it's never shown.
  final Widget Function() previewVideoBuilder;
  final bool previewLoading;
  final String? previewError;

  const LiveTabView({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.visible,
    required this.previewChannel,
    required this.now,
    required this.next,
    required this.deliberate,
    required this.resolving,
    required this.scrollController,
    required this.firstChannelFocusNode,
    required this.focusNodeForChannel,
    required this.lastPlayedChannelId,
    required this.previewChannelId,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onPlayChannel,
    required this.onLongPressChannel,
    required this.onChannelMoveLeft,
    required this.onChannelMoveDown,
    required this.onCatchup,
    required this.categories,
    required this.selectedCategoryId,
    required this.focusNodeForCategory,
    required this.onCategorySelected,
    required this.onMoveRightToChannels,
    required this.onPaneFallbackKey,
    required this.previewVideoBuilder,
    required this.previewLoading,
    required this.previewError,
  });

  Widget _buildChannelList(
    BuildContext context, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(12, 4, 12, 16),
  }) {
    final allowLongPressPreview =
        deliberate && MediaQuery.of(context).size.width < 950;
    return ListView.builder(
      controller: scrollController,
      padding: padding,
      scrollCacheExtent: const ScrollCacheExtent.pixels(
        120,
      ), // keep nearby rows built for D-pad without over-prefetching logos
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final c = visible[i];
        return _ChannelTile(
          channel: c,
          now: now[c.id],
          next: next[c.id],
          favorite: isFavorite(c.id),
          debugLabel: 'live.channel.${c.id}',
          enabled: !resolving,
          autofocus: lastPlayedChannelId == null
              ? i == 0
              : c.id == lastPlayedChannelId,
          focusNode: i == 0 ? firstChannelFocusNode : focusNodeForChannel(c.id),
          onTap: () => onPlayChannel(c),
          onLongPress: allowLongPressPreview
              ? () => onLongPressChannel(c)
              : null,
          selected: c.id == previewChannelId,
          onMoveLeftToCategory: () => onChannelMoveLeft(c.id),
          onMoveDown: () => onChannelMoveDown(c.id),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Couldn\'t load this source.\n$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textLo),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
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
    final preview = previewChannel!;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 950) return _buildChannelList(context);
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: onPaneFallbackKey,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(
              children: [
                SizedBox(
                  width: 240,
                  child: _LiveCategoryPane(
                    categories: categories,
                    selectedCategoryId: selectedCategoryId,
                    focusNodeForCategory: focusNodeForCategory,
                    onSelected: onCategorySelected,
                    onMoveRightToChannels: onMoveRightToChannels,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      _LivePreviewPanel(
                        channel: preview,
                        now: now[preview.id],
                        next: next[preview.id],
                        previewVideo: previewVideoBuilder(),
                        previewActive: previewChannelId == preview.id,
                        previewLoading:
                            previewLoading && previewChannelId == preview.id,
                        previewError: previewChannelId == preview.id
                            ? previewError
                            : null,
                        deliberate: deliberate,
                        favorite: isFavorite(preview.id),
                        onToggleFavorite: () => onToggleFavorite(preview.id),
                        onCatchup: preview.hasArchive
                            ? () => onCatchup(preview)
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: _buildChannelList(
                          context,
                          padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The movies/series browsing body: the grid/list of [MediaItem]s with paging,
/// error/empty states, and D-pad focus. Extracted from `ChannelListScreen`'s
/// State as a widget with an explicit input contract so it rebuilds
/// independently of the rest of the (large) screen and so the media state can
/// later move behind a controller without touching this view. Live TV keeps its
/// own body; this handles [ContentKind.movie]/[ContentKind.series] only.
class MediaTabView extends StatelessWidget {
  final ContentKind kind;

  /// Filtered items to show (favorites/hidden/search already applied by the
  /// parent), and the underlying snapshot (drives "load more" / paging).
  final List<MediaItem> visible;
  final MediaLibrarySnapshot? snapshot;

  final bool loading;
  final bool loadingMore;
  final String? error;

  /// True when a live search query (>= 2 chars) is active — hides "load more"
  /// since search returns a flat, non-paged result set.
  final bool showingSearch;

  /// Id of the last-played item in this kind, autofocused on return when still
  /// visible (else the first item is).
  final String? lastPlayedId;

  final ScrollController scrollController;
  final FocusNode? firstFocusNode;

  final bool Function(String id) isFavorite;
  final ValueChanged<MediaItem> onOpenMedia;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  const MediaTabView({
    super.key,
    required this.kind,
    required this.visible,
    required this.snapshot,
    required this.loading,
    required this.loadingMore,
    required this.error,
    required this.showingSearch,
    required this.lastPlayedId,
    required this.scrollController,
    required this.firstFocusNode,
    required this.isFavorite,
    required this.onOpenMedia,
    required this.onLoadMore,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final showLoadMore =
        !showingSearch && (loadingMore || snapshot?.hasMore == true);
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
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
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
        final hasLastVisible =
            lastPlayedId != null &&
            visible.any((media) => media.id == lastPlayedId);
        FocusNode? focusNodeFor(int i) => hasLastVisible
            ? (visible[i].id == lastPlayedId ? firstFocusNode : null)
            : (i == 0 ? firstFocusNode : null);
        bool autofocusFor(int i) =>
            hasLastVisible ? visible[i].id == lastPlayedId : i == 0;
        if (!wide) {
          return ListView.builder(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            itemCount: visible.length + (showLoadMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == visible.length) {
                return _MediaLoadMoreTile(
                  snapshot: snapshot,
                  loading: loadingMore,
                  onPressed: onLoadMore,
                );
              }
              return _MediaListTile(
                item: visible[i],
                favorite: isFavorite(visible[i].id),
                autofocus: autofocusFor(i),
                focusNode: focusNodeFor(i),
                onTap: () => onOpenMedia(visible[i]),
              );
            },
          );
        }
        final columns = constraints.maxWidth >= 1280 ? 6 : 4;
        return GridView.builder(
          controller: scrollController,
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
                snapshot: snapshot,
                loading: loadingMore,
                onPressed: onLoadMore,
              );
            }
            return _MediaGridTile(
              item: visible[i],
              favorite: isFavorite(visible[i].id),
              autofocus: autofocusFor(i),
              focusNode: focusNodeFor(i),
              onTap: () => onOpenMedia(visible[i]),
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

  /// Stable focus node per tab, owned by the screen so Back can jump focus here
  /// (see [_ChannelListScreenState._handleRootBack]).
  final Map<ContentKind, FocusNode> focusNodes;

  const _ContentTabs({
    required this.value,
    required this.onChanged,
    required this.focusNodes,
  });

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
              focusNode: focusNodes[ContentKind.live],
              onTap: () => onChanged(ContentKind.live),
            ),
            const SizedBox(width: 8),
            _TabChip(
              icon: Icons.movie_outlined,
              label: 'Movies',
              selected: value == ContentKind.movie,
              autofocus: value == ContentKind.movie,
              focusNode: focusNodes[ContentKind.movie],
              onTap: () => onChanged(ContentKind.movie),
            ),
            const SizedBox(width: 8),
            _TabChip(
              icon: Icons.tv_outlined,
              label: 'Series',
              selected: value == ContentKind.series,
              autofocus: value == ContentKind.series,
              focusNode: focusNodes[ContentKind.series],
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
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _TabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.autofocus,
    required this.onTap,
    this.focusNode,
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
      focusNode: widget.focusNode,
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
  final FocusNode? searchCellFocusNode;
  final KeyEventResult Function(FocusNode, KeyEvent)? onSearchCellKeyEvent;
  final Widget? categoryControl;
  final Widget? actionControl;

  const _Toolbar({
    required this.searchController,
    required this.query,
    required this.hintText,
    required this.onQueryChanged,
    required this.onClearQuery,
    this.searchCellFocusNode,
    this.onSearchCellKeyEvent,
    this.categoryControl,
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
          cellFocusNode: searchCellFocusNode,
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
        final category = categoryControl;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: onSearchCellKeyEvent,
            child: narrow
                ? Column(
                    children: [
                      search,
                      if (category != null || action != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: double.infinity,
                            child: category == null
                                ? action!
                                : (action == null
                                      ? category
                                      : Row(
                                          children: [
                                            Expanded(child: category),
                                            const SizedBox(width: 8),
                                            action,
                                          ],
                                        )),
                          ),
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: search),
                      if (category != null) ...[
                        const SizedBox(width: 12),
                        category,
                      ],
                      if (action != null) ...[const SizedBox(width: 8), action],
                    ],
                  ),
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

class _LiveCategoryPane extends StatelessWidget {
  final List<Category> categories;
  final String? selectedCategoryId;
  final FocusNode Function(String? categoryId) focusNodeForCategory;
  final ValueChanged<String?> onSelected;
  final VoidCallback onMoveRightToChannels;

  const _LiveCategoryPane({
    required this.categories,
    required this.selectedCategoryId,
    required this.focusNodeForCategory,
    required this.onSelected,
    required this.onMoveRightToChannels,
  });

  @override
  Widget build(BuildContext context) {
    final items = <({String? id, String label})>[
      (id: null, label: 'All channels'),
      ...categories.map((category) => (id: category.id, label: category.title)),
    ];
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.arrowRight):
            const _MoveRightToChannelsIntent(),
      },
      child: Actions(
        actions: {
          _MoveRightToChannelsIntent:
              CallbackAction<_MoveRightToChannelsIntent>(
                onInvoke: (_) {
                  onMoveRightToChannels();
                  return null;
                },
              ),
        },
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(color: AppColors.line),
          ),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text(
                  'Playlists',
                  style: TextStyle(
                    color: AppColors.textLo,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final item in items)
                      Builder(
                        builder: (context) {
                          final selected = item.id == selectedCategoryId;
                          return FocusableCard(
                            autofocus: selected,
                            focusNode: focusNodeForCategory(item.id),
                            debugLabel: 'live.category.${item.id ?? 'all'}',
                            onKeyEvent: (node, event) {
                              final isRight =
                                  event.logicalKey ==
                                  LogicalKeyboardKey.arrowRight;
                              if (!isRight) return KeyEventResult.ignored;
                              onMoveRightToChannels();
                              return KeyEventResult.handled;
                            },
                            onTap: () => onSelected(item.id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected
                                      ? AppColors.textHi
                                      : AppColors.textLo,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LivePreviewPanel extends StatelessWidget {
  final Channel channel;
  final Programme? now;
  final Programme? next;
  /// The preview's video widget ([PreviewVideo]) — native platform view or
  /// media_kit texture, decided by the controller.
  final Widget previewVideo;
  final bool previewActive;
  final bool previewLoading;
  final String? previewError;

  /// When true (TV remote), OK starts the preview rather than auto-previewing
  /// on focus, so the hint invites a first OK to preview.
  final bool deliberate;
  final bool favorite;
  final VoidCallback onToggleFavorite;

  /// Opens catch-up; null when the channel has no archive.
  final VoidCallback? onCatchup;

  const _LivePreviewPanel({
    required this.channel,
    required this.now,
    required this.next,
    required this.previewVideo,
    required this.previewActive,
    required this.previewLoading,
    required this.previewError,
    required this.deliberate,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onCatchup,
  });

  String _fmt(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String? get _hint {
    if (previewActive && previewError == null) {
      return 'Press OK/Select to play fullscreen';
    }
    if (deliberate) return 'Press OK/Select to preview';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final current = now;
    final upcoming = next;
    double? progress;
    if (current != null) {
      final total = current.stop.difference(current.start).inSeconds;
      final elapsed = DateTime.now().difference(current.start).inSeconds;
      progress = total <= 0 ? null : (elapsed / total).clamp(0.0, 1.0);
    }
    return Container(
      height: 190,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.tile),
        gradient: const LinearGradient(
          colors: [Color(0xFF101B2B), Color(0xFF0A111B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: AppColors.line),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 182;
          final titleSize = compact ? 20.0 : 24.0;
          final infoSize = compact ? 14.0 : 16.0;
          final previewWidth = compact ? 220.0 : 250.0;
          return Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: previewWidth,
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (previewActive &&
                            !previewLoading &&
                            previewError == null)
                          Focus(
                            canRequestFocus: false,
                            skipTraversal: true,
                            descendantsAreFocusable: false,
                            child: IgnorePointer(child: previewVideo),
                          )
                        else if (channel.logo != null &&
                            channel.logo!.isNotEmpty)
                          Image.network(
                            channel.logo!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.live_tv_rounded,
                              color: AppColors.textLo,
                              size: 42,
                            ),
                          )
                        else
                          const Icon(
                            Icons.live_tv_rounded,
                            color: AppColors.textLo,
                            size: 42,
                          ),
                        if (previewLoading)
                          Container(
                            color: Colors.black.withValues(alpha: 0.45),
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        if (previewError != null)
                          Container(
                            color: Colors.black.withValues(alpha: 0.62),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(10),
                            child: const Text(
                              'Preview unavailable',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textLo,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (previewActive && !previewLoading)
                          Align(
                            alignment: Alignment.bottomLeft,
                            child: Container(
                              margin: const EdgeInsets.all(8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'Preview',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textHi,
                                fontSize: titleSize,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (onCatchup != null)
                            _CatchupButton(onPressed: onCatchup!),
                          _FavoriteButton(
                            favorite: favorite,
                            onPressed: onToggleFavorite,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (current != null)
                        Text(
                          '${_fmt(current.start)} - ${_fmt(current.stop)} · ${current.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textHi,
                            fontSize: infoSize,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else
                        const Text(
                          'No programme information',
                          style: TextStyle(
                            color: AppColors.textLo,
                            fontSize: 14,
                          ),
                        ),
                      if (progress != null) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: AppColors.line,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.accent,
                            ),
                          ),
                        ),
                      ],
                      if (!compact &&
                          current?.description != null &&
                          current!.description!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          current.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (!compact && !previewLoading && _hint != null) ...[
                        Text(
                          _hint!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      if (upcoming != null)
                        Text(
                          'Next · ${_fmt(upcoming.start)} - ${_fmt(upcoming.stop)} · ${upcoming.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Focusable star toggle used in the per-item surfaces (live preview panel,
/// phone preview sheet, media details sheet). On TV it's reached by D-pad (e.g.
/// Up from the top channel into the preview panel); OK/Enter toggles it.
class _FavoriteButton extends StatelessWidget {
  final bool favorite;
  final VoidCallback onPressed;

  const _FavoriteButton({required this.favorite, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
      icon: Icon(
        favorite ? Icons.star_rounded : Icons.star_outline_rounded,
        color: favorite ? AppColors.accent : AppColors.textLo,
      ),
      onPressed: onPressed,
    );
  }
}

/// Non-interactive favorited marker for list/grid tiles (no focus stop).
class _FavoriteBadge extends StatelessWidget {
  final double size;
  const _FavoriteBadge({this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.star_rounded, size: size, color: AppColors.accent);
  }
}

/// Opens the catch-up / archive picker. Shown on live surfaces only when the
/// channel reports [Channel.hasArchive].
class _CatchupButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _CatchupButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Catch-up',
      icon: const Icon(Icons.history_rounded, color: AppColors.textLo),
      onPressed: onPressed,
    );
  }
}

/// Bottom-sheet catch-up picker: the channel's cached past programmes, grouped
/// by day (most recent first), each a D-pad-navigable row that plays the
/// archive stream. [programmes] is expected newest-first.
class _CatchupSheet extends StatelessWidget {
  final Channel channel;
  final List<Programme> programmes;
  final void Function(Programme) onPlay;

  const _CatchupSheet({
    required this.channel,
    required this.programmes,
    required this.onPlay,
  });

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _pad2(int n) => n.toString().padLeft(2, '0');
  static String _time(DateTime t) => '${_pad2(t.hour)}:${_pad2(t.minute)}';

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.history_rounded,
                    color: AppColors.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Catch-up · ${channel.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: programmes.length,
                itemBuilder: (context, i) {
                  final p = programmes[i];
                  final showHeader =
                      i == 0 || !_sameDay(programmes[i - 1].start, p.start);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showHeader)
                        Padding(
                          padding: EdgeInsets.only(
                            top: i == 0 ? 4 : 14,
                            bottom: 4,
                            left: 4,
                          ),
                          child: Text(
                            _dayLabel(p.start),
                            style: const TextStyle(
                              color: AppColors.textLo,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      FocusableCard(
                        autofocus: i == 0,
                        debugLabel: 'catchup.$i',
                        onTap: () => onPlay(p),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 96,
                                child: Text(
                                  '${_time(p.start)}–${_time(p.stop)}',
                                  style: const TextStyle(
                                    color: AppColors.textLo,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  p.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textHi,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.play_arrow_rounded,
                                color: AppColors.textLo,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone-only bottom sheet: a compact, audible live preview with a Play button.
/// Reuses the screen's single preview player/controller.
class _PhonePreviewSheet extends StatefulWidget {
  final LivePreviewController preview;
  final Channel channel;
  final Programme? now;
  final Programme? next;
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onPlay;

  /// Opens catch-up; null when the channel has no archive.
  final VoidCallback? onCatchup;

  const _PhonePreviewSheet({
    required this.preview,
    required this.channel,
    required this.now,
    required this.next,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onPlay,
    required this.onCatchup,
  });

  @override
  State<_PhonePreviewSheet> createState() => _PhonePreviewSheetState();
}

class _PhonePreviewSheetState extends State<_PhonePreviewSheet> {
  bool _buffering = false;
  late bool _favorite = widget.favorite;
  StreamSubscription<bool>? _bufferingSub;

  @override
  void initState() {
    super.initState();
    widget.preview.addListener(_onPreviewChanged);
    _onPreviewChanged();
  }

  /// The media_kit player exists only on the fallback path and is created
  /// lazily mid-flight, so its buffering stream is subscribed to on demand —
  /// the native path has no equivalent signal (the resolve/open `loading`
  /// state covers the visible gap there).
  void _onPreviewChanged() {
    final preview = widget.preview;
    if (!preview.nativeActive &&
        preview.hasEmbeddedPlayer &&
        _bufferingSub == null) {
      _buffering = preview.player.state.buffering;
      _bufferingSub = preview.player.stream.buffering.listen((b) {
        if (mounted) setState(() => _buffering = b);
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.preview.removeListener(_onPreviewChanged);
    _bufferingSub?.cancel();
    super.dispose();
  }

  String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final current = widget.now;
    final upcoming = widget.next;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Colors.black),
                    // Only once loaded: building PreviewVideo earlier would spin
                    // up the media_kit texture while the native path is still
                    // deciding whether it's needed at all.
                    if (widget.preview.channelId == widget.channel.id &&
                        widget.preview.stream != null &&
                        widget.preview.error == null)
                      PreviewVideo(preview: widget.preview),
                    if (widget.preview.loading || _buffering)
                      const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (widget.onCatchup != null)
                  _CatchupButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onCatchup!();
                    },
                  ),
                _FavoriteButton(
                  favorite: _favorite,
                  onPressed: () {
                    setState(() => _favorite = !_favorite);
                    widget.onToggleFavorite();
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (current != null)
              Text(
                '${_fmt(current.start)} - ${_fmt(current.stop)} · ${current.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textHi, fontSize: 14),
              )
            else
              const Text(
                'No programme information',
                style: TextStyle(color: AppColors.textLo, fontSize: 14),
              ),
            if (upcoming != null) ...[
              const SizedBox(height: 4),
              Text(
                'Next · ${_fmt(upcoming.start)} - ${_fmt(upcoming.stop)} · ${upcoming.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textLo, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play fullscreen'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final Programme? now;
  final Programme? next;
  final bool favorite;
  final bool enabled;
  final bool autofocus;
  final bool selected;
  final FocusNode? focusNode;
  final String? debugLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onMoveLeftToCategory;
  final VoidCallback onMoveDown;

  const _ChannelTile({
    required this.channel,
    required this.now,
    required this.next,
    required this.favorite,
    required this.enabled,
    required this.autofocus,
    required this.selected,
    this.focusNode,
    this.debugLabel,
    required this.onTap,
    this.onLongPress,
    required this.onMoveLeftToCategory,
    required this.onMoveDown,
  });

  static String _formatProgrammeTime(DateTime time) {
    final hours = time.hour.toString().padLeft(2, '0');
    final minutes = time.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  @override
  Widget build(BuildContext context) {
    final current = now;
    final upcoming = next;
    double? progress;
    if (current != null) {
      final total = current.stop.difference(current.start).inSeconds;
      final elapsed = DateTime.now().difference(current.start).inSeconds;
      progress = total <= 0 ? null : (elapsed / total).clamp(0.0, 1.0);
    }

    return FocusableCard(
      autofocus: autofocus,
      focusNode: focusNode,
      debugLabel: debugLabel ?? 'live.channel.${channel.id}',
      scrollOnFocus: true,
      onKeyEvent: (node, event) {
        final isLeft = event.logicalKey == LogicalKeyboardKey.arrowLeft;
        final isDown = event.logicalKey == LogicalKeyboardKey.arrowDown;
        if (!isLeft && !isDown) return KeyEventResult.ignored;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.handled;
        }
        if (isLeft) {
          onMoveLeftToCategory();
          return KeyEventResult.handled;
        }
        onMoveDown();
        return KeyEventResult.handled;
      },
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Logo(channel: channel),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                    Text(
                      'Live · ${_formatProgrammeTime(current.start)} – ${_formatProgrammeTime(current.stop)} · ${current.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: AppColors.line,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.accent,
                        ),
                      ),
                    ),
                    if (upcoming != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Next · ${_formatProgrammeTime(upcoming.start)} – ${_formatProgrammeTime(upcoming.stop)} · ${upcoming.title}',
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
            if (favorite) ...[const SizedBox(width: 8), const _FavoriteBadge()],
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.play_circle_fill_rounded
                  : Icons.play_arrow_rounded,
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
        onKeyEvent: (_, event) => event is KeyRepeatEvent
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
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
    );
  }
}

class _MediaListTile extends StatelessWidget {
  final MediaItem item;
  final bool favorite;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _MediaListTile({
    required this.item,
    required this.favorite,
    required this.autofocus,
    this.focusNode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      focusNode: focusNode,
      debugLabel: 'media.item.${item.id}',
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
            if (favorite) ...[const SizedBox(width: 8), const _FavoriteBadge()],
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
  final bool favorite;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _MediaGridTile({
    required this.item,
    required this.favorite,
    required this.autofocus,
    this.focusNode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      focusNode: focusNode,
      debugLabel: 'media.item.${item.id}',
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
                          child: _RatingBadge(
                            rating: item.rating,
                            compact: true,
                          ),
                        ),
                      ),
                    if (favorite)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: AppColors.ink.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const _FavoriteBadge(size: 16),
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
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onPlay;
  final ValueChanged<MediaItem>? onChanged;

  const _MediaDetailsSheet({
    required this.repo,
    required this.item,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onPlay,
    this.onChanged,
  });

  @override
  State<_MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends State<_MediaDetailsSheet> {
  late MediaItem _item = widget.item;
  late bool _favorite = widget.favorite;
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    _FavoriteButton(
                      favorite: _favorite,
                      onPressed: () {
                        setState(() => _favorite = !_favorite);
                        widget.onToggleFavorite();
                      },
                    ),
                  ],
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
