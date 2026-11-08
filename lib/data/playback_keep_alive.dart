// Who, app-wide, is allowed to hold a provider's playback keep-alive open.
//
// A provider account here is single-connection by assumption — it is why the
// Android preview and the fullscreen player share one engine, and why a zap
// stops before it resolves — so "what is playing" is a **single slot**, never
// a set. This coordinator is that slot: arming it for one source disarms
// whatever source held it before, and a stop is accepted only from the arming
// that is still current.
//
// The token discipline is the same one `ChannelHandlerOwner`
// (`lib/player/channel_owner.dart`) uses for the native MethodChannels, and it
// exists for the same class of bug: the preview and the fullscreen route both
// believe they own playback across a handoff, and the one that is *leaving*
// runs its teardown last. Without a token, the preview's `stop()` on the way
// into fullscreen would silence the keep-alive the fullscreen route had just
// armed.

import 'package:flutter/foundation.dart';

import '../sources/source.dart';

/// The single armed-playback slot. See [PlaybackKeepAlive].
class PlaybackKeepAliveCoordinator {
  PlaybackKeepAliveCoordinator();

  /// The app-wide instance. Tests build their own rather than reaching for
  /// this one.
  static final PlaybackKeepAliveCoordinator instance =
      PlaybackKeepAliveCoordinator();

  int _token = 0;
  PlaybackKeepAlive? _current;

  /// The token of the most recent [started]. A caller that wants to be able to
  /// stop "its" playback reads this immediately after the resolve that armed
  /// it and hands it back to [stopped].
  int get token => _token;

  /// The source currently kept alive, or null when nothing is.
  @visibleForTesting
  PlaybackKeepAlive? get current => _current;

  /// Arms the keep-alive for [source] because [channel] is now playing through
  /// it, and returns the token that identifies this arming.
  ///
  /// A source with no [PlaybackKeepAlive] capability still bumps the token and
  /// still disarms whatever was armed before: "something else is playing now"
  /// is true regardless of whether the new provider needs a keep-alive, and a
  /// cross-source zap from a portal to a playlist is exactly that case.
  int started(Source source, Channel channel) {
    final next = source is PlaybackKeepAlive
        ? source as PlaybackKeepAlive
        : null;
    if (!identical(next, _current)) {
      _current?.playbackStopped();
      _current = next;
    }
    next?.playbackStarted(channel);
    return ++_token;
  }

  /// Disarms, but only if [token] is still the current arming — a stale stop
  /// from a superseded owner is ignored.
  void stopped(int token) {
    if (token != _token) return;
    stopAll();
  }

  /// Disarms unconditionally: nothing is playing anywhere. Used when a
  /// fullscreen route closes (the session may have zapped to a different
  /// source, so the route's own token is no longer current) and on teardown.
  void stopAll() {
    _token++;
    final current = _current;
    _current = null;
    current?.playbackStopped();
  }
}
