// In-player live channel zapping: the Dart-authoritative state machine behind
// Up/Down channel changes, the "last channel" toggle, channel-number entry and
// (from Phase 6) the quick list.
//
// **Dart owns the list, the cursor and the decision; the surfaces own only
// input and pixels.** The launch list's ordering rules live nowhere else — the
// category filter, the catalog ordering favourites derive
// (`screens/favorites_order.dart`), and the cross-source Favorites view whose
// every row carries its *own* `SourceConfig` and therefore its own repository,
// EPG, buffering and favourites store. Re-deriving any of that in Kotlin, C++
// and Lua would be three more places for it to drift, and the failure mode is
// not a cosmetic one: it is playing provider B's channel through provider A's
// resolve. See docs/player.md "Live zapping".

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../sources/source.dart';
import '../sources/source_config.dart';
import 'buffer_preset.dart';
import 'zap_command.dart';
import 'zap_quick_list.dart';

/// How long the cursor must rest before the settled channel is resolved and
/// played.
///
/// This is what makes a *held* Up key cost one `create_link` instead of one per
/// channel passed — which on a single-connection Stalker portal is the
/// difference between zapping and a token storm. The banner updates
/// immediately on every press regardless; only playback waits.
const Duration kZapSettleDelay = Duration(milliseconds: 600);

/// How long a transient banner note ("No channel 123", a failed zap) stays up.
const Duration kZapMessageDuration = Duration(milliseconds: 1500);

/// One row of the zap range: a channel plus the source that owns it.
///
/// The config, not just an id, because *everything* per-channel is per-owning-
/// source — the repository that resolves it, its buffering preset, its stored
/// aspect mode, and which favourites store its star writes to. A cross-source
/// favourite carries a different one from the active source's.
@immutable
class ZapEntry {
  final Channel channel;
  final SourceConfig config;

  /// The owning source's *display* name — the player's source badge. Passed in
  /// rather than derived, because the active source's is `repo.source.name`
  /// (which a `SourceConfig` alone cannot produce without building a provider
  /// client) while a cross-source row's is its label.
  final String sourceName;

  const ZapEntry({
    required this.channel,
    required this.config,
    required this.sourceName,
  });

  String get sourceId => config.id;
  String get channelId => channel.id;
  String get name => channel.name;
  int? get number => channel.number;

  @override
  bool operator ==(Object other) =>
      other is ZapEntry &&
      other.channel.id == channel.id &&
      other.config.id == config.id;

  @override
  int get hashCode => Object.hash(channel.id, config.id);
}

/// Everything [LiveZapController] needs from the host screen, as an interface
/// so the controller can be unit-tested with no widget tree, no repository and
/// **no libmpv** — the last one is not optional, since a Windows dev box has
/// none and the suites that need one silently skip (CLAUDE.md, "Testing
/// notes").
abstract class ZapCatalog {
  /// Resolve [entry] through its *owning* source's repository. Called at play
  /// time only, never ahead — Stalker `create_link` locators are single-use.
  Future<StreamInfo> resolve(ZapEntry entry);

  /// The now/next snapshot for [entry], from the owning source's guide.
  ({Programme? now, Programme? next}) epgFor(ZapEntry entry);

  bool isFavorite(ZapEntry entry);
  Future<void> setFavorite(ZapEntry entry, bool value);

  /// The stored aspect-mode label of [entry]'s owning source, and the sink for
  /// a change made in the player. Per owning source, so a cross-source
  /// favourite's framing is stored against its own provider.
  String? aspectLabelFor(ZapEntry entry);
  Future<void> persistAspect(ZapEntry entry, String label);

  /// The buffering preset of [entry]'s owning source.
  BufferPreset bufferPresetFor(ZapEntry entry);

  /// A credential-free diagnostics note. Implementations route it to
  /// `DiagnosticsLog`; **never** pass a locator, a header or a logo URL.
  void log(String note);

  // ── Quick list (Phase 6) ─────────────────────────────────────────────────
  //
  // Three reads and nothing else. The controller never learns *how* a range
  // is shaped — whether these rows came from one provider's category list or
  // from the cross-source Favorites view grouped by owning source is entirely
  // the host's business, exactly as it already is for the launch range.

  /// The quick list's top mode: the categories this session's launch range
  /// can be re-ranged to, in catalog order, led by the range's "everything"
  /// row (id `''`).
  Future<List<ZapCategoryRow>> quickListCategories();

  /// The channels of [category] as a **fresh zap range**, in catalog order.
  /// An empty answer is refused by the controller rather than applied — a
  /// session with no entries has no channel to be on.
  Future<List<ZapEntry>> quickListChannels(ZapCategoryRow category);

  /// [entry]'s cached guide for **today** (local midnight to midnight), in
  /// start order. Empty when the source has no guide for it.
  Future<List<Programme>> quickListSchedule(ZapEntry entry);
}

/// One row of the quick list's [ZapQuickListMode.categories] mode.
///
/// Deliberately not `Category`: a cross-source Favorites range has no
/// provider categories at all, and its top mode lists *sources* instead (see
/// docs/player.md "The quick list (Phase 6)"). Both shapes are just an
/// id and a title to everything downstream.
@immutable
class ZapCategoryRow {
  const ZapCategoryRow({required this.id, required this.title});

