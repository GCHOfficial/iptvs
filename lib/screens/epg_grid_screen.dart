import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/library_repository.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/image_utils.dart';

/// EPG timeline grid: one row per channel, programme cells positioned on a
/// shared time axis (now − 1h → now + 24h, fixed scale).
///
/// Layout: rows are a lazy vertical `ListView`; the horizontal axis is **not**
/// a Scrollable — every row (and the hour header) is translated by one shared
/// [ValueNotifier] offset, which avoids N linked ScrollControllers and keeps
/// all rows aligned. D-pad focus drives the horizontal offset (a focused cell
/// scrolls itself into view); touch/mouse drag pans it.
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

class _EpgGridScreenState extends State<EpgGridScreen> {
  static const _pxPerMinute = 4.0; // 30-min slot = 120px
  static const _rowHeight = 52.0;
  static const _channelColumnWidth = 168.0;

  late final DateTime _windowStart = _floorToHalfHour(
    DateTime.now().subtract(const Duration(hours: 1)),
  );
  late final DateTime _windowEnd = _windowStart.add(
    const Duration(hours: 25),
  );

  double get _totalWidth =>
      _windowEnd.difference(_windowStart).inMinutes * _pxPerMinute;

  /// Shared horizontal offset for the header + every row.
  final ValueNotifier<double> _hOffset = ValueNotifier(0);
  final ScrollController _vController = ScrollController();

  /// The programme whose cell currently holds D-pad focus — shown in full in
  /// the detail bar below the grid, since narrow cells truncate their title.
  final ValueNotifier<(Channel, Programme)?> _focused = ValueNotifier(null);

