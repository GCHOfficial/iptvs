import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Debug-only, in-process counters for player-lifecycle resources: media_kit
/// [Player] instances, the live-reconnect watchdog [Timer] in
/// `player_screen.dart`, [ChannelHandlerOwner] claims, and the Linux native
/// mpv IPC sessions (`LinuxNativeSession`). Every increment/decrement helper
/// is a no-op outside [kDebugMode], so this never touches release behavior.
///
/// [snapshot] merges these Dart-side counts with the native debug counters
/// exposed by the Android/Windows `iptvs/native_hdr_player` channel's
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
  static int reconnectTimers = 0;
  static int channelOwners = 0;
  static int linuxNativeSessions = 0;

  static void incMediaKitPlayers() {
    if (kDebugMode) mediaKitPlayers++;
  }

  static void decMediaKitPlayers() {
    if (kDebugMode) mediaKitPlayers--;
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

  /// Snapshot of Dart-side counters merged with the native `debugCounters`
  /// map (Android/Windows only). Empty in release; never throws — any native
  /// failure (missing method, platform exception, wrong shape) just omits the
  /// native keys.
  static Future<Map<String, int>> snapshot() async {
    if (!kDebugMode) return const {};
    final result = <String, int>{
      'mediaKitPlayers': mediaKitPlayers,
      'reconnectTimers': reconnectTimers,
      'channelOwners': channelOwners,
      'linuxNativeSessions': linuxNativeSessions,
    };
    if (Platform.isAndroid || Platform.isWindows) {
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
    reconnectTimers = 0;
    channelOwners = 0;
    linuxNativeSessions = 0;
  }
}