  /// `''` is the mode's "everything" row — "All channels" on a single-source
  /// range, "Favorites · All sources" on the cross-source one. Never a
  /// provider category id.
  final String id;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is ZapCategoryRow && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

/// The live zap state machine for one fullscreen session.
///
/// Created by `channel_list_screen` when it opens the player, handed to
/// `PlayerScreen` as its `zap` field, and disposed when the route pops. It is
/// the single source of truth for *which live channel the player is on*, which
/// is why `PlayerScreen` reads title / EPG / favourite / aspect / buffering /
/// re-resolve through it rather than from its own immutable widget fields.
class LiveZapController extends ChangeNotifier {
  LiveZapController({
    required List<ZapEntry> entries,
    required int initialIndex,
    required this.catalog,
    String rangeCategoryId = '',
    String rangeLabel = 'Channels',
    this.settleDelay = kZapSettleDelay,
    this.digitCommitDelay = kDigitEntryCommitDelay,
    this.messageDuration = kZapMessageDuration,
  }) : // Stored by reference, not copied: a zap range is the whole catalog on
       // an unfiltered source, and `zapEntriesOf` hands over a *lazy* view
       // precisely so a 250k-channel launch doesn't materialise 250k objects
       // before the first frame. Callers pass a snapshot they never mutate.
       _entries = entries,
       assert(entries.isNotEmpty),
       assert(initialIndex >= 0 && initialIndex < entries.length),
       _index = initialIndex,
       _playingIndex = initialIndex,
       _playingEntry = entries[initialIndex],
       _launchEntry = entries[initialIndex],
       _rangeCatId = rangeCategoryId,
       _rangeCatLabel = rangeLabel;

  final ZapCatalog catalog;
  final Duration settleDelay;

  /// Idle time before a typed channel number commits itself. Defaults to the
  /// value the live tab's own digit entry uses — they must agree — and is
  /// injectable only so tests don't have to wait it out.
  final Duration digitCommitDelay;
  final Duration messageDuration;

  /// **Not final: the quick list can re-range a live session.** Picking a
  /// different category in the quick list replaces the list Up/Down walks —
  /// that is the whole point of offering categories in the player, and the
  /// alternative (a quick list that can only jump inside the launch range)
  /// would make the range a thing the user can never change without leaving
  /// the player. See [applyQuickListCategory].
  List<ZapEntry> _entries;
  int _index;

  /// The playing channel's index in the **current** range, or `-1` when a
  /// re-range left it outside — it is still what is on screen either way,
  /// which is why [_playingEntry] rather than this index is the authority.
  int _playingIndex;
  ZapEntry _playingEntry;

  /// "Last channel" is a *channel*, not an index: a re-range renumbers
  /// everything, and recalling row 7 of a list the user has since replaced
  /// would zap somewhere arbitrary.
  ZapEntry? _previousEntry;
  final ZapEntry _launchEntry;
  String _rangeCatId;
  String _rangeCatLabel;
  int _zapCount = 0;
  bool _disposed = false;

  final ZapDebounce _settleTimer = ZapDebounce();
  final ZapDebounce _digitTimer = ZapDebounce();
  Timer? _messageTimer;
  String _digitBuffer = '';
  String? _message;
  bool _settling = false;
  bool _settleRunning = false;
  bool _resettleWanted = false;

  /// Single-flight across the zap settle, the reconnect watchdog's re-resolve
  /// and "Go to live" — the Dart mirror of Kotlin's `ResolveGate`, for the
  /// same single-connection reason.
  final ZapResolveGate _gate = ZapResolveGate();

  // ── Wiring from PlayerScreen ───────────────────────────────────────────────

  /// Stop whatever is currently playing, before the next channel is resolved.
  /// Single-connection accounts refuse the new stream while the old one holds
  /// the slot, so this runs *first* and is awaited.
  Future<void> Function()? onStopCurrent;

  /// Play a freshly resolved [StreamInfo] on the surface already in use. The
  /// surface never changes on a zap (docs/player.md "Live zapping").
  Future<void> Function(StreamInfo stream, ZapEntry entry)? onPlay;

  /// Fired once per channel the session actually plays, so the host can note
  /// it as the last-played channel.
  void Function(ZapEntry entry)? onChannelChanged;

  // ── Read-only state ────────────────────────────────────────────────────────

  List<ZapEntry> get entries => _entries;
  int get index => _index;
  int get playingIndex => _playingIndex;

  /// The entry the cursor is on — which is what the banner shows and what the
  /// next settle will play. Between a keypress and the settle this is *ahead*
  /// of what is on screen; that is the point.
  ZapEntry get current => _entries[_index];

  /// The entry that is actually playing right now.
  ZapEntry get playing => _playingEntry;

  ZapEntry get launchEntry => _launchEntry;

  /// The category id the current range reflects (`''` = the range's
  /// "everything" row), and its display title.
  String get rangeCategoryId => _rangeCatId;
  String get rangeLabel => _rangeCatLabel;

