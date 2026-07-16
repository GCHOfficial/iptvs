import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_repository.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/image_utils.dart';

/// EPG timeline grid: one row per channel, programme cells positioned on a
/// shared time axis (now − 1h → now + 24h, fixed scale).
///
/// Navigation uses an explicit **selection cursor**, not Flutter's geometry
/// traversal. The screen owns `_selectedRow` + a `_cursorTime`; the selected
/// programme on a row is the one airing at the cursor time. A single [Focus]
/// on the grid captures the D-pad and moves the selection deterministically —
/// Left/Right step programme boundaries, Up/Down change channel **keeping the
/// time column** (the way a TV guide should feel), and the screen drives the
/// pan/scroll itself. This means navigation never depends on whether a lazy
/// row or an async programme cell happens to be built, and the cells
/// themselves are cheap (no per-cell focus node / InkWell / Material), so
/// scrolling stays smooth on long, dense guides.
///
/// OK on a *current* programme plays the channel; on a *past* programme of an
/// archive-capable channel it plays catch-up; anything else shows details.
class EpgGridScreen extends StatefulWidget {
  final LibraryRepository repo;

  /// Channels to list (the caller's filtered/visible set), in display order.
  final List<Channel> channels;

  /// Plays [Channel] live (the caller owns resolution + the player route).
  final void Function(Channel channel) onPlayChannel;

  /// Plays a past [Programme] via catch-up (caller resolves the archive).
  final void Function(Channel channel, Programme programme) onPlayArchive;

  const EpgGridScreen({
    super.key,
    required this.repo,
    required this.channels,
    required this.onPlayChannel,
    required this.onPlayArchive,
  });

  @override
  State<EpgGridScreen> createState() => _EpgGridScreenState();
}

