// The in-player live-zapping command vocabulary, shared by **every** surface.
//
// The zap state machine is Dart-authoritative (see [LiveZapController] and
// docs/player.md "Live zapping"): the native surfaces are input sources and
// views, never owners of the channel list or the cursor. Each one therefore
// only ever sends one of these short strings up to Dart:
//
// - Android: `nativeZap` on `iptvs/native_hdr_player`, `{command: <string>}`
// - Windows: the existing `nativeControl` method, same strings
// - Linux: the existing `user-data/iptvs-control` property, same strings
// - the shared Flutter overlay: its own key bindings, parsed through here too
//
// One vocabulary and **one parser** is the whole point. The repo's history is
// that presentation rules re-implemented per surface drift (badge labels, the
// favorite-star slot, the "Go to live" label); a *navigation* rule that drifts
// would zap to the wrong channel, so the string is parsed in exactly one
// place and the surfaces hold none of the meaning.

import 'dart:async';

import 'package:flutter/services.dart';

/// What a parsed zap command asks the controller to do.
enum ZapCommandKind {
  /// Next higher channel — the next row *down* the launch list.
  channelUp,

  /// Next lower channel — the previous row up the launch list.
  channelDown,

  /// The classic "last channel" toggle.
  previousChannel,

  /// Open the quick list.
  openList,

  /// Close the quick list.
  closeList,

  /// Append a digit to the channel-number entry buffer.
  digit,

  /// Move the quick list's cursor by [ZapCommand.value] rows.
  move,

  /// OK on the quick list's selected row (or commit the digit buffer).
  activate,

  /// Back/Left inside the quick list — pop one mode off its stack.
  back,

  /// Set the current channel's favorite state absolutely
  /// ([ZapCommand.value] `1`/`0`).
  favorite,
}

/// A parsed member of the zap vocabulary. [value] is meaningful for
/// [ZapCommandKind.digit] (0..9), [ZapCommandKind.move] (a signed row delta)
/// and [ZapCommandKind.favorite] (1/0); it is 0 otherwise.
class ZapCommand {
  final ZapCommandKind kind;
  final int value;

  const ZapCommand(this.kind, [this.value = 0]);

  @override
  bool operator ==(Object other) =>
      other is ZapCommand && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'ZapCommand(${kind.name}, $value)';
}

/// Parses one command string from any surface. Returns null for anything that
/// isn't part of the vocabulary — including a well-formed prefix with an
/// unusable argument (`zap:digit:x`), because a command we can't read is not a
/// command we should guess at.
ZapCommand? parseZapCommand(String? raw) {
  if (raw == null) return null;
  switch (raw) {
    case 'zap:up':
      return const ZapCommand(ZapCommandKind.channelUp);
    case 'zap:down':
      return const ZapCommand(ZapCommandKind.channelDown);
    case 'zap:prev':
      return const ZapCommand(ZapCommandKind.previousChannel);
    case 'zap:list':
      return const ZapCommand(ZapCommandKind.openList);
    case 'zap:close':
      return const ZapCommand(ZapCommandKind.closeList);
    case 'zap:activate':
      return const ZapCommand(ZapCommandKind.activate);
    case 'zap:back':
      return const ZapCommand(ZapCommandKind.back);
  }
  if (raw.startsWith('zap:digit:')) {
    final digit = int.tryParse(raw.substring('zap:digit:'.length));
    if (digit == null || digit < 0 || digit > 9) return null;
    return ZapCommand(ZapCommandKind.digit, digit);
  }
  if (raw.startsWith('zap:move:')) {
    final delta = int.tryParse(raw.substring('zap:move:'.length));
    if (delta == null || delta == 0) return null;
    return ZapCommand(ZapCommandKind.move, delta);
  }
  if (raw.startsWith('favorite:')) {
    final value = raw.substring('favorite:'.length);
    if (value != '0' && value != '1') return null;
    return ZapCommand(ZapCommandKind.favorite, value == '1' ? 1 : 0);
  }
  return null;
}