  /// How many channel changes this session has actually played. Non-zero means
  /// the caller must not resume a preview onto the launch channel on return.
  int get zapCount => _zapCount;
  bool get zapped => _zapCount > 0;

  String get digitBuffer => _digitBuffer;
  String? get message => _message;

  /// True while a settled zap is stopping / resolving / opening. The live
  /// reconnect watchdog must stand down for the duration: the stream it would
  /// be reconnecting is one we deliberately stopped.
  bool get settling => _settling;

  bool get hasPendingMove => _settleTimer.pending || _index != _playingIndex;

  int _bannerRevision = 0;

  /// Bumped on every notification — the Dart mirror of Kotlin's
  /// `zapBannerAtMs`. The Flutter overlay's banner restarts its own dwell
  /// timer whenever this changes, so a held key keeps the banner up rather
  /// than letting an earlier press's timer expire mid-hold.
  int get bannerRevision => _bannerRevision;

  // ── Presentation, read by PlayerScreen in place of its widget fields ──────

  String get title => playing.name;
  String get sourceName => playing.sourceName;
  int? get channelNumber => playing.number;
  ({Programme? now, Programme? next}) get epg => catalog.epgFor(playing);

  /// The **cursor's** now/next — the guide of the channel a held key has got
  /// to, not the one still on screen. [epg] stays on the playing entry until
  /// the settle catches up; this is what the zap banner shows instead, so a
  /// held key's acknowledgement carries its own guide rather than the
  /// outgoing channel's.
  ({Programme? now, Programme? next}) get cursorEpg => catalog.epgFor(current);
  bool get isFavorite => catalog.isFavorite(playing);
  String? get aspectLabel => catalog.aspectLabelFor(playing);
  BufferPreset get bufferPreset => catalog.bufferPresetFor(playing);

  Future<void> setFavorite(bool value) => catalog.setFavorite(playing, value);
  Future<void> persistAspect(String label) =>
      catalog.persistAspect(playing, label);

  /// Banner payload for the native surfaces (`setZapBanner`). Carries the
  /// **cursor's** channel, not the playing one, because the banner is what
  /// tells the user where a held key has got to. Deliberately no URL, no
  /// headers and no logo beyond the provider-supplied one the row already
  /// draws elsewhere.
  Map<String, Object?> bannerPayload() {
    final entry = current;
    final guide = catalog.epgFor(entry);
    final now = guide.now;
    final next = guide.next;
    return <String, Object?>{
      if (entry.number != null) 'channelNumber': entry.number,
      'channelName': entry.name,
      'sourceName': entry.sourceName,
      if (entry.channel.logo != null) 'logoUrl': entry.channel.logo,
      'digits': _digitBuffer,
      if (_message != null) 'message': _message,
      'settling': _settling || _settleTimer.pending,
      'position': _index + 1,
      'total': _entries.length,
      if (now != null) ...{
        'epgNowTitle': now.title,
        'epgNowStartMs': now.start.millisecondsSinceEpoch.toDouble(),
        'epgNowStopMs': now.stop.millisecondsSinceEpoch.toDouble(),
        if (now.description != null && now.description!.isNotEmpty)
          'epgNowDesc': now.description,
      },
      if (next != null) ...{
        'epgNextTitle': next.title,
        'epgNextStartMs': next.start.millisecondsSinceEpoch.toDouble(),
        'epgNextStopMs': next.stop.millisecondsSinceEpoch.toDouble(),
      },
    };
  }

  // ── Input ──────────────────────────────────────────────────────────────────

  /// Applies one member of the shared vocabulary. Returns whether it was
  /// consumed, so a surface can fall through to its ordinary key handling.
  bool handleCommand(ZapCommand command) {
    // **While the quick list is open it owns navigation.** Nothing here can
    // change channel except an explicit OK on a row: a list on screen that
    // the user is reading must not have channels changing behind it, and the
    // dedicated channel keys would otherwise mean one thing on the video and
    // another over the list. They keep their meaning — "the next/previous
    // channel in list order" — applied to the cursor instead of to playback.
    if (_listOpen) return _handleQuickListCommand(command);
    switch (command.kind) {
      case ZapCommandKind.channelUp:
        channelUp();
        return true;
      case ZapCommandKind.channelDown:
        channelDown();
        return true;
      case ZapCommandKind.previousChannel:
        previousChannel();
        return true;
      case ZapCommandKind.digit:
        appendDigit(command.value);
        return true;
      case ZapCommandKind.activate:
        // OK commits a pending number early; otherwise it is not ours — the
        // surface's own OK (reveal the chrome) still runs.
        if (_digitBuffer.isEmpty) return false;
        commitDigits();
        return true;
      case ZapCommandKind.back:
        // Back clears a half-typed number before it means anything else, the
        // same peel-one-rung shape the live tab's Back ladder uses.
        if (_digitBuffer.isEmpty) return false;
        clearDigits();
        return true;
      case ZapCommandKind.favorite:
        unawaited(setFavorite(command.value == 1));
        return true;
      case ZapCommandKind.openList:
        openQuickList();
        return true;
      case ZapCommandKind.closeList:
        // Closed already: consumed all the same, so a surface's close key is
        // never handed on to mean something else.
        return true;
      case ZapCommandKind.descend:
      case ZapCommandKind.move:
        // Only meaningful over an open list; with none open they are not this
        // controller's keys, so the surface keeps its ordinary behaviour.
        return false;
    }
  }