class _EpgGridScreenState extends State<EpgGridScreen>
    with SingleTickerProviderStateMixin {
  static const _pxPerMinute = 4.0; // 30-min slot = 120px
  static const _rowHeight = 52.0;
  static const _channelColumnWidth = 168.0;

  late final DateTime _windowStart = _floorToHalfHour(
    DateTime.now().subtract(const Duration(hours: 1)),
  );
  late final DateTime _windowEnd = _windowStart.add(const Duration(hours: 25));

  double get _totalWidth =>
      _windowEnd.difference(_windowStart).inMinutes * _pxPerMinute;

  /// Shared horizontal offset for the header + every row.
  final ValueNotifier<double> _hOffset = ValueNotifier(0);
  final ScrollController _vController = ScrollController();

  /// Smooth horizontal pans (D-pad reveal / jump-to-now); touch drag sets the
  /// offset directly instead.
  late final AnimationController _panController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<double>? _panTween;

  /// The grid's single D-pad focus target — cells are not individually
  /// focusable, so navigation is a pure selection model.
  final FocusNode _gridFocus = FocusNode(debugLabel: 'epg.grid');

  /// Selection cursor: which channel row, and the anchor time whose programme
  /// is selected. Up/Down keep [_cursorTime] so movement holds the time column.
  int _selectedRow = 0;
  late DateTime _cursorTime = DateTime.now();

  /// The selected programme's index within the current row's list — the single
  /// source of truth for the highlight and the detail bar. Left/Right step this
  /// directly (pure index stepping, immune to overlapping/gappy guide data);
  /// only a row change re-derives it from [_cursorTime] via [_selectedIndexIn].
  int _selectedCol = 0;

  /// Width of the timeline area (viewport minus the channel column), cached
  /// from the body [LayoutBuilder] for the reveal/clamp math.
  double _timelineWidth = 0;

  /// Resolved per-channel programmes, loaded lazily and request-coalesced: rows
  /// built in the same frame share one `programmesForChannels` query.
  final Map<String, List<Programme>> _programmes = {};
  final Set<String> _requested = {};
  final Set<String> _pendingBatch = {};
  bool _batchScheduled = false;

  static DateTime _floorToHalfHour(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 0 : 30);

  /// HH:mm — the one formatter for the ruler, detail bar and details dialog.
  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _panController.addListener(() {
      final tween = _panTween;
      if (tween != null) _hOffset.value = tween.value;
    });
    if (widget.channels.isNotEmpty) _ensureLoaded(widget.channels.first.id);
    // Open at "now" minus a little context.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToNow());
  }

  @override
  void dispose() {
    _panController.dispose();
    _hOffset.dispose();
    _vController.dispose();
    _gridFocus.dispose();
    super.dispose();
  }

  // ── Programme loading ──────────────────────────────────────────────────────

  void _ensureLoaded(String channelId) {
    if (_programmes.containsKey(channelId) || _requested.contains(channelId)) {
      return;
    }
    _requested.add(channelId);
    _pendingBatch.add(channelId);
    if (!_batchScheduled) {
      _batchScheduled = true;
      scheduleMicrotask(_runBatch);
    }
  }

  Future<void> _runBatch() async {
    _batchScheduled = false;
    final ids = _pendingBatch.toList();
    _pendingBatch.clear();
    if (ids.isEmpty) return;
    List<Programme> forId(Map<String, List<Programme>> byChannel, String id) =>
        byChannel[id] ?? const [];
    try {
      final byChannel = await widget.repo.db.programmesForChannels(
        widget.repo.source.id,
        ids,
        from: _windowStart,
        to: _windowEnd,
      );
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          _programmes[id] = forId(byChannel, id);
        }
        _resolveSelectedColOnLoad(ids);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          _programmes[id] = const [];
        }
      });
    }
  }

  /// Once the *selected* row's programmes finish loading, resolve which one the
  /// held cursor time selects — so the initial selection (and the detail bar)
  /// appears as soon as row 0 loads, and a row we scrolled onto before its data
  /// arrived catches up.
  void _resolveSelectedColOnLoad(List<String> loadedIds) {
    if (widget.channels.isEmpty) return;
    final selectedId = widget.channels[_selectedRow].id;
    if (!loadedIds.contains(selectedId)) return;
    final col = _resolveColForRow(_selectedRow);
    if (col >= 0) _selectedCol = col;
  }

  // ── Geometry / reveal ──────────────────────────────────────────────────────

  double _offsetForTime(DateTime time) =>
      time.difference(_windowStart).inMinutes * _pxPerMinute;

  double get _maxOffset =>
      (_totalWidth - _timelineWidth).clamp(0.0, double.infinity);

  /// Set the offset directly (touch drag), cancelling any running pan.
  void _panTo(double offset) {
    _panController.stop();
    _hOffset.value = offset.clamp(0.0, _maxOffset);
  }

  /// Smoothly pan to [target] (D-pad reveal / jump-to-now).
  void _animatePanTo(double target) {
    final clamped = target.clamp(0.0, _maxOffset);
    if ((clamped - _hOffset.value).abs() < 0.5) return;
    _panTween = Tween<double>(begin: _hOffset.value, end: clamped).animate(
      CurvedAnimation(parent: _panController, curve: Curves.easeOutCubic),
    );
    _panController.forward(from: 0);
  }

  /// Keep [programme]'s span horizontally in view.
  void _revealProgramme(Programme programme) {
    final left = _offsetForTime(_clampStart(programme));
    final width = _cellWidth(programme, _windowStart, _windowEnd);
    final offset = _hOffset.value;
    if (left < offset) {
      _animatePanTo(left - 24);
    } else if (left + width > offset + _timelineWidth) {
      _animatePanTo(left + width - _timelineWidth + 24);
    }
  }

  /// Scroll the vertical list so channel [row] sits centered in the viewport —
  /// a row that hugged the bottom edge would be covered by the detail bar.
  void _revealRow(int row) {
    if (!_vController.hasClients) return;
    final position = _vController.position;
    final target =
        (row * _rowHeight - (position.viewportDimension - _rowHeight) / 2)
            .clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.5) return;
    _vController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  DateTime _clampStart(Programme p) =>
      p.start.isBefore(_windowStart) ? _windowStart : p.start;

  void _jumpToNow() {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _cursorTime = now;
      final col = _resolveColForRow(_selectedRow);
      if (col >= 0) _selectedCol = col;
    });
    // Instant, not animated: the guide should open already at "now", and an
    // auto-started ticker here would fight the widget-test clock.
    _panTo(_offsetForTime(now) - 120);
  }

  // ── Selection / navigation ─────────────────────────────────────────────────

  /// The currently selected (channel, programme), or null when the selected
  /// row has no loaded programmes yet.
  (Channel, Programme)? get _selection {
    if (widget.channels.isEmpty) return null;
    final channel = widget.channels[_selectedRow];
    final items = _programmes[channel.id];
    if (items == null || items.isEmpty) return null;
    final index = _selectedCol.clamp(0, items.length - 1);
    return (channel, items[index]);
  }

  /// Re-derive [_selectedCol] for [row] from the held [_cursorTime]. Returns the
  /// programme index, or -1 when that row has no loaded programmes yet.
  int _resolveColForRow(int row) {
    if (row < 0 || row >= widget.channels.length) return -1;
    final items = _programmes[widget.channels[row].id];
    if (items == null || items.isEmpty) return -1;
    return _selectedIndexIn(items, _cursorTime);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      // At the top row, let focus escape upward to the AppBar action instead of
      // being trapped in the grid.
      if (_selectedRow == 0) return KeyEventResult.ignored;
      return _moveRow(-1);
    }
    if (key == LogicalKeyboardKey.arrowDown) return _moveRow(1);
    if (key == LogicalKeyboardKey.arrowLeft) return _moveColumn(-1);
    if (key == LogicalKeyboardKey.arrowRight) return _moveColumn(1);
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _activateSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Move the selection [delta] rows, clamped (no wrap). Keeps [_cursorTime] so
  /// the time column holds; re-derives the selected programme on the new row
  /// (the one airing at the held time) and drives the vertical scroll.
  KeyEventResult _moveRow(int delta) {
    final channels = widget.channels;
    if (channels.isEmpty) return KeyEventResult.handled;
    final next = (_selectedRow + delta).clamp(0, channels.length - 1);
    if (next == _selectedRow) return KeyEventResult.handled;
    _ensureLoaded(channels[next].id);
    setState(() {
      _selectedRow = next;
      // Hold the time column: pick the programme airing at [_cursorTime] on the
      // new row. When the row isn't loaded yet, _runBatch derives it on arrival.
      final col = _resolveColForRow(next);
      if (col >= 0) _selectedCol = col;
    });
    _revealRow(next);
    // The selected programme sits at the same time, so it's usually already in
    // view; reveal it anyway in case its span extends off-screen.
    final items = _programmes[channels[next].id];
    if (items != null && items.isNotEmpty) {
      _revealProgramme(items[_selectedCol.clamp(0, items.length - 1)]);
    }
    return KeyEventResult.handled;
  }

  /// Step the selection [delta] programmes along the current row, clamped (no
  /// wrap). Pure index stepping — the highlight follows [_selectedCol], not a
  /// re-resolution of [_cursorTime], so overlapping/duplicate guide entries
  /// can't trap the cursor. [_cursorTime] tracks the new programme's start so a
  /// later Up/Down still holds the right time column.
  KeyEventResult _moveColumn(int delta) {
    final channels = widget.channels;
    if (channels.isEmpty) return KeyEventResult.handled;
    final items = _programmes[channels[_selectedRow].id];
    if (items == null || items.isEmpty) return KeyEventResult.handled;
    final current = _selectedCol.clamp(0, items.length - 1);
    final next = (current + delta).clamp(0, items.length - 1);
    if (next == current) {
      if (_selectedCol != current) setState(() => _selectedCol = current);
      return KeyEventResult.handled;
    }
    final programme = items[next];
    setState(() {
      _selectedCol = next;
      _cursorTime = _clampStart(programme);
    });
    _revealProgramme(programme);
    return KeyEventResult.handled;
  }

  void _activateSelected() {
    final selection = _selection;
    if (selection == null) return;
    _showProgrammeDetails(selection.$1, selection.$2);
  }

  /// Touch: select the tapped cell and open its details.
  void _selectAndActivate(int row, Programme programme) {
    final items = _programmes[widget.channels[row].id] ?? const [];
    final index = items.indexOf(programme);
    setState(() {
      _selectedRow = row;
      if (index >= 0) _selectedCol = index;
      _cursorTime = _clampStart(programme);
    });
    _gridFocus.requestFocus();
    _showProgrammeDetails(widget.channels[row], programme);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TV guide'),
        actions: [
          IconButton(
            tooltip: 'Jump to now',
            icon: const Icon(Icons.today_rounded),
            onPressed: _jumpToNow,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          _timelineWidth = (constraints.maxWidth - _channelColumnWidth).clamp(
            0.0,
            double.infinity,
          );
          return Focus(
            focusNode: _gridFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              onHorizontalDragUpdate: (details) =>
                  _panTo(_hOffset.value - details.delta.dx),
              child: Column(
                children: [
                  _hourHeader(),
                  const Divider(height: 1, color: AppColors.line),
                  Expanded(
                    child: widget.channels.isEmpty
                        ? const Center(
                            child: Text(
                              'No channels',
                              style: TextStyle(color: AppColors.textLo),
                            ),
                          )
                        : ListView.builder(
                            controller: _vController,
                            itemExtent: _rowHeight,
                            itemCount: widget.channels.length,
                            itemBuilder: (context, i) {
                              final channel = widget.channels[i];
                              _ensureLoaded(channel.id);
                              return _ChannelRow(
                                channel: channel,
                                programmes: _programmes[channel.id] ?? const [],
                                isSelectedRow: i == _selectedRow,
                                selectedIndex: i == _selectedRow
                                    ? _selectedCol
                                    : -1,
                                windowStart: _windowStart,
                                windowEnd: _windowEnd,
                                pxPerMinute: _pxPerMinute,
                                timelineWidth: _timelineWidth,
                                channelColumnWidth: _channelColumnWidth,
                                hOffset: _hOffset,
                                onTapProgramme: (programme) =>
                                    _selectAndActivate(i, programme),
                              );
                            },
                          ),
                  ),
                  _focusedDetailBar(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Detail strip for the selected cell: cells too narrow for their title (a
  /// 15-minute programme is ~60px wide) get their full name/time read here.
  Widget _focusedDetailBar() {
    final selection = _selection;
    if (selection == null) return const SizedBox.shrink();
    final (channel, programme) = selection;
    final description = programme.description;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            programme.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${channel.name} · ${_hm(programme.start)} – ${_hm(programme.stop)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textLo, fontSize: 12),
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 4),
            // Give the synopsis its own room (up to three lines) instead of
            // cramming it onto the meta line — the reported "make the box bigger
            // to fit all the text".
            Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textLo,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showProgrammeDetails(Channel channel, Programme programme) {
    final now = DateTime.now();
    final isCurrent =
        !programme.start.isAfter(now) && programme.stop.isAfter(now);
    final isPast = !programme.stop.isAfter(now);
    final canCatchup = isPast && channel.hasArchive;

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          programme.title,
          style: const TextStyle(color: AppColors.textHi),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${channel.name} · ${_hm(programme.start)} – ${_hm(programme.stop)}',
              style: const TextStyle(color: AppColors.textLo, fontSize: 13),
            ),
            if (programme.description case final description?) ...[
              const SizedBox(height: 10),
              Text(
                description,
                maxLines: 10,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textLo),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            // Keep a focused control on a TV remote even when no contextual
            // action button renders (a future programme, or a past one on a
            // non-archive channel) — otherwise the dialog opens with nothing
            // focused and the D-pad has no target.
            autofocus: !canCatchup && !isCurrent,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (canCatchup)
            FilledButton.icon(
              autofocus: true,
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: const Text('Watch catch-up'),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onPlayArchive(channel, programme);
              },
            )
          else if (isCurrent)
            FilledButton.icon(
              autofocus: true,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Play live'),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onPlayChannel(channel);
              },
            ),
        ],
      ),
    );
  }

  Widget _hourHeader() {
    final hours = <Widget>[];
    var tick = _windowStart;
    while (tick.isBefore(_windowEnd)) {
      hours.add(
        Positioned(
          left: _offsetForTime(tick),
          top: 0,
          bottom: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _hm(tick),
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          ),
        ),
      );
      tick = tick.add(const Duration(minutes: 30));
    }
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const SizedBox(width: _channelColumnWidth),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: _hOffset,
                builder: (context, offset, child) => Transform.translate(
                  offset: Offset(-offset, 0),
                  child: child,
                ),
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: _totalWidth,
                  child: SizedBox(
                    width: _totalWidth,
                    child: Stack(children: hours),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Index of the programme selected at [t]: the one whose [start, stop) contains
/// [t] — the **latest-starting** such programme when guide entries overlap, so
/// it matches the front-painted cell — else (in a gap, or before the first) the
/// last one starting at/before [t], else the first. [items] must be sorted by
/// start. -1 when empty.
int _selectedIndexIn(List<Programme> items, DateTime t) {
  if (items.isEmpty) return -1;
  int? containing;
  for (var i = 0; i < items.length; i++) {
    final p = items[i];
    if (!p.start.isAfter(t) && p.stop.isAfter(t)) containing = i;
  }
  if (containing != null) return containing;
  var index = 0;
  for (var i = 0; i < items.length; i++) {
    if (!items[i].start.isAfter(t)) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

/// Painted width of [programme]'s cell. [nextStart] — the following
/// programme's start — visually truncates an overlong entry (bad guide
/// runtimes, e.g. a 13:00–17:00 row overlapping the 14:00 one) so cells never
/// overlap; the detail bar still shows the programme's real times.
double _cellWidth(
  Programme programme,
  DateTime windowStart,
  DateTime windowEnd, {
  DateTime? nextStart,
}) {
  final start = programme.start.isBefore(windowStart)
      ? windowStart
      : programme.start;
  var stop = programme.stop.isAfter(windowEnd) ? windowEnd : programme.stop;
  if (nextStart != null &&
      nextStart.isAfter(start) &&
      nextStart.isBefore(stop)) {
    stop = nextStart;
  }
  final width =
      stop.difference(start).inMinutes * _EpgGridScreenState._pxPerMinute;
  return width < 24 ? 24 : width;
}

class _ChannelRow extends StatelessWidget {
  /// Subtle full-row lift behind the selected channel (sits over the scaffold
  /// ink; the cells keep their own fills on top).
  static final Color _rowTint = AppColors.panelHi.withValues(alpha: 0.45);

  final Channel channel;
  final List<Programme> programmes;
  final bool isSelectedRow;

  /// The selected programme index on this row, or -1 when it isn't the selected
  /// row. Driven by the grid's [_EpgGridScreenState._selectedCol] so the
  /// highlight matches index stepping exactly (no per-row re-resolution).
  final int selectedIndex;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pxPerMinute;
  final double timelineWidth;
  final double channelColumnWidth;
  final ValueNotifier<double> hOffset;
  final ValueChanged<Programme> onTapProgramme;

  const _ChannelRow({
    required this.channel,
    required this.programmes,
    required this.isSelectedRow,
    required this.selectedIndex,
    required this.windowStart,
    required this.windowEnd,
    required this.pxPerMinute,
    required this.timelineWidth,
    required this.channelColumnWidth,
    required this.hOffset,
    required this.onTapProgramme,
  });

  double _left(DateTime time) =>
      time.difference(windowStart).inMinutes * pxPerMinute;

  DateTime _clampStart(Programme p) =>
      p.start.isBefore(windowStart) ? windowStart : p.start;

  @override
  Widget build(BuildContext context) {
    // A full-row lift plus an accent bar in the channel column marks the active
    // channel across the whole width — so it's clear *which* row the cursor is on
    // even when the selected cell sits far along the timeline. A ColoredBox (no
    // border/inset) keeps every row's timeline aligned with the hour ruler.
    return ColoredBox(
      color: isSelectedRow ? _rowTint : Colors.transparent,
      child: Row(
        children: [
          SizedBox(
            width: channelColumnWidth,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      if (channel.logo case final logo? when logo.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: logo,
                            width: 30,
                            height: 30,
                            fit: BoxFit.cover,
                            memCacheWidth: imageCacheSize(context, 30),
                            errorWidget: (_, _, _) => const SizedBox(width: 30),
                          ),
                        )
                      else
                        const SizedBox(width: 30),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          channel.number != null
                              ? '${channel.number} ${channel.name}'
                              : channel.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textHi,
                            fontSize: 12,
                            fontWeight: isSelectedRow
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelectedRow)
                  Positioned(
                    left: 0,
                    top: 8,
                    bottom: 8,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: hOffset,
                builder: (context, offset, _) {
                  // Horizontal virtualization: build only the cells whose span
                  // intersects the visible window (+ a buffer). Safe now that
                  // cells aren't focus targets — nothing to strand.
                  const buffer = 240.0;
                  final from = offset - buffer;
                  final to = offset + timelineWidth + buffer;
                  final cells = <Widget>[];
                  // The selected cell is appended last so it paints above any
                  // residual overlap (e.g. the 24px minimum width).
                  Widget? selectedCell;
                  for (var i = 0; i < programmes.length; i++) {
                    final p = programmes[i];
                    final left = _left(_clampStart(p));
                    final width = _cellWidth(
                      p,
                      windowStart,
                      windowEnd,
                      nextStart: i + 1 < programmes.length
                          ? programmes[i + 1].start
                          : null,
                    );
                    if (left + width < from || left > to) continue;
                    final cell = Positioned(
                      left: left - offset,
                      width: width,
                      top: 2,
                      bottom: 2,
                      child: _ProgrammeCell(
                        programme: p,
                        channelName: channel.name,
                        position: i + 1,
                        total: programmes.length,
                        selected: i == selectedIndex,
                        onTap: () => onTapProgramme(p),
                      ),
                    );
                    if (i == selectedIndex) {
                      selectedCell = cell;
                    } else {
                      cells.add(cell);
                    }
                  }
                  if (selectedCell != null) cells.add(selectedCell);
                  return Stack(clipBehavior: Clip.hardEdge, children: cells);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A lightweight programme cell — a plain tappable container with a
/// selection-driven highlight. Deliberately *not* a [FocusableCard]: hundreds
/// are laid out per screen, so it carries no focus node, InkWell, Material or
/// implicit animation. Focus/selection lives in the parent grid.
class _ProgrammeCell extends StatelessWidget {
  final Programme programme;
  final String channelName;
  final int position;
  final int total;
  final bool selected;
  final VoidCallback onTap;

  const _ProgrammeCell({
    required this.programme,
    required this.channelName,
    required this.position,
    required this.total,
    required this.selected,
    required this.onTap,
  });

  /// Selected cell fill: a solid accent-tinted lift (not just [AppColors.panelHi]),
  /// so the selection cursor reads clearly from across the room and it's obvious
  /// the D-pad is doing something — the reported "looks like nothing's selected".
  static final Color _selectedFill = Color.alphaBlend(
    AppColors.accent.withValues(alpha: 0.30),
    AppColors.panel,
  );

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent =
        !programme.start.isAfter(now) && programme.stop.isAfter(now);
    final isPast = !programme.stop.isAfter(now);
    return Semantics(
      label:
          '${programme.title}, $channelName, ${_EpgGridScreenState._hm(programme.start)} to ${_EpgGridScreenState._hm(programme.stop)}, $position of $total',
      button: true,
      selected: selected,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? _selectedFill : AppColors.panel,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.line,
              width: selected ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                programme.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected || isCurrent
                      ? AppColors.textHi
                      : isPast
                      ? AppColors.textLo
                      : AppColors.textLo.withValues(alpha: 0.8),
                  fontSize: 12,
                  fontWeight: selected
                      ? FontWeight.w700
                      : isCurrent
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
