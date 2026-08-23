import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:media_kit/media_kit.dart';

import '../data/device_class.dart';
import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/net.dart';
import '../data/source_store.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/routed_focus_node.dart';
import '../player/ios_engine.dart';
import '../player/linux_native_session.dart';
import '../player/buffer_preset.dart';
import '../player/player_screen.dart';
import 'channel_list_chrome.dart';
import 'diagnostics_screen.dart';
import 'epg_grid_screen.dart';
import 'favorites_controller.dart';
import 'favorites_order.dart';
import 'global_favorites_controller.dart';
import 'legal_screen.dart';
import 'live_controller.dart';
import 'live_focus_coordinator.dart';
import 'live_preview_controller.dart';
import 'live_tab_view.dart';
import 'media_tab_controller.dart';
import 'media_tab_view.dart';

/// The ways [_ChannelListScreenState._openLivePlayer] can reconcile a running
/// live preview with a fullscreen open, decided purely from state so the
/// branching is unit-testable without a widget tree or a real platform.
/// Pinned by `test/fullscreen_handoff_test.dart`.
///
/// - [adoptNative]: Android's fullscreen Activity adopts the running shared
///   ExoPlayer engine (`SharedEngine`) — seamless, preview left playing.
/// - [adoptEmbedded]: the fullscreen [PlayerScreen] adopts the preview's
///   media_kit engine directly and keeps it playing through the handoff —
///   seamless on every non-Android platform, including Linux for **SDR streams
///   and all of X11** (the native mpv window buys nothing there). The one
///   exception is a **Wayland HDR** source (see [stopResolveFresh]).
/// - [stopResolveFresh]: a same-channel handoff where the fullscreen player is
///   about to run on a **different engine than the preview**, so there is
///   nothing to adopt. Two cases reach it:
///   * **Linux Wayland HDR** — the native mpv *process* takes over
///     (`linuxNativeLikely` is Wayland-gated and `streamLikelyHdr` is true),
///     the one case where the native window earns its cost (real HDR
///     passthrough). SDR/X11 stay [adoptEmbedded].
///   * **iOS AVPlayer** (`crossEngineFullscreen`) — the preview always runs on
///     embedded media_kit/libmpv, but an AVPlayer-routed channel goes
///     fullscreen on a presented `AVPlayerLayer` controller. AVPlayer cannot
///     adopt an mpv session.
///   Either way the preview must be *stopped* outright — pausing it would
///   leave its provider connection open (a single-connection portal then sees
///   two), and the preview's already-resolved stream carries a spent
///   single-use Stalker `play_token` — so the channel is re-resolved fresh too.
/// - [pausePreview]: a same-channel handoff that isn't adopted and doesn't
///   need [stopResolveFresh]'s connection teardown (chiefly Android falling
///   back to its embedded media_kit preview) — paused and resumed on return.
/// - [stopPreview]: a different-channel preview (last-channel zap,
///   EPG-grid play) — stopped outright so it neither doubles audio nor a
///   provider connection; not restarted on return.
/// - [none]: no preview is running that needs reconciling.
enum FullscreenHandoff {
  adoptNative,
  adoptEmbedded,
  stopResolveFresh,
  pausePreview,
  stopPreview,
  none,
}

/// Pure decision function behind [FullscreenHandoff] — see there for what
/// each outcome means and why. [linuxNativeLikely] is the Wayland-gated
/// native-worth-using predicate ([LinuxNativeSession.nativeLikelyAvailable];
/// already false off Linux and on X11). [streamLikelyHdr] is true when the
/// preview is rendering a PQ/HLG/Dolby-Vision source — the only case where the
/// native mpv window earns its non-seamless fresh-resolve cost. Together they
/// select [FullscreenHandoff.stopResolveFresh] *only* for Wayland+HDR; every
/// other Linux same-channel handoff (SDR, or X11) stays the seamless
/// [FullscreenHandoff.adoptEmbedded]. (A source that starts SDR then turns out
/// HDR still escalates later, inside `PlayerScreen._maybeEscalateLinuxNative`.)
///
/// [crossEngineFullscreen] is the iOS analogue of that pair, collapsed into one
/// flag because the caller already knows the answer with no probe: the preview
/// runs on embedded media_kit/libmpv, and `selectIosEngine` says this channel
/// goes fullscreen on **AVPlayer**. AVPlayer cannot adopt an mpv session, and a
/// merely *paused* media_kit engine still holds its provider connection —
/// provider accounts are single-connection, so two live engines break playback.
/// Hence the same stop-and-re-resolve treatment Wayland HDR gets. Defaults
/// false, so every non-iOS caller and every existing case is unaffected.
FullscreenHandoff decideFullscreenHandoff({
  required bool reusePreview,
  required bool sameChannelPreview,
  required bool previewHasStream,
  required bool isAndroid,
  required bool nativePreviewActive,
  required bool linuxNativeLikely,
  required bool previewPlaying,
  bool streamLikelyHdr = false,
  bool crossEngineFullscreen = false,
}) {
  final adoptPreview = reusePreview && sameChannelPreview && previewHasStream;
  if (adoptPreview && isAndroid && nativePreviewActive) {
    return FullscreenHandoff.adoptNative;
  }
  if (adoptPreview &&
      !isAndroid &&
      (crossEngineFullscreen || (linuxNativeLikely && streamLikelyHdr))) {
    return FullscreenHandoff.stopResolveFresh;
  }
  if (adoptPreview && !isAndroid) {
    return FullscreenHandoff.adoptEmbedded;
  }
  if (!previewPlaying) return FullscreenHandoff.none;
  if (sameChannelPreview) return FullscreenHandoff.pausePreview;
  return FullscreenHandoff.stopPreview;
}

/// What an OK/click on a channel row does on a wide (split-pane) layout, given
/// the preview's state for that same channel. Pure so the branching is
/// unit-testable; pinned by `test/fullscreen_handoff_test.dart`.
///
/// The [awaitPreviewThenOpen] rung is the one that used to be missing, and it
/// is the whole point of this function. A second OK landing while the preview's
/// own `create_link` was still in flight fell through to "start a preview" and
/// **restarted the channel**: a new resolve superseding the in-flight one (both
/// burning single-use Stalker `play_token`s) and, on Android,
/// `SharedEngine.openPreview` → `ExoPlayerEngine.load()` on the running engine —
/// a visible stream reload, after which the user still had to press OK a third
/// time to actually go fullscreen. It is an Android-TV-shaped bug: there the
/// preview is deliberate (OK starts it, see `_deliberatePreview`) and a remote
/// invites a second press while a slow portal resolves, whereas a phone bypasses
/// the preview entirely on its narrow layout and a desktop preview auto-starts
/// on hover well before the click.
enum ChannelPlayAction {
  /// This channel is previewing and resolved — go fullscreen, adopting it.
  openFullscreen,

  /// This channel's preview is still resolving. Wait for *that* resolve and
  /// then go fullscreen; never start a second one.
  awaitPreviewThenOpen,

  /// Nothing is previewing this channel (or its preview failed) — start one.
  startPreview,
}

/// Whether the live list draws EPG lines inside its rows.
///
/// **The one input the row extent and the row contents must agree on.** The
/// extent drives the selection model's `index * extent` scroll maths and is
/// handed to `LiveTabView` as its `itemExtent`, while `LiveTabView` re-derives
/// the row layout from the same metrics — so a view that answers this
/// differently on the two sides scrolls by a height its rows aren't drawn at.
///
/// The two views are asked **different questions**, which is the whole point of
/// this being one function rather than a bare `hasEpg` read. [hasEpg] is
/// whether the *active* source has a guide; [hasCrossSourceEpg] is whether the
/// cross-source Favorites view has one of its own. Reading `hasEpg` in the
/// cross-source view laid its rows out at 68.1 px inside an itemExtent of
/// 105.9 — the active source having a guide says nothing about whether a
/// foreign row will draw one.
///
/// The cross-source view's guide is keyed by `(sourceId, channelId)` and
/// reaches the rows through `LiveTabView.epgFor`; it is deliberately *not* the
/// active source's maps, which are keyed by channel id alone and would print
/// another provider's programme against a foreign row.
///
/// Pure and top-level for the same reason as
/// [shouldLeaveCrossSourceFavoritesView]: the screen that uses it can only be
/// widget-tested with libmpv present, which no Windows dev box has.
bool liveRowsShowEpg({
  required String? categoryId,
  required bool hasEpg,
  required bool hasCrossSourceEpg,
}) => categoryId == kAllSourcesFavoritesCategoryId ? hasCrossSourceEpg : hasEpg;

/// Whether the live tab must fall back to "All" because the cross-source
/// Favorites view is selected but no longer offered.
///
/// Its category entry only appears while a favorite exists in a source other
/// than the active one, so unfavoriting the last foreign favorite — or
/// switching to a source where every remaining favorite is local — removes the
/// entry from the pane while the selection still points at it, leaving an empty
/// list selected on a category the user can neither see nor move off. The
/// per-source Favorites view has always had this fallback; this is the same
/// rule for the cross-source one.
bool shouldLeaveCrossSourceFavoritesView({
  required String? categoryId,
  required bool hasForeignFavorites,
}) => categoryId == kAllSourcesFavoritesCategoryId && !hasForeignFavorites;