  bool _handleQuickListCommand(ZapCommand command) {
    switch (command.kind) {
      case ZapCommandKind.openList:
        return true;
      case ZapCommandKind.closeList:
        closeQuickList();
        return true;
      case ZapCommandKind.move:
        moveQuickList(command.value);
        return true;
      // The dedicated channel keys move the cursor by one row **in list
      // order** — `channelUp` is "the next channel", which is the next row
      // *down*, exactly as it is for playback (see [channelUp]).
      case ZapCommandKind.channelUp:
        moveQuickList(1);
        return true;
      case ZapCommandKind.channelDown:
        moveQuickList(-1);
        return true;
      case ZapCommandKind.activate:
        if (_digitBuffer.isNotEmpty) {
          commitDigits();
          return true;
        }
        activateQuickList();
        return true;
      case ZapCommandKind.descend:
        descendQuickList();
        return true;
      case ZapCommandKind.back:
        if (_digitBuffer.isNotEmpty) {
          clearDigits();
          return true;
        }
        quickListBack();
        return true;
      case ZapCommandKind.digit:
        appendDigit(command.value);
        return true;
      case ZapCommandKind.previousChannel:
        // Consumed and inert: recall is a channel change, and the list is
        // open precisely because the user is choosing one deliberately.
        return true;
      case ZapCommandKind.favorite:
        // Still absolute, still about the **playing** channel — the star on
        // the chrome behind the list, not the row under the cursor.
        unawaited(setFavorite(command.value == 1));
        return true;
    }
  }

  /// Next higher channel: the next row *down* the launch list.
  ///
  /// **Both directions wrap**, unlike the live tab (where Up never wraps
  /// because it escapes to another pane). There is nothing to escape to here,
  /// and a remote that stops dead at the end of the list reads as broken.
  void channelUp() => _moveTo((_index + 1) % _entries.length);

  void channelDown() =>
      _moveTo((_index - 1 + _entries.length) % _entries.length);

  /// Classic "last channel" recall. No-op until two channels have played —
  /// and also a no-op when the previous channel isn't in the current range
  /// any more (the quick list re-ranged away from it), because there is no
  /// cursor position to move to and silently widening the range behind the
  /// user's back would be worse than doing nothing.
  void previousChannel() {
    final target = _previousEntry;
    if (target == null) return;
    final index = _indexOfEntry(target);
    if (index < 0 || index == _index) return;
    _moveTo(index);
  }

  void appendDigit(int digit) {
    if (digit < 0 || digit > 9) return;
    if (_digitBuffer.length >= kDigitEntryMaxDigits) return;
    _digitBuffer += '$digit';
    _clearMessage();
    _digitTimer.schedule(digitCommitDelay, commitDigits);
    _notify();
  }

  /// Jumps to the channel whose [Channel.number] matches the buffer.
  ///
  /// The search is **the zap range only** — the list Up/Down walks. Falling
  /// back to the whole source would land the player on a channel the cursor
  /// can't then step away from, and a cross-source launch list has no single
  /// "whole source" to fall back to. A miss says so in the banner and leaves
  /// playback alone. A number no channel carries (or a duplicate) resolves to
  /// the first match in list order, exactly as the live tab's own digit entry
  /// does.
  void commitDigits() {
    _digitTimer.cancel();
    final raw = _digitBuffer;
    if (raw.isEmpty) return;
    _digitBuffer = '';
    final number = int.tryParse(raw);
    if (number == null) {
      _notify();
      return;
    }
    final target = _entries.indexWhere((e) => e.number == number);
    // With the quick list open a typed number **moves the cursor**, it does
    // not zap: the list is on screen so the user can see and confirm what
    // they picked, and jumping playback out from under an open list is the
    // one thing the list exists to avoid. Only the channels mode can act on a
    // channel number at all; in the other two the buffer is simply dropped.
    if (_listOpen) {
      if (_listMode != ZapQuickListMode.channels) {
        _notify();
        return;
      }
      if (target < 0) {
        _showMessage('No channel $number');
        return;
      }
      _setQuickListCursor(target);
      return;
    }
    if (target < 0) {
      _showMessage('No channel $number');
      return;
    }
    if (target == _index) {
      _notify();
      return;
    }
    // A typed number is a deliberate, specific destination — there is no scan
    // to coalesce, so it commits at once rather than waiting out the settle.
    _moveTo(target, immediate: true);
  }

  void clearDigits() {
    _digitTimer.cancel();
    if (_digitBuffer.isEmpty) return;
    _digitBuffer = '';
    _notify();
  }

  /// Commits a pending cursor move now (used by OK and by teardown paths that
  /// must not leave a half-applied zap behind).
  void commitPendingMove() => _settleTimer.flush();

