// The in-player **quick list** (Phase 6): the browsable list the fullscreen
// live player opens over the video, and the one wire payload every surface
// renders it from.
//
// Like the rest of zapping (see `live_zap_controller.dart` and docs/player.md
// "Live zapping"), **Dart owns the list, the cursor and the decision**; the
// surfaces own only input and pixels. The quick list makes that split load
// more weight than the banner did — it is a *browsable* list, not a one-line
// readout — so the payload below is deliberately a **window of already
// formatted rows** rather than a model the surfaces walk:
//
//  * a launch range can be a 250k-channel catalog, and shipping it to Kotlin,
//    C++ and Lua once per open is not a thing a set-top box can afford;
//  * every label a surface draws (the now-playing secondary line, `HH:mm –
//    HH:mm`, the badges) is formatted *here*, so the four renderers cannot
//    disagree about wording the way the badge labels and the "Go to live"
//    chip once did (CLAUDE.md, "The live chrome is one layout on every
//    surface");
//  * a row carries plain flags (`selected`, `playing`, `archive`, `past`,
//    `live`) instead of a state a renderer has to re-derive from timestamps,
//    so "is this catch-up?" is answered once, by the side that knows what
//    `Channel.hasArchive` means.
//
// Nothing here imports a controller, a repository or a `SourceConfig`: it is a
// pure value layer, so `player_overlay.dart` and its widget tests stay
// libmpv-free exactly as [ZapBannerState] does.

import 'package:flutter/foundation.dart';

/// How many rows a `setQuickList` push carries around the cursor.
///
/// A window, not the whole list: the launch range is routinely the whole
/// catalog. 40 is comfortably more than any surface draws at once (the tallest
/// native list menu shows well under 20 rows), so the cursor can be walked and
/// even paged without a round trip in the common case, while the payload stays
/// a few kilobytes whatever the range's size.
const int kZapWindowRows = 40;

/// Which mode of the quick list's **mode stack** is on screen.
///
/// The stack is the whole navigation model: Right/OK descends, Left/Back
/// ascends, and Back at the top closes. It is deliberately *not* a
/// three-column panel — a column layout has to fit three lists at once, which
/// neither a 4:3 GDI overlay nor mpv's OSD can do legibly, and it would need
/// its own cross-pane focus rules on top of the ones docs/tv-navigation.md
/// already records.
enum ZapQuickListMode {
  /// The launch range's categories. Picking one **re-ranges** the session.
  categories,

  /// The channels of the current range, each with a now-playing line.
  channels,

  /// One channel's schedule for today.
  schedule,
}

/// What a row stands for, so a surface can pick an icon without parsing the
/// mode out of band.
enum ZapQuickListRowKind { category, channel, programme }

/// One rendered row of the quick list. Every string is final copy — a surface
/// prints it, never formats it.
@immutable
class ZapQuickListRow {
  const ZapQuickListRow({
    required this.index,
    required this.id,
    required this.label,
    required this.kind,
    this.secondary,
    this.badge,
    this.selected = false,
    this.playing = false,
    this.archive = false,
    this.past = false,
    this.live = false,
  });

  /// Absolute index in the full list, **not** in the window — so a surface can
  /// draw a position readout or a scrollbar without doing windowing maths.
  final int index;

  /// Stable identity within the mode: a category id (`''` = the mode's
  /// "everything" row), a channel id, or a programme's start in epoch
  /// milliseconds as a decimal string. Opaque to every surface; it exists so a
  /// pointer/touch tap can name a row rather than an index that may have moved.
  final String id;

  final String label;
  final ZapQuickListRowKind kind;

  /// The dimmer line under [label]: the channel's now-playing programme, a
  /// programme's `HH:mm – HH:mm`, or null.
  final String? secondary;

  /// A short trailing tag — `CATCH-UP`, `ON NOW`, `PLAYING` — or null.
  final String? badge;

  /// The cursor is on this row.
  final bool selected;

  /// This row is the channel the session is actually playing right now
  /// (which is not necessarily the selected one).
  final bool playing;

  /// Schedule rows: activating this row starts catch-up.
  final bool archive;

  /// Schedule rows: the programme has already ended.
  final bool past;

  /// Schedule rows: the programme is on air now.
  final bool live;

  Map<String, Object?> toPayload() => <String, Object?>{
    'index': index,
    'id': id,
    'label': label,
    'kind': kind.name,
    if (secondary != null) 'secondary': secondary,
    if (badge != null) 'badge': badge,
    'selected': selected,
    'playing': playing,
    'archive': archive,
    'past': past,
    'live': live,
  };

  @override
  bool operator ==(Object other) =>
      other is ZapQuickListRow &&
      other.index == index &&
      other.id == id &&
      other.label == label &&
      other.kind == kind &&
      other.secondary == secondary &&
      other.badge == badge &&
      other.selected == selected &&
      other.playing == playing &&
      other.archive == archive &&
      other.past == past &&
      other.live == live;