ChannelPlayAction decideChannelPlayAction({
  required bool sameChannelPreview,
  required bool previewHasStream,
  required bool previewLoading,
}) {
  if (!sameChannelPreview) return ChannelPlayAction.startPreview;
  if (previewHasStream) return ChannelPlayAction.openFullscreen;
  if (previewLoading) return ChannelPlayAction.awaitPreviewThenOpen;
  // Same channel, not loading, no stream: the preview errored out. Retrying it
  // is the useful answer, and it's what a first OK would have done.
  return ChannelPlayAction.startPreview;
}

/// Native Linux discovery may spawn/version-check an external mpv process on
/// its first call. Pay that cost only when its result can change the handoff:
/// a same-channel HDR preview that would otherwise be adopted embedded.
/// Non-preview opens and SDR previews go straight through; if an initially SDR
/// stream later reports HDR, [PlayerScreen] still performs its one-shot
/// embedded-to-native escalation.
bool shouldProbeLinuxNativeForHandoff({
  required bool isLinux,
  required bool reusePreview,
  required bool sameChannelPreview,
  required bool previewHasStream,
  required bool streamLikelyHdr,
}) =>
    isLinux &&
    reusePreview &&
    sameChannelPreview &&
    previewHasStream &&
    streamLikelyHdr;

/// Every downstream boolean [_ChannelListScreenState._openLivePlayer] needs
/// from a [FullscreenHandoff], derived here instead of re-tested against the
/// raw inputs at the call site — a duplicate formula there previously could
/// (and once did) desync from the actual decision when preview state changed
/// across an `await`. Pinned by `test/fullscreen_handoff_test.dart`.
extension FullscreenHandoffDerived on FullscreenHandoff {
  /// The fullscreen player adopts a still-running preview engine — Android's
  /// shared native engine or the embedded media_kit one — and the preview
  /// keeps playing straight through the handoff.
  bool get seamless =>
      this == FullscreenHandoff.adoptNative ||
      this == FullscreenHandoff.adoptEmbedded;

  /// [PlayerScreen] should adopt the preview's embedded media_kit
  /// [Player]/`VideoController` directly. Never true on Android — that's
  /// [adoptsNativePreview] instead.
  bool get adoptsEmbeddedPreview => this == FullscreenHandoff.adoptEmbedded;

  /// Android's fullscreen Activity should adopt the running shared native
  /// preview engine.
  bool get adoptsNativePreview => this == FullscreenHandoff.adoptNative;

  /// Linux native mpv is about to take over: the preview must be stopped and
  /// the channel re-resolved fresh (a spent play_token) rather than adopted.
  bool get stopsAndResolvesFresh => this == FullscreenHandoff.stopResolveFresh;

  /// A same-channel, non-adopted handoff: pause the preview and resume it on
  /// return.
  bool get pausesPreview => this == FullscreenHandoff.pausePreview;

  /// A different-channel preview: stop it outright, not restarted on return.
  bool get stopsPreview => this == FullscreenHandoff.stopPreview;
}

/// Lists a source's channels with in-memory search + category filtering, plus
/// now/next EPG (when the source provides it).
class ChannelListScreen extends StatefulWidget {
  final LibraryRepository repo;

  /// The active source's config, carrying per-source preferences (e.g. hidden
  /// categories). Read for presentation only — browsing filters key off it.
  final SourceConfig config;

  /// All configured sources. Needed by the cross-source Favorites view, which
  /// labels each row with its owning source and builds that source's
  /// repository on demand to play it — see [_ChannelListScreenState._repoFor].
  final SourceStore store;
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
    required this.store,
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

  /// The cross-source Favorites view's rows, and the per-source repositories
  /// built on demand to play them (see [_repoFor]).
  late GlobalFavoritesController _globalFavorites;
  StreamSubscription<void>? _favoritesReplacedSub;
  final Map<String, LibraryRepository> _foreignRepos = {};
  String? _categoryId;
  String _query = '';

