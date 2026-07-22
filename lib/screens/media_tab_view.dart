import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/library_repository.dart';
import '../data/source_hint_parser.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/favorite_controls.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';
import '../data/app_database.dart' show PlaybackPosition;
import 'media_tab_controller.dart' show ContinueWatchingEntry;

/// `1:23:45` / `12:34` style label for a resume position.
String _positionLabel(Duration position) {
  final hours = position.inHours;
  final minutes = position.inMinutes % 60;
  final seconds = position.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// Grid density for poster catalogues. Android's TV render targets commonly
/// expose a desktop-sized logical viewport, so the old fixed 4/6-column rule
/// produced enormous cards and only one or two visible rows. Compact mode uses
/// a bounded target card width instead, while desktop keeps its established
/// breakpoints.
@immutable
class MediaGridMetrics {
  final int columns;
  final double spacing;
  final EdgeInsets padding;

  const MediaGridMetrics._({
    required this.columns,
    required this.spacing,
    required this.padding,
  });

  factory MediaGridMetrics.forWidth(double width, {bool compact = false}) {
    if (!compact) {
      return MediaGridMetrics._(
        columns: width >= 1280 ? 6 : 4,
        spacing: 12,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
      );
    }
    return MediaGridMetrics._(
      columns: (width / 180).floor().clamp(5, 10),
      spacing: 8,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
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

  /// In-progress items (saved playback positions) shown as a horizontal
  /// "Continue watching" rail above the grid; [onResume] plays one, resuming.
  /// [onRemoveContinueWatching] drops one entry (clears its saved position).
  final List<ContinueWatchingEntry> continueWatching;
  final ValueChanged<MediaItem> onResume;
  final ValueChanged<ContinueWatchingEntry> onRemoveContinueWatching;

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
    this.continueWatching = const [],
    required this.onResume,
    required this.onRemoveContinueWatching,
  });

  @override
  Widget build(BuildContext context) {
    // The rail rides in the *same* scroll view as the grid/list below (as a
    // leading sliver) rather than sitting above it in a fixed-height Column.
    // A fixed height there could exceed the whole available viewport on a
    // short screen (phone landscape, mainly) — Column+Expanded overflows in
    // that case, which broke the rail's own horizontal drag along with it.
    // As a sliver it just contributes to the (already scrollable) content
    // and never forces an overflow.
    final showRail = !showingSearch && continueWatching.isNotEmpty;
    final railSliver = showRail
        ? SliverToBoxAdapter(
            child: _ContinueWatchingRail(
              entries: continueWatching,
              onResume: onResume,
              onRemove: onRemoveContinueWatching,
            ),
          )
        : null;

    if (loading || error != null || visible.isEmpty) {
      final status = _statusBody(context);
      if (railSliver == null) return status;
      return CustomScrollView(
        slivers: [
          railSliver,
          SliverFillRemaining(hasScrollBody: false, child: status),
        ],
      );
    }

    final showLoadMore =
        !showingSearch && (loadingMore || snapshot?.hasMore == true);
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
          return CustomScrollView(
            controller: scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            slivers: [
              ?railSliver,
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                sliver: SliverList.builder(
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
                      position: i + 1,
                      total: visible.length,
                      autofocus: autofocusFor(i),
                      focusNode: focusNodeFor(i),
                      onTap: () => onOpenMedia(visible[i]),
                    );
                  },
                ),
              ),
            ],
          );
        }
        final grid = MediaGridMetrics.forWidth(
          constraints.maxWidth,
          compact: defaultTargetPlatform == TargetPlatform.android,
        );
        return CustomScrollView(
          controller: scrollController,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
          slivers: [
            ?railSliver,
            SliverPadding(
              padding: grid.padding,
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: grid.columns,
                  crossAxisSpacing: grid.spacing,
                  mainAxisSpacing: grid.spacing,
                  childAspectRatio: 0.64,
                ),
                delegate: SliverChildBuilderDelegate((context, i) {
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
                    position: i + 1,
                    total: visible.length,
                    autofocus: autofocusFor(i),
                    focusNode: focusNodeFor(i),
                    onTap: () => onOpenMedia(visible[i]),
                  );
                }, childCount: visible.length + (showLoadMore ? 1 : 0)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _statusBody(BuildContext context) {
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
    return Center(
      child: Text(
        'No ${kind == ContentKind.movie ? 'movies' : 'series'} match',
        style: const TextStyle(color: AppColors.textLo),
      ),
    );
  }
}

/// Remaining watch time as `23 min left` / `1 hr 12 min left`, or null when
/// the duration is unknown or the item is effectively finished.
String? _remainingLabel(PlaybackPosition position) {
  if (position.duration <= Duration.zero) return null;
  final remaining = position.duration - position.position;
  if (remaining.inSeconds < 30) return null;
  final minutes = remaining.inMinutes;
  if (minutes < 1) return 'Less than a min left';
  if (minutes < 60) return '$minutes min left';
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  return mins == 0 ? '$hours hr left' : '$hours hr $mins min left';
}

/// `S2 · E5 · 23 min left` style second line — season/episode (episodes
/// only) and remaining time, whichever of the two apply.
String? _continueWatchingSubtitle(ContinueWatchingEntry entry) {
  final item = entry.item;
  final parts = <String>[
    if (item.seasonNumber != null && item.episodeNumber != null)
      'S${item.seasonNumber} · E${item.episodeNumber}',
    ?_remainingLabel(entry.position),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Horizontal "Continue watching" strip: poster tiles with a progress bar,
/// newest first. One `FocusTraversalGroup` so the D-pad walks the rail as a
/// row between the toolbar and the grid. Sized noticeably larger than the
/// other rails so the title and remaining-time text stay legible on phones.
class _ContinueWatchingRail extends StatelessWidget {
  final List<ContinueWatchingEntry> entries;
  final ValueChanged<MediaItem> onResume;
  final ValueChanged<ContinueWatchingEntry> onRemove;

  const _ContinueWatchingRail({
    required this.entries,
    required this.onResume,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: Text(
              'Continue watching',
              style: TextStyle(
                color: AppColors.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            // Only tall enough for the tile's own content (16:9 thumbnail +
            // title + subtitle + the Remove row below the card) — not sized
            // against the screen, so it can never itself overflow a short
            // viewport (phone landscape). It scrolls away with the rest of
            // the tab content.
            height: 224,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => _ContinueWatchingTile(
                entry: entries[i],
                onTap: () => onResume(entries[i].item),
                onRemove: () => onRemove(entries[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueWatchingTile extends StatelessWidget {
  // 16:9 — these thumbnails are usually a video-frame screenshot or a
  // backdrop still, both landscape; cropping them into a portrait poster
  // box (the old design) zoomed in hard and made compression noise obvious.
  static const double _width = 224.0;
  static const double _thumbHeight = 126.0;

  final ContinueWatchingEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ContinueWatchingTile({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final subtitle = _continueWatchingSubtitle(entry);
    return SizedBox(
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FocusableCard(
            onTap: onTap,
            debugLabel: 'media.continue.${item.id}',
            child: SizedBox(
              width: _width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: _width,
                      height: _thumbHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _Thumb(
                            item: item,
                            width: _width,
                            height: _thumbHeight,
                          ),
                          // Resume affordance — makes it obvious at a glance
                          // that these tiles play mid-way through, not from
                          // the start.
                          Center(
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                          // Progress bar overlaid on the thumbnail (with a
                          // scrim behind it for contrast on bright artwork)
                          // rather than a separate row, so the freed-up
                          // space goes to the title.
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.0),
                                    Colors.black.withValues(alpha: 0.7),
                                  ],
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: entry.position.progress,
                                  minHeight: 4,
                                  backgroundColor: Colors.white.withValues(
                                    alpha: 0.3,
                                  ),
                                  color: AppColors.accent,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textHi,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textLo,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                  // Breathing room between the text and the card's bottom
                  // border — the card itself adds no internal padding.
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
          // A genuine sibling *below* the card, not overlaid on top of it.
          // An overlaid corner badge is unreachable by D-pad: Flutter's
          // directional focus search matches against candidates' screen
          // rects, and a badge nested inside the card's own rect never reads
          // as "up/down/left/right" of it — confirmed by testing an
          // overlaid version, where arrow keys skipped straight over it to
          // the next card. A non-overlapping rect below it works exactly
          // like moving between adjacent cards in the row.
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: _RemoveButton(onPressed: onRemove),
          ),
        ],
      ),
    );
  }
}

/// Clears one continue-watching entry — a genuine sibling stop below its
/// card (see [_ContinueWatchingTile]'s doc comment on why it can't overlay
/// the card instead).
class _RemoveButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _RemoveButton({required this.onPressed});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: _focused ? AppColors.panelHi : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: _focused ? Border.all(color: AppColors.accent) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.close_rounded,
                size: 13,
                color: _focused ? AppColors.accent : AppColors.textLo,
              ),
              const SizedBox(width: 4),
              Text(
                'Remove',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _focused ? AppColors.accent : AppColors.textLo,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A landscape (16:9) artwork tile for the continue-watching rail — prefers
/// [MediaItem.backdrop] (a proper cinematic still) and falls back to
/// [MediaItem.poster] (often a video-frame screenshot for episodes), since
/// either is landscape-shaped content, unlike [_Poster]'s portrait crop.
class _Thumb extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const _Thumb({required this.item, required this.width, required this.height});

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
    final backdrop = item.backdrop;
    final poster = item.poster;
    final image = (backdrop != null && backdrop.isNotEmpty)
        ? backdrop
        : (poster != null && poster.isNotEmpty)
        ? poster
        : null;
    if (image == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: image,
        width: width,
        height: height,
        fit: BoxFit.cover,
        memCacheWidth: imageCacheSize(context, width),
        memCacheHeight: imageCacheSize(context, height),
        errorWidget: (_, _, _) => fallback,
        placeholder: (_, _) => fallback,
      ),
    );
  }
}

class _MediaListTile extends StatelessWidget {
  final MediaItem item;
  final bool favorite;
  final int position;
  final int total;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _MediaListTile({
    required this.item,
    required this.favorite,
    required this.position,
    required this.total,
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
      semanticsLabel: [
        item.title,
        if (item.year != null) item.year!,
        '$position of $total',
        if (favorite) 'Favorite',
      ].join(', '),
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
                  // Parsed once per tile build: the pattern binds the list so
                  // the emptiness test and the widget share one parse.
                  if (sourceHintLabels(item) case final hints
                      when hints.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _SourceHints(hints: hints),
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
            if (favorite) ...[const SizedBox(width: 8), const FavoriteBadge()],
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
  final int position;
  final int total;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _MediaGridTile({
    required this.item,
    required this.favorite,
    required this.position,
    required this.total,
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
      semanticsLabel: [
        item.title,
        if (item.year != null) item.year!,
        '$position of $total',
        if (favorite) 'Favorite',
      ].join(', '),
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
                          child: const FavoriteBadge(size: 16),
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
            if (sourceHintLabels(item) case final hints
                when hints.isNotEmpty) ...[
              const SizedBox(height: 5),
              _SourceHints(hints: hints, compact: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// Renders already-parsed hint labels. It deliberately takes the parsed list
/// rather than the `MediaItem`: `sourceHintLabels` is not cheap (regexes + the
/// language alias table) and every call site already has to test the result for
/// emptiness, so parsing here too would double the cost on every tile build.
class _SourceHints extends StatelessWidget {
  final List<String> hints;
  final bool compact;

  const _SourceHints({required this.hints, this.compact = false});

  @override
  Widget build(BuildContext context) {
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final renderedWidth = width.isFinite && width > 0
            ? width
            : constraints.maxWidth;
        final renderedHeight = height.isFinite && height > 0
            ? height
            : constraints.maxHeight;
        final fallback = Container(
          width: renderedWidth,
          height: renderedHeight,
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
          child: CachedNetworkImage(
            imageUrl: poster,
            width: renderedWidth,
            height: renderedHeight,
            fit: BoxFit.cover,
            memCacheWidth: imageCacheSize(context, renderedWidth),
            memCacheHeight: imageCacheSize(context, renderedHeight),
            errorWidget: (_, _, _) => fallback,
            placeholder: (_, _) => fallback,
          ),
        );
      },
    );
  }
}

class MediaDetailsSheet extends StatefulWidget {
  final LibraryRepository repo;
  final MediaItem item;
  final bool favorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onPlay;
  final ValueChanged<MediaItem>? onChanged;

  /// Plays one episode picked from the series browser. Routed back through the
  /// screen's own play path (rather than pushing a player here) so the
  /// "Continue watching" rail reloads on return, exactly like a movie does.
  final ValueChanged<MediaItem>? onPlayEpisode;

  const MediaDetailsSheet({
    super.key,
    required this.repo,
    required this.item,
    required this.favorite,
    required this.onToggleFavorite,
    required this.onPlay,
    this.onChanged,
    this.onPlayEpisode,
    this.resume,
    this.onPlayFromStart,
  });

  /// Saved resume point for this item, if any — turns the Play button into
  /// "Resume from h:mm:ss" and surfaces [onPlayFromStart] beside it.
  final PlaybackPosition? resume;
  final VoidCallback? onPlayFromStart;

  @override
  State<MediaDetailsSheet> createState() => _MediaDetailsSheetState();
}

class _MediaDetailsSheetState extends State<MediaDetailsSheet> {
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
    // Close the sheet, then hand the episode to the screen's play path (which
    // resolves, plays, and — critically — reloads "Continue watching" on
    // return). Pushing a player straight from here bypassed that reload, so the
    // series rail went stale until a manual refresh.
    Navigator.of(context).pop();
    widget.onPlayEpisode?.call(item);
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
                    FavoriteButton(
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
                if (sourceHintLabels(_item) case final hints
                    when hints.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _SourceHints(hints: hints),
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
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: widget.onPlay,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          widget.resume != null
                              ? 'Resume from ${_positionLabel(widget.resume!.position)}'
                              : 'Play',
                        ),
                      ),
                      if (widget.resume != null &&
                          widget.onPlayFromStart != null)
                        OutlinedButton.icon(
                          onPressed: widget.onPlayFromStart,
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('From start'),
                        ),
                    ],
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