  @override
  int get hashCode => Object.hash(
    index,
    id,
    label,
    kind,
    secondary,
    badge,
    selected,
    playing,
    archive,
    past,
    live,
  );
}

/// The whole quick list as one immutable snapshot — the Flutter overlay's
/// input and, through [toPayload], the `setQuickList` wire payload.
///
/// Pure and dependency-free for the same reason [ZapBannerState] is
/// (`player_overlay.dart`): the widget that draws it, and the tests that
/// exercise that widget, must not need a `LiveZapController`, a repository or
/// libmpv.
@immutable
class ZapQuickListState {
  const ZapQuickListState({
    required this.open,
    required this.mode,
    required this.heading,
    required this.rows,
    required this.selectedIndex,
    required this.windowStart,
    required this.total,
    this.loading = false,
    this.emptyLabel,
    this.revision = 0,
  });

  /// The closed list — what every route that never opens one publishes, and
  /// what `setQuickList` pushes so a native surface tears its own list down.
  static const closed = ZapQuickListState(
    open: false,
    mode: ZapQuickListMode.channels,
    heading: '',
    rows: <ZapQuickListRow>[],
    selectedIndex: 0,
    windowStart: 0,
    total: 0,
  );

  final bool open;
  final ZapQuickListMode mode;

  /// The panel title: the source (categories), the category (channels), or the
  /// channel (schedule) — i.e. the rung above the one on screen.
  final String heading;

  /// The window: at most [kZapWindowRows] rows starting at [windowStart].
  final List<ZapQuickListRow> rows;

  /// Cursor position, **absolute** — an index into the full list, not into
  /// [rows]. `windowStart <= selectedIndex < windowStart + rows.length`
  /// whenever [total] is non-zero.
  final int selectedIndex;

  /// Absolute index of `rows.first`.
  final int windowStart;

  /// Size of the full list the window is cut from.
  final int total;

  /// A fetch is in flight (a category's channels, a channel's schedule).
  final bool loading;

  /// What to draw instead of rows when [total] is zero and nothing is loading
  /// — "No guide for today", "No channels here". Null while loading.
  final String? emptyLabel;

  /// Bumped on every change, so a surface can restart a dwell/animation on a
  /// real update rather than on an identical re-push. Same job as
  /// `LiveZapController.bannerRevision`.
  final int revision;

  /// The cursor's offset inside [rows], or -1 when the window doesn't hold it
  /// (only possible for an empty list).
  int get selectedInWindow {
    final offset = selectedIndex - windowStart;
    return offset >= 0 && offset < rows.length ? offset : -1;
  }

  bool get isEmpty => total == 0;

  Map<String, Object?> toPayload() => <String, Object?>{
    'open': open,
    'mode': mode.name,
    'heading': heading,
    'rows': [for (final row in rows) row.toPayload()],
    'selectedIndex': selectedIndex,
    'windowStart': windowStart,
    'total': total,
    'loading': loading,
    if (emptyLabel != null) 'emptyLabel': emptyLabel,
    'revision': revision,
  };

  @override
  bool operator ==(Object other) =>
      other is ZapQuickListState &&
      other.open == open &&
      other.mode == mode &&
      other.heading == heading &&
      other.selectedIndex == selectedIndex &&
      other.windowStart == windowStart &&
      other.total == total &&
      other.loading == loading &&
      other.emptyLabel == emptyLabel &&
      other.revision == revision &&
      listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(
    open,
    mode,
    heading,
    selectedIndex,
    windowStart,
    total,
    loading,
    emptyLabel,
    revision,
    Object.hashAll(rows),
  );
}

/// First index of the [window]-sized slice of a [total]-row list that contains
/// [selected], keeping the cursor centred where the list is long enough.
///
/// Pure, and pinned by `test/zap_quick_list_test.dart` at every edge, because
/// this is the one piece of arithmetic four renderers depend on being right:
/// a window that doesn't contain the cursor draws a list with no visible
/// selection, which on a remote is indistinguishable from a frozen screen (the
/// exact failure the EPG grid's horizontal reveal already records —
/// docs/tv-navigation.md).
int zapWindowStart({
  required int total,
  required int selected,
  int window = kZapWindowRows,
}) {
  if (total <= window || window <= 0) return 0;
  final half = window ~/ 2;
  var start = selected - half;
  if (start < 0) start = 0;
  if (start > total - window) start = total - window;
  return start;
}

String _pad2(int n) => n.toString().padLeft(2, '0');

/// `HH:mm`, 24-hour — the format every player surface already prints for the
/// live EPG strip (`epgRangeLabel`, the Compose/GDI/Lua strips).
String zapTimeLabel(DateTime t) => '${_pad2(t.hour)}:${_pad2(t.minute)}';

/// `HH:mm – HH:mm`, with the en dash the EPG strip uses.
String zapTimeRangeLabel(DateTime start, DateTime stop) =>
    '${zapTimeLabel(start)} – ${zapTimeLabel(stop)}';