  // ── Quick list (Phase 6) ───────────────────────────────────────────────
  //
  // A **mode stack** over one list widget, not a three-column panel:
  // categories → channels → one channel's schedule for today. Right/OK
  // descends, Left/Back ascends, Back at the top closes. The cursor is a
  // plain integer per mode and rows are never focus targets, which is the
  // same selection model the live tab and the EPG grid use and for the same
  // reason (docs/tv-navigation.md) — an off-screen row in a lazily built list
  // cannot be focused, and this list is routinely 250k rows long.

  bool _listOpen = false;
  ZapQuickListMode _listMode = ZapQuickListMode.channels;

  /// Monotonic, bumped by every mode change, open and close. A fetch that
  /// comes back against a stale generation is dropped — the same
  /// generation-guard rule `MediaTabController`/`LiveController` follow
  /// (CLAUDE.md, "Async publishes are generation-guarded").
  int _listGeneration = 0;
  bool _listLoading = false;
  String? _listEmptyLabel;

  List<ZapCategoryRow> _categories = const [];
  int _categoryCursor = 0;

  /// The channels mode's cursor is an index into [_entries] — the live zap
  /// range itself, never a copy of it.
  int _channelCursor = 0;

  ZapEntry? _scheduleEntry;
  List<Programme> _schedule = const [];
  int _scheduleCursor = 0;

  ({ZapEntry entry, Programme programme})? _pendingCatchup;

  /// Asks the host to end the fullscreen session. Wired by `PlayerScreen` to
  /// its own back action, and used for exactly one thing: leaving live for
  /// catch-up (see [pendingCatchup]).
  void Function()? onExitRequested;

  bool get quickListOpen => _listOpen;
  ZapQuickListMode get quickListMode => _listMode;

  /// Set when OK landed on a **past** programme of an archive channel. The
  /// host reads it after its route pops and opens catch-up through its own
  /// existing path.
  ///
  /// Catch-up deliberately does **not** play in place. It is VOD-shaped — a
  /// seek bar, no live reconnect watchdog, its own iOS engine key, no zap
  /// range — so playing it on the live route would mean reconfiguring the
  /// watchdog, the overlay, the dynamic-range escalation and the native
  /// surface mid-session, which is the "the surface never changes on a zap"
  /// invariant stood on its head. Ending the session and reopening through
  /// the channel list's shipped `_playCatchup` costs one route transition and
  /// reuses a path that already works on every platform.
  ({ZapEntry entry, Programme programme})? get pendingCatchup =>
      _pendingCatchup;

  /// Opens on the **channels** mode, cursor on the channel actually playing.
  ///
  /// Channels rather than categories because that is the rung the user wants
  /// nine times out of ten, and because it is the only one that needs no
  /// fetch at all — the range is already in hand, so the list draws on the
  /// same frame as the keypress.
  void openQuickList() {
    if (_listOpen) return;
    _listOpen = true;
    _listGeneration++;
    _listLoading = false;
    _listEmptyLabel = null;
    _listMode = ZapQuickListMode.channels;
    _channelCursor = _playingIndex >= 0 ? _playingIndex : _index;
    _notify();
  }

  void closeQuickList() {
    if (!_listOpen) return;
    _listOpen = false;
    // Bumped so a fetch still in flight can never publish into a closed list
    // (or, worse, into the next one the user opens).
    _listGeneration++;
    _listLoading = false;
    _listEmptyLabel = null;
    _scheduleEntry = null;
    _schedule = const [];
    _notify();
  }

  /// One rung up the stack; at the top it closes.
  void quickListBack() {
    if (!_listOpen) return;
    switch (_listMode) {
      case ZapQuickListMode.schedule:
        _listGeneration++;
        _listLoading = false;
        _listEmptyLabel = null;
        _scheduleEntry = null;
        _schedule = const [];
        _listMode = ZapQuickListMode.channels;
        _notify();
      case ZapQuickListMode.channels:
        unawaited(_openCategories());
      case ZapQuickListMode.categories:
        closeQuickList();
    }
  }

  /// One rung down the stack. OK and Right agree everywhere except the
  /// channels mode, where OK *plays* and Right opens the schedule.
  void descendQuickList() {
    if (!_listOpen) return;
    switch (_listMode) {
      case ZapQuickListMode.categories:
        activateQuickList();
      case ZapQuickListMode.channels:
        if (_entries.isEmpty) return;
        unawaited(_openSchedule(_entries[_channelCursor]));
      case ZapQuickListMode.schedule:
        activateQuickList();
    }
  }

  /// Moves the cursor by [delta] rows, **clamped, never wrapped**.
  ///
  /// Unlike the player's Up/Down (which wrap, because there is nothing to
  /// escape to on a bare video — docs/tv-navigation.md "In-player
  /// navigation"), a list on screen has visible ends, and `zap:move` carries
  /// an arbitrary signed delta so a page key can move by a screenful: wrapping
  /// a 250k-row list on a PageDown would be a jump the user cannot undo by
  /// pressing the opposite key.
  void moveQuickList(int delta) {
    if (!_listOpen || delta == 0) return;
    _setQuickListCursor(_quickListCursor + delta);
  }

