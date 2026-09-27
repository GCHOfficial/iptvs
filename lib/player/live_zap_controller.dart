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
       _launchIndex = initialIndex;

  final ZapCatalog catalog;
  final Duration settleDelay;

  /// Idle time before a typed channel number commits itself. Defaults to the
  /// value the live tab's own digit entry uses — they must agree — and is
  /// injectable only so tests don't have to wait it out.
  final Duration digitCommitDelay;
  final Duration messageDuration;

  final List<ZapEntry> _entries;
  int _index;
  int _playingIndex;
  int? _previousIndex;
  final int _launchIndex;
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
  ZapEntry get playing => _entries[_playingIndex];

  ZapEntry get launchEntry => _entries[_launchIndex];

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

  // ── Presentation, read by PlayerScreen in place of its widget fields ──────

  String get title => playing.name;
  String get sourceName => playing.sourceName;
  int? get channelNumber => playing.number;
  ({Programme? now, Programme? next}) get epg => catalog.epgFor(playing);
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
      case ZapCommandKind.closeList:
      case ZapCommandKind.move:
        // Quick list — Phase 6. Not consumed yet, so the surface keeps its
        // present behaviour rather than swallowing the key into a no-op.
        return false;
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

  /// Classic "last channel" recall. No-op until two channels have played.
  void previousChannel() {
    final target = _previousIndex;
    if (target == null || target == _index) return;
    _moveTo(target);
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
        final entry = _entries[target];
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
        _previousIndex = _playingIndex;
        _playingIndex = target;
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
    _index = _playingIndex;
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
