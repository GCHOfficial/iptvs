import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Debug-only, in-process counters for player-lifecycle resources: media_kit
/// [Player] instances, the live-reconnect watchdog [Timer] in
/// `player_screen.dart`, [ChannelHandlerOwner] claims, and the Linux native
/// mpv IPC sessions (`LinuxNativeSession`) — plus one resource that is not the
/// player's but obeys the same alarm, the LAN diagnostics share's `HttpServer`
/// (`diagnosticsShareServers`). Every increment/decrement helper
/// is a no-op outside [kDebugMode], so this never touches release behavior.
///
/// [snapshot] merges these Dart-side counts with the native debug counters
/// exposed by the Android/Windows/iOS `iptvs/native_hdr_player` channel's
/// `debugCounters` method (engine/surface/view counts on the native side) —
/// release builds return an empty native map, and any native error (not yet
/// implemented, unsupported platform, etc.) is tolerated by simply omitting
/// those keys rather than throwing.
///
/// **Invariant**: after a full player open/close cycle every counter must be
/// back to zero — a nonzero count once everything has settled means
/// something leaked (a `Player` never disposed, a `Timer` never cancelled, a
/// channel handler claimed but never released). This is what
/// `integration_test/player_soak_test.dart` asserts across many cycles.
class ResourceCounters {
  ResourceCounters._();

  static const MethodChannel _nativeHdrPlayer = MethodChannel(
    'iptvs/native_hdr_player',
  );

  static int mediaKitPlayers = 0;
  static int mediaKitVideoControllers = 0;
  static int reconnectTimers = 0;
  static int channelOwners = 0;
  static int linuxNativeSessions = 0;
  static int diagnosticsShareServers = 0;

  static void incMediaKitPlayers() {
    if (kDebugMode) mediaKitPlayers++;
  }

  static void decMediaKitPlayers() {
    if (kDebugMode) mediaKitPlayers--;
  }

  /// A media_kit `VideoController` this app constructed.
  ///
  /// Counted separately from [mediaKitPlayers] because it is a *platform*
  /// resource with no `dispose()` of its own: on Android it allocates a
  /// Flutter `SurfaceProducer` — below API 29 a `SurfaceTexture`-backed one —
  /// and the only thing that ever releases it is the owning `Player.dispose()`
  /// draining `player.platform.release` into media_kit's
  /// `VideoOutputManager.Dispose`. A controller still counted after a cycle is
  /// therefore a leaked SurfaceTexture, which is what the GC finalizer later
  /// tears down off the platform thread (the API-28 `ConsumerBase` SIGSEGV).
  /// So the decrement belongs where that release really happens — in the
  /// `.then` of the owning player's `dispose()` — never beside the widget that
  /// stopped rendering it.
  static void incMediaKitVideoControllers() {
    if (kDebugMode) mediaKitVideoControllers++;
  }

  static void decMediaKitVideoControllers() {
    if (kDebugMode) mediaKitVideoControllers--;
  }

  static void incReconnectTimers() {
    if (kDebugMode) reconnectTimers++;
  }

  static void decReconnectTimers() {
    if (kDebugMode) reconnectTimers--;
  }

  static void incChannelOwners() {
    if (kDebugMode) channelOwners++;
  }

  static void decChannelOwners() {
    if (kDebugMode) channelOwners--;
  }

  static void incLinuxNativeSessions() {
    if (kDebugMode) linuxNativeSessions++;
  }

  static void decLinuxNativeSessions() {
    if (kDebugMode) linuxNativeSessions--;
  }

  /// The LAN diagnostics share's `HttpServer` (`DiagnosticsShareServer`).
  ///
  /// Not a player resource, but it belongs to exactly the same alarm: it is a
  /// listening socket serving the diagnostics log to the local network, so a
  /// count that fails to settle at zero is a share the user believes they
  /// closed and which is in fact still answering. Incremented only on a
  /// *successful* bind and decremented once in `stop()`, behind a flag — a bind
  /// that threw must not decrement, and `stop()` races its own expiry timer by
  /// design, so it must not decrement twice.
  static void incDiagnosticsShareServers() {
    if (kDebugMode) diagnosticsShareServers++;
  }

  static void decDiagnosticsShareServers() {
    if (kDebugMode) diagnosticsShareServers--;
  }

  /// Snapshot of Dart-side counters merged with the native `debugCounters`
  /// map (Android/Windows/iOS only). Empty in release; never throws — any native
  /// failure (missing method, platform exception, wrong shape) just omits the
  /// native keys.
  static Future<Map<String, int>> snapshot() async {
    if (!kDebugMode) return const {};
    final result = <String, int>{
      'mediaKitPlayers': mediaKitPlayers,
      'mediaKitVideoControllers': mediaKitVideoControllers,
      'reconnectTimers': reconnectTimers,
      'channelOwners': channelOwners,
      'linuxNativeSessions': linuxNativeSessions,
      'diagnosticsShareServers': diagnosticsShareServers,
    };
    if (Platform.isAndroid || Platform.isWindows || Platform.isIOS) {
      try {
        final native = await _nativeHdrPlayer.invokeMethod('debugCounters');
        if (native is Map) {
          for (final entry in native.entries) {
            final key = entry.key;
            final value = entry.value;
            if (key is! String) continue;
            if (value is num) result[key] = value.toInt();
          }
        }
      } catch (_) {
        // Missing method / platform exception / natives not built yet with
        // this call — tolerate it so a snapshot() never throws.
      }
    }
    return result;
  }

  /// Test-only: resets all Dart-side counters. Tests run in debug mode, so
  /// state left over from an earlier test would otherwise leak across tests.
  @visibleForTesting
  static void resetForTest() {
    mediaKitPlayers = 0;
    mediaKitVideoControllers = 0;
    reconnectTimers = 0;
    channelOwners = 0;
    linuxNativeSessions = 0;
    diagnosticsShareServers = 0;
  }
}
