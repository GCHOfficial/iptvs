import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:media_kit/media_kit.dart';

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/net.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/routed_focus_node.dart';
import '../player/player_screen.dart';
import 'channel_list_chrome.dart';
import 'diagnostics_screen.dart';
import 'epg_grid_screen.dart';
import 'favorites_controller.dart';
import 'live_controller.dart';
import 'live_focus_coordinator.dart';
import 'live_preview_controller.dart';
import 'live_tab_view.dart';
import 'media_tab_controller.dart';
import 'media_tab_view.dart';

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

class _ChannelListScreenState extends State<ChannelListScreen>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();

  ContentKind _tab = ContentKind.live;
  // Live channel/category/EPG data + load lifecycle live in a controller; the
  // screen keeps the live focus/D-pad state and preview player (see below).
  late LiveController _live;
  // Movies/series browsing state + async ops live in a controller per kind;
  // both persist for the screen's lifetime so state survives tab switches.
  late Map<ContentKind, MediaTabController> _mediaControllers;
  MediaTabController _media(ContentKind kind) => _mediaControllers[kind]!;
  // Favorited item ids per content kind (live channels / movies / series) live
  // in a controller; the "last favorite removed → fall back to All" handling
  // stays here (it's tied to _categoryId / the media controllers).
  late FavoritesController _favorites;
  String? _categoryId;
  String _query = '';

  bool _resolving = false;
  Timer? _searchTimer;
  // One controller for whichever list/grid is mounted (only one exists per tab),
  // so a tab/category change can jump it back to the top.
  final ScrollController _scrollController = ScrollController();
  // The live category sidebar's controller, so the focus coordinator can
  // jump-scroll an off-screen category into build range before focusing it
  // (a bare requestFocus on an unbuilt node silently no-ops).
  final ScrollController _categoryScrollController = ScrollController();
  // Live D-pad focus machinery (nodes, pane routing, down-hold lock, resume
  // bookkeeping) lives in the coordinator; see live_focus_coordinator.dart.
  late final LiveFocusCoordinator _focus;
  // One stable focus node per content-kind tab chip, so a Back-key peel can jump
  // focus straight to the current tab (and detect when focus is already there)
  // instead of arrowing up item by item through a long list — see
  // _handleRootBack. Deliberately plain FocusNodes, not a FocusScope: the whole
  // screen relies on a single flat scope with FocusTraversalGroups so arrow-down
  // flows tabs → toolbar → list, and a nested scope would trap that traversal.
  final Map<ContentKind, FocusNode> _tabFocusNodes = {
    ContentKind.live: RoutedFocusNode('content.tab.live'),
    ContentKind.movie: RoutedFocusNode('content.tab.movie'),
    ContentKind.series: RoutedFocusNode('content.tab.series'),
  };
  String? _lastPlayedLiveChannelId;
  // The channel played before the current one — the zap ("last channel")
  // target. Only meaningful within this screen's lifetime.
  String? _previousPlayedLiveChannelId;

  void _notePlayedChannel(String id) {
    if (_lastPlayedLiveChannelId != null && _lastPlayedLiveChannelId != id) {
      _previousPlayedLiveChannelId = _lastPlayedLiveChannelId;
    }
    _lastPlayedLiveChannelId = id;
  }

  // Live preview player + its state live in a controller; the screen keeps the
  // focus-driven preview trigger (below), fullscreen playback, and the phone
  // preview sheet, which drive it.
  late LivePreviewController _preview;
  // Focus-debounce for desktop auto-preview (stays here — it's focus timing).
  Timer? _previewTimer;

  // Controller notifications rebuild only the subtrees that read them (via
  // ListenableBuilder in build) — never the whole screen. [_dataListenable] is
  // everything except the preview; the preview's frequent loading/error ticks
  // during channel surfing only rebuild the body.
  late Listenable _dataListenable;
  late Listenable _bodyListenable;

  @override
  void initState() {
    super.initState();
    _createRepositoryControllers();
    _focus = LiveFocusCoordinator(
      scrollController: _scrollController,
      categoryScrollController: _categoryScrollController,
      visibleChannels: () => _visible,
      orderedCategoryIds: () => [
        null,
        for (final category in _liveCategoriesForUi) category.id,
      ],
      channelRowExtent: _liveChannelRowExtent,
      categoryRowExtent: _liveCategoryRowExtent,
      isWide: _isWide,
      isMounted: () => mounted,
      onChannelSelectionChanged: _onChannelSelectionChanged,
      onCategoryActivated: _selectCategory,
      onPlayChannel: _play,
      onToggleFavorite: (channel) =>
          unawaited(_toggleFavorite(ContentKind.live, channel.id)),
      onFocusTabs: _focusTabs,
    );
    _bodyListenable = Listenable.merge([_dataListenable, _preview, _focus]);
    WidgetsBinding.instance.addObserver(this);
    _loadLive();
    _live.startEpgRefresh();
  }

  void _createRepositoryControllers() {
    _live = LiveController(repo: widget.repo);
    _preview = LivePreviewController(repo: widget.repo, onError: _showSnack);
    _favorites = FavoritesController(repo: widget.repo);
    _mediaControllers = {
      for (final kind in const [ContentKind.movie, ContentKind.series])
        kind: MediaTabController(
          kind: kind,
          repo: widget.repo,
          onEnrichError: _showSnack,
        ),
    };
    _dataListenable = Listenable.merge([
      _live,
      _favorites,
      ..._mediaControllers.values,
    ]);
  }

  void _disposeRepositoryControllers() {
    _live.dispose();
    _preview.dispose();
    _favorites.dispose();
    for (final controller in _mediaControllers.values) {
      controller.dispose();
    }
  }

  /// The app going to the background (home button, back-exit, launcher) must
  /// not leave the preview engine running — its audio would keep playing
  /// behind the launcher (the shared native engine outlives the Flutter UI).
  /// Skipped while a fullscreen playback handoff is in flight ([_resolving]
  /// spans the whole player push): launching the native player also
  /// backgrounds this screen's lifecycle, and an adopted preview engine must
  /// keep playing through it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused) return;
    if (_resolving) return;
    if (_preview.channelId != null) {
      unawaited(_preview.stop(clearSelection: true));
    }
  }

  /// Load live channels (via the controller) plus the focus-node prune and
  /// favorites, which stay in the screen.
  Future<void> _loadLive({bool forceRefresh = false}) async {
    await _live.load(forceRefresh: forceRefresh);
    if (!mounted) return;
    _focus.clampSelection();
    await _loadFavorites(ContentKind.live);
  }

  @override
  void didUpdateWidget(covariant ChannelListScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.repo, widget.repo)) {
      _previewTimer?.cancel();
      _previewTimer = null;
      _disposeRepositoryControllers();
      _createRepositoryControllers();
      _bodyListenable = Listenable.merge([_dataListenable, _preview, _focus]);
      _visibleKey = null;
      _visibleCache = null;
      _focus.resetChannelSelection();
      _loadLive();
      _live.startEpgRefresh();
      if (_tab != ContentKind.live) {
        _loadMediaTab(_tab);
      }
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _disposeRepositoryControllers();
    _searchTimer?.cancel();
    _previewTimer?.cancel();
    _focus.dispose();
    for (final node in _tabFocusNodes.values) {
      node.dispose();
    }
    _searchController.dispose();
    _scrollController.dispose();
    _categoryScrollController.dispose();
    super.dispose();
  }

  /// Whether previews are *deliberate* on this platform. On Android (phone + TV)
  /// they are: a preview starts only on an explicit OK press (TV split-pane) or
  /// long-press (phone), carries audio, and — once running — stays **locked** to
  /// that channel. D-pad focus moving around never starts, stops, or retargets a
  /// preview; only pressing OK on a different channel switches it. On desktop
  /// previews are *not* deliberate: they auto-start muted, mouse-hover style,
  /// after a short focus debounce (the branch at the end of
  /// [_onChannelSelectionChanged]).
  bool get _deliberatePreview => Platform.isAndroid;

  void _onChannelSelectionChanged(Channel channel, bool hasFocus) {
    if (!hasFocus) {
      if (!_deliberatePreview && _preview.channelId == channel.id) {
        _previewTimer?.cancel();
      }
      return;
    }

    if (_deliberatePreview) {
      // Android (TV/phone): the preview requires an explicit OK/Enter press to
      // start and to switch channels. Focus alone never starts, stops, or
      // retargets a preview — it stays locked to the channel it was started on
      // until the user presses OK on a different one.
      return;
    }

    _previewTimer?.cancel();

    // Debounce for 500ms (desktop mouse/keyboard).
    _previewTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final isWide = MediaQuery.of(context).size.width >= kWideLayoutMinWidth;
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
      // Only the visible top route may own the D-pad. When playback was
      // launched from a *pushed* route (e.g. the EPG grid), that route is
      // still on top after the player pops — requesting focus on the covered
      // channel list here would steal primaryFocus cross-route (FocusManager
      // has no notion of routes) and leave the visible screen's D-pad dead.
      // Flutter's own route focus restoration re-focuses that route's node.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      if (_tab == ContentKind.live) {
        _focus.restoreSelectionToChannel(_lastPlayedLiveChannelId);
        return;
      }
      if (_tab == ContentKind.movie || _tab == ContentKind.series) {
        if (_visibleMedia(_tab).isEmpty) return;
        _media(_tab).firstFocusNode.requestFocus();
      }
    });
  }

  /// Modal routes normally restore focus, but that restoration is timing
  /// dependent when a sheet rebuilds the lazy list behind it. Keep an explicit
  /// handle to the browsing target and restore it after ordinary dismissal.
  /// A sheet action that immediately opens playback is excluded; the player
  /// return path owns focus in that case.
  void _restoreFocusAfterModal(FocusNode? previousFocus) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resolving) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      if (previousFocus?.context != null && previousFocus!.canRequestFocus) {
        previousFocus.requestFocus();
        return;
      }
      if (_tab == ContentKind.live) {
        _focus.focusChannels();
      } else if (_visibleMedia(_tab).isNotEmpty) {
        _media(_tab).firstFocusNode.requestFocus();
      } else {
        _focusTabs();
      }
    });
  }

  void _setQuery(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    if (_tab == ContentKind.live) {
      // A new result set starts at the top — otherwise the cursor would keep an
      // index that now points at an unrelated channel.
      _focus.resetChannelSelection();
      _focus.clampSelection();
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

  /// Set an absolute favorite state (used by the fullscreen player's overlay
  /// star, which reports the desired final state rather than a toggle). Reuses
  /// [_toggleFavorite] so the empty-Favorites-view fallback still applies.
  Future<void> _setLiveFavorite(String id, bool favorite) async {
    if (_isFavorite(ContentKind.live, id) == favorite) return;
    await _toggleFavorite(ContentKind.live, id);
  }

  Future<void> _toggleFavorite(ContentKind kind, String id) async {
    final nowEmpty = await _favorites.toggle(kind, id);
    if (!mounted) return;
    if (kind == ContentKind.live) {
      _focus.clampSelection();
    }
    if (!nowEmpty) return;
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

  // Memoized filtered channel list. [_visible] is read from the build path
  // *and* every D-pad key event (move-down, focus restore, prune), so on a
  // large playlist an unmemoized O(N) filter would run several times per key
  // repeat. The key fields compare by identity (List/Set/SourceConfig don't
  // override ==): the controllers reassign fresh collections on change, and
  // the config is a fresh object per reload.
  List<Channel>? _visibleCache;
  (String?, String, List<Channel>, Set<String>, SourceConfig)? _visibleKey;

  List<Channel> get _visible {
    final key = (
      _categoryId,
      _query.trim().toLowerCase(),
      _live.channels,
      _favoriteIds(ContentKind.live),
      widget.config,
    );
    if (_visibleKey == key) return _visibleCache!;
    _visibleKey = key;
    return _visibleCache = _computeVisible();
  }

  List<Channel> _computeVisible() {
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

  Future<void> _play(Channel channel) async {
    if (_resolving) return;
    final isWide = MediaQuery.of(context).size.width >= kWideLayoutMinWidth;
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
        _notePlayedChannel(channel.id);
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
              title: channel.name,
              stream: stream,
              sourceName: widget.repo.source.name,
              epgNow: _live.now[channel.id],
              epgNext: _live.next[channel.id],
              favoriteInitial: _isFavorite(ContentKind.live, channel.id),
              onSetFavorite: (fav) => _setLiveFavorite(channel.id, fav),
            ),
          ),
        );
        _restoreListFocusAfterPlayback();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not play: ${redactText('$e')}')),
          );
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
      _notePlayedChannel(channel.id);
      // An adopted engine keeps playing straight through the handoff (that's
      // the seamless part). Any *non*-seamless fullscreen opens its own playback
      // pipeline, so a preview left running would double the audio behind it.
      final seamless = adoptPreview && (adoptNative || !Platform.isAndroid);
      final previewPlaying =
          _preview.channelId != null || _preview.nativeActive;
      final sameChannelPreview = _preview.channelId == channel.id;
      // Same channel (a media_kit-fallback preview going native-fullscreen):
      // pause and resume on return. A *different* channel (the "last channel"
      // zap / EPG-grid play, which resolve fresh with reusePreview: false and so
      // never adopt the engine previewing whatever else): stop it outright — not
      // just pause — so we neither double the audio nor hold a second provider
      // connection open (single-connection accounts would refuse the new stream).
      final pausedPreview = !seamless && previewPlaying && sameChannelPreview;
      final stoppedPreview = !seamless && previewPlaying && !sameChannelPreview;
      if (stoppedPreview) {
        await _preview.stop();
      } else if (pausedPreview) {
        await _preview.pause();
      }
      // Context-independent on purpose — nothing in the player derives from
      // the route builder's element.
      Widget buildPlayer() => PlayerScreen(
        title: channel.name,
        stream: stream,
        sourceName: widget.repo.source.name,
        epgNow: _live.now[channel.id],
        epgNext: _live.next[channel.id],
        existingPlayer: (adoptPreview && !adoptNative) ? _preview.player : null,
        existingController: (adoptPreview && !adoptNative)
            ? _preview.controller
            : null,
        adoptNativePreview: adoptNative,
        favoriteInitial: _isFavorite(ContentKind.live, channel.id),
        onSetFavorite: (fav) => _setLiveFavorite(channel.id, fav),
      );
      // The adopted native handoff pushes a *transparent, non-animated* route:
      // PlayerScreen stays see-through while the native Activity launches, so
      // this screen (with the preview's frozen last frame) remains visible
      // until the Activity's first frame — no black flash (see
      // PlayerScreen._transparentHandoff).
      final route = adoptNative
          ? PageRouteBuilder<bool>(
              opaque: false,
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (_, _, _) => buildPlayer(),
            )
          : MaterialPageRoute<bool>(builder: (_) => buildPlayer());
      final hotSwapped = await navigator.push<bool>(route) ?? false;
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
      } else if (pausedPreview && _preview.stream != null) {
        // A same-channel non-adopted fullscreen paused the preview above; resume
        // it now that we're back (matches the catch-up path). A stopped preview
        // (different channel) is intentionally not restarted.
        await _preview.play();
      }
      _restoreListFocusAfterPlayback();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not play: ${redactText('$e')}')),
      );
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Resolve [channel] and play it fullscreen directly, bypassing the preview
  /// flow (used by zap and the EPG grid).
  Future<void> _playChannelFullscreen(Channel channel) async {
    if (_resolving) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stream = await widget.repo.resolve(channel);
      if (!mounted) return;
      await _openLivePlayer(channel, stream, reusePreview: false);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not play: ${redactText('$e')}')),
      );
    }
  }

  /// Zap straight back to the previously played live channel — classic
  /// "last channel" recall.
  Future<void> _zapToPreviousChannel() async {
    final id = _previousPlayedLiveChannelId;
    final channel = id == null ? null : _findChannelById(id);
    if (channel != null) await _playChannelFullscreen(channel);
  }

  /// Open the TV-guide grid for the currently visible channels.
  void _openEpgGrid() {
    unawaited(_preview.stop());
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EpgGridScreen(
          repo: widget.repo,
          channels: _visible,
          onPlayChannel: (channel) =>
              unawaited(_playChannelFullscreen(channel)),
          onPlayArchive: (channel, programme) =>
              unawaited(_playCatchup(channel, programme)),
        ),
      ),
    );
  }

  /// Phone-only: open a compact, audible preview of [channel] in a bottom
  /// sheet (tap on a tile still goes straight to fullscreen). Reuses the single
  /// preview player; the sheet's Play button hands off to fullscreen.
  Future<void> _showPreviewSheet(Channel channel) async {
    if (_resolving) return;
    final previousFocus = FocusManager.instance.primaryFocus;
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
      builder: (sheetContext) => PhonePreviewSheet(
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
    _restoreFocusAfterModal(previousFocus);
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
    final previousFocus = FocusManager.instance.primaryFocus;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => CatchupSheet(
        channel: channel,
        // Most recent first.
        programmes: programmes.reversed.toList(),
        onPlay: (programme) {
          Navigator.of(sheetContext).pop();
          unawaited(_playCatchup(channel, programme));
        },
      ),
    );
    _restoreFocusAfterModal(previousFocus);
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
      _notePlayedChannel(channel.id);
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
        SnackBar(content: Text('Could not play catch-up: ${redactText('$e')}')),
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
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open: ${redactText('$e')}')),
      );
    }
  }

  void _replaceMediaItem(MediaItem replacement) {
    _media(replacement.kind).replaceItems({replacement.id: replacement});
  }

  /// Play a movie/episode fullscreen, auto-resuming from any saved position
  /// unless [fromStart]. The player persists the new position (periodically,
  /// on exit, and via the Android native player's close payload).
  Future<void> _playMedia(MediaItem item, {bool fromStart = false}) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      DiagnosticsLog.instance.add(
        'library',
        'resolve ${item.kind.name} source=${widget.repo.source.name} title=${item.title} id=${item.id}',
      );
      final resume = fromStart
          ? null
          : await widget.repo.db.readPlaybackPosition(
              widget.repo.source.id,
              item.kind,
              item.id,
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
            playback: PlaybackContext(
              db: widget.repo.db,
              sourceId: widget.repo.source.id,
              kind: item.kind,
              itemId: item.id,
              resumeFrom: resume?.position,
            ),
          ),
        ),
      );
      // The rail reflects the position just saved by the player.
      unawaited(_media(ContentKind.movie).loadContinueWatching());
      unawaited(_media(ContentKind.series).loadContinueWatching());
      _restoreListFocusAfterPlayback();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not play: ${redactText('$e')}')),
      );
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _showMediaDetails(MediaItem item) async {
    // Saved resume point (if any) drives the sheet's Resume / From-start pair.
    final resume =
        item.kind == ContentKind.movie || item.kind == ContentKind.episode
        ? await widget.repo.db.readPlaybackPosition(
            widget.repo.source.id,
            item.kind,
            item.id,
          )
        : null;
    if (!mounted) return;
    final previousFocus = FocusManager.instance.primaryFocus;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.panel,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (context) => MediaDetailsSheet(
        repo: widget.repo,
        item: item,
        favorite: _isFavorite(item.kind, item.id),
        onToggleFavorite: () => _toggleFavorite(item.kind, item.id),
        onChanged: _replaceMediaItem,
        resume: resume,
        // Episodes picked in the series browser play through the same path as
        // movies, so "Continue watching" reloads on return (the sheet used to
        // push its own player, which skipped that reload — the series rail then
        // went stale until a manual refresh).
        onPlayEpisode: _playMedia,
        onPlay:
            item.kind == ContentKind.movie || item.kind == ContentKind.episode
            ? () {
                Navigator.of(context).pop();
                _playMedia(item);
              }
            : null,
        onPlayFromStart: resume != null
            ? () {
                Navigator.of(context).pop();
                _playMedia(item, fromStart: true);
              }
            : null,
      ),
    );
    _restoreFocusAfterModal(previousFocus);
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

  /// The two-column (TV/desktop) layout, which is the only one with a category
  /// sidebar and preview panel. The coordinator routes the D-pad off this.
  bool _isWide() =>
      mounted && MediaQuery.of(context).size.width >= kWideLayoutMinWidth;

  LiveLayoutMetrics get _liveLayoutMetrics => LiveLayoutMetrics.forSize(
    mounted ? MediaQuery.sizeOf(context) : const Size(1280, 720),
    compactWideLayout: defaultTargetPlatform == TargetPlatform.android,
  );

  double _liveChannelRowExtent() =>
      _liveLayoutMetrics.channelRowExtent(_live.now.isNotEmpty);

  double _liveCategoryRowExtent() => _liveLayoutMetrics.categoryRowExtent;

  /// The content tabs — the top of the Back ladder and the D-pad's ceiling.
  void _focusTabs() => _tabFocusNodes[_tab]?.requestFocus();

  /// Apply a live category filter: OK on a sidebar row, a tap, or the phone
  /// dropdown. The channel cursor restarts at the top of the new list. The
  /// focus coordinator moves OK activation into a non-empty channel list;
  /// pointer/dropdown callers retain their natural focus behavior.
  void _selectCategory(String? categoryId) {
    setState(() => _categoryId = categoryId);
    _focus.syncCategorySelection(categoryId);
    _focus.resetChannelSelection();
    _focus.clampSelection();
    _scrollToTop();
  }

  /// Double-Back exit confirmation: the first Back at the top of the ladder
  /// arms this and shows "Press Back again to exit"; a second Back inside the
  /// window actually exits.
  DateTime? _exitArmedAt;
  static const _exitConfirmWindow = Duration(seconds: 2);

  /// Peels exactly one rung per Back press. The live ladder, in order:
  ///
  ///   channel list (cursor not on the first row) → **first channel**
  ///     → **categories** (wide) → **first category** ("All channels")
  ///     → **search box** → **content tabs** → exit (double-Back).
  ///
  /// Because the live lists are a selection model, each rung is a plain check on
  /// the coordinator's region + selected index — no focus-label archaeology.
  /// Media: deep grid → top of the grid → tabs → exit. The app only ever exits
  /// from the tabs, and only on a second Back within [_exitConfirmWindow].
  void _handleRootBack(bool didPop, Object? result) {
    if (didPop) return;
    final label = focusRouteKey(FocusManager.instance.primaryFocus);
    // Flutter invokes every registered PopScope when a pop is blocked, so defer
    // entirely to TvTextField's own PopScope while its inner field is actually
    // being edited — it already exits edit mode on Back.
    if (label == 'TvTextField.field') return;

    final wideLive = _tab == ContentKind.live && _isWide();

    if (_tab == ContentKind.live) {
      switch (_focus.region) {
        case LiveFocusRegion.channels:
          // Rung 0: with the intra-row cursor on the favorite star, Back
          // mirrors Left — it peels the cursor back onto the row body.
          if (_focus.channelColumn == ChannelRowColumn.favorite) {
            _focus.resetChannelColumn();
            return;
          }
          // Rung 1: climbing out of the list starts from its top.
          if (!_focus.onFirstChannel) {
            _focus.selectChannel(0);
            return;
          }
          // Rung 2: out of the list into the sidebar (wide) — phones have no
          // sidebar, so they peel straight to the search box.
          if (wideLive) {
            _focus.focusCategories();
          } else {
            _focus.focusSearch();
          }
          return;
        case LiveFocusRegion.previewControls:
          // The preview controls sit between the search box and the list.
          if (wideLive) {
            _focus.focusCategories();
          } else {
            _focus.focusSearch();
          }
          return;
        case LiveFocusRegion.categories:
          // Rung 3: move the *highlight* to "All channels" — this deliberately
          // does not change the active filter (OK does that).
          if (!_focus.onFirstCategory) {
            _focus.selectCategory(0);
            return;
          }
          // Rung 4: out of the sidebar into the search box.
          _focus.focusSearch();
          return;
        case LiveFocusRegion.search:
          // Rung 5: search → the section tabs.
          _focusTabs();
          return;
        case LiveFocusRegion.none:
          break; // fall through to the shared handling below
      }
    }

    // Movies/series grid — same top-of-list rung as the channel list, then
    // the tabs.
    if (label.startsWith('media.')) {
      final controller = _media(_tab);
      final scroll = controller.scrollController;
      if (scroll.hasClients &&
          scroll.position.pixels > scroll.position.viewportDimension) {
        scroll.jumpTo(0);
        // The first tile may not be built until the frame after the jump —
        // focus post-frame with one retry (same pattern as the coordinator's
        // focusFirstChannel).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (controller.firstFocusNode.context != null) {
            controller.firstFocusNode.requestFocus();
            return;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) controller.firstFocusNode.requestFocus();
          });
        });
      } else {
        _focusTabs();
      }
      return;
    }
    // The media tabs' own search cell peels to the tabs (live's search box is
    // handled by the region ladder above).
    if (label == 'TvTextField.cell') {
      _focusTabs();
      return;
    }
    // The search field's clear (×) button is its own focusable stop beside the
    // cell (see TvTextField); Back peels it to the search cell (live) / the
    // tabs (media) instead of falling through to the exit prompt.
    if (label == 'TvTextField.clear') {
      if (_tab == ContentKind.live) {
        _focus.focusSearch();
      } else {
        _focusTabs();
      }
      return;
    }
    // Un-routed focus (route key '') is the app **chrome** — the AppBar actions
    // and the toolbar's buttons are plain IconButtons, while every *content*
    // focusable on this screen carries a route key. The chrome sits above the
    // ladder, so Back from it goes straight to the exit prompt rather than
    // diving back down into the sections and making the user climb out again.
    //
    // The one exception is a bare scope / nothing actually focused (a transient
    // state, e.g. right after a dialog is dismissed): that isn't somewhere the
    // user can *be*, so recover to the tabs instead of offering to exit.
    final focusedNode = FocusManager.instance.primaryFocus;
    if (label.isEmpty &&
        (focusedNode == null || focusedNode is FocusScopeNode)) {
      _focusTabs();
      return;
    }
    // Otherwise fall through: the content tabs and the chrome are both the top
    // of the ladder — exit, behind a double-Back confirmation.
    // The content tabs, or anything else routed but unhandled: nothing left to
    // peel — exit, behind a double-Back confirmation so mashing Back up the
    // ladder can't overshoot into the launcher.
    // This screen is HomeShell's root content (not a pushed route), so there
    // may be nothing to pop to — fall back to the platform default (exit).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    final now = DateTime.now();
    final armed =
        _exitArmedAt != null &&
        now.difference(_exitArmedAt!) <= _exitConfirmWindow;
    if (!armed) {
      _exitArmedAt = now;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Press Back again to exit'),
            duration: _exitConfirmWindow,
          ),
        );
      return;
    }
    // Exiting must not leave the preview engine playing behind the launcher
    // (Android's back-exit only moves the task back — the engine would keep
    // its audio running).
    if (_preview.channelId != null || _preview.nativeActive) {
      unawaited(_preview.stop(clearSelection: true));
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleRootBack,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.repo.source.name),
          leading:
              (widget.onChangeProfile != null ||
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
                  if (_tab == ContentKind.live &&
                      _previousPlayedLiveChannelId != null)
                    IconButton(
                      tooltip: 'Last channel',
                      icon: const Icon(Icons.swap_horiz_rounded),
                      onPressed: _zapToPreviousChannel,
                    ),
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
                          builder: (_) => DiagnosticsScreen(
                            database: widget.repo.db,
                            sourceId: widget.repo.source.id,
                            onReingest: () => _loadLive(forceRefresh: true),
                          ),
                        ),
                      );
                    },
                  ),
                  ListenableBuilder(
                    listenable: _dataListenable,
                    builder: (context, _) => IconButton(
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
              ChannelContentTabs(
                value: _tab,
                onChanged: _selectTab,
                focusNodes: _tabFocusNodes,
              ),
              // Toolbar + status line read the data controllers (loading /
              // enrich / category state) but not the preview, so preview ticks
              // never rebuild them.
              ListenableBuilder(
                listenable: _dataListenable,
                builder: (context, _) => _buildToolbarAndStatus(context),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: _bodyListenable,
                  builder: (context, _) => _buildBody(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbarAndStatus(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChannelToolbar(
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
              ? _focus.searchCellFocusNode
              : null,
          onSearchCellKeyEvent: _focus.handleSearchCellKey,
          categoryControl:
              (_tab == ContentKind.live &&
                  MediaQuery.of(context).size.width >= kWideLayoutMinWidth)
              ? null
              : (_tab == ContentKind.live
                    ? ChannelCategoryDropdown(
                        categories: _liveCategoriesForUi,
                        value: _categoryId,
                        onChanged: _selectCategory,
                      )
                    : MediaCategoryDropdown(
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
          actionControl: _tab == ContentKind.live
              ? ChannelToolbarIconButton(
                  tooltip: 'TV guide',
                  busy: false,
                  icon: Icons.calendar_view_day_rounded,
                  onPressed: _openEpgGrid,
                )
              : !widget.repo.canEnrichMetadata
              ? null
              : ChannelToolbarIconButton(
                  tooltip: _media(_tab).enriching
                      ? 'Cancel metadata refresh'
                      : 'Refresh displayed metadata',
                  busy: _media(_tab).enriching,
                  icon: _media(_tab).enriching
                      ? Icons.stop_rounded
                      : Icons.auto_awesome_outlined,
                  onPressed: _media(_tab).loading || _media(_tab).searching
                      ? null
                      : _media(_tab).enriching
                      ? _media(_tab).cancelEnrich
                      : () => _media(_tab).enrichVisible(_visibleMedia(_tab)),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _statusText(_tab == ContentKind.live ? _visible.length : 0),
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final visible = _tab == ContentKind.live ? _visible : const <Channel>[];
    return _tab == ContentKind.live
        ? _withDigitEntryChip(_buildLiveBody(visible))
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
            continueWatching: _media(_tab).continueWatching,
            onResume: _playMedia,
            onRemoveContinueWatching: (entry) =>
                _media(_tab).removeFromContinueWatching(entry),
          );
  }

  /// Overlays the digit-entry "Ch 123" chip while the user is typing a
  /// channel number on the remote (see [LiveFocusCoordinator.digitBuffer]).
  Widget _withDigitEntryChip(Widget body) {
    if (_focus.digitBuffer.isEmpty) return body;
    return Stack(
      children: [
        body,
        Positioned(
          top: 8,
          right: 16,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.panel.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(AppRadius.tile),
              border: Border.all(color: AppColors.accent, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                'Ch ${_focus.digitBuffer}',
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveBody(List<Channel> visible) {
    return LiveTabView(
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
      categoryScrollController: _categoryScrollController,
      channelsFocusNode: _focus.channelsFocusNode,
      selectedChannelIndex: _focus.selectedChannelIndex,
      onChannelsKey: _focus.handleChannelsKey,
      channelColumn: _focus.channelColumn,
      channelRowExtent: _liveChannelRowExtent(),
      categoryRowExtent: _liveCategoryRowExtent(),
      lastPlayedChannelId: _lastPlayedLiveChannelId,
      previewChannelId: _preview.channelId,
      isFavorite: (id) => _isFavorite(ContentKind.live, id),
      onToggleFavorite: (id) => _toggleFavorite(ContentKind.live, id),
      onPlayChannel: _play,
      onPreviewChannel: (channel) => unawaited(_showPreviewSheet(channel)),
      onSelectChannelIndex: (i) => _focus.selectChannel(i, reveal: false),
      onCatchup: _showCatchupSheet,
      categories: _liveCategoriesForUi,
      selectedCategoryId: _categoryId,
      categoriesFocusNode: _focus.categoriesFocusNode,
      selectedCategoryIndex: _focus.selectedCategoryIndex,
      onCategoriesKey: _focus.handleCategoriesKey,
      onCategorySelected: _selectCategory,
      onSelectCategoryIndex: (i) => _focus.selectCategory(i, reveal: false),
      previewFavoriteFocusNode: _focus.previewFavoriteFocusNode,
      previewCatchupFocusNode: _focus.previewCatchupFocusNode,
      onPreviewControlKey: _focus.handlePreviewControlKey,
      previewVideoBuilder: () => PreviewVideo(preview: _preview),
      previewLoading: _preview.loading,
      previewError: _preview.error,
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
      // When a preview is actively running (or loading), lock the panel to
      // that channel.  D-pad focus moves away without disrupting it.
      final previewActive = _preview.stream != null || _preview.loading;
      return byId(previewActive ? _preview.channelId : null) ??
          byId(_focus.selectedChannelId) ??
          byId(_preview.channelId) ??
          byId(_lastPlayedLiveChannelId) ??
          visible.first;
    }
    return byId(_preview.channelId) ??
        byId(_lastPlayedLiveChannelId) ??
        visible.first;
  }
}
