import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
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
  Player get player => _player ??= Player();

  VideoController? _controller;
  VideoController get controller => _controller ??= VideoController(player);

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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_player?.dispose());
    super.dispose();
  }
}