  bool _resolving = false;
  Timer? _searchTimer;
  // One controller for whichever list/grid is mounted (only one exists per tab),
  // so a tab/category change can jump it back to the top.
  /// This screen owns its own [ScaffoldMessenger] (see [build]) so its
  /// snackbars can't outlive the route and paint over the pushed player.
  ///
  /// That messenger is created *inside* `build`, so it sits **below** this
  /// State's own context — `ScaffoldMessenger.of(context)` from here resolves
  /// to `MaterialApp`'s outer messenger instead, which no longer has a
  /// registered `Scaffold` and trips `assert(_scaffolds.isNotEmpty)` the
  /// moment anything tries to show a snackbar (the double-Back exit prompt was
  /// the first to hit it). Every snackbar this State shows goes through the
  /// key.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  ScaffoldMessengerState get _messenger => _messengerKey.currentState!;

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
  //
  // [_focus] is deliberately **not** merged in here: it fires on every D-pad
  // press *and* every focus change, and rebuilding the whole live body for
  // those was the dominant per-frame cost under key auto-repeat. The live body
  // subscribes to the coordinator's narrow slices instead
  // (LiveFocusCoordinator.channelSelection / categorySelection / previewRegion
  // / digitEntry) — see docs/tv-navigation.md.
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
      // The coordinator has no `BuildContext`, so it can't reach `appMotion`
      // itself — this callback is how the list reveal honours "remove
      // animations". Lazily evaluated (same shape as `isWide`/`isMounted`), so
      // reading `MediaQuery` here is safe despite running in `initState`.
      reduceMotion: () => mounted && MediaQuery.disableAnimationsOf(context),
    );
    _bodyListenable = Listenable.merge([_dataListenable, _preview]);
    WidgetsBinding.instance.addObserver(this);
    _loadLive();
    _live.startEpgRefresh();
    _globalFavorites.startEpgRefresh();
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
    _globalFavorites = GlobalFavoritesController(
      db: widget.repo.db,
      store: widget.store,
    );
    // A cloud pull rewrites favorites without going through any controller, and
    // now runs unattended (launch/resume). Re-read both sets when it does, or
    // the stars on screen keep showing the pre-pull state.
    _favoritesReplacedSub = widget.repo.db.favoritesReplaced.listen((_) {
      if (!mounted) return;
      unawaited(_loadFavorites(ContentKind.live));
      unawaited(_globalFavorites.load());
    });
    _dataListenable = Listenable.merge([
      _live,
      _favorites,
      _globalFavorites,
      ..._mediaControllers.values,
    ]);
  }

  /// The repository that owns [sourceId] — the active one where it matches,
  /// otherwise a lightweight repository built on demand for a cross-source
  /// favorite and cached for this screen's lifetime.
  ///
  /// No metadata providers: these exist only to resolve and play a live
  /// channel, never to browse or enrich a catalog. Each one owns a [Source]
  /// (its provider client), so [_disposeForeignRepos] must dispose them.
  /// Takes the [SourceConfig] rather than looking one up by id: the caller
  /// already holds the row's own config, and a lookup here could throw if the
  /// cross-source list were reloaded between choosing a row and playing it.
  LibraryRepository _repoFor(SourceConfig config) {
    if (config.id == widget.repo.source.id) return widget.repo;
    return _foreignRepos.putIfAbsent(
      config.id,
      () => LibraryRepository(
        source: config.build(),
        db: widget.repo.db,
        metadataProviders: const [],
        autoEnrichMetadata: false,
      ),
    );
  }


  /// The buffering preset of the source that *owns* [channel].
  ///
  /// Mirrors [_repoForChannel]: a cross-source favorite plays through its own
  /// source's repository, so it must play with its own source's buffering too
  /// — reading the active source's would apply one provider's setting to
  /// another provider's stream.
  BufferPreset _bufferPresetForChannel(Channel channel) {
    final cross = _crossSourceFavoriteFor(channel);
    return bufferPresetFromName(
      (cross?.config ?? widget.config).bufferPresetName,
    );
  }

  /// The repository that owns [channel] *in the current view* — the active
  /// source's, or a cross-source favorite's owning source.
  ///
  /// Cheap outside the cross-source view: [_crossSourceFavoriteFor] returns
  /// null unless that category is selected.
  LibraryRepository _repoForChannel(Channel channel) {
    final cross = _crossSourceFavoriteFor(channel);
    return cross == null ? widget.repo : _repoFor(cross.config);
  }

  /// Whether the preview is showing (or loading) [channel] — asked with the
  /// owning source attached.
  ///
  /// Every one of these comparisons used to be `_preview.channelId ==
  /// channel.id`, which was sound only while the preview was guaranteed to be
  /// the active source's. Now that a cross-source favorite can preview, a bare
  /// id match can be a *different provider's* channel that happens to share it
  /// — and the consequences are all silent: going fullscreen on the wrong
  /// stream, suppressing a hover re-arm that should have fired, locking the
  /// panel to the wrong row.
  /// The id of the source that owns [channel] in the current view — **without
  /// building anything.**
  ///
  /// Deliberately not `_repoForChannel(channel).source.id`. That constructs a
  /// `LibraryRepository` *and* a live provider client as a side effect, and
  /// this is reached from `ListView.builder`'s item builder: scrolling the
  /// cross-source list would instantiate a provider client for every source
  /// whose row came into view, for channels the user never plays. Worse,
  /// `SourceConfig.build()` null-asserts its credential fields, so a
  /// credential-less source (an E2EE-locked device, or a cloud-pulled source
  /// whose secrets haven't arrived) would throw *inside build* and take the
  /// whole channel list down with it — where the play path catches the same
  /// throw and shows a snackbar.
  String _sourceIdForChannel(Channel channel) =>
      _crossSourceFavoriteFor(channel)?.sourceId ?? widget.repo.source.id;

  bool _isPreviewing(Channel channel) =>
      _preview.isPreviewing(_sourceIdForChannel(channel), channel.id);

  Future<void> _disposeForeignRepos() async {
    final repos = _foreignRepos.values.toList();
    _foreignRepos.clear();
    for (final repo in repos) {
      await repo.source.dispose();
    }
  }

  void _disposeRepositoryControllers() {
    unawaited(_favoritesReplacedSub?.cancel() ?? Future<void>.value());
    _favoritesReplacedSub = null;
    _live.dispose();
    _preview.dispose();
    _favorites.dispose();
    _globalFavorites.dispose();
    // Fire-and-forget: each foreign repository owns a provider client whose
    // dispose is async, and neither `dispose()` nor the source-change rebuild
    // can await. Nothing reads them again — the map is cleared synchronously.
    unawaited(_disposeForeignRepos());
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
      DiagnosticsLog.instance.add('library', 'lifecycle paused: preview stop');
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
    if (!mounted) return;
    // Cross-source rows come from the cache, not from this source's load, so
    // this neither waits on nor blocks the active catalog.
    await _globalFavorites.load();
    if (mounted) _ensureCrossSourceCategoryStillOffered();
  }

  @override
  void didUpdateWidget(covariant ChannelListScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.repo, widget.repo)) {
      _previewTimer?.cancel();
      _previewTimer = null;
      _disposeRepositoryControllers();
      _createRepositoryControllers();
      _bodyListenable = Listenable.merge([_dataListenable, _preview]);
      _visibleKey = null;
      _visibleCache = null;
      _visibleMediaKey = null;
      _visibleMediaCache = null;
      _channelsByIdKey = null;
      _channelsByIdCache = null;
      _crossSourceIndexKey = null;
      _crossSourceIndexCache = null;
      _focus.resetChannelSelection();
      _loadLive();
      _live.startEpgRefresh();
      _globalFavorites.startEpgRefresh();
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
      if (!_deliberatePreview && _isPreviewing(channel)) {
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
      // Never (re)start a preview while a fullscreen open/playback is in
      // flight (_resolving spans the whole player push): the Linux native
      // path stops the preview to free its provider connection, and a hover
      // re-arm here would open a second connection behind the player.
      if (_resolving) return;
      // Already previewing (or resolving) this exact channel — a hover
      // re-arm would pointlessly burn another create_link (tokens are
      // single-use; portals may rate-limit).
      if (_isPreviewing(channel) &&
          (_preview.stream != null || _preview.loading)) {
        return;
      }
      final isWide = isWideLayout(MediaQuery.sizeOf(context));
      if (isWide && _tab == ContentKind.live) {
        _preview.start(
          channel,
          from: _repoForChannel(channel),
          bufferPreset: _bufferPresetForChannel(channel),
        );
      }
    });
  }

  Channel? _findChannelById(String id) => _channelsById[id];

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

  /// Unfavorite (or re-favorite) a channel belonging to a source other than the
  /// active one, from the player's star.
  ///
  /// Writes straight to the cache: [FavoritesController] holds only the active
  /// source's ids, so routing this through it would toggle the wrong source's
  /// favorite — or, where the ids happen to collide, the wrong channel.
  Future<void> _setForeignFavorite(
    String sourceId,
    String channelId,
    bool favorite,
  ) async {
    await widget.repo.db.setFavorite(
      sourceId,
      ContentKind.live,
      channelId,
      favorite,
    );
    if (!mounted) return;
    if (favorite) {
      // Re-favorited from the player: re-read so the row comes back in order.
      await _globalFavorites.load();
    } else {
      _globalFavorites.removeLocally(sourceId, channelId);
    }
    if (mounted) _ensureCrossSourceCategoryStillOffered();
    if (mounted) _focus.clampSelection();
  }

  /// Flips a foreign channel's favorite state, in whichever direction it is
  /// currently in. Used where the control is a true toggle (the phone preview
  /// sheet) rather than the cross-source list's remove-only star.
  Future<void> _toggleForeignFavorite(String sourceId, String channelId) async {
    final favorited = _globalFavorites.items.any(
      (item) => item.sourceId == sourceId && item.channel.id == channelId,
    );
    await _setForeignFavorite(sourceId, channelId, !favorited);
  }

  /// Star pressed on a row of the cross-source view.
  ///
  /// Every row there *is* a favorite, so the only meaningful action is removing
  /// it — and it has to be removed from the source that owns it. Matching the
  /// id against the visible rows keeps this correct when the same provider
  /// channel id exists in several sources.
  Future<void> _unfavoriteCrossSourceRow(String channelId) async {
    for (final item in _globalFavorites.items) {
      if (item.channel.id != channelId) continue;
      // A row from the *active* source goes through the normal path so the
      // per-source Favorites view's in-memory set stays in step; only a truly
      // foreign row needs the direct write.
      if (item.sourceId == widget.repo.source.id) {
        await _toggleFavorite(ContentKind.live, channelId);
      } else {
        await _setForeignFavorite(item.sourceId, channelId, false);
      }
      return;
    }
  }

  Future<void> _toggleFavorite(ContentKind kind, String id) async {
    final nowEmpty = await _favorites.toggle(kind, id);
    if (!mounted) return;
    if (kind == ContentKind.live) {
      // The cross-source view reads the same `favorites` table through its own
      // controller, which this write goes nowhere near — so without this it only
      // caught up on the next full reload, and a channel starred from the
      // ordinary list simply wasn't in "Favorites · All sources" until the user
      // refreshed, while the per-source Favorites view updated instantly.
      //
      // Incremental (see `applyLocalChange`), because this is a star press: a
      // full reload would re-read the OS keychain and requery every contributing
      // source on every one.
      final channel = _channelsById[id];
      if (channel != null) {
        unawaited(
          _globalFavorites.applyLocalChange(
            config: widget.config,
            channel: channel,
            favorite: _isFavorite(ContentKind.live, id),
          ),
        );
      }
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

  /// True when the cross-source view has something the per-source one doesn't.
  /// Also decides whether its category entry is offered at all.
  bool get _hasForeignFavorites => _globalFavorites.items.any(
    (item) => item.sourceId != widget.repo.source.id,
  );

  /// Falls back to "All" when the cross-source view is selected but no longer
  /// offered — unfavoriting the last foreign favorite, or switching to a source
  /// where every remaining favorite is local.
  ///
  /// Same reason the per-source Favorites view has this: the entry vanishes
  /// from the pane while `_categoryId` still points at it, leaving an empty
  /// list selected on a category the user cannot see or move off.
  void _ensureCrossSourceCategoryStillOffered() {
    if (!shouldLeaveCrossSourceFavoritesView(
      categoryId: _categoryId,
      hasForeignFavorites: _hasForeignFavorites,
    )) {
      return;
    }
    setState(() => _categoryId = null);
    _focus.resetChannelSelection();
    _focus.clampSelection();
    // Leaving the cross-source view also changes the row extent (those rows
    // carry no EPG, so they run on the shorter one — `liveRowsShowEpg`), which
    // makes the retained pixel offset mean a different row than it did a frame
    // ago. Every other category switch resets the cursor and the scroll for the
    // same reason; this fallback is a category switch too, just one the user
    // didn't press.
    _scrollToTop();
  }

  /// Live categories shown in the pane/dropdown: the Favorites entry (only when
  /// something is favorited) followed by the enabled provider categories.
  List<Category> get _liveCategoriesForUi {
    final cats = _visibleCategories;
    final hasOwn = _favoriteIds(ContentKind.live).isNotEmpty;
    // "All sources" only earns a row when it would actually show something the
    // per-source view doesn't: favorites living in a *different* source. With
    // one source configured (or favorites in only this one) the two lists are
    // identical, and a duplicate entry is just noise on a remote.
    final hasForeign = _hasForeignFavorites;
    if (!hasOwn && !hasForeign) return cats;
    return [
      if (hasOwn) const Category(id: kFavoritesCategoryId, title: 'Favorites'),
      if (hasForeign)
        const Category(
          id: kAllSourcesFavoritesCategoryId,
          title: 'Favorites · All sources',
        ),
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
  (
    String?,
    String,
    List<Channel>,
    Set<String>,
    SourceConfig,
    List<GlobalFavoriteChannel>, // cross-source rows, reassigned on change
  )?
  _visibleKey;

  // Preview and last-played resolution look channels up by id on every body
  // rebuild — which is every D-pad press — and they search the *unfiltered*
  // catalogue, so an unmemoized scan is O(N) per keypress on a large portal.
  // Keyed on the channel list's identity, like _visibleCache above: the
  // controller reassigns a fresh list on change.
  Map<String, Channel>? _channelsByIdCache;
  List<Channel>? _channelsByIdKey;

  Map<String, Channel> get _channelsById {
    final channels = _live.channels;
    if (identical(_channelsByIdKey, channels)) return _channelsByIdCache!;
    _channelsByIdKey = channels;
    return _channelsByIdCache = {for (final c in channels) c.id: c};
  }

  List<Channel> get _visible {
    final key = (
      _categoryId,
      _query.trim().toLowerCase(),
      _live.channels,
      _favoriteIds(ContentKind.live),
      widget.config,
      _globalFavorites.items,
    );
    if (_visibleKey == key) return _visibleCache!;
    _visibleKey = key;
    return _visibleCache = _computeVisible();
  }

  List<Channel> _computeVisible() {
    final q = _query.trim().toLowerCase();
    // The cross-source view is not a filter over the loaded catalog — its rows
    // come from the cache across every source, so it replaces the list rather
    // than narrowing it. Category hiding is per-source and deliberately not
    // applied: a favorite is an explicit pick, exactly as in the per-source
    // Favorites view.
    if (_categoryId == kAllSourcesFavoritesCategoryId) {
      return [
        for (final item in _globalFavorites.items)
          if (q.isEmpty || item.channel.name.toLowerCase().contains(q))
            item.channel,
      ];
    }
    final favoritesView = _categoryId == kFavoritesCategoryId;
    final favs = favoritesView ? _favoriteIds(ContentKind.live) : null;
    final hidden = _hiddenCategories(ContentKind.live);
    final matched = _live.channels.where((c) {
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
    if (!favoritesView) return matched;
    // Favorites read in catalog order: category order first, then the channel
    // order inside it — which `matched` already carries, having been filtered
    // straight out of the catalog. Every other category view is a single
    // category, so only this one has any grouping to do. Ranked against the
    // *full* category list rather than the visible one, because a favorite is
    // deliberately still shown when its category is disabled.
    final categoryRanks = catalogRanks(_live.categories.map((c) => c.id));
    return orderedByCatalog(
      matched,
      categoryRank: (c) => rankOf(categoryRanks, c.categoryId),
    );
  }

  // Memoized filtered media list, for the same reason as [_visible]: it is read
  // from both `_statusText` and `_buildBody`, which each listen to
  // `_dataListenable`, so a single notification re-filtered and re-allocated it
  // twice. Metadata enrichment is the worst case — the media controller
  // notifies once per 20-item chunk, and every live/favorites notification used
  // to pay for it too. Key fields compare by identity (MediaLibrarySnapshot,
  // List, Set and SourceConfig don't override ==) and the controller reassigns
  // fresh collections on every mutation (`_replaceItems` copies the snapshot and
  // the search results), so a stale hit is impossible.
  List<MediaItem>? _visibleMediaCache;
  (
    ContentKind,
    MediaTabController,
    String?, // controller.categoryId
    String, // trimmed query (the lowercased form is derived from it)
    String?, // controller.searchQuery
    MediaLibrarySnapshot?,
    List<MediaItem>, // controller.searchResults
    Set<String>, // favorites for this kind
    SourceConfig, // hidden categories
  )?
  _visibleMediaKey;

  List<MediaItem> _visibleMedia(ContentKind kind) {
    final controller = _media(kind);
    final key = (
      kind,
      controller,
      controller.categoryId,
      _query.trim(),
      controller.searchQuery,
      controller.snapshot,
      controller.searchResults,
      _favoriteIds(kind),
      widget.config,
    );
    if (_visibleMediaKey == key) return _visibleMediaCache!;
    _visibleMediaKey = key;
    return _visibleMediaCache = _computeVisibleMedia(kind);
  }

  List<MediaItem> _computeVisibleMedia(ContentKind kind) {
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
    final matched = items.where((item) {
      if (favoritesView) {
        if (!favs!.contains(item.id)) return false;
      } else {
        if (hidden.contains(item.categoryId)) return false;
      }
      if (q.isNotEmpty && !item.title.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    if (!favoritesView) return matched;
    // Same rule as the live Favorites view — see `_computeVisible`.
    final categoryRanks = catalogRanks(
      (controller.snapshot?.categories ?? const <MediaCategory>[]).map(
        (c) => c.id,
      ),
    );
    return orderedByCatalog(
      matched,
      categoryRank: (item) => rankOf(categoryRanks, item.categoryId),
    );
  }

  /// The cross-source favorite backing [channel], or null when this isn't the
  /// "All sources" view.
  ///
  /// Matched by **identity**, not by id: the same provider channel id can exist
  /// in several sources — the duplicate case this whole view has to handle —
  /// and the visible list holds the controller's own [Channel] instances, so
  /// identity is exact where an id would be ambiguous.
  /// Lookup tables for [_crossSourceFavoriteFor], rebuilt only when the
  /// controller republishes its list.
  ///
  /// That resolver runs for **every visible row on every rebuild** — now twice
  /// per row, once for the source chip and once for the guide — and the live
  /// list rebuilds on every D-pad press. Two linear scans of the whole
  /// favorites list per call is precisely the shape that makes a remote feel
  /// unresponsive, so it is a pair of maps instead. Keyed on the list's
  /// identity, like [_channelsById]: the controller assigns a fresh list on
  /// every change.
  ({
    Map<Channel, GlobalFavoriteChannel> byInstance,
    Map<String, GlobalFavoriteChannel> byId,
  })?
  _crossSourceIndexCache;
  List<GlobalFavoriteChannel>? _crossSourceIndexKey;

  ({
    Map<Channel, GlobalFavoriteChannel> byInstance,
    Map<String, GlobalFavoriteChannel> byId,
  })
  get _crossSourceIndex {
    final items = _globalFavorites.items;
    if (identical(_crossSourceIndexKey, items)) return _crossSourceIndexCache!;
    _crossSourceIndexKey = items;
    // Explicitly identity-keyed: `Channel` has no `==` override today, and this
    // must not silently become a value lookup if one is ever added — the whole
    // point of the first probe is that it beats an ambiguous id.
    final byInstance = Map<Channel, GlobalFavoriteChannel>.identity();
    final byId = <String, GlobalFavoriteChannel>{};
    for (final item in items) {
      byInstance[item.channel] = item;
      // First match wins, as the scan it replaces did.
      byId.putIfAbsent(item.channel.id, () => item);
    }
    return _crossSourceIndexCache = (byInstance: byInstance, byId: byId);
  }

  GlobalFavoriteChannel? _crossSourceFavoriteFor(Channel channel) {
    if (_categoryId != kAllSourcesFavoritesCategoryId) return null;
    final index = _crossSourceIndex;
    // Identity first — exact even when two sources carry the same channel id,
    // which is the duplicate case this view exists to disambiguate.
    //
    // Then by id. `load()` republishes fresh `Channel` instances (a re-favorite
    // from the player, a `_loadLive` refresh), so a reload between the frame
    // that built the row and this callback running would miss on identity
    // alone — and falling through would play a *foreign* channel through the
    // active source's repository. Ambiguous only when the same id exists in
    // several sources and the instance is stale, which is strictly better than
    // resolving against the wrong provider outright.
    return index.byInstance[channel] ?? index.byId[channel.id];
  }

  /// Now/next for [channel], resolved through whichever source owns it.
  ///
  /// A [foreign] row's guide lives under **its own** source id. Reading the
  /// active source's maps by channel id would show a *different* provider's
  /// programme against this channel, because provider ids are unique only
  /// within a provider — which is exactly the collision this view puts two of
  /// in one list.
  ///
  /// Every surface that prints a programme goes through here: the row, the
  /// preview panel, the phone preview sheet and the fullscreen player. They
  /// used to hand a foreign row `null` on all four, so a cross-source favorite
  /// showed no guide anywhere.
  ({Programme? now, Programme? next}) _epgFor(
    Channel channel, {
    required bool foreign,
    required String sourceId,
  }) => foreign
      ? _globalFavorites.epgFor(sourceId, channel.id)
      : (now: _live.now[channel.id], next: _live.next[channel.id]);

  /// Now/next for a row of the cross-source Favorites view.
  ///
  /// Resolved through the row's **owning** source, which is the entire reason
  /// this view can carry a guide at all: the active source's maps are keyed by
  /// channel id, and a foreign row's id can mean a different channel there — so
  /// reading them would print that provider's programme against this one.
  ///
  /// A foreign source's guide is only refreshed while that source is active, so
  /// it can be stale. That degrades to *nothing* rather than to something
  /// wrong: both halves of the query are bounded by the current instant, so an
  /// out-of-date guide simply stops matching and the row draws plain.
  ({Programme? now, Programme? next}) _crossSourceEpgFor(Channel channel) {
    final item = _crossSourceFavoriteFor(channel);
    if (item == null) return (now: null, next: null);
    return _globalFavorites.epgFor(item.sourceId, item.channel.id);
  }

  Future<void> _play(Channel channel) async {
    if (_resolving) return;
    final isWide = isWideLayout(MediaQuery.sizeOf(context));
    // A cross-source favorite plays through *its own* source's repository, on
    // every path below — the preview, the resolve, the fullscreen route and
    // that route's reconnect re-resolve. Resolving it against the active
    // source would hand provider A a channel id that means something else
    // there (or nothing), and spend a single-use create_link doing it.
    final playRepo = _repoForChannel(channel);
    if (!isWide) {
      await _openFullscreenDirect(channel, playRepo);
      return;
    }

    // On wide screens, reconcile with whatever this channel's preview is doing.
    switch (decideChannelPlayAction(
      sameChannelPreview: _isPreviewing(channel),
      previewHasStream: _preview.stream != null,
      previewLoading: _preview.loading,
    )) {
      case ChannelPlayAction.openFullscreen:
        await _openLivePlayer(channel, _preview.stream!, repo: playRepo);
      case ChannelPlayAction.awaitPreviewThenOpen:
        await _openLivePlayerWhenPreviewReady(channel, repo: playRepo);
      case ChannelPlayAction.startPreview:
        // First OK starts the preview; on a TV remote it's deliberate, so
        // unmuted.
        await _preview.start(
          channel,
          muted: !_deliberatePreview,
          from: playRepo,
          bufferPreset: _bufferPresetForChannel(channel),
        );
    }
  }

  /// Resolve and open fullscreen with no preview involved, through [repo] —
  /// the active source's on a narrow screen, or the owning source's for a
  /// cross-source favorite.
  Future<void> _openFullscreenDirect(
    Channel channel,
    LibraryRepository repo,
  ) async {
    // A repository other than the active one means a cross-source favorite:
    // its EPG and favorite state live under its own source id, not the active
    // controllers' (which only ever hold the active source).
    final foreign = !identical(repo, widget.repo);
    // **Silence any running preview first.** This body used to be the
    // narrow-screen path only, where no preview exists — it is now also the
    // cross-source path on wide screens, where one may well be playing. A
    // non-adopted fullscreen that leaves the preview running doubles the audio
    // and holds a second provider connection open (CLAUDE.md, "any *non*-adopted
    // fullscreen must silence the running preview"). Stopped, not paused: the
    // channel is by definition a different one, so its connection must go.
    if (_preview.channelId != null || _preview.nativeActive) {
      await _preview.stop();
    }
    {
      setState(() => _resolving = true);
      try {
        DiagnosticsLog.instance.add(
          'library',
          'open live fullscreen source=${repo.source.name} channel=${channel.name} id=${channel.id}',
        );
        final stream = await repo.resolve(channel);
        if (!mounted) return;
        _notePlayedChannel(channel.id);
        final epg = _epgFor(
          channel,
          foreign: foreign,
          sourceId: repo.source.id,
        );
        await Navigator.of(context).push(
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => PlayerScreen(
              title: channel.name,
              stream: stream,
              sourceName: repo.source.name,
              bufferPreset: _bufferPresetForChannel(channel),
              epgNow: epg.now,
              epgNext: epg.next,
              favoriteInitial: foreign
                  ? true
                  : _isFavorite(ContentKind.live, channel.id),
              onSetFavorite: (fav) => foreign
                  ? _setForeignFavorite(repo.source.id, channel.id, fav)
                  : _setLiveFavorite(channel.id, fav),
              // Live reloads (reconnect watchdog, "Go to live") re-resolve
              // through the source: Stalker create_link tokens are
              // single-use, so the originally resolved URL is dead after any
              // portal-side kill.
              resolveAgain: () => repo.resolve(channel),
              iosEngineKey: channel.id,
            ),
          ),
        );
        _restoreListFocusAfterPlayback();
      } catch (e) {
        if (mounted) {
          _messenger.showSnackBar(
            SnackBar(content: Text('Could not play: ${redactText('$e')}')),
          );
        }
      } finally {
        if (mounted) setState(() => _resolving = false);
      }
    }
  }

  /// Second OK on a channel whose preview is still resolving: wait for the
  /// resolve already in flight and then hand it to fullscreen, rather than
  /// starting a competing one (see [ChannelPlayAction.awaitPreviewThenOpen]).
  ///
  /// `_resolving` is held across the wait, which both shows the list's
  /// in-progress affordance and makes [_play]'s own re-entry guard swallow
  /// further presses — a remote user leaning on OK can't stack resolves.
  Future<void> _openLivePlayerWhenPreviewReady(
    Channel channel, {
    LibraryRepository? repo,
  }) async {
    setState(() => _resolving = true);
    try {
      await _preview.pendingStart;
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
    if (!mounted) return;
    // The wait can end in something other than "this channel is playing": the
    // resolve failed, or a newer `start` superseded it. Open only what actually
    // came up, and never restart anything from here — a failed preview shows
    // its own error and the next OK retries it.
    if (!_isPreviewing(channel) || _preview.stream == null) return;
    await _openLivePlayer(channel, _preview.stream!, repo: repo);
  }

  /// Opens fullscreen playback for [channel]/[stream]. When [reusePreview] and
  /// the preview is already showing this exact channel, the fullscreen player
  /// *adopts* the running preview engine instead of resolving/opening fresh:
  /// on Android the native Activity takes over the shared ExoPlayer engine
  /// (only the video surface moves — audio and buffer never stop); elsewhere
  /// the same media_kit [Player] is handed to [PlayerScreen]. On Linux that
  /// covers SDR and all of X11; only a **Wayland HDR** source instead takes
  /// the non-seamless native mpv path (it can't adopt anything — see
  /// [FullscreenHandoff.stopResolveFresh]). Seamless adoption leaves the
  /// preview playing, not paused, around the handoff.
  ///
  /// [resumePreviewOnReturn] is false for the phone sheet (no panel to return
  /// to): the preview is stopped once fullscreen exits instead of resumed.
  Future<void> _openLivePlayer(
    Channel channel,
    StreamInfo stream, {
    bool reusePreview = true,
    bool resumePreviewOnReturn = true,
    LibraryRepository? repo,
  }) async {
    // The owning source: the active one for an ordinary channel, another
    // provider's for a cross-source favorite. Everything the route needs from
    // "the source" comes from here — name, re-resolve, reconnect — and the
    // things that live only under the *active* source (EPG, the favorites set)
    // are answered differently when they disagree.
    final playRepo = repo ?? widget.repo;
    final foreign = !identical(playRepo, widget.repo);
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = _messenger;
    var playbackStream = stream;
    // Set only while the Wayland+HDR stop-and-resolve-fresh path below has
    // torn the preview down but not yet completed the fullscreen push — if
    // resolve() or route setup throws in that window, the catch block
    // restarts the same preview so the pane doesn't sit dead until an
    // unrelated selection change.
    var restorePreviewOnFailure = false;
    // Assigned once `decision` is known (inside the try, after the await
    // below) — declared here so the catch block can still read it.
    var previewWasMuted = false;
    try {
      DiagnosticsLog.instance.add(
        'library',
        'open live fullscreen source=${playRepo.source.name} channel=${channel.name} id=${channel.id}',
      );
      _notePlayedChannel(channel.id);
      // Native discovery can require an external mpv version probe on its
      // first call. The result only matters for a same-channel HDR preview;
      // probing for SDR or a non-adoptable preview added avoidable latency to
      // ordinary opens after the Linux native path was introduced.
      final initialSameChannelPreview = _preview.isPreviewing(
        playRepo.source.id,
        channel.id,
      );
      final initialPreviewHasStream = _preview.stream != null;
      final initialStreamLikelyHdr = _preview.hasEmbeddedPlayer
          ? isHdrColorimetry(
              gamma: _preview.player.state.videoParams.gamma,
              primaries: _preview.player.state.videoParams.primaries,
              matrix: _preview.player.state.videoParams.colormatrix,
            )
          : false;
      final shouldProbeLinux = shouldProbeLinuxNativeForHandoff(
        isLinux: Platform.isLinux,
        reusePreview: reusePreview,
        sameChannelPreview: initialSameChannelPreview,
        previewHasStream: initialPreviewHasStream,
        streamLikelyHdr: initialStreamLikelyHdr,
      );
      final linuxNative =
          shouldProbeLinux && await LinuxNativeSession.nativeLikelyAvailable();
      // Preview state is read exactly once, here — after every await that
      // precedes the decision — and every downstream boolean is derived from
      // `decision` alone. A previous version recomputed an "adoptPreview"
      // local from preview state read *before* the await above while
      // `decision` read it after; a preview-state change mid-await (e.g. the
      // native engine reporting mid-flight that a channel is unsupported)
      // could desync the two, risking double audio or a second provider
      // connection. Reading once also fixed a latent bug: the old duplicate
      // formula ignored the isAndroid gate baked into `decideFullscreenHandoff`,
      // so an Android same-channel *fallback* preview (native engine not
      // active) — correctly decided as pausePreview — was nonetheless treated
      // as adoptable at the `existingPlayer`/restore-mute call sites below.
      final previewChannelId = _preview.channelId;
      // Read here with the rest of the preview state, not via
      // `_preview.isPreviewing` — the read-once discipline above is the whole
      // point of this block, and a helper that re-reads the controller would
      // reintroduce exactly the desync it exists to prevent.
      final previewSourceId = _preview.previewSourceId;
      final previewNativeActive = _preview.nativeActive;
      final previewStreamUrl = _preview.stream?.url;
      final previewHasStream = previewStreamUrl != null;
      final previewMuted = _preview.isMuted;
      final previewPlaying = previewChannelId != null || previewNativeActive;
      // "Same channel" means same *source* too: the identical id in another
      // provider's list is a different channel, and adopting its engine would
      // put provider A's stream behind provider B's title.
      final sameChannelPreview =
          previewChannelId == channel.id &&
          previewSourceId == playRepo.source.id;
      // Read the preview engine's current colorimetry: only a Wayland *HDR*
      // source justifies the native mpv path's non-seamless fresh-resolve cost
      // (SDR/X11 stay embedded/seamless). The embedded preview player carries
      // media_kit's videoParams; guard on hasEmbeddedPlayer so we never
      // lazily spin one up (and it's always false on Android's native preview).
      final streamLikelyHdr = _preview.hasEmbeddedPlayer
          ? isHdrColorimetry(
              gamma: _preview.player.state.videoParams.gamma,
              primaries: _preview.player.state.videoParams.primaries,
              matrix: _preview.player.state.videoParams.colormatrix,
            )
          : false;
      // iOS: the preview is always embedded media_kit/libmpv, but an
      // AVPlayer-routed channel goes fullscreen on a presented AVPlayerLayer
      // controller — a different engine, so nothing can be adopted. Cheap to
      // decide (a pure function of the already-resolved preview URL, no probe),
      // so it's computed inline with the rest of the once-only preview read.
      final crossEngine =
          Platform.isIOS &&
          previewStreamUrl != null &&
          selectIosEngine(
                url: previewStreamUrl,
                memoKey: channel.id,
                forcedMpv: IosEngineMemo.forcedMpv,
              ) ==
              IosPlaybackEngine.avPlayer;
      final decision = decideFullscreenHandoff(
        reusePreview: reusePreview,
        sameChannelPreview: sameChannelPreview,
        previewHasStream: previewHasStream,
        isAndroid: Platform.isAndroid,
        nativePreviewActive: previewNativeActive,
        linuxNativeLikely: linuxNative,
        previewPlaying: previewPlaying,
        streamLikelyHdr: streamLikelyHdr,
        crossEngineFullscreen: crossEngine,
      );
      final adoptNative = decision.adoptsNativePreview;
      // Covers both cross-engine shapes: Linux Wayland-HDR native mpv and iOS
      // AVPlayer. Only the Linux one sets `preferLinuxNative` below.
      final stopResolveFresh = decision.stopsAndResolvesFresh;
      // Same channel (a media_kit-fallback preview going native-fullscreen):
      // pause and resume on return. A *different* channel (the "last channel"
      // zap / EPG-grid play, which resolve fresh with reusePreview: false and so
      // never adopt the engine previewing whatever else): stop it outright — not
      // just pause — so we neither double the audio nor hold a second provider
      // connection open (single-connection accounts would refuse the new stream).
      final pausedPreview = decision.pausesPreview;
      final stoppedPreview = decision.stopsPreview;
      // Fullscreen always plays at full volume; used to restore a muted
      // (desktop auto-hover) preview once we return. True for every decision
      // that adopts the running engine (seamlessly or via the Wayland+HDR
      // stop-and-resolve-fresh path) — not for a merely paused/stopped one.
      previewWasMuted =
          (decision.seamless || decision.stopsAndResolvesFresh) && previewMuted;
      DiagnosticsLog.instance.add(
        'library',
        'fullscreen open decision=${decision.name} linuxNative=$linuxNative '
            'hdr=$streamLikelyHdr crossEngine=$crossEngine',
      );
      if (stoppedPreview) {
        await _preview.stop();
      } else if (pausedPreview) {
        await _preview.pause();
      } else if (stopResolveFresh) {
        // The incoming engine (Linux native mpv process / iOS AVPlayer) opens
        // its own provider connection — a merely-paused media_kit engine would
        // still hold its connection open (a single-connection portal then sees
        // two, fighting each other in a create_link storm), and the preview's
        // already-resolved stream carries a spent single-use Stalker
        // play_token — so stop outright and re-resolve fresh instead of
        // reusing `stream`.
        await _preview.stop();
        // If resolve() or the route setup below throws before the push goes
        // through, the catch block restarts this same preview — otherwise it
        // would sit dead (channelId set, stream null) until an unrelated
        // selection change.
        restorePreviewOnFailure = true;
        playbackStream = await playRepo.resolve(channel);
      }
      final epg = _epgFor(
        channel,
        foreign: foreign,
        sourceId: playRepo.source.id,
      );
      // Context-independent on purpose — nothing in the player derives from
      // the route builder's element.
      Widget buildPlayer() => PlayerScreen(
        title: channel.name,
        stream: playbackStream,
        sourceName: playRepo.source.name,
        bufferPreset: _bufferPresetForChannel(channel),
        epgNow: epg.now,
        epgNext: epg.next,
        existingPlayer: decision.adoptsEmbeddedPreview ? _preview.player : null,
        existingController: decision.adoptsEmbeddedPreview
            ? _preview.controller
            : null,
        adoptNativePreview: adoptNative,
        // Wayland+HDR: open straight to native mpv (the preview was stopped and
        // `playbackStream` re-resolved fresh above). SDR/X11 open embedded and
        // escalate to native later only if the source turns out to be HDR.
        // Explicitly Linux-gated: iOS reaches `stopResolveFresh` too (the
        // AVPlayer cross-engine case), and must not ask for a Linux mpv process.
        preferLinuxNative: Platform.isLinux && stopResolveFresh,
        // iOS: stable content id for the AVPlayer-failure memo, so a container
        // sniff that turns out wrong is remembered per channel.
        iosEngineKey: channel.id,
        // Windows: keep an adopted **SDR** preview on its embedded texture for a
        // seamless handoff both ways (no `vo` swap to the native HWND, preview
        // never disposed). HDR keeps the native HWND path for real D3D11 HDR —
        // the same SDR-embedded / HDR-dedicated split Linux uses.
        preferWindowsEmbedded:
            decision.adoptsEmbeddedPreview &&
            Platform.isWindows &&
            !streamLikelyHdr,
        // `FavoritesController` holds only the active source's ids, so a
        // foreign row's star has to be answered — and written — against its own
        // source. A cross-source row is by definition favorited.
        favoriteInitial: foreign
            ? true
            : _isFavorite(ContentKind.live, channel.id),
        onSetFavorite: (fav) => foreign
            ? _setForeignFavorite(playRepo.source.id, channel.id, fav)
            : _setLiveFavorite(channel.id, fav),
        // Live reloads (reconnect watchdog, "Go to live") re-resolve through
        // the source: Stalker create_link tokens are single-use, so the
        // originally resolved URL is dead after any portal-side kill.
        resolveAgain: () => playRepo.resolve(channel),
      );
      // The adopted native handoff pushes a *transparent, non-animated* route:
      // PlayerScreen stays see-through while the native Activity launches, so
      // this screen (with the preview's frozen last frame) remains visible
      // until the Activity's first frame — no black flash (see
      // PlayerScreen._transparentHandoff).
      // Start opening immediately. The default Material route animates for
      // ~300 ms while the player is already resolving/decoding, which makes
      // preview→fullscreen feel slower on every platform and delays the first
      // visible frame behind an opaque transition. Native Android adoption
      // remains transparent; ordinary routes are opaque but non-animated.
      final route = PageRouteBuilder<bool>(
        opaque: !adoptNative,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => buildPlayer(),
      );
      // The embedded seamless handoff hands `_preview.player` to the fullscreen
      // route, so from here until the pop that one engine has two live-EOF
      // watchdogs on it. Silence the preview's for the duration — the
      // fullscreen one owns recovery, and the preview's would reopen the stream
      // under it and reset the volume to the preview's mute state (see
      // [LivePreviewController.adoptedByFullscreen]).
      _preview.adoptedByFullscreen = decision.adoptsEmbeddedPreview;
      final hotSwapped = await navigator.push<bool>(route) ?? false;
      // The push (and whatever PlayerScreen did while up) completed — a
      // failure past this point isn't the stop-and-resolve-fresh setup
      // failing, so the catch block no longer needs to restart the preview.
      restorePreviewOnFailure = false;
      DiagnosticsLog.instance.add(
        'library',
        'fullscreen returned hotSwapped=$hotSwapped mounted=$mounted '
            'previewStream=${_preview.stream != null}',
      );
      if (!mounted) return;
      if (hotSwapped) {
        // The fullscreen player re-pointed this player's video output at the
        // Windows native HDR surface, which just tore down — no longer safe
        // to reuse for the preview's embedded texture.
        await _preview.discardPlayer();
      } else if (!resumePreviewOnReturn) {
        // Phone sheet handoff: nothing shows the preview after fullscreen.
        await _preview.stop(clearSelection: true);
      } else if (stopResolveFresh) {
        // Same-channel cross-engine stop is the one stop case that restarts: the
        // preview was stopped only to free the connection/token for the other
        // engine (Linux native mpv / iOS AVPlayer), not because the user left
        // the channel.
        await _preview.start(
          channel,
          muted: previewWasMuted,
          from: playRepo,
          bufferPreset: _bufferPresetForChannel(channel),
        );
      } else if (decision.seamless && _preview.stream != null) {
        await _preview.play();
        if (previewWasMuted) await _preview.setMuted(true);
      } else if (pausedPreview && _preview.stream != null) {
        // A same-channel non-adopted fullscreen paused the preview above; resume
        // it now that we're back (matches the catch-up path). A stopped preview
        // (different channel) is intentionally not restarted.
        await _preview.play();
      }
      // Only now: the restore above is the preview's own re-entry, and
      // `PlayerScreen.dispose` (which pauses the adopted player and drops its
      // `completed` subscription) is not guaranteed to have finished when the
      // route popped. Handing recovery back any earlier lets a `completed`
      // landing in that window restart the channel underneath the restore — and
      // on the `hotSwapped` branch, restart a player about to be discarded.
      _preview.adoptedByFullscreen = false;
      _restoreListFocusAfterPlayback();
    } catch (e) {
      if (restorePreviewOnFailure) {
        DiagnosticsLog.instance.add(
          'library',
          'fullscreen stop-resolve failed — restarting preview '
              'channel=${channel.id}',
        );
        try {
          await _preview.start(
            channel,
            muted: previewWasMuted,
            from: playRepo,
            bufferPreset: _bufferPresetForChannel(channel),
          );
        } catch (_) {}
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Could not play: ${redactText('$e')}')),
      );
    } finally {
      // Belt-and-braces for the throw-before-pop path: a preview left marked as
      // adopted would never recover from an EOF again.
      _preview.adoptedByFullscreen = false;
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Resolve [channel] and play it fullscreen directly, bypassing the preview
  /// flow (used by zap and the EPG grid).
  Future<void> _playChannelFullscreen(Channel channel) async {
    if (_resolving) return;
    // Set before the resolve (not just before the push): _openLivePlayer's
    // own guard only takes effect once it's called, and resolve() itself can
    // take a while (Stalker create_link), leaving a window for a second
    // activation to slip past the `if (_resolving) return` above and
    // double-push. _openLivePlayer's finally resets this once it runs; the
    // finally below only fires (i.e. `_resolving` is still true) when
    // resolve() itself threw before ever reaching it.
    setState(() => _resolving = true);
    final messenger = _messenger;
    try {
      final stream = await widget.repo.resolve(channel);
      if (!mounted) return;
      await _openLivePlayer(channel, stream, reusePreview: false);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not play: ${redactText('$e')}')),
      );
    } finally {
      if (mounted && _resolving) setState(() => _resolving = false);
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
    // The grid is single-source by construction: it takes one repository and
    // resolves every play through it, and its guide rows come from that
    // source's `programmes`. Handing it the cross-source list would show an
    // empty guide and then resolve a foreign channel against the wrong
    // provider, so that view opens the grid over the active source's channels
    // instead of its own rows.
    final channels = _categoryId == kAllSourcesFavoritesCategoryId
        ? _live.channels
        : _visible;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EpgGridScreen(
          repo: widget.repo,
          channels: channels,
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
    // The owning source. This path used to resolve every row through the
    // *active* repository, including a cross-source favorite — the "never
    // preview a foreign row" rule was enforced on the OK and hover paths but
    // not here, so a long-press in the cross-source view asked provider A for
    // provider B's channel id.
    final previewRepo = _repoForChannel(channel);
    final foreign = !identical(previewRepo, widget.repo);
    final previousFocus = FocusManager.instance.primaryFocus;
    unawaited(
      _preview.start(
        channel,
        muted: false,
        from: previewRepo,
        bufferPreset: _bufferPresetForChannel(channel),
      ),
    );
    // Set when Play hands the preview to fullscreen — the handoff owns the
    // preview's lifecycle from there (stopped when fullscreen exits), so the
    // post-sheet cleanup below must leave it alone.
    var handedOff = false;
    final epg = _epgFor(
      channel,
      foreign: foreign,
      sourceId: previewRepo.source.id,
    );
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
        // A cross-source row's guide and favorite state live under its own
        // source id, not the active controllers' — see `_epgFor`.
        now: epg.now,
        next: epg.next,
        // A cross-source row is favorited by definition when the sheet opens,
        // so `true` is the right *initial* value — the sheet keeps its own
        // optimistic state from there.
        favorite: foreign ? true : _isFavorite(ContentKind.live, channel.id),
        // A real toggle, not the list row's unfavorite-only action: the sheet
        // flips its own star, so wiring the row's callback here left a second
        // tap unable to put the favorite back — the star read "not favorited"
        // and tapping it did nothing.
        onToggleFavorite: () => foreign
            ? unawaited(
                _toggleForeignFavorite(previewRepo.source.id, channel.id),
              )
            : _toggleFavorite(ContentKind.live, channel.id),
        onCatchup: channel.hasArchive ? () => _showCatchupSheet(channel) : null,
        onPlay: () {
          final stream = _preview.stream;
          Navigator.of(sheetContext).pop();
          if (stream != null && _isPreviewing(channel)) {
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
                repo: previewRepo,
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
    final messenger = _messenger;
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
    final messenger = _messenger;
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
            bufferPreset: _bufferPresetForChannel(channel),
            epgNow: programme,
            // Catch-up is deliberately memoised under its own key rather than
            // the live channel's: an archive URL can be a different container
            // than the live one, and conflating them would let a catch-up
            // AVPlayer failure permanently downgrade the live channel to SDR
            // (or vice versa).
            iosEngineKey: 'catchup:${channel.id}',
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
    final messenger = _messenger;
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
    final messenger = _messenger;
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
            // Movies/series are always the active source — only live rows can
            // belong to another one.
            bufferPreset: bufferPresetFromName(widget.config.bufferPresetName),
            playback: PlaybackContext(
              db: widget.repo.db,
              sourceId: widget.repo.source.id,
              kind: item.kind,
              itemId: item.id,
              resumeFrom: resume?.position,
            ),
            iosEngineKey: item.id,
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
      // Without `isScrollControlled` a modal sheet is capped at 9/16 of the
      // screen height — 202 px on a 360-tall landscape phone, where the poster
      // alone is 180. The inner `SingleChildScrollView` still sizes to its
      // content, so a short movie sheet stays short; this only lifts the
      // ceiling for sheets that have something to show.
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxWidth: 720,
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
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
  bool _isWide() => mounted && isWideLayout(MediaQuery.sizeOf(context));

  /// The live tab's geometry, read from the **window** `MediaQuery`.
  ///
  /// This is the authority for the two lists' `itemExtent`s *and* for the
  /// coordinator's `index * extent` scroll maths (via [_liveChannelRowExtent] /
  /// [_liveCategoryRowExtent]). `LiveTabView.build` constructs the same metrics
  /// again to size the row *contents*; both must pass identical arguments —
  /// same window size, same `compactWideLayout`, same text scale — or the
  /// selection model scrolls by a height the rows aren't drawn at. A
  /// debug-only assert in `LiveTabView.build` compares the two.
  LiveLayoutMetrics get _liveLayoutMetrics => LiveLayoutMetrics.forSize(
    mounted ? MediaQuery.sizeOf(context) : const Size(1280, 720),
    compactWideLayout: defaultTargetPlatform == TargetPlatform.android,
    textScale: mounted ? MediaQuery.textScalerOf(context).scale(1) : 1.0,
  );

  bool get _liveRowsShowEpg => liveRowsShowEpg(
    categoryId: _categoryId,
    hasEpg: _live.now.isNotEmpty,
    hasCrossSourceEpg: _globalFavorites.hasEpg,
  );

  double _liveChannelRowExtent() =>
      _liveLayoutMetrics.channelRowExtent(_liveRowsShowEpg);

  /// The row extent the live list was last built with, so a change in it can
  /// re-reveal the selection.
  double? _lastLiveRowExtent;

  /// Re-reveal the selected row when the row *height* changes underneath it.
  ///
  /// The live list scrolls by exact `index * itemExtent` arithmetic, so the
  /// offset is only correct for the extent it was computed against. Rows are
  /// 72px without an EPG line and 112 with one, and **`_liveRowsShowEpg` can
  /// flip after the rows are already on screen** — most visibly in the
  /// cross-source Favorites view, whose guide is fetched separately
  /// (`GlobalFavoritesController.hasEpg`) and lands after the list is built.
  ///
  /// The symptom is precise and was reported as such: the cursor is on the
  /// right channel, the list is scrolled to the wrong place, and one press of
  /// Up or Down snaps it back — because that press re-reveals against the
  /// extent the rows now actually have. The error grows with the row index,
  /// which is why it reads as "the highlighted channel isn't centred".
  ///
  /// Deliberately post-frame: the reveal has to run *after* the list has been
  /// rebuilt with the new `itemExtent`, or it computes against the old geometry
  /// again. The first observation only records the extent — there is nothing to
  /// correct before a list exists.
  void _resyncLiveRowExtent() {
    final extent = _liveChannelRowExtent();
    final previous = _lastLiveRowExtent;
    if (previous == extent) return;
    _lastLiveRowExtent = extent;
    if (previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.revealSelectedChannel();
    });
  }

  double _liveCategoryRowExtent() => _liveLayoutMetrics.categoryRowExtent;

  /// The last geometry line written, so an unchanged window logs once rather
  /// than once per build.
  String? _loggedLayout;

  /// Deliberately **not** called from `build`. `DiagnosticsLog` is a
  /// `ChangeNotifier` and the diagnostics screen listens to it, so writing a
  /// line mid-build can `markNeedsBuild` a widget this frame has already
  /// built — the classic "setState called during build" assertion, reachable
  /// by resizing the window while the diagnostics screen is open. Dependency
  /// changes are exactly when the geometry moves, and this hook runs outside
  /// the build phase.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _logLayoutGeometry();
  }

  /// Records the window geometry the layout decisions are made from.
  ///
  /// Everything about which browsing UI appears turns on **logical** width
  /// ([kWideLayoutMinWidth], 950): the category side-pane, the live preview
  /// panel, and therefore whether the shared-engine preview path exists at all.
  /// Logical width is physical pixels divided by the device pixel ratio, which
  /// is exactly the quantity a screenshot cannot show — a 3840 px TV reports
  /// 960 at dpr 4.0 and 873 at dpr 4.4, and only one of those gets the two-pane
  /// layout. An export that says the app rendered the phone layout, without
  /// saying what it measured to decide that, sends the reader looking for a
  /// missing category list that was never missing.
  void _logLayoutGeometry() {
    final size = MediaQuery.sizeOf(context);
    final line =
        'layout window=${size.width.toStringAsFixed(0)}x'
        '${size.height.toStringAsFixed(0)} '
        'dpr=${MediaQuery.devicePixelRatioOf(context).toStringAsFixed(2)} '
        'textScale=${MediaQuery.textScalerOf(context).scale(1).toStringAsFixed(2)} '
        'wide=${isWideLayout(size)} tv=$isTelevision';
    if (line == _loggedLayout) return;
    _loggedLayout = line;
    DiagnosticsLog.instance.addAndPrint('library', line);
  }

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
      _messenger
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
    // **A messenger scoped to this screen**, not `MaterialApp`'s.
    //
    // The app-level messenger lives *above* the Navigator, so anything it is
    // showing survives a route push and keeps painting over whatever comes
    // next — the Continue-watching "Undo" snackbar was observed sitting on top
    // of fullscreen live TV on an unrelated channel, offering to undo
    // something the user could no longer see. Owning a messenger here puts
    // these snackbars *below* the route that pushes `PlayerScreen`, so opening
    // the player covers them instead of carrying them along, and returning
    // still finds one that hasn't timed out.
    return ScaffoldMessenger(
      key: _messengerKey,
      child: PopScope(
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
                    IconButton(
                      tooltip: 'Help & about',
                      icon: const Icon(Icons.help_outline),
                      onPressed: () async {
                        await _preview.stop();
                        if (!context.mounted) return;
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const LegalScreen(),
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
                                (_tab != ContentKind.live &&
                                    _media(_tab).loading)
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
          //
          // Edge-to-edge (targetSdk 35+): SafeArea shrinks the body's constraints,
          // so the live list's Expanded viewport ends above/beside the system bar.
          // That is what keeps LiveFocusCoordinator._reveal correct — it scrolls a
          // selected row to `viewportDimension`, so the viewport itself must
          // exclude the inset or the selected row lands underneath the bar.
          // Insets are zero on Android TV, so this is a no-op there.
          body: SafeArea(
            top: false,
            child: FocusTraversalGroup(
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
                  isWideLayout(MediaQuery.sizeOf(context)))
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
            categoryFilterActive: _media(_tab).categoryId != null,
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
            onRestoreContinueWatching: (entry) =>
                _media(_tab).restoreContinueWatching(entry),
          );
  }

  /// Overlays the digit-entry "Ch 123" chip while the user is typing a
  /// channel number on the remote (see [LiveFocusCoordinator.digitBuffer]).
  ///
  /// [body] is passed through as the builder's `child`, so typing digits
  /// repaints the chip only — never the channel list underneath it.
  Widget _withDigitEntryChip(Widget body) {
    return ListenableBuilder(
      listenable: _focus.digitEntry,
      child: body,
      builder: (context, child) {
        if (_focus.digitBuffer.isEmpty) return child!;
        return Stack(
          children: [
            child!,
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
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
      },
    );
  }

  Widget _buildLiveBody(List<Channel> visible) {
    final crossSourceView = _categoryId == kAllSourcesFavoritesCategoryId;
    // Row height can change under a selection that never moved — see
    // [_resyncLiveRowExtent]. Checked here because this is the one place that
    // knows the extent the list is about to be built with.
    _resyncLiveRowExtent();
    return LiveTabView(
      loading: _live.loading,
      error: _live.error,
      onRetry: () => _loadLive(forceRefresh: true),
      visible: visible,
      searchActive: _query.trim().length >= 2,
      // Only the cross-source view labels its rows; elsewhere every row belongs
      // to the active source and the chip would say the same thing on all of
      // them.
      sourceLabelFor: _categoryId == kAllSourcesFavoritesCategoryId
          ? (channel) => _crossSourceFavoriteFor(channel)?.sourceLabel
          : null,
      // Resolved inside the preview pane's own rebuild: on a TV remote the
      // panel follows the channel cursor, and the cursor now moves without
      // rebuilding this method.
      resolvePreviewChannel: () => _resolvePreviewChannel(visible),
      // These maps are the *active* source's, keyed by channel id — which a
      // foreign row can collide with, so the cross-source view must never be
      // handed them. Its own guide arrives through `epgFor` below, keyed by
      // (source, channel), where there is no collision to have.
      //
      // Gated on the *same* predicate as the row extent, not a parallel test —
      // `LiveTabView` asserts that its `itemExtent` matches the layout it
      // computes from `showsEpg`, so these must be incapable of drifting apart
      // rather than merely agreeing today.
      now: crossSourceView || !_liveRowsShowEpg ? const {} : _live.now,
      next: crossSourceView || !_liveRowsShowEpg ? const {} : _live.next,
      showsEpg: _liveRowsShowEpg,
      epgFor: crossSourceView ? _crossSourceEpgFor : null,
      deliberate: _deliberatePreview,
      resolving: _resolving,
      scrollController: _scrollController,
      categoryScrollController: _categoryScrollController,
      focus: _focus,
      channelRowExtent: _liveChannelRowExtent(),
      categoryRowExtent: _liveCategoryRowExtent(),
      lastPlayedChannelId: _lastPlayedLiveChannelId,
      previewChannelId: _preview.channelId,
      // Source-aware, for the cross-source view: two providers can both carry
      // a channel with this id, and only one of them is previewing.
      isPreviewingRow: _isPreviewing,
      // In the cross-source view a row's favorite state belongs to *its* source,
      // not the active one. Reading it from `FavoritesController` (keyed to the
      // active source) drew every foreign row with an empty star, and toggling
      // wrote a phantom favorite under the wrong source id — which the delta
      // push would then have sent to the cloud.
      isFavorite: crossSourceView
          ? (id) => true
          : (id) => _isFavorite(ContentKind.live, id),
      onToggleFavorite: crossSourceView
          ? (id) => unawaited(_unfavoriteCrossSourceRow(id))
          : (id) => _toggleFavorite(ContentKind.live, id),
      onPlayChannel: _play,
      onPreviewChannel: (channel) => unawaited(_showPreviewSheet(channel)),
      onCatchup: _showCatchupSheet,
      categories: _liveCategoriesForUi,
      selectedCategoryId: _categoryId,
      onCategorySelected: _selectCategory,
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
    final crossSourceView = _categoryId == kAllSourcesFavoritesCategoryId;
    // In the cross-source view the rows are not the active source's catalog, so
    // `_channelsById` cannot find them — it would miss every foreign row and
    // fall through to `visible.first`, leaving the panel pointed at whatever
    // happens to be at the top. The favorites list is small enough to scan, and
    // [preferSourceId] breaks the tie when two providers share an id.
    Channel? byId(String? id, {String? preferSourceId}) {
      if (id == null) return null;
      if (!crossSourceView) return _channelsById[id];
      Channel? sameIdOtherSource;
      for (final item in _globalFavorites.items) {
        if (item.channel.id != id) continue;
        if (preferSourceId == null || item.sourceId == preferSourceId) {
          return item.channel;
        }
        sameIdOtherSource ??= item.channel;
      }
      return sameIdOtherSource;
    }

    final previewSourceId = _preview.previewSourceId;
    if (_deliberatePreview) {
      // When a preview is actively running (or loading), lock the panel to
      // that channel.  D-pad focus moves away without disrupting it.
      final previewActive = _preview.stream != null || _preview.loading;
      return byId(
            previewActive ? _preview.channelId : null,
            preferSourceId: previewSourceId,
          ) ??
          byId(_focus.selectedChannelId) ??
          byId(_preview.channelId, preferSourceId: previewSourceId) ??
          byId(_lastPlayedLiveChannelId) ??
          visible.first;
    }
    return byId(_preview.channelId, preferSourceId: previewSourceId) ??
        byId(_lastPlayedLiveChannelId) ??
        visible.first;
  }
}