  void _setQuickListCursor(int target) {
    final total = _quickListTotal;
    if (total == 0) return;
    final clamped = target < 0
        ? 0
        : target > total - 1
        ? total - 1
        : target;
    if (clamped == _quickListCursor) return;
    switch (_listMode) {
      case ZapQuickListMode.categories:
        _categoryCursor = clamped;
      case ZapQuickListMode.channels:
        _channelCursor = clamped;
      case ZapQuickListMode.schedule:
        _scheduleCursor = clamped;
    }
    _notify();
  }

  /// OK on the selected row.
  void activateQuickList() {
    if (!_listOpen || _listLoading) return;
    switch (_listMode) {
      case ZapQuickListMode.categories:
        if (_categories.isEmpty) return;
        unawaited(applyQuickListCategory(_categories[_categoryCursor]));
      case ZapQuickListMode.channels:
        if (_entries.isEmpty) return;
        final target = _channelCursor;
        closeQuickList();
        // A deliberate, specific destination, exactly like a typed channel
        // number: it commits at once rather than waiting out the settle
        // window, which exists to coalesce a *scan*.
        _moveTo(target, immediate: true);
      case ZapQuickListMode.schedule:
        _activateScheduleRow();
    }
  }

  void _activateScheduleRow() {
    final entry = _scheduleEntry;
    if (entry == null || _schedule.isEmpty) return;
    final programme = _schedule[_scheduleCursor];
    final past = !programme.stop.isAfter(DateTime.now());
    if (past && entry.channel.hasArchive) {
      _pendingCatchup = (entry: entry, programme: programme);
      catalog.log(
        'zap quick list catch-up source=${entry.sourceName} '
        'channel=${entry.name} programme=${programme.title}',
      );
      closeQuickList();
      onExitRequested?.call();
      return;
    }
    // Current or future programme (or a channel with no archive): the only
    // thing there is to play is the channel, live.
    final index = _indexOfEntry(entry);
    closeQuickList();
    if (index < 0) return;
    _moveTo(index, immediate: true);
  }

  /// Re-ranges the session to [category] and drops back into the channels
  /// mode on it.
  ///
  /// **This changes the Up/Down range too, deliberately.** The quick list is
  /// the only way to change the range without leaving the player, and a list
  /// that could move the cursor somewhere Up/Down then refuses to follow
  /// would be two cursors over two different lists — the exact
  /// "which list am I in" confusion the single selection model exists to
  /// avoid. An **empty** category is refused instead of applied: a session
  /// with no entries has no channel to be on, and the range the user can
  /// still see is better than none.
  Future<void> applyQuickListCategory(ZapCategoryRow category) async {
    final generation = ++_listGeneration;
    _listLoading = true;
    _listEmptyLabel = null;
    _notify();
    List<ZapEntry> rows;
    try {
      rows = await catalog.quickListChannels(category);
    } catch (error) {
      catalog.log('zap quick list channels failed: ${error.runtimeType}');
      rows = const [];
    }
    if (_disposed || generation != _listGeneration) return;
    _listLoading = false;
    if (rows.isEmpty) {
      _showMessage('No channels in ${category.title}');
      return;
    }
    _entries = rows;
    _rangeCatId = category.id;
    _rangeCatLabel = category.title;
    _playingIndex = _indexOfEntry(_playingEntry);
    _index = _playingIndex >= 0 ? _playingIndex : 0;
    _channelCursor = _index;
    _listMode = ZapQuickListMode.channels;
    catalog.log(
      'zap quick list re-range category=${category.title} rows=${rows.length}',
    );
    _notify();
  }

  Future<void> _openCategories() async {
    final generation = ++_listGeneration;
    _listMode = ZapQuickListMode.categories;
    _listLoading = true;
    _listEmptyLabel = null;
    _notify();
    List<ZapCategoryRow> rows;
    try {
      rows = await catalog.quickListCategories();
    } catch (error) {
      catalog.log('zap quick list categories failed: ${error.runtimeType}');
      rows = const [];
    }
    if (_disposed || generation != _listGeneration) return;
    _categories = rows;
    _listLoading = false;
    _listEmptyLabel = rows.isEmpty ? 'No categories' : null;
    final current = rows.indexWhere((row) => row.id == _rangeCatId);
    _categoryCursor = current < 0 ? 0 : current;
    _notify();
  }

  Future<void> _openSchedule(ZapEntry entry) async {
    final generation = ++_listGeneration;
    _listMode = ZapQuickListMode.schedule;
    _scheduleEntry = entry;
    _schedule = const [];
    _scheduleCursor = 0;
    _listLoading = true;
    _listEmptyLabel = null;
    _notify();
    List<Programme> rows;
    try {
      rows = await catalog.quickListSchedule(entry);
    } catch (error) {
      catalog.log('zap quick list schedule failed: ${error.runtimeType}');
      rows = const [];
    }
    if (_disposed || generation != _listGeneration) return;
    _schedule = rows;
    _listLoading = false;
    _listEmptyLabel = rows.isEmpty ? 'No guide for today' : null;
    // Opens on what is airing now — the row the user is looking at the video
    // of — falling back to the first of the day.
    final now = DateTime.now();
    final airing = rows.indexWhere(
      (p) => !p.start.isAfter(now) && p.stop.isAfter(now),
    );
    _scheduleCursor = airing < 0 ? 0 : airing;
    _notify();
  }

