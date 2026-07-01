import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../player/mpv_options.dart';
import '../sources/source.dart';

/// Owns the live split-pane/phone **preview** player and its state — the
/// media_kit [Player] + [VideoController], which channel is previewing, its
/// resolved [StreamInfo], and loading/error — as a [ChangeNotifier] so the
/// screen rebuilds via a listener.
///
/// Fullscreen playback, the phone preview sheet, and focus handling stay in the
/// screen (they need navigation/context/focus); they drive the preview through
/// [start]/[stop]/[pause]/[play] and read these fields.
///
/// The [Player] and [VideoController] are created lazily (only when a preview
/// actually starts / the preview panel first renders) so the media_kit video
/// output isn't spun up during loading or on layouts that never show it.
class LivePreviewController extends ChangeNotifier {
  final LibraryRepository repo;

  /// Surfaces a preview-resolution failure (the screen shows a snackbar).
  final void Function(String message)? onError;

  LivePreviewController({required this.repo, this.onError});

  Player? _player;
  Player get player => _player ??= _createPlayer();

  VideoController? _controller;
  // Force hardware decode for the preview via the controller config — the only
  // place `hwdec` sticks (media_kit sets it at controller creation, overriding
  // setProperty). On a weak TV box the default `auto-safe` silently drops to
  // software decode, playing 4K HEVC in slow-motion at ~100% CPU. Android-only;
  // other platforms keep media_kit's default.
  VideoController get controller =>
      _controller ??= VideoController(
        player,
        configuration: Platform.isAndroid
            ? const VideoControllerConfiguration(hwdec: kAndroidPreviewHwdec)
            : const VideoControllerConfiguration(),
      );

  StreamSubscription<VideoParams>? _hwdecProbe;
  bool _loggedHwdec = false;

  Player _createPlayer() {
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    // Unlike the fullscreen player, previews never get a native HDR/HWND surface —
    // they're always the embedded (texture) path. Apply the same live-stream
    // network/demuxer tuning + tone-map-to-SDR options the fullscreen embedded
    // fallback uses. (Hardware decode is set separately on the VideoController
    // config above — that's the one place `hwdec` isn't overridden.)
    final platform = player.platform;
    if (platform is NativePlayer) {
      unawaited(
        applyMpvOptions(platform, {
          ...kLiveMpvOptions,
          ...embeddedVideoOptionsForPlatform(),
        }),
      );
      // Log the decoder mpv actually engaged once frames start flowing, so the
      // exportable diagnostics confirm hardware decode (not a silent software
      // fallback) on the low-power TV boxes where this matters.
      _hwdecProbe = player.stream.videoParams.listen((_) {
        if (_loggedHwdec) return;
        unawaited(_logPreviewHwdec(platform));
      });
    }
    return player;
  }

  Future<void> _logPreviewHwdec(NativePlayer platform) async {
    if (_loggedHwdec) return;
    try {
      final hwdec = (await platform.getProperty('hwdec-current')).trim();
      if (hwdec.isEmpty || hwdec == 'no') return; // decoder not up yet / software
      _loggedHwdec = true;
      unawaited(_hwdecProbe?.cancel());
      _hwdecProbe = null;
      DiagnosticsLog.instance.add('library', 'preview active hwdec=$hwdec');
    } catch (_) {
      // Property unavailable on this build — leave the probe running.
    }
  }

  /// Channel currently selected for preview (may still be loading), or null.
  String? channelId;
  StreamInfo? stream;
  bool loading = false;
  String? error;

  int _requestId = 0;
  bool _disposed = false;

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  /// Resolve [channel] and open it in the preview player. [muted] is true for
  /// desktop auto-previews (mouse-hover style) and false for deliberate ones
  /// (OK / long-press). Superseded by a newer call via a request id.
  Future<void> start(Channel channel, {bool muted = true}) async {
    if (loading) return;
    final requestId = ++_requestId;
    _set(() {
      channelId = channel.id;
      loading = true;
      error = null;
      stream = null;
    });
    try {
      DiagnosticsLog.instance.add(
        'library',
        'preview live source=${repo.source.name} channel=${channel.name} id=${channel.id}',
      );
      final resolved = await repo.resolve(channel);
      if (_disposed || requestId != _requestId) return;
      await player.open(Media(resolved.url, httpHeaders: resolved.headers));
      await player.setVolume(muted ? 0 : 100);
      if (_disposed || requestId != _requestId) return;
      _set(() {
        stream = resolved;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (_disposed || requestId != _requestId) return;
      _set(() {
        loading = false;
        error = '$e';
      });
      onError?.call('Could not preview: $e');
    }
  }

  /// Stop the preview player. [clearSelection] also drops the previewing
  /// channel (used when leaving the live view / closing the phone sheet).
  Future<void> stop({bool clearSelection = false}) async {
    try {
      if (_player != null) await _player!.stop();
    } catch (_) {}
    if (_disposed) return;
    _set(() {
      loading = false;
      error = null;
      stream = null;
      if (clearSelection) channelId = null;
    });
  }

  /// Pause/resume the preview player around fullscreen playback (no-ops if the
  /// player was never created).
  Future<void> pause() async {
    if (_player != null) await _player!.pause();
  }

  Future<void> play() async {
    if (_player != null) await _player!.play();
  }

  /// Disposes the current player entirely and clears preview state. Used when
  /// the fullscreen player adopted this player and hot-swapped its video
  /// output to the Windows native HDR surface (see [PlayerScreen]) — once that
  /// surface tears down, the player's mpv `vo`/`wid` are no longer valid for
  /// this controller's embedded texture, so it's discarded rather than reused.
  /// The next [start] call builds a fresh one.
  Future<void> discardPlayer() async {
    final player = _player;
    unawaited(_hwdecProbe?.cancel());
    _hwdecProbe = null;
    _loggedHwdec = false;
    _player = null;
    _controller = null;
    channelId = null;
    loading = false;
    error = null;
    stream = null;
    if (!_disposed) notifyListeners();
    if (player != null) await player.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_hwdecProbe?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }
}
