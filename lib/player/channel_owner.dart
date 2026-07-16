import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'resource_counters.dart';

/// Arbitrates ownership of a static, process-wide [MethodChannel] handler
/// across successive short-lived owners (a [State] recreated by navigation, a
/// controller replaced by a new source's screen, …).
///
/// A bare `channel.setMethodCallHandler(handler)` / `setMethodCallHandler(null)`
/// pair is unsafe when a new owner can claim the channel before the old owner
/// disposes: the old owner's unconditional `dispose`-time clear then wipes out
/// the *new* owner's handler, and native calls that should reach the new owner
/// go nowhere. This gives every claim a monotonically increasing token so a
/// stale owner's `release` is a safe no-op once superseded, and the currently
/// installed wrapper ignores calls once its own token is no longer current.
class ChannelHandlerOwner {
  ChannelHandlerOwner(this._channel);

  final MethodChannel _channel;
  int _current = 0;

  /// Installs [handler] as the channel's handler and returns a token
  /// identifying this claim. Pass the token to [release] when done.
  int claim(Future<dynamic> Function(MethodCall call) handler) {
    final token = ++_current;
    ResourceCounters.incChannelOwners();
    _channel.setMethodCallHandler((call) async {
      if (token != _current) return null; // superseded owner: ignore
      return handler(call);
    });
    return token;
  }

  /// Clears the channel's handler, but only if [token] is still the current
  /// claim — a newer owner's claim already replaced it, so this is a no-op.
  /// The counter, however, is decremented unconditionally: every claimant
  /// calls [release] exactly once from its `dispose`, so this balances
  /// [claim] even when the platform-handler clear itself is skipped for a
  /// superseded token.
  void release(int token) {
    ResourceCounters.decChannelOwners();
    if (token != _current) return; // a newer owner already claimed it
    _channel.setMethodCallHandler(null);
  }

  @visibleForTesting
  int get currentToken => _current;
}