  int get _quickListTotal => switch (_listMode) {
    ZapQuickListMode.categories => _categories.length,
    ZapQuickListMode.channels => _entries.length,
    ZapQuickListMode.schedule => _schedule.length,
  };

  int get _quickListCursor => switch (_listMode) {
    ZapQuickListMode.categories => _categoryCursor,
    ZapQuickListMode.channels => _channelCursor,
    ZapQuickListMode.schedule => _scheduleCursor,
  };

  /// The quick list as one immutable snapshot — the Flutter overlay's input
  /// and, through [ZapQuickListState.toPayload], the `setQuickList` wire
  /// payload. Built fresh on read; nothing caches it, because every field is
  /// derived from state the controller already holds.
  ZapQuickListState get quickList {
    if (!_listOpen) return ZapQuickListState.closed;
    final total = _quickListTotal;
    final cursor = total == 0 ? 0 : _quickListCursor;
    final start = zapWindowStart(total: total, selected: cursor);
    final end = total < start + kZapWindowRows ? total : start + kZapWindowRows;
    return ZapQuickListState(
      open: true,
      mode: _listMode,
      heading: switch (_listMode) {
        ZapQuickListMode.categories => playing.sourceName,
        ZapQuickListMode.channels => _rangeCatLabel,
        ZapQuickListMode.schedule => _scheduleEntry?.name ?? '',
      },
      rows: [
        for (var i = start; i < end; i++) _quickListRow(i, selected: i == cursor),
      ],
      selectedIndex: cursor,
      windowStart: start,
      total: total,
      loading: _listLoading,
      emptyLabel: _listLoading ? null : _listEmptyLabel,
      revision: _bannerRevision,
    );
  }

  /// The `setQuickList` payload. A no-op-shaped `{open: false, …}` while the
  /// list is closed, so a surface always has something to tear down with.
  Map<String, Object?> quickListPayload() => quickList.toPayload();

  ZapQuickListRow _quickListRow(int index, {required bool selected}) {
    switch (_listMode) {
      case ZapQuickListMode.categories:
        final row = _categories[index];
        return ZapQuickListRow(
          index: index,
          id: row.id,
          label: row.title,
          kind: ZapQuickListRowKind.category,
          selected: selected,
          playing: row.id == _rangeCatId,
        );
      case ZapQuickListMode.channels:
        final entry = _entries[index];
        final guide = catalog.epgFor(entry);
        final number = entry.number;
        return ZapQuickListRow(
          index: index,
          id: entry.channelId,
          label: number == null ? entry.name : '$number · ${entry.name}',
          kind: ZapQuickListRowKind.channel,
          // The now-playing line the design asks for, falling back to the
          // owning source — which on a cross-source Favorites range is the
          // one thing that tells two identically named rows apart.
          secondary: guide.now?.title ?? entry.sourceName,
          selected: selected,
          playing: entry == _playingEntry,
        );
      case ZapQuickListMode.schedule:
        final programme = _schedule[index];
        final now = DateTime.now();
        final past = !programme.stop.isAfter(now);
        final live = !programme.start.isAfter(now) && !past;
        final archive =
            past && (_scheduleEntry?.channel.hasArchive ?? false);
        return ZapQuickListRow(
          index: index,
          id: '${programme.start.millisecondsSinceEpoch}',
          label: programme.title,
          kind: ZapQuickListRowKind.programme,
          secondary: zapTimeRangeLabel(programme.start, programme.stop),
          badge: live
              ? 'ON NOW'
              : archive
              ? 'CATCH-UP'
              : null,
          selected: selected,
          archive: archive,
          past: past,
          live: live,
        );
    }
  }

