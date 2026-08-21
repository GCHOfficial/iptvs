import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../sources/source.dart';
import '../theme.dart';
import '../widgets/favorite_controls.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';
import 'live_focus_coordinator.dart';
import 'live_preview_controller.dart';

// ── Shared EPG wording ───────────────────────────────────────────────────────
// One home for how the current/next programme reads, so the channel list, the
// wide preview panel, and the phone preview sheet all use the same terms. Change
// the label here and every surface follows.

String _epgTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The current-programme label (leads with the show so a long channel name
/// can't crowd it out): e.g. `Now · The Morning Show`.
String nowProgrammeLabel(Programme p) => 'Now · ${p.title}';

/// The next-programme label: e.g. `Next · News at Nine`.
String nextProgrammeLabel(Programme p) => 'Next · ${p.title}';

/// A programme's clock range, e.g. `20:00 – 21:00`.
String programmeTimeRange(Programme p) =>
    '${_epgTime(p.start)} – ${_epgTime(p.stop)}';

// ── Uniform row heights ──────────────────────────────────────────────────────
// The channel list and category sidebar are navigated by a *selection cursor*
// (see [LiveFocusCoordinator]), which scrolls by computing `index * extent`.
// That only works if rows are a uniform, known height — so both lists set an
// explicit `itemExtent` instead of sizing to their content. Channel rows come in
// two sizes: with EPG (name + now/next + progress) and without.

/// Channel row height when the source has EPG (now/next lines).
const double kChannelRowExtentWithEpg = 112;

/// Channel row height when there's no EPG to show (logo + name only).
const double kChannelRowExtentPlain = 72;

/// Category sidebar row height. 48, not the visually sufficient 44, because the
/// row draws a 2 px gap above and below itself inside the extent — 48 − 4 is
/// exactly the 44 px minimum pointer target the row's hit area must keep.
const double kCategoryRowExtent = 48;

/// Vertical gap drawn *inside* [kCategoryRowExtent] (and its scaled variants),
/// so the extent the selection model scrolls by and the row's hit area differ
/// by exactly `2 * this`.
const double kCategoryRowGap = 2;

/// Viewport height below which a layout compresses its row/preview geometry.
/// Applies to the wide (TV/desktop) layout *and* to a short **narrow** one — an
/// 800x360 landscape phone is not a "phone portrait", and at full density it
/// showed two channel rows. Phone portrait stays at scale 1 (see
/// docs/tv-navigation.md).
const double kShortViewportMaxHeight = 560;

/// Upper bound on the accessibility text scale the live layout tracks. Beyond
/// this the fixed-extent lists would eat the whole viewport; the text itself
/// still scales past it (Flutter owns that), the *row heights* just stop
/// growing, and the row's own `maxLines`/ellipsis absorb the rest.
const double kMaxLiveTextScale = 1.4;

// Line heights of a channel row's fixed-size lines at text scale 1.
//
// **These are a hint, not a guarantee.** The row cannot overflow whatever they
// say — `_ChannelTile` lays its text column out unconstrained inside a
// `ClipRect`, so a wrong number here costs at most a sub-pixel clip. All they
// decide is *when the "Next" line is dropped* ([LiveLayoutMetrics.denseChannelRow]).
//
// They used to use a 1.3 factor on the theory that the bundled Inter is ~1.21.
// Measured against the real font (a widget test that loads `Inter` and reads
// the laid-out `RenderParagraph` heights back — `test/layout_overflow_test.dart`),
// a 12.5 px run lays out at 18 px and an 11.5 px one at 16 px: Inter's real
// ratio is ~1.41, *and* the engine rounds each line's ascent and descent to
// whole logical pixels on top of that. 1.3 was therefore short by ~1.5 px a
// line, which is how a four-line row that the metrics called "fits" overflowed
// its extent. 1.45 covers both effects at the sizes this row uses.
const double _kNowLineHeight = 12.5 * 1.45;
const double _kMetaLineHeight = 11.5 * 1.45;

/// Gap between two of a channel row's text lines. Three of them separate the
/// four lines, so this is also the row's cheapest source of vertical slack —
/// 4 → 3 bought back the 3 px the corrected line-height factors above cost,
/// keeping the "Next" line on windows that used to keep it.
const double _kRowLineGap = 3.0;

/// The row's own vertical chrome inside the extent: the 3 px gap above/below,
/// the tile's inner padding, and its border.
///
/// The border term is a flat 2 (1 px a side) and **does not vary with the
/// cursor**: the accent focus ring is painted as a `foregroundDecoration`, which
/// costs no layout, precisely so the selected row's content box is the same size
/// as every other row's. It previously reserved the focused 2-px-a-side width
/// instead, which is a fair description of what the old ring cost but left every
/// *unselected* row 2 px of dead space.
double _rowChrome(bool compact) => 6 + (compact ? 12 : 16) + 2;

/// The channel row height for a list that does ([hasEpg]) or doesn't carry EPG.
double channelRowExtentFor(bool hasEpg) =>
    hasEpg ? kChannelRowExtentWithEpg : kChannelRowExtentPlain;

/// Test seam: when true, channel logos render their fallback instead of loading
/// through `CachedNetworkImage`/`flutter_cache_manager`. Widget tests that build
/// the live list set this so the cache manager's `path_provider` calls and its
/// cleanup `Timer` (both hostile to `flutter test`) never run. Off in
/// production.
@visibleForTesting
bool debugDisableNetworkChannelLogos = false;

/// Bounded density for wide browsing layouts.
///
/// Android TV can expose either 960×540 or 1920×1080 logical viewports for a 4K
/// panel. Fixed desktop dimensions make the preview and chrome too large in
/// both cases, so Android wide layouts request compact geometry explicitly.
/// Other platforms still scale only when their viewport is short. Minimum
/// D-pad targets and Flutter's accessibility text scale remain untouched.
@immutable
class LiveLayoutMetrics {
  final double scale;

  /// The accessibility text scale the extents were built for, clamped to
  /// `[1, kMaxLiveTextScale]`. Stored so a row can size anything else it draws
  /// against the *same* number the extent used.
  final double textScale;
  final double previewHeight;
  final double previewWidth;
  final double categoryPaneWidth;
  final double channelRowExtentPlain;
  final double channelRowExtentWithEpg;
  final double categoryRowExtent;
  final double outerPadding;
  final double paneGap;
  final double panelPadding;
  final double titleSize;
  final double infoSize;

  /// Font size for a channel row's name. Density-scaled like everything else —
  /// it used to be the theme's fixed 16 px `titleMedium` while the extent
  /// around it shrank, which is where the compact row lost most of its
  /// headroom. Text *scaling* is not applied here: Flutter already scales the
  /// glyphs, and the extent grows by [textScale] to make room.
  final double rowTitleSize;

  /// True only for the **ten-foot** density (the Android-TV compact wide
  /// layout), as opposed to [compact], which is just "something shrank".
  ///
  /// The two used to be the same thing, and then short-viewport scaling made
  /// `compact` true for an 800x360 landscape phone and a 1280x600 desktop
  /// window as well — both of which are pointer/touch postures. Anything
  /// deciding *input-modality* affordances (rather than density) has to ask
  /// this instead; see [favoriteTargetSize].
  final bool tenFootUi;

  const LiveLayoutMetrics._({
    required this.scale,
    required this.textScale,
    required this.tenFootUi,
    required this.previewHeight,
    required this.previewWidth,
    required this.categoryPaneWidth,
    required this.channelRowExtentPlain,
    required this.channelRowExtentWithEpg,
    required this.categoryRowExtent,
    required this.outerPadding,
    required this.paneGap,
    required this.panelPadding,
    required this.titleSize,
    required this.infoSize,
    required this.rowTitleSize,
  });

  /// Geometry for a live body of [size].
  ///
  /// [textScale] is the platform's accessibility text scale
  /// (`MediaQuery.textScalerOf(context).scale(1)`). **Every construction site
  /// must pass the same value**: the channel list's `itemExtent` and the
  /// coordinator's `index * extent` scroll maths are two reads of this same
  /// pure function, and the selection model breaks the moment they disagree.
  /// Row extents (and the paddings around them) are multiplied by it *after*
  /// the density clamps, so a larger system font grows the rows instead of
  /// overflowing them — Android's first step is already 1.15 and iOS reaches
  /// 1.35, against a compact row that had ~3% headroom.
  factory LiveLayoutMetrics.forSize(
    Size size, {
    bool compactWideLayout = false,
    double textScale = 1.0,
  }) {
    final isWide = size.width >= kWideLayoutMinWidth;
    final short = size.height < kShortViewportMaxHeight;
    // Height compression is not a wide-layout privilege: an 800x360 landscape
    // phone is short for exactly the same reason a 1280x600 desktop window is,
    // and at full density it fitted two channel rows. Phone *portrait* (tall
    // and narrow) still gets the unscaled geometry.
    final scale = isWide
        ? compactWideLayout
              ? 0.625
              : (size.height / 720).clamp(0.75, 1.0)
        : short
        ? (size.height / 720).clamp(0.75, 1.0)
        : 1.0;
    final text = textScale.clamp(1.0, kMaxLiveTextScale);
    return LiveLayoutMetrics._(
      scale: scale,
      textScale: text,
      tenFootUi: isWide && compactWideLayout,
      previewHeight: (190 * scale).clamp(120, 190) * text,
      previewWidth: (250 * scale).clamp(170, 250),
      categoryPaneWidth: (240 * scale).clamp(180, 240),
      channelRowExtentPlain:
          (kChannelRowExtentPlain * scale).clamp(56, 72) * text,
      channelRowExtentWithEpg:
          (kChannelRowExtentWithEpg * scale).clamp(88, 112) * text,
      categoryRowExtent:
          (kCategoryRowExtent * scale).clamp(40, kCategoryRowExtent) * text,
      outerPadding: (12 * scale).clamp(8, 12),
      paneGap: (12 * scale).clamp(8, 12),
      panelPadding: (14 * scale).clamp(10, 14) * text,
      titleSize: (24 * scale).clamp(20, 24),
      infoSize: (16 * scale).clamp(13, 16),
      rowTitleSize: (16 * scale).clamp(13, 16),
    );
  }

  /// Side of the channel logo / number badge.
  ///
  /// Derived from the row it sits in rather than fixed at 36/40, so it grows
  /// with the taller EPG row — and with density and text scaling — instead of
  /// being dwarfed by it. The floor keeps the *plain* row's badge at roughly
  /// its previous size (that row's content box is only ~48 px, so a
  /// proportional value there would shrink it), and the ceiling stops the
  /// badge from ever being what makes a row overflow.
  double logoSize(bool hasEpg) =>
      ((channelRowExtent(hasEpg) - _rowChrome(compact)) * 0.62).clamp(
        36.0,
        60.0,
      );

  double channelRowExtent(bool hasEpg) =>
      hasEpg ? channelRowExtentWithEpg : channelRowExtentPlain;

  bool get compact => scale < 0.95;

  /// Stacked height the *four*-line EPG row (name / now / time+progress /
  /// next) needs at this density and text scale.
  double get _epgRowContentHeight =>
      _rowChrome(compact) +
      (rowTitleSize * 1.5 +
              _kNowLineHeight +
              _kMetaLineHeight * 2 +
              _kRowLineGap * 3) *
          textScale;

  /// Whether the channel row must drop its "Next" line to fit its extent.
  ///
  /// This is a **content-height** test, not `extent < kChannelRowExtentWithEpg`.
  /// That older test fired on *any* reduction, so a 700 px-tall desktop window
  /// — with ~19 px of room to spare — silently lost the line; and it would now
  /// fire backwards under text scaling, where the extent grows past the
  /// baseline while the text grows faster.
  bool get denseChannelRow => channelRowExtentWithEpg < _epgRowContentHeight;

  /// Side of the favorite star's hit area. 44 (the platform minimum pointer
  /// target) wherever a pointer is plausible; the compact row is 56 px tall and
  /// remote-only, so it keeps the tighter 32 that fits it.
  /// Hit area for the row's favourite star.
  ///
  /// Gated on [tenFootUi], **not** [compact]: 44 is the touch minimum and the
  /// star sits beside a row whose tap starts fullscreen playback on a phone,
  /// so a miss is expensive. Only the ten-foot layout drops to 32 — there the
  /// input is a remote, where hit area is meaningless, and 44 doesn't fit the
  /// 56 px row anyway. Reading `compact` here silently gave the 32 px target
  /// to landscape phones once short-viewport scaling landed, which is the one
  /// posture that most needed the big one.
  double get favoriteTargetSize => (tenFootUi ? 32.0 : 44.0) * textScale;
}

/// The live-TV browsing body: the channel list (with the category side-pane and
/// preview panel on wide layouts, plain list on phones), plus its D-pad focus
/// wiring. Extracted from `ChannelListScreen`'s State as a widget with an
/// explicit contract so it rebuilds independently; the preview player, focus
/// nodes, and D-pad handlers stay owned by the screen and are injected here.
///
/// D-pad note: the two lists are **selection models**, not collections of focus
/// nodes. Each has a single [FocusNode] and highlights the row at its selected
/// index; rows themselves are not focusable (they stay tappable for touch).
///
/// Rebuild note: the three panes each sit in their **own** [ListenableBuilder]
/// over a narrow slice of [LiveFocusCoordinator]
/// ([LiveFocusCoordinator.categorySelection] / `previewRegion` /
/// `channelSelection`). That is why the cursor state is read live off [focus]
/// rather than passed in as a snapshot: one D-pad press must repaint only the
/// pane(s) that actually changed, not the whole live body. See
/// docs/tv-navigation.md.
class LiveTabView extends StatelessWidget {
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  final List<Channel> visible;

  /// True when a live search query (>= 2 chars) is active, mirroring
  /// `MediaTabView.showingSearch`. Combined with [selectedCategoryId] to
  /// decide the empty-state wording below: a genuinely unfiltered-empty
  /// source ("this provider returned nothing") reads very differently from a
  /// filtered-empty one ("nothing matches"). Defaults to false — the live
  /// tab's search text lives in `ChannelListScreen`, which this view does not
  /// own; wire this through from the caller alongside the search box.
  final bool searchActive;

  /// Resolves the preview target (null only when [visible] is empty). A
  /// callback, not a value: on a TV remote the panel follows the channel
  /// cursor, so it must be re-resolved inside the preview pane's own rebuild.
  final Channel? Function() resolvePreviewChannel;
  final Map<String, Programme> now;
  final Map<String, Programme> next;

  /// Owning-source name for a row, or null to show no chip. Non-null only in
  /// the cross-source Favorites view — see [_ChannelTile.sourceLabel].
  final String? Function(Channel channel)? sourceLabelFor;

  final bool deliberate;
  final bool resolving;
  final ScrollController scrollController;

  /// Scroll controller for the category sidebar; the coordinator drives it.
  final ScrollController categoryScrollController;

  /// The live tab's selection model: both lists' single D-pad nodes, their
  /// selected indices, the intra-row [ChannelRowColumn], the key handlers, and
  /// the narrow listenables the three panes subscribe to. Owned (created and
  /// disposed) by the screen; read-only here.
  final LiveFocusCoordinator focus;

  /// Uniform channel row height (see [channelRowExtentFor]) — must match what
  /// the coordinator uses for its scroll math.
  final double channelRowExtent;
  final double categoryRowExtent;

  final String? lastPlayedChannelId;
  final String? previewChannelId;

  final bool Function(String id) isFavorite;
  final ValueChanged<String> onToggleFavorite;
  final ValueChanged<Channel> onPlayChannel;

  /// Phone-only: opens the audible preview sheet for a long-pressed channel
  /// row (the sheet carries Play, favorite and catch-up). Wide layouts have
  /// the preview panel instead, so long-press does nothing there.
  final ValueChanged<Channel> onPreviewChannel;

  /// Opens catch-up for a channel (called only for archive-capable channels).
  final ValueChanged<Channel> onCatchup;

  final List<Category> categories;

  /// The *active* filter (bolded), which is not necessarily where the D-pad
  /// cursor sits — Back moves the cursor without changing the filter.
  final String? selectedCategoryId;

  final ValueChanged<String?> onCategorySelected;

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
    this.searchActive = false,
    this.sourceLabelFor,
    required this.resolvePreviewChannel,
    required this.now,
    required this.next,
    required this.deliberate,
    required this.resolving,
    required this.scrollController,
    required this.categoryScrollController,
    required this.focus,
    required this.channelRowExtent,
    required this.categoryRowExtent,
    required this.lastPlayedChannelId,
    required this.previewChannelId,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onPlayChannel,
    required this.onPreviewChannel,
    required this.onCatchup,
    required this.categories,
    required this.selectedCategoryId,
    required this.onCategorySelected,
    required this.previewVideoBuilder,
    required this.previewLoading,
    required this.previewError,
  });

  /// Touch/mouse: move the D-pad cursor onto a tapped row before acting on it,
  /// so the cursor and the pointer never disagree.
  void _selectChannelIndex(int i) => focus.selectChannel(i, reveal: false);

  /// The channel list. One [Focus] owns the whole list's D-pad
  /// ([LiveFocusCoordinator.handleChannelsKey]); rows are plain, non-focusable
  /// widgets highlighted at the coordinator's selected index. `itemExtent` keeps
  /// rows uniform so the coordinator's `index * extent` scroll math is exact.
  ///
  /// The [ListenableBuilder] sits *inside* the [Focus] (so the node and its
  /// autofocus are never churned) and subscribes only to
  /// [LiveFocusCoordinator.channelSelection]: a category-cursor move or a digit
  /// keypress must not rebuild these rows.
  Widget _buildChannelList(
    BuildContext context,
    LiveLayoutMetrics metrics, {
    required bool wide,
    EdgeInsets padding = const EdgeInsets.fromLTRB(12, 4, 12, 16),
  }) {
    return Focus(
      focusNode: focus.channelsFocusNode,
      autofocus: true,
      onKeyEvent: focus.handleChannelsKey,
      child: ListenableBuilder(
        listenable: focus.channelSelection,
        builder: (context, _) {
          final selected = focus.selectedChannelIndex;
          final onFavoriteColumn =
              focus.channelColumn == ChannelRowColumn.favorite;
          final listFocused = focus.channelsFocusNode.hasFocus;
          return ListView.builder(
            controller: scrollController,
            padding: padding,
            itemExtent: channelRowExtent,
            itemCount: visible.length,
            semanticChildCount: visible.length,
            itemBuilder: (context, i) {
              final c = visible[i];
              return IndexedSemantics(
                index: i,
                child: _ChannelTile(
                  channel: c,
                  sourceLabel: sourceLabelFor?.call(c),
                  now: now[c.id],
                  next: next[c.id],
                  favorite: isFavorite(c.id),
                  enabled: !resolving,
                  position: i + 1,
                  total: visible.length,
                  metrics: metrics,
                  // The cursor is drawn even when the list doesn't own the
                  // D-pad — subdued rather than accented — so you can always see
                  // where you'll land when you come back, while the *accent*
                  // clearly marks which pane the D-pad is actually in.
                  cursor: i == selected,
                  favoriteCursor: i == selected && onFavoriteColumn,
                  listFocused: listFocused,
                  previewing: c.id == previewChannelId,
                  onTap: () {
                    _selectChannelIndex(i);
                    onPlayChannel(c);
                  },
                  onToggleFavorite: () {
                    _selectChannelIndex(i);
                    onToggleFavorite(c.id);
                  },
                  // Phone: long-press opens the audible preview sheet (it
                  // carries Play, favorite and catch-up). Wide layouts already
                  // have the preview panel, so long-press does nothing there.
                  onLongPress: wide
                      ? null
                      : () {
                          _selectChannelIndex(i);
                          onPreviewChannel(c);
                        },
                ),
              );
            },
          );
        },
      ),
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
    // **Not an early return.** On a wide layout the only UI that can change
    // the category is the sidebar — `ChannelListScreen` nulls the toolbar
    // dropdown whenever live && wide — so returning a bare `Center` here
    // unmounted the sidebar along with the list and left *no* way back: every
    // caller of `_selectCategory` was gone, and `focusCategories()` then
    // requested focus on a node with no context, which is a silent no-op.
    // Picking a provider category that happens to have zero channels (common
    // on portals) became unrecoverable short of restarting the app. The empty
    // message is a *body* that replaces the list, not the whole tab.
    Widget? emptyBody;
    if (visible.isEmpty) {
      final filtered = searchActive || selectedCategoryId != null;
      emptyBody = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            filtered
                ? 'No channels match'
                : 'This source has no channels — try Reload from the '
                      'toolbar or check the source.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textLo),
          ),
        ),
      );
    }
    final size = MediaQuery.sizeOf(context);
    // Computed once here rather than per row in [_ChannelTile.build]: it is the
    // same value for every row (it only reads the window size), and resolving it
    // per row also made every row a MediaQuery dependent.
    //
    // **The same inputs as `ChannelListScreen._liveLayoutMetrics`.** That one
    // feeds [channelRowExtent]/[categoryRowExtent] (this list's `itemExtent`)
    // *and* the coordinator's `index * extent` scroll maths; this one sizes the
    // row's contents. Both read the window `MediaQuery` — nothing in `lib/`
    // installs a modified `MediaQuery` between the screen and here — so the two
    // calls are the same pure function of the same values. The assert below
    // fails loudly (debug-only) the first time that stops being true.
    final metrics = LiveLayoutMetrics.forSize(
      size,
      compactWideLayout: defaultTargetPlatform == TargetPlatform.android,
      textScale: MediaQuery.textScalerOf(context).scale(1),
    );
    assert(
      channelRowExtent == metrics.channelRowExtent(now.isNotEmpty) &&
          categoryRowExtent == metrics.categoryRowExtent,
      'live row extents disagree: itemExtent/coordinator got '
      '$channelRowExtent/$categoryRowExtent, the row layout computed '
      '${metrics.channelRowExtent(now.isNotEmpty)}/${metrics.categoryRowExtent}. '
      'The selection model scrolls by index * extent, so these must be one '
      'value — see LiveLayoutMetrics.forSize.',
    );
    // **One width authority for the whole live tab.** Everything else that
    // branches on "wide" reads the *window* width through `MediaQuery`:
    // `ChannelListScreen._isWide()` (which the coordinator takes as its `isWide`
    // callback, so it decides where Up escapes to and whether Left/Back reach
    // the sidebar), `_play` (wide = preview-first, phone = straight to
    // fullscreen), the long-press gate below, and `LiveLayoutMetrics.forSize`
    // itself. This used to be a `LayoutBuilder` reading `constraints.maxWidth`
    // instead — the body's *own* width, which the screen's `SafeArea` shrinks by
    // the left/right system-bar and cutout insets in Android landscape. A window
    // just over `kWideLayoutMinWidth` therefore rendered the **phone** layout
    // while every other branch still believed it was wide, and that band was a
    // dead zone: no preview panel and no long-press sheet (so the preview was
    // unreachable), a tap starting an audible preview with nothing on screen to
    // show it, and — worst — the Back ladder stalling forever at rung 2, because
    // `focusCategories()` requested focus on a sidebar node that was never built.
    // A body narrower than the window now simply renders the two-pane layout a
    // little tighter, which is what the rest of the screen already assumes.
    if (size.width < kWideLayoutMinWidth) {
      // Narrow keeps the old behaviour: the toolbar dropdown is still mounted
      // here, so the category remains changeable with the list gone.
      return emptyBody ?? _buildChannelList(context, metrics, wide: false);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        metrics.outerPadding,
        4,
        metrics.outerPadding,
        8,
      ),
      child: Row(
        children: [
          SizedBox(
            width: metrics.categoryPaneWidth,
            // Only the category cursor + the sidebar's own focus repaint
            // this pane; walking the channel list must not.
            child: ListenableBuilder(
              listenable: focus.categorySelection,
              builder: (context, _) => _LiveCategoryPane(
                categories: categories,
                selectedCategoryId: selectedCategoryId,
                selectedIndex: focus.selectedCategoryIndex,
                focusNode: focus.categoriesFocusNode,
                onKey: focus.handleCategoriesKey,
                scrollController: categoryScrollController,
                onSelected: onCategorySelected,
                onSelectIndex: (i) => focus.selectCategory(i, reveal: false),
                rowExtent: categoryRowExtent,
              ),
            ),
          ),
          SizedBox(width: metrics.paneGap),
          Expanded(
            child: Column(
              children: [
                // The panel follows the channel cursor (it shows the
                // selected channel until a preview locks it) and its own
                // controls' focus — but not which list holds the D-pad.
                ListenableBuilder(
                  listenable: focus.previewRegion,
                  builder: (context, _) => _buildPreviewPanel(context, metrics),
                ),
                SizedBox(height: metrics.paneGap),
                Expanded(
                  // The sidebar above stays mounted either way; only this
                  // slot swaps to the message. Deliberately *not*
                  // `_buildChannelList` over an empty list — that node
                  // handles no keys, so arrows would escape to geometry
                  // traversal instead of staying in the live body.
                  child:
                      emptyBody ??
                      _buildChannelList(
                        context,
                        metrics,
                        wide: true,
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPanel(BuildContext context, LiveLayoutMetrics metrics) {
    // Null is a live path, not just defensiveness: the wide layout now keeps
    // the sidebar (and this panel) mounted while the channel list is empty, so
    // an empty category reaches here with nothing to resolve.
    final preview = resolvePreviewChannel();
    if (preview == null) return SizedBox(height: metrics.previewHeight);
    return _LivePreviewPanel(
      channel: preview,
      now: now[preview.id],
      next: next[preview.id],
      previewVideo: previewVideoBuilder(),
      previewActive: previewChannelId == preview.id,
      previewLoading: previewLoading && previewChannelId == preview.id,
      previewError: previewChannelId == preview.id ? previewError : null,
      deliberate: deliberate,
      favorite: isFavorite(preview.id),
      onToggleFavorite: () => onToggleFavorite(preview.id),
      onCatchup: preview.hasArchive ? () => onCatchup(preview) : null,
      favoriteFocusNode: focus.previewFavoriteFocusNode,
      catchupFocusNode: focus.previewCatchupFocusNode,
      onControlKey: focus.handlePreviewControlKey,
      metrics: metrics,
    );
  }
}

/// The category sidebar as a selection model: a single [FocusNode] owns the
/// D-pad, rows are plain widgets highlighted at [selectedIndex]. The *active
/// filter* ([selectedCategoryId]) is a separate, bolded state — Back moves the
/// cursor without changing the filter, so the two must be drawn differently.
class _LiveCategoryPane extends StatelessWidget {
  final List<Category> categories;
  final String? selectedCategoryId;
  final int selectedIndex;
  final FocusNode focusNode;
  final KeyEventResult Function(FocusNode, KeyEvent) onKey;
  final ScrollController scrollController;
  final ValueChanged<String?> onSelected;
  final ValueChanged<int> onSelectIndex;
  final double rowExtent;

  const _LiveCategoryPane({
    required this.categories,
    required this.selectedCategoryId,
    required this.selectedIndex,
    required this.focusNode,
    required this.onKey,
    required this.scrollController,
    required this.onSelected,
    required this.onSelectIndex,
    required this.rowExtent,
  });

  @override
  Widget build(BuildContext context) {
    final items = <({String? id, String label})>[
      (id: null, label: 'All channels'),
      ...categories.map((category) => (id: category.id, label: category.title)),
    ];
    return Container(
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
            child: Focus(
              focusNode: focusNode,
              onKeyEvent: onKey,
              child: ListView.builder(
                controller: scrollController,
                itemExtent: rowExtent,
                itemCount: items.length,
                semanticChildCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  return IndexedSemantics(
                    index: i,
                    child: _CategoryRow(
                      label: item.label,
                      active: item.id == selectedCategoryId,
                      cursor: i == selectedIndex,
                      listFocused: focusNode.hasFocus,
                      position: i + 1,
                      total: items.length,
                      onTap: () {
                        onSelectIndex(i);
                        onSelected(item.id);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pointer-hover fill for the two live lists.
///
/// Hover used to be `InkWell(hoverColor: AppColors.panelHi)` inside a
/// *transparent* `Material`, with the row's own `AnimatedContainer` painting an
/// opaque fill over the exact same bounds — the ink splash was drawn and then
/// completely occluded, so hover was invisible on both lists. It is now driven
/// by the container's colour instead, and deliberately sits *between* the
/// resting panel and the selection cursor's `panelHi`: a hovered row must not
/// impersonate the D-pad cursor, which is the only thing OK acts on.
final Color _kRowHoverFill = Color.lerp(
  AppColors.panel,
  AppColors.panelHi,
  0.5,
)!;

class _CategoryRow extends StatefulWidget {
  final String label;

  /// This category is the active filter.
  final bool active;

  /// The D-pad cursor is on this row.
  final bool cursor;

  /// The sidebar currently owns the D-pad (see [_ChannelTile.listFocused]).
  final bool listFocused;
  final int position;
  final int total;
  final VoidCallback onTap;

  const _CategoryRow({
    required this.label,
    required this.active,
    required this.cursor,
    required this.listFocused,
    required this.position,
    required this.total,
    required this.onTap,
  });

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final active = widget.active;
    final cursor = widget.cursor;
    final onTap = widget.onTap;
    final focused = cursor && widget.listFocused;
    return Semantics(
      label: '$label, ${widget.position} of ${widget.total}',
      button: true,
      selected: active,
      onTap: onTap,
      excludeSemantics: true,
      child: Padding(
        // Only [kCategoryRowGap] per side (was 3): the extent is 48, so the
        // row's own hit area stays at the 44 px pointer-target minimum.
        padding: const EdgeInsets.symmetric(vertical: kCategoryRowGap),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            onHover: (hovered) {
              if (hovered != _hovered) setState(() => _hovered = hovered);
            },
            onTap: onTap,
            child: AnimatedContainer(
              duration: appMotion(context, const Duration(milliseconds: 120)),
              decoration: BoxDecoration(
                color: cursor
                    ? AppColors.panelHi
                    : _hovered
                    ? _kRowHoverFill
                    : AppColors.panel,
                borderRadius: BorderRadius.circular(AppRadius.tile),
                border: Border.all(
                  color: focused ? AppColors.accent : AppColors.line,
                  width: focused ? 2 : 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active || cursor ? AppColors.textHi : AppColors.textLo,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
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

  /// Routed focus nodes + D-pad handler for the Favorite / Catch-up controls,
  /// so they join the channel column's contained navigation.
  final FocusNode favoriteFocusNode;
  final FocusNode catchupFocusNode;
  final KeyEventResult Function(bool fromCatchup, KeyEvent event) onControlKey;
  final LiveLayoutMetrics metrics;

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
    required this.favoriteFocusNode,
    required this.catchupFocusNode,
    required this.onControlKey,
    required this.metrics,
  });

  /// How this platform's pointer reads in the hints below. `deliberate` is a
  /// *touch/remote* posture (Android today, iOS next), so this is "tap" wherever
  /// the deliberate hints actually render; the desktop wording only exists so a
  /// future non-deliberate/deliberate reshuffle can't silently start telling a
  /// mouse user to tap.
  static String get _pointerVerb =>
      defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS
      ? 'tap'
      : 'click';

  /// The hint under (or, when compact, over) the thumbnail.
  ///
  /// **It must never name an input the device doesn't have.** A `deliberate`
  /// preview is started by OK *or* by a pointer — a tap on a channel row runs
  /// the same `onPlayChannel` → `_play` path OK does, previewing first and
  /// going fullscreen on the second activation. The old wording said only
  /// "Press OK/Select", which on a touch tablet in landscape (wide layout, no
  /// remote) read as an instruction the user could not follow even though
  /// tapping a row worked. Kept short: the compact variant renders as a chip on
  /// a ~170 px thumbnail and ellipsizes past roughly 22 characters.
  String? get _hint {
    if (previewActive && previewError == null) {
      // Both inputs, on both postures: a second activation goes fullscreen
      // whether it arrives as OK or as a pointer, and the desktop wording used
      // to name only the key even though `_pointerVerb` was right there.
      return deliberate
          ? 'OK or $_pointerVerb again for fullscreen'
          : 'OK/Select or $_pointerVerb again for fullscreen';
    }
    if (deliberate) return 'OK or $_pointerVerb to preview';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final current = now;
    final upcoming = next;
    final compact = metrics.compact;
    double? progress;
    if (current != null) {
      final total = current.stop.difference(current.start).inSeconds;
      final elapsed = DateTime.now().difference(current.start).inSeconds;
      progress = total <= 0 ? null : (elapsed / total).clamp(0.0, 1.0);
    }
    return Container(
      height: metrics.previewHeight,
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
      // Deliberately no `LayoutBuilder` here: it read no constraint at all, so
      // all it bought was an extra builder on a panel that already knows its
      // own size from [metrics].
      child: Padding(
        padding: EdgeInsets.all(metrics.panelPadding),
        child: Row(
          children: [
            Container(
              width: metrics.previewWidth,
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
                    else if (!debugDisableNetworkChannelLogos &&
                        channel.logo != null &&
                        channel.logo!.isNotEmpty)
                      LayoutBuilder(
                        builder: (context, constraints) => CachedNetworkImage(
                          imageUrl: channel.logo!,
                          fit: BoxFit.cover,
                          memCacheWidth: imageCacheSize(
                            context,
                            constraints.maxWidth.isFinite
                                ? constraints.maxWidth
                                : 480,
                          ),
                          errorWidget: (_, url, error) {
                            logImageFailure(error, url);
                            return const Icon(
                              Icons.live_tv_rounded,
                              color: AppColors.textLo,
                              size: 42,
                            );
                          },
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
                    // The below-panel text hint (`_hint`) is gated behind
                    // `!compact`, but Android TV wide layouts are always
                    // compact (0.625 scale) — the device that most needs
                    // the "press OK" nudge. Mirror the "Preview" badge
                    // above with a corner chip on the thumbnail itself,
                    // which costs zero layout height, so compact layouts
                    // still get the hint. Non-compact layouts keep the
                    // text hint unchanged and don't get this chip too.
                    if (compact &&
                        !previewActive &&
                        !previewLoading &&
                        previewError == null &&
                        _hint != null)
                      Align(
                        alignment: Alignment.bottomRight,
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
                          child: Text(
                            _hint!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
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
            SizedBox(width: metrics.paneGap),
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
                            fontSize: metrics.titleSize,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (onCatchup != null)
                        _CatchupButton(
                          onPressed: onCatchup!,
                          focusNode: catchupFocusNode,
                          onKeyEvent: (node, event) =>
                              onControlKey(true, event),
                        ),
                      FavoriteButton(
                        favorite: favorite,
                        onPressed: onToggleFavorite,
                        focusNode: favoriteFocusNode,
                        onKeyEvent: (node, event) => onControlKey(false, event),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 2 : 8),
                  if (current != null)
                    Text(
                      '${nowProgrammeLabel(current)} · ${programmeTimeRange(current)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textHi,
                        fontSize: metrics.infoSize,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else
                    const Text(
                      'No programme information',
                      style: TextStyle(color: AppColors.textLo, fontSize: 14),
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
                      '${nextProgrammeLabel(upcoming)} · ${programmeTimeRange(upcoming)}',
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
      ),
    );
  }
}

/// Opens the catch-up / archive picker. Shown on live surfaces only when the
/// channel reports [Channel.hasArchive].
class _CatchupButton extends StatelessWidget {
  final VoidCallback onPressed;

  /// Optional routed focus node + D-pad key handler (live preview panel only).
  final FocusNode? focusNode;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  const _CatchupButton({
    required this.onPressed,
    this.focusNode,
    this.onKeyEvent,
  });

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: 'Catch-up',
      focusNode: focusNode,
      icon: const Icon(Icons.history_rounded, color: AppColors.textLo),
      onPressed: onPressed,
    );
    if (onKeyEvent == null) return button;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: onKeyEvent,
      child: button,
    );
  }
}

/// Bottom-sheet catch-up picker: the channel's cached past programmes, grouped
/// by day (most recent first), each a D-pad-navigable row that plays the
/// archive stream. [programmes] is expected newest-first.
class CatchupSheet extends StatelessWidget {
  final Channel channel;
  final List<Programme> programmes;
  final void Function(Programme) onPlay;

  const CatchupSheet({
    super.key,
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
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
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
class PhonePreviewSheet extends StatefulWidget {
  final LivePreviewController preview;
  final Channel channel;
  final Programme? now;
  final Programme? next;
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onPlay;

  /// Opens catch-up; null when the channel has no archive.
  final VoidCallback? onCatchup;

  const PhonePreviewSheet({
    super.key,
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
  State<PhonePreviewSheet> createState() => _PhonePreviewSheetState();
}

class _PhonePreviewSheetState extends State<PhonePreviewSheet> {
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

  @override
  Widget build(BuildContext context) {
    final current = widget.now;
    final upcoming = widget.next;
    return SafeArea(
      child: ConstrainedBox(
        // Cap the sheet height so it never expands to the full screen: that
        // pushed the drag handle up against the status bar (a downward drag
        // pulled the OS notification shade) and clipped the lower controls
        // off with no way to scroll to them. Mirrors CatchupSheet.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
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
              // Scroll the video + text/EPG so tall content (large/landscape
              // phones) never clips; the Play button below stays pinned and
              // always tappable.
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Container(color: Colors.black),
                              // Only once loaded: building PreviewVideo earlier
                              // would spin up the media_kit texture while the
                              // native path is still deciding whether it's
                              // needed at all.
                              if (widget.preview.channelId ==
                                      widget.channel.id &&
                                  widget.preview.stream != null &&
                                  widget.preview.error == null)
                                PreviewVideo(preview: widget.preview),
                              if (widget.preview.loading || _buffering)
                                const Center(
                                  child: SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
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
                          FavoriteButton(
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
                          '${nowProgrammeLabel(current)} · ${programmeTimeRange(current)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textHi,
                            fontSize: 14,
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
                      if (upcoming != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${nextProgrammeLabel(upcoming)} · ${programmeTimeRange(upcoming)}',
                          maxLines: 1,
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
              ),
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
      ),
    );
  }
}

/// A channel row. **Not focusable** — the list's single focus node owns the
/// D-pad and this row simply draws the cursor when it's the selected index (see
/// [LiveFocusCoordinator]). It stays tappable/long-pressable for touch + mouse.
class _ChannelTile extends StatefulWidget {
  final Channel channel;
  final Programme? now;
  final Programme? next;
  final bool favorite;
  final bool enabled;
  final int position;
  final int total;

  /// Resolved once by [LiveTabView.build] and passed down — every row would
  /// otherwise recompute the identical value (and take a MediaQuery dependency)
  /// on every rebuild.
  final LiveLayoutMetrics metrics;

  /// The D-pad selection cursor is on this row.
  final bool cursor;

  /// The D-pad cursor is on this row's *favorite star* column
  /// ([ChannelRowColumn.favorite]) rather than the row body. The star cell
  /// then carries the accent ring and the row body drops its own.
  final bool favoriteCursor;

  /// The channel list currently owns the D-pad. A cursor in an *unfocused* list
  /// still shows, but subdued — the accent always marks the active pane.
  final bool listFocused;

  /// This channel is the one currently being previewed.
  final bool previewing;

  /// Owning source's name, shown as a subdued suffix after the channel name in
  /// the cross-source Favorites view; null everywhere else (where every row
  /// belongs to the active source and the chip would be noise).
  ///
  /// Deliberately *inline with the title* rather than on a line of its own: the
  /// live list is a selection model whose scroll math is `index * itemExtent`,
  /// so a row that grows by a line breaks index→offset for the whole list.
  final String? sourceLabel;
  final VoidCallback onTap;

  /// Tap on the star cell (touch/mouse) — toggles this channel's favorite.
  final VoidCallback onToggleFavorite;
  final VoidCallback? onLongPress;

  const _ChannelTile({
    required this.channel,
    required this.now,
    required this.next,
    required this.favorite,
    required this.enabled,
    required this.position,
    required this.total,
    required this.metrics,
    required this.cursor,
    required this.favoriteCursor,
    required this.listFocused,
    required this.previewing,
    required this.onTap,
    required this.onToggleFavorite,
    this.sourceLabel,
    this.onLongPress,
  });

  // The two possible favorite actions, hoisted to constants: the row rebuilds
  // on every cursor move, and `CustomSemanticsAction` has value equality, so
  // allocating a fresh one per row per rebuild bought nothing.
  static const _addFavoriteAction = CustomSemanticsAction(
    label: 'Add to favorites',
  );
  static const _removeFavoriteAction = CustomSemanticsAction(
    label: 'Remove from favorites',
  );

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final metrics = widget.metrics;
    final cursor = widget.cursor;
    final favorite = widget.favorite;
    final favoriteCursor = widget.favoriteCursor;
    final listFocused = widget.listFocused;
    final enabled = widget.enabled;
    final onTap = widget.onTap;
    final onToggleFavorite = widget.onToggleFavorite;
    final current = widget.now;
    final upcoming = widget.next;
    // Drop the "Next" line only when the four lines genuinely don't fit the
    // extent ([LiveLayoutMetrics.denseChannelRow]). This used to be
    // `extent < kChannelRowExtentWithEpg`, i.e. "any reduction at all", which
    // cost a 700 px-tall desktop window its "Next" line with room to spare —
    // and which text scaling inverts, since the extent then grows past the
    // baseline while the text inside grows faster.
    final dense = metrics.denseChannelRow;
    double? progress;
    if (current != null) {
      final total = current.stop.difference(current.start).inSeconds;
      final elapsed = DateTime.now().difference(current.start).inSeconds;
      progress = total <= 0 ? null : (elapsed / total).clamp(0.0, 1.0);
    }

    // The row body carries the accent only while the intra-row cursor is on
    // the *body* column; on the favorite column the star cell takes it over.
    // The panelHi fill stays either way, so the selected row remains visible.
    final active = cursor && listFocused && !favoriteCursor;
    // One buffer instead of two intermediate lists and two joins — same text:
    // `name, Now · X, Next · Y, 3 of 12, Favorite`.
    final label = StringBuffer(channel.name);
    if (widget.sourceLabel case final source?) label.write(', from $source');
    if (current != null) label.write(', ${nowProgrammeLabel(current)}');
    if (upcoming != null) label.write(', ${nextProgrammeLabel(upcoming)}');
    label.write(', ${widget.position} of ${widget.total}');
    label.write(favorite ? ', Favorite' : ', Not favorite');
    final semanticsLabel = label.toString();
    final favoriteAction = favorite
        ? _ChannelTile._removeFavoriteAction
        : _ChannelTile._addFavoriteAction;
    return Semantics(
      label: semanticsLabel,
      button: true,
      selected: cursor,
      enabled: enabled,
      onTap: enabled ? onTap : null,
      customSemanticsActions: {favoriteAction: onToggleFavorite},
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            onHover: (hovered) {
              if (hovered != _hovered) setState(() => _hovered = hovered);
            },
            onTap: onTap,
            onLongPress: widget.onLongPress,
            child: AnimatedContainer(
              duration: appMotion(context, const Duration(milliseconds: 120)),
              decoration: BoxDecoration(
                // Hover is painted by this container, not by the InkWell's
                // (fully occluded) hoverColor, and stays distinct from the
                // cursor's panelHi — see [_kRowHoverFill].
                color: cursor
                    ? AppColors.panelHi
                    : _hovered
                    ? _kRowHoverFill
                    : AppColors.panel,
                borderRadius: BorderRadius.circular(AppRadius.tile),
                border: Border.all(
                  color: active ? AppColors.accent : AppColors.line,
                ),
              ),
              // **The cursor ring is painted, not laid out.** `Container`
              // reserves `decoration.border`'s width as padding but never
              // `foregroundDecoration`'s, so drawing the 2 px accent ring here
              // puts it in exactly the same place a `decoration` border would
              // (both `DecoratedBox`es wrap the same rect) while leaving the
              // selected row's content box identical to every other row's.
              // With the ring in `decoration` the cursor row had 2 px less
              // height and width than its neighbours — which is why a row that
              // fitted everywhere else overflowed the moment it was selected.
              foregroundDecoration: active
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.tile),
                      border: Border.all(color: AppColors.accent, width: 2),
                    )
                  : null,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: metrics.compact ? 10 : 12,
                  vertical: metrics.compact ? 6 : 8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _Logo(
                      channel: channel,
                      size: metrics.logoSize(widget.now != null),
                    ),
                    SizedBox(width: metrics.compact ? 10 : 12),
                    // **The text column is laid out unconstrained and clipped.**
                    // The row height is authoritative — the live list is a
                    // selection model that scrolls by `index * itemExtent` — so
                    // the content has to fit the box *by construction*, not by
                    // estimate. Handing the `Column` an unbounded main axis is
                    // what makes that true: it can never be over-allocated, so
                    // it can never report an overflow, and `ClipRect` turns any
                    // residual (a font whose real line height runs past
                    // [_kNowLineHeight] and friends, an accessibility text scale
                    // past [kMaxLiveTextScale]) into an invisible sub-pixel trim
                    // instead of a striped bar across the row a user is looking
                    // at. `OverflowBox` sizes itself to the parent, so the
                    // `centerLeft` alignment reproduces the `Row`'s own
                    // `CrossAxisAlignment.center` exactly while it fits — and
                    // splits any trim between the title's leading and the last
                    // line's descenders when it doesn't. Same pattern as
                    // `_MediaGridTile`'s fixed-height text block.
                    Expanded(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minHeight: 0,
                          maxHeight: double.infinity,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // The title shares its line with the source chip
                              // when there is one. `Flexible` (not `Expanded`)
                              // so a short name doesn't push the chip to the
                              // far edge, and the chip's font stays below the
                              // title's so the line height — and therefore the
                              // row extent — is still set by the title alone.
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Flexible(
                                    child: Text(
                                      channel.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      // Density-scaled, unlike the theme's fixed
                                      // 16 px titleMedium it used to take
                                      // verbatim: the extent around this line
                                      // shrinks on compact/short layouts, and a
                                      // fixed title was the biggest single
                                      // consumer of the headroom that left.
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontSize: metrics.rowTitleSize,
                                          ),
                                    ),
                                  ),
                                  if (widget.sourceLabel case final source?) ...[
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        source,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: AppColors.textLo,
                                          fontSize: metrics.rowTitleSize - 4,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              if (current != null) ...[
                                const SizedBox(height: _kRowLineGap),
                                // Current show on its own emphasized line —
                                // leads with the title so a long channel name
                                // never hides it.
                                Text(
                                  nowProgrammeLabel(current),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.accent,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: _kRowLineGap),
                                // Time range + progress share a row so the bar
                                // reads as "where we are between these times".
                                Row(
                                  children: [
                                    Text(
                                      programmeTimeRange(current),
                                      style: const TextStyle(
                                        color: AppColors.textLo,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          // Not `progress`: a null value means
                                          // *indeterminate*, so a programme with
                                          // a bad duration would animate this
                                          // row forever and keep the frame
                                          // pipeline awake. The preview panel
                                          // already guards this by not drawing
                                          // the bar at all.
                                          value: progress ?? 0,
                                          minHeight: 3,
                                          backgroundColor: AppColors.line,
                                          valueColor:
                                              const AlwaysStoppedAnimation<
                                                Color
                                              >(AppColors.accent),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                // The 88 px Android-TV row keeps the current
                                // show, range and progress visible, but moves
                                // "Next" to the preview panel/semantics rather
                                // than clipping it against the fixed
                                // selection-model extent.
                                if (upcoming != null && !dense)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: _kRowLineGap,
                                    ),
                                    child: Text(
                                      nextProgrammeLabel(upcoming),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.textLo,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Always-visible favorite star: a touch target on every row,
                    // and the D-pad's intra-row favorite column when
                    // [favoriteCursor] holds the cursor.
                    //
                    // The hit area is [LiveLayoutMetrics.favoriteTargetSize] —
                    // 44 px wherever a pointer is plausible, because on a phone
                    // this sits beside a row whose tap starts *fullscreen
                    // playback*, and a 32 px miss is an accidental channel
                    // change. The compact (Android TV, remote-only) row is
                    // 56 px tall and can't hold 44, so it keeps 32. The
                    // decorated cell inside stays its natural size, so the
                    // accent ring doesn't balloon with the target.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onToggleFavorite,
                      child: SizedBox.square(
                        dimension: metrics.favoriteTargetSize,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: favoriteCursor && listFocused
                                  ? AppColors.panelHi
                                  : null,
                              borderRadius: BorderRadius.circular(
                                AppRadius.tile,
                              ),
                              border: favoriteCursor && listFocused
                                  ? Border.all(
                                      color: AppColors.accent,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: Icon(
                              favorite
                                  ? Icons.star_rounded
                                  : Icons.star_outline_rounded,
                              size: 20,
                              color: favorite
                                  ? AppColors.accent
                                  : AppColors.textLo.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      widget.previewing
                          ? Icons.play_circle_fill_rounded
                          : Icons.play_arrow_rounded,
                      color: enabled ? AppColors.accent : AppColors.textLo,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatefulWidget {
  final Channel channel;
  final double size;
  const _Logo({required this.channel, required this.size});

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
    final size = widget.size;
    final cacheSize = imageCacheSize(context, size);
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
    if (logo == null || logo.isEmpty || debugDisableNetworkChannelLogos) {
      return fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image(
        image: ScrollAwareImageProvider(
          context: _scrollContext,
          imageProvider: ResizeImage.resizeIfNeeded(
            cacheSize,
            cacheSize,
            CachedNetworkImageProvider(logo),
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