  /// Per-channel programme futures, request-coalesced: rows built in the same
  /// frame share one `programmesForChannels` query instead of N single-channel
  /// lookups.
  final Map<String, Completer<List<Programme>>> _programmeRequests = {};
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
    // Open at "now" minus a little context.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToNow());
  }

  @override
  void dispose() {
    _hOffset.dispose();
    _vController.dispose();
    _focused.dispose();
    super.dispose();
  }

  double _offsetForTime(DateTime time) =>
      time.difference(_windowStart).inMinutes * _pxPerMinute;

  double get _maxOffset {
    final viewport =
        (context.findRenderObject() as RenderBox?)?.size.width ??
        MediaQuery.sizeOf(context).width;
    final visible = viewport - _channelColumnWidth;
    return (_totalWidth - visible).clamp(0.0, double.infinity);
  }

  void _panTo(double offset) =>
      _hOffset.value = offset.clamp(0.0, _maxOffset);

  void _jumpToNow() {
    if (!mounted) return;
    _panTo(_offsetForTime(DateTime.now()) - 120);
  }

  /// Keep the focused cell's span in view.
  void _revealSpan(double left, double width) {
    final viewport =
        ((context.findRenderObject() as RenderBox?)?.size.width ??
            MediaQuery.sizeOf(context).width) -
        _channelColumnWidth;
    final offset = _hOffset.value;
    if (left < offset) {
      _panTo(left - 24);
    } else if (left + width > offset + viewport) {
      _panTo(left + width - viewport + 24);
    }
  }

  Future<List<Programme>> _programmesFor(Channel channel) {
    final existing = _programmeRequests[channel.id];
    if (existing != null) return existing.future;
    final completer = Completer<List<Programme>>();
    _programmeRequests[channel.id] = completer;
    _pendingBatch.add(channel.id);
    if (!_batchScheduled) {
      _batchScheduled = true;
      // Coalesce all channels requested this frame into one query.
      scheduleMicrotask(_runBatch);
    }
    return completer.future;
  }

  Future<void> _runBatch() async {
    _batchScheduled = false;
    final ids = _pendingBatch.toList();
    _pendingBatch.clear();
    if (ids.isEmpty) return;
    try {
      final byChannel = await widget.repo.db.programmesForChannels(
        widget.repo.source.id,
        ids,
        from: _windowStart,
        to: _windowEnd,
      );
      for (final id in ids) {
        _programmeRequests[id]?.complete(byChannel[id] ?? const []);
      }
    } catch (error) {
      for (final id in ids) {
        final completer = _programmeRequests.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(const []);
        }
      }
    }
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
      body: GestureDetector(
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
                      itemBuilder: (context, i) => _ChannelRow(
                        channel: widget.channels[i],
                        autofocus: i == 0,
                        programmes: _programmesFor(widget.channels[i]),
                        windowStart: _windowStart,
                        windowEnd: _windowEnd,
                        pxPerMinute: _pxPerMinute,
                        totalWidth: _totalWidth,
                        channelColumnWidth: _channelColumnWidth,
                        hOffset: _hOffset,
                        onRevealSpan: _revealSpan,
                        onActivate: (programme) =>
                            _activate(widget.channels[i], programme),
                        onFocusProgramme: (programme) =>
                            _focused.value = (widget.channels[i], programme),
                      ),
                    ),
            ),
            _focusedDetailBar(),
          ],
        ),
      ),
    );
  }

  /// Detail strip for the focused cell: cells too narrow for their title (a
  /// 15-minute programme is ~60px wide) get their full name/time read here.
  Widget _focusedDetailBar() {
    return ValueListenableBuilder<(Channel, Programme)?>(
      valueListenable: _focused,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        final (channel, programme) = value;
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
                '${channel.name} · ${_hm(programme.start)} – ${_hm(programme.stop)}'
                '${description != null && description.isNotEmpty ? ' · $description' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textLo, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  void _activate(Channel channel, Programme programme) {
    final now = DateTime.now();
    final isCurrent =
        !programme.start.isAfter(now) && programme.stop.isAfter(now);
    if (isCurrent) {
      widget.onPlayChannel(channel);
      return;
    }
    final isPast = !programme.stop.isAfter(now);
    if (isPast && channel.hasArchive) {
      widget.onPlayArchive(channel, programme);
      return;
    }
    _showProgrammeDetails(channel, programme);
  }

  void _showProgrammeDetails(Channel channel, Programme programme) {
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
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
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

class _ChannelRow extends StatelessWidget {
  final Channel channel;
  final bool autofocus;
  final Future<List<Programme>> programmes;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pxPerMinute;
  final double totalWidth;
  final double channelColumnWidth;
  final ValueNotifier<double> hOffset;
  final void Function(double left, double width) onRevealSpan;
  final ValueChanged<Programme> onActivate;
  final ValueChanged<Programme> onFocusProgramme;

  const _ChannelRow({
    required this.channel,
    required this.autofocus,
    required this.programmes,
    required this.windowStart,
    required this.windowEnd,
    required this.pxPerMinute,
    required this.totalWidth,
    required this.channelColumnWidth,
    required this.hOffset,
    required this.onRevealSpan,
    required this.onActivate,
    required this.onFocusProgramme,
  });

  double _left(DateTime time) =>
      time.difference(windowStart).inMinutes * pxPerMinute;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: channelColumnWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                    style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: ValueListenableBuilder<double>(
              valueListenable: hOffset,
              builder: (context, offset, child) => Transform.translate(
                offset: Offset(-offset, 0),
                child: child,
              ),
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: totalWidth,
                child: SizedBox(
                  width: totalWidth,
                  child: FutureBuilder<List<Programme>>(
                    future: programmes,
                    builder: (context, snapshot) {
                      final items = snapshot.data;
                      if (items == null || items.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final (i, programme) in items.indexed)
                            Positioned(
                              left: _left(
                                programme.start.isBefore(windowStart)
                                    ? windowStart
                                    : programme.start,
                              ),
                              width: _cellWidth(programme),
                              top: 2,
                              bottom: 2,
                              child: _ProgrammeCell(
                                programme: programme,
                                autofocus: autofocus && i == _nowIndex(items),
                                onTap: () => onActivate(programme),
                                onFocused: () {
                                  onFocusProgramme(programme);
                                  onRevealSpan(
                                    _left(
                                      programme.start.isBefore(windowStart)
                                          ? windowStart
                                          : programme.start,
                                    ),
                                    _cellWidth(programme),
                                  );
                                },
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  double _cellWidth(Programme programme) {
    final start = programme.start.isBefore(windowStart)
        ? windowStart
        : programme.start;
    final stop = programme.stop.isAfter(windowEnd)
        ? windowEnd
        : programme.stop;
    final width = stop.difference(start).inMinutes * pxPerMinute;
    return width < 24 ? 24 : width;
  }

  int _nowIndex(List<Programme> items) {
    final now = DateTime.now();
    final index = items.indexWhere(
      (p) => !p.start.isAfter(now) && p.stop.isAfter(now),
    );
    return index < 0 ? 0 : index;
  }
}

class _ProgrammeCell extends StatelessWidget {
  final Programme programme;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onFocused;

  const _ProgrammeCell({
    required this.programme,
    required this.autofocus,
    required this.onTap,
    required this.onFocused,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent =
        !programme.start.isAfter(now) && programme.stop.isAfter(now);
    final isPast = !programme.stop.isAfter(now);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      child: FocusableCard(
        onTap: onTap,
        autofocus: autofocus,
        // The horizontal axis isn't a Scrollable; onFocused pans it instead.
        // Vertical ensureVisible still applies via the outer ListView.
        scrollOnFocus: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              programme.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isCurrent
                    ? AppColors.textHi
                    : isPast
                    ? AppColors.textLo
                    : AppColors.textLo.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