  /// Index of [entry] in the current range, or -1. O(n) and deliberately only
  /// called on a re-range or a recall — the lazy range materialises a
  /// `ZapEntry` per probe, so this must never reach a per-keypress path.
  int _indexOfEntry(ZapEntry entry) {
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i] == entry) return i;
    }
    return -1;
  }

  // ── Resolve ────────────────────────────────────────────────────────────────

  /// Re-resolves the channel **currently playing** — this is what
  /// `PlayerScreen.resolveAgain` becomes once zapping exists, so the reconnect
  /// watchdog and "Go to live" act on the channel on screen rather than the
  /// one the route was launched with.
  ///
  /// Returns null when a zap owns the round trip, which the caller already
  /// treats as "keep the locator we have" (`_freshLiveStream`).
  Future<StreamInfo?> resolveCurrent() async {
    if (_settleRunning) return null;
    final token = _gate.begin();
    if (token == null) return null;
    try {
      final stream = await catalog.resolve(playing);
      if (!_gate.settle(token)) return null;
      return stream;
    } catch (_) {
      _gate.settle(token);
      rethrow;
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  void _moveTo(int target, {bool immediate = false}) {
    if (_disposed) return;
    _index = target;
    _clearMessage();
    _notify();
    if (immediate) {
      _settleTimer.cancel();
      unawaited(_settle());
    } else {
      _settleTimer.schedule(settleDelay, () => unawaited(_settle()));
    }
  }

  Future<void> _settle() async {
    if (_disposed) return;
    if (_settleRunning) {
      // A resolve is already in flight. Coalesce rather than starting a second
      // one: provider accounts are single-connection, and the loop below
      // re-reads the cursor when it finishes.
      _resettleWanted = true;
      return;
    }
    _settleRunning = true;
    _setSettling(true);
    try {
      do {
        _resettleWanted = false;
        final target = _index;
        if (target == _playingIndex) break;
        // The list this index belongs to, captured with it: the quick list
        // can re-range the session while a settle is in flight, and `target`
        // then means a different row (or none) in the new range.
        final list = _entries;
        final entry = list[target];
        // A reconnect re-resolve in flight describes the channel we are
        // leaving; discard its outcome rather than let it reload behind us.
        // (The HTTP call itself can't be cancelled — the same tolerance
        // Kotlin's `ResolveGate` timeout path already has.)
        _gate.abandon();
        final token = _gate.begin();
        catalog.log(
          'zap settle source=${entry.sourceName} channel=${entry.name} '
          'id=${entry.channelId}',
        );
        StreamInfo? stream;
        Object? failure;
        try {
          // Stop first: the old stream holds the account's one connection, and
          // a single-connection portal refuses the new create_link while it
          // does.
          await onStopCurrent?.call();
          stream = await catalog.resolve(entry);
        } catch (error) {
          failure = error;
        }
        if (token != null && !_gate.settle(token)) {
          // Superseded while we were away — the newer settle owns the outcome.
          continue;
        }
        if (_disposed) return;
        if (stream == null) {
          catalog.log('zap failed channel=${entry.name} id=${entry.channelId}');
          await _revertFailedZap(entry, failure);
          continue;
        }
        _previousEntry = _playingEntry;
        // `_playingEntry` is the authority; the index is only re-derived —
        // at O(n), and only on the rare re-range-during-settle race — when
        // the range moved under us. Getting it wrong would draw the
        // "playing" marker on the wrong quick-list row and open the list on
        // it.
        _playingIndex = identical(list, _entries)
            ? target
            : _indexOfEntry(entry);
        _playingEntry = entry;
        _zapCount++;
        onChannelChanged?.call(entry);
        await onPlay?.call(stream, entry);
      } while (_resettleWanted && !_disposed);
    } finally {
      _settleRunning = false;
      _setSettling(false);
    }
  }

  /// A failed zap has already stopped the previous stream, so reporting is not
  /// enough — the channel the user was watching has to be brought back.
  Future<void> _revertFailedZap(ZapEntry attempted, Object? error) async {
    if (_playingIndex >= 0) _index = _playingIndex;
    _showMessage("Couldn't play ${attempted.name}");
    try {
      final restored = await catalog.resolve(playing);
      if (_disposed) return;
      await onPlay?.call(restored, playing);
    } catch (_) {
      // Nothing left to try: the surface keeps its own error/reconnect
      // handling, which is what a dead stream would have hit anyway.
    }
  }

  void _setSettling(bool value) {
    if (_settling == value) return;
    _settling = value;
    _notify();
  }

  void _showMessage(String text) {
    _message = text;
    _messageTimer?.cancel();
    _messageTimer = Timer(messageDuration, () {
      _messageTimer = null;
      if (_message == null) return;
      _message = null;
      _notify();
    });
    _notify();
  }

  void _clearMessage() {
    _messageTimer?.cancel();
    _messageTimer = null;
    if (_message == null) return;
    _message = null;
  }

  void _notify() {
    if (_disposed) return;
    _bannerRevision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _settleTimer.cancel();
    _digitTimer.cancel();
    _messageTimer?.cancel();
    _messageTimer = null;
    onStopCurrent = null;
    onPlay = null;
    onChannelChanged = null;
    onExitRequested = null;
    super.dispose();
  }
}


/// A read-only, **lazily materialised** [ZapEntry] view over a channel list
/// that all belongs to one source — which is every launch range except the
/// cross-source Favorites view.
///
/// The entries are built on access rather than up front because an unfiltered
/// source's zap range is its whole catalog: eagerly wrapping 250k channels
/// would cost several megabytes and a visible pause on a set-top box, at the
/// exact moment the user is waiting for a picture. Lookups are O(1) and the
/// transient entries a scan creates are collected immediately.
List<ZapEntry> zapEntriesOf(
  List<Channel> channels, {
  required SourceConfig config,
  required String sourceName,
}) => _HomogeneousZapEntries(channels, config, sourceName);

class _HomogeneousZapEntries extends ListBase<ZapEntry> {
  _HomogeneousZapEntries(this._channels, this._config, this._sourceName);

  final List<Channel> _channels;
  final SourceConfig _config;
  final String _sourceName;

  @override
  int get length => _channels.length;

  @override
  set length(int value) =>
      throw UnsupportedError('A zap range is a snapshot; it cannot be resized');

  @override
  ZapEntry operator [](int index) => ZapEntry(
    channel: _channels[index],
    config: _config,
    sourceName: _sourceName,
  );

  @override
  void operator []=(int index, ZapEntry value) =>
      throw UnsupportedError('A zap range is a snapshot; it cannot be written');
}
