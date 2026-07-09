import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;

import '../sources/source.dart';
import '../theme.dart';
import '../widgets/favorite_controls.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';
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

class _MoveRightToChannelsIntent extends Intent {
  const _MoveRightToChannelsIntent();
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

  /// Scroll controller for the category sidebar, so the focus coordinator can
  /// jump an off-screen category into build range before focusing it.
  final ScrollController categoryScrollController;

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
  final ValueChanged<String> onChannelMoveUp;

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

  /// D-pad handler for a category card (Right → channels, Up/Down cycle the
  /// category list with wrap). Keyed by the card's own category id.
  final KeyEventResult Function(String? categoryId, KeyEvent event)
  onCategoryCardKey;
  final KeyEventResult Function(FocusNode, KeyEvent) onPaneFallbackKey;

  /// Routed focus nodes + D-pad handler for the preview panel's Favorite /
  /// Catch-up controls (the top of the channel column on the wide layout).
  final FocusNode previewFavoriteFocusNode;
  final FocusNode previewCatchupFocusNode;
  final KeyEventResult Function(bool fromCatchup, KeyEvent event)
  onPreviewControlKey;

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
    required this.categoryScrollController,
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
    required this.onChannelMoveUp,
    required this.onCatchup,
    required this.categories,
    required this.selectedCategoryId,
    required this.focusNodeForCategory,
    required this.onCategorySelected,
    required this.onMoveRightToChannels,
    required this.onCategoryCardKey,
    required this.onPaneFallbackKey,
    required this.previewFavoriteFocusNode,
    required this.previewCatchupFocusNode,
    required this.onPreviewControlKey,
    required this.previewVideoBuilder,
    required this.previewLoading,
    required this.previewError,
  });

  Widget _buildChannelList(
    BuildContext context, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(12, 4, 12, 16),
  }) {
    final allowLongPressPreview =
        deliberate && MediaQuery.of(context).size.width < kWideLayoutMinWidth;
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
          onMoveUp: () => onChannelMoveUp(c.id),
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
        if (constraints.maxWidth < kWideLayoutMinWidth) return _buildChannelList(context);
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
                    scrollController: categoryScrollController,
                    focusNodeForCategory: focusNodeForCategory,
                    onSelected: onCategorySelected,
                    onMoveRightToChannels: onMoveRightToChannels,
                    onCategoryCardKey: onCategoryCardKey,
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
                        favoriteFocusNode: previewFavoriteFocusNode,
                        catchupFocusNode: previewCatchupFocusNode,
                        onControlKey: onPreviewControlKey,
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

class _LiveCategoryPane extends StatelessWidget {
  final List<Category> categories;
  final String? selectedCategoryId;
  final ScrollController scrollController;
  final FocusNode Function(String? categoryId) focusNodeForCategory;
  final ValueChanged<String?> onSelected;
  final VoidCallback onMoveRightToChannels;
  final KeyEventResult Function(String? categoryId, KeyEvent event)
  onCategoryCardKey;

  const _LiveCategoryPane({
    required this.categories,
    required this.selectedCategoryId,
    required this.scrollController,
    required this.focusNodeForCategory,
    required this.onSelected,
    required this.onMoveRightToChannels,
    required this.onCategoryCardKey,
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
                  controller: scrollController,
                  children: [
                    for (final item in items)
                      Builder(
                        builder: (context) {
                          final selected = item.id == selectedCategoryId;
                          return FocusableCard(
                            focusNode: focusNodeForCategory(item.id),
                            debugLabel: 'live.category.${item.id ?? 'all'}',
                            onKeyEvent: (node, event) =>
                                onCategoryCardKey(item.id, event),
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

  /// Routed focus nodes + D-pad handler for the Favorite / Catch-up controls,
  /// so they join the channel column's contained navigation.
  final FocusNode favoriteFocusNode;
  final FocusNode catchupFocusNode;
  final KeyEventResult Function(bool fromCatchup, KeyEvent event) onControlKey;

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
  });

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
                          LayoutBuilder(
                            builder: (context, constraints) =>
                                CachedNetworkImage(
                                  imageUrl: channel.logo!,
                                  fit: BoxFit.cover,
                                  memCacheWidth: imageCacheSize(
                                    context,
                                    constraints.maxWidth.isFinite
                                        ? constraints.maxWidth
                                        : 480,
                                  ),
                                  errorWidget: (_, _, _) => const Icon(
                                    Icons.live_tv_rounded,
                                    color: AppColors.textLo,
                                    size: 42,
                                  ),
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
                            onKeyEvent: (node, event) =>
                                onControlKey(false, event),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (current != null)
                        Text(
                          '${nowProgrammeLabel(current)} · ${programmeTimeRange(current)}',
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
          );
        },
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
                '${nextProgrammeLabel(upcoming)} · ${programmeTimeRange(upcoming)}',
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
  final VoidCallback onMoveUp;

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
    required this.onMoveUp,
  });

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
        final isUp = event.logicalKey == LogicalKeyboardKey.arrowUp;
        if (!isLeft && !isDown && !isUp) return KeyEventResult.ignored;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.handled;
        }
        if (isLeft) {
          onMoveLeftToCategory();
          return KeyEventResult.handled;
        }
        if (isUp) {
          onMoveUp();
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
                    const SizedBox(height: 8),
                    // Current show on its own emphasized line — leads with the
                    // title so a long channel name never hides it.
                    Text(
                      nowProgrammeLabel(current),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Time range + progress share a row so the bar reads as
                    // "where we are between these times".
                    Row(
                      children: [
                        Text(
                          programmeTimeRange(current),
                          style: const TextStyle(
                            color: AppColors.textLo,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ClipRRect(
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
                        ),
                      ],
                    ),
                    if (upcoming != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          nextProgrammeLabel(upcoming),
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
            if (favorite) ...[const SizedBox(width: 8), const FavoriteBadge()],
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
    if (logo == null || logo.isEmpty) return fallback;

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