// ── Channel-number entry ─────────────────────────────────────────────────────
//
// Shared by the live tab's `LiveFocusCoordinator` and the in-player
// [LiveZapController]. They are the *same gesture* in two places — typing a
// channel number on a remote — and two copies of the timing would be two
// different behaviours the user has to learn.

/// Idle time after the last digit before the buffer commits on its own.
const Duration kDigitEntryCommitDelay = Duration(milliseconds: 1500);

/// Longest channel number the buffer will accept.
const int kDigitEntryMaxDigits = 4;

/// Digit keys a remote / keyboard / numpad can produce.
///
/// Not `const`: [LogicalKeyboardKey] overrides `==`, which bars it from keying
/// a const map.
final Map<LogicalKeyboardKey, int> kDigitEntryKeys = {
  LogicalKeyboardKey.digit0: 0,
  LogicalKeyboardKey.digit1: 1,
  LogicalKeyboardKey.digit2: 2,
  LogicalKeyboardKey.digit3: 3,
  LogicalKeyboardKey.digit4: 4,
  LogicalKeyboardKey.digit5: 5,
  LogicalKeyboardKey.digit6: 6,
  LogicalKeyboardKey.digit7: 7,
  LogicalKeyboardKey.digit8: 8,
  LogicalKeyboardKey.digit9: 9,
  LogicalKeyboardKey.numpad0: 0,
  LogicalKeyboardKey.numpad1: 1,
  LogicalKeyboardKey.numpad2: 2,
  LogicalKeyboardKey.numpad3: 3,
  LogicalKeyboardKey.numpad4: 4,
  LogicalKeyboardKey.numpad5: 5,
  LogicalKeyboardKey.numpad6: 6,
  LogicalKeyboardKey.numpad7: 7,
  LogicalKeyboardKey.numpad8: 8,
  LogicalKeyboardKey.numpad9: 9,
};

/// Single-flight settlement for a locator round trip, the Dart mirror of
/// Kotlin's `ResolveGate` (`android/.../player/LiveResolve.kt`).
///
/// Two things must hold at once, for the same reason they do on Android:
/// provider accounts are single-connection, so at most one `create_link` may
/// be in flight; and exactly one outcome per request may be applied, so a
/// superseded resolve can never land its stream on top of a newer one.
///
/// [abandon] is the addition zapping needs: a zap supersedes an in-flight
/// reconnect re-resolve outright — that reply describes the channel the user
/// has already left, and applying it would reload the *old* channel behind the
/// new one.
class ZapResolveGate {
  int _issued = 0;
  int _pending = 0;

  /// True while a request is waiting to settle.
  bool get inFlight => _pending != 0;

  /// Opens the gate, returning this request's token, or null when one is
  /// already in flight.
  int? begin() {
    if (_pending != 0) return null;
    _pending = ++_issued;
    return _pending;
  }

  /// True when [token] still owns the gate — the caller may apply its outcome.
  /// False for a superseded or already-settled request.
  bool settle(int token) {
    if (_pending == 0 || token != _pending) return false;
    _pending = 0;
    return true;
  }

  /// Drops whatever is in flight without settling it, so the next [begin]
  /// succeeds and the abandoned request's outcome is discarded.
  void abandon() => _pending = 0;
}

/// A debounce that can also be committed early, used for the zap settle window
/// and the digit buffer. Exposed as a class so [LiveZapController] can be
/// driven synchronously in tests via [flush].
class ZapDebounce {
  Timer? _timer;
  void Function()? _action;

  bool get pending => _timer != null;

  void schedule(Duration delay, void Function() action) {
    _timer?.cancel();
    _action = action;
    _timer = Timer(delay, () {
      _timer = null;
      final pendingAction = _action;
      _action = null;
      pendingAction?.call();
    });
  }

  /// Runs the pending action now, if any.
  void flush() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    final pendingAction = _action;
    _action = null;
    pendingAction?.call();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _action = null;
  }
}
