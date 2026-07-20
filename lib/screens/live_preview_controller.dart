import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/net.dart';
import '../player/channel_owner.dart';
import '../player/mpv_options.dart';
import '../player/player_screen.dart' show kReconnectStallMs, reconnectMinGapMs;
import '../player/resource_counters.dart';
import '../sources/source.dart';

/// Owns the live split-pane/phone **preview** player and its state — which
/// channel is previewing, its resolved [StreamInfo], and loading/error — as a
/// [ChangeNotifier] so the screen rebuilds via a listener.
///
/// Two playback paths, chosen per channel:
///
/// - **Android (default)**: the *shared native ExoPlayer engine* (Kotlin
///   `SharedEngine`), rendering into a platform view. This is what makes the
///   preview → fullscreen handoff seamless: the fullscreen Activity *adopts*
///   the running engine (only the video surface moves — audio, decoder and
///   buffer carry over) instead of reloading the stream, and it's also the
///   cheapest decode path for weak TV boxes (MediaCodec straight into a
///   TextureView, no mpv → GL texture copy).
/// - **Fallback / other platforms**: the embedded media_kit [Player] +
///   [VideoController] texture. On Android this covers streams the native
///   engine can't decode (chiefly Dolby Vision P5 on non-DV hardware — mpv
///   software-reshapes those), remembered per channel in
///   [_nativeUnsupportedIds].
///
/// Fullscreen playback, the phone preview sheet, and focus handling stay in
/// the screen (they need navigation/context/focus); they drive the preview
/// through [start]/[stop]/[pause]/[play] and read these fields.
class LivePreviewController extends ChangeNotifier {
  final LibraryRepository repo;

  /// Surfaces a preview-resolution failure (the screen shows a snackbar).
  final void Function(String message)? onError;

  LivePreviewController({required this.repo, this.onError}) {
    if (Platform.isAndroid) {
      // Last-created controller wins the channel — there's one live preview at
      // a time, and a new source's screen replaces the old controller.
      _previewToken = _previewOwner.claim(_handleNativeCall);
    }
  }

  static const MethodChannel _nativeChannel = MethodChannel(
    'iptvs/native_preview',
  );
  // Arbitrates the static channel's handler across successive controllers
  // (a new source's screen replacing the old one) so a superseded
  // controller's dispose can never clear a newer controller's handler. See
  // [ChannelHandlerOwner].
  static final ChannelHandlerOwner _previewOwner = ChannelHandlerOwner(
    _nativeChannel,
  );
  int? _previewToken;

  /// Channels whose video the native engine can't decode (e.g. Dolby Vision
  /// P5 on non-DV hardware) — they preview via media_kit for this session.
  final Set<String> _nativeUnsupportedIds = <String>{};

  /// True while the native shared engine (not media_kit) owns the preview.
  bool nativeActive = false;

  /// Current mute state (native volume isn't readable back, so track it here).
  bool muted = true;

  bool get isMuted => muted;

  Player? _player;
  Player get player => _player ??= _createPlayer();

  /// True once the embedded media_kit player exists (it's created lazily, and
  /// never at all while the native path serves every preview).
  bool get hasEmbeddedPlayer => _player != null;

  VideoController? _controller;
  // Force hardware decode for the preview via the controller config — the only
  // place `hwdec` sticks (media_kit sets it at controller creation, overriding
  // setProperty). On a weak TV box the default `auto-safe` silently drops to
  // software decode, playing 4K HEVC in slow-motion at ~100% CPU. Android-only;
  // other platforms keep media_kit's default.
  VideoController get controller => _controller ??= VideoController(
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
    ResourceCounters.incMediaKitPlayers();
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
    // media_kit maps mpv's `eof-reached` to `completed: true` — a clean
    // server-side EOF, distinct from a player error. Nothing else here
    // recovers from it (the fullscreen watchdogs are per-PlayerScreen, not
    // preview-owned), so the preview would otherwise sit dead until an
    // unrelated selection change. See [_handleCompleted].
    _completedSub = player.stream.completed.listen(_handleCompleted);
    return player;
  }

  /// Recovers from a clean EOF on the embedded preview player by re-starting
  /// the same channel (never a different one — the preview only ever plays
  /// what the user explicitly chose). Re-resolves rather than reopening the
  /// stale URL: provider tokens (Stalker `create_link`) are single-use.
  /// Rate-limited and capped by the shared reconnect min-gap policy so a
  /// stream stuck bouncing at EOF doesn't loop forever.
  void _handleCompleted(bool completed) {
    if (!completed || _disposed || nativeActive || _pausedByApp) return;
    final channel = _activeChannel;
    // Not (or no longer) previewing this channel — including mid-`start()`
    // resolves, where `loading` is true — so there's nothing to recover.
    if (channel == null || channelId != channel.id || loading) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // A completed landing well after the last restart is a fresh incident
    // (the restart held for a full stall window), not a continuation of a
    // stuck loop — forget the earlier attempts.
    if (_lastEofRestartMs != 0 && now - _lastEofRestartMs >= kReconnectStallMs) {
      _eofRestartAttempts = 0;
    }
    if (_eofRestartAttempts >= _maxConsecutiveEofRestarts) {
      DiagnosticsLog.instance.add(
        'library',
        'preview eof giving up channel=${channel.name} '
            'attempts=$_eofRestartAttempts',
      );
      _set(() {
        loading = false;
        error = 'Stream ended';
      });
      return;
    }
    final minGap = reconnectMinGapMs(
      priorAttempts: _eofRestartAttempts,
      force: false,
    );
    if (_lastEofRestartMs != 0 && now - _lastEofRestartMs < minGap) return;
    _eofRestartAttempts++;
    _lastEofRestartMs = now;
    DiagnosticsLog.instance.add(
      'library',
      'preview eof restart channel=${channel.name} '
          'attempt=$_eofRestartAttempts',
    );
    unawaited(start(channel, muted: muted));
  }

  Future<void> _logPreviewHwdec(NativePlayer platform) async {
    if (_loggedHwdec) return;
    try {
      final hwdec = (await platform.getProperty('hwdec-current')).trim();
      // Decoder not up yet, or a software fallback — nothing to log.
      if (hwdec.isEmpty || hwdec == 'no') return;
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

  /// The channel [start] most recently targeted — kept so a clean server-side
  /// EOF can restart the *same* channel (never any other; "preview is
  /// deliberate and locked"). Cleared by [stop]/[discardPlayer] so an
  /// app-initiated stop never triggers a restart.
  Channel? _activeChannel;

  /// True while the app (not a genuine EOF) has paused the preview around a
  /// fullscreen handoff — an EOF landing in this window is ignored.
  bool _pausedByApp = false;

  /// Consecutive automatic EOF-restart attempts for the current incident, and
  /// when the last one fired — caps a stuck stream from looping forever and
  /// resets once a restart holds for a full stall window (a fresh incident).
  int _eofRestartAttempts = 0;
  int _lastEofRestartMs = 0;
  static const int _maxConsecutiveEofRestarts = 3;

  StreamSubscription<bool>? _completedSub;

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  bool _useNative(Channel channel) =>
      Platform.isAndroid && !_nativeUnsupportedIds.contains(channel.id);

  /// Resolve [channel] and open it in the preview player. [muted] is true for
  /// desktop auto-previews (mouse-hover style) and false for deliberate ones
  /// (OK / long-press). Superseded by a newer call via a request id.
  Future<void> start(Channel channel, {bool muted = true}) async {
    // No guard on `loading`: a newer call must supersede an in-flight resolve
    // (a slow Stalker create_link would otherwise swallow the user's channel
    // change). The request id makes the stale attempt's completions no-ops.
    final requestId = ++_requestId;
    this.muted = muted;
    if (_activeChannel?.id != channel.id) {
      // A genuinely new selection, not an EOF-triggered restart of the same
      // channel — forget any earlier incident's restart bookkeeping.
      _eofRestartAttempts = 0;
      _lastEofRestartMs = 0;
    }
    _activeChannel = channel;
    _pausedByApp = false;
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
      if (_useNative(channel)) {
        final opened = await _openNative(resolved, muted: muted);
        if (_disposed || requestId != _requestId) return;
        if (opened) {
          // A previous fallback (media_kit) preview may still be running.
          if (_player != null) unawaited(_player!.stop());
          _set(() {
            nativeActive = true;
            stream = resolved;
            loading = false;
            error = null;
          });
          return;
        }
        // Native engine unavailable for this channel — embedded path instead.
        _nativeUnsupportedIds.add(channel.id);
      }
      if (nativeActive) {
        nativeActive = false;
        unawaited(_stopNative());
      }
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
      // Exception text can embed the stream URL (credentials in the path) —
      // scrub before anything user-visible.
      final message = redactText('$e');
      _set(() {
        loading = false;
        error = message;
      });
      onError?.call('Could not preview: $message');
    }
  }

  Future<bool> _openNative(StreamInfo resolved, {required bool muted}) async {
    try {
      final opened = await _nativeChannel.invokeMethod<bool>('open', {
        'url': resolved.url,
        'headers': resolved.headers,
        'muted': muted,
      });
      if (opened == true) {
        DiagnosticsLog.instance.add('library', 'preview native engine open');
        return true;
      }
      return false;
    } catch (e) {
      // No URL in the log — provider URLs carry credentials.
      DiagnosticsLog.instance.add(
        'library',
        'preview native engine unavailable: ${e.runtimeType}',
      );
      return false;
    }
  }

  Future<void> _stopNative() async {
    try {
      await _nativeChannel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Events pushed by the Kotlin side (`SharedEngine` via MainActivity).
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed || call.method != 'previewEvent') return null;
    final args = call.arguments as Map?;
    if (!nativeActive) return null;
    switch (args?['event']) {
      case 'unsupported':
        // The native engine can't decode this channel's video — remember that
        // and fall back to the embedded media_kit preview mid-flight.
        final id = channelId;
        final s = stream;
        if (id != null) _nativeUnsupportedIds.add(id);
        nativeActive = false;
        if (s == null) return null;
        DiagnosticsLog.instance.add(
          'library',
          'preview video unsupported by native engine — media_kit fallback',
        );
        try {
          await player.open(Media(s.url, httpHeaders: s.headers));
          await player.setVolume(muted ? 0 : 100);
          _set(() {});
        } catch (e) {
          _set(() => error = redactText('$e'));
        }
      case 'lost':
        // Fullscreen swapped the adopted shared engine for mpv (unsupported
        // video), so the native preview is gone. Clear the preview; the next
        // (re)focus starts a fresh one on the fallback path.
        final id = channelId;
        if (id != null) _nativeUnsupportedIds.add(id);
        _set(() {
          nativeActive = false;
          stream = null;
          loading = false;
        });
      case 'error':
        // Native engine error text can carry the stream URL — scrub it.
        final message = redactText(
          (args?['message'] as String?) ?? 'stream error',
        );
        _set(() {
          loading = false;
          error = message;
        });
    }
    return null;
  }

  /// Stop the preview player. [clearSelection] also drops the previewing
  /// channel (used when leaving the live view / closing the phone sheet).
  Future<void> stop({bool clearSelection = false}) async {
    // App-initiated stop — never auto-restart on the EOF this may itself
    // trigger (media_kit's `stop()` reports `completed: false`, but clear the
    // target anyway so a straggling event can't act on it).
    _activeChannel = null;
    if (nativeActive) {
      nativeActive = false;
      await _stopNative();
    }
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
    _pausedByApp = true;
    if (nativeActive) {
      try {
        await _nativeChannel.invokeMethod('pause');
      } catch (_) {}
      return;
    }
    if (_player != null) await _player!.pause();
  }

  Future<void> play() async {
    _pausedByApp = false;
    if (nativeActive) {
      try {
        await _nativeChannel.invokeMethod('play');
      } catch (_) {}
      return;
    }
    if (_player != null) await _player!.play();
  }

  /// Mute/unmute whichever engine is previewing (and remember the state).
  Future<void> setMuted(bool value) async {
    muted = value;
    if (nativeActive) {
      try {
        await _nativeChannel.invokeMethod('setVolume', {
          'volume': value ? 0.0 : 1.0,
        });
      } catch (_) {}
      return;
    }
    if (_player != null) await _player!.setVolume(value ? 0 : 100);
  }

  /// Disposes the current player entirely and clears preview state. Used when
  /// the fullscreen player adopted this player and hot-swapped its video
  /// output to the Windows native HDR surface (see [PlayerScreen]) — once that
  /// surface tears down, the player's mpv `vo`/`wid` are no longer valid for
  /// this controller's embedded texture, so it's discarded rather than reused.
  /// The next [start] call builds a fresh one.
  Future<void> discardPlayer() async {
    final player = _player;
    if (nativeActive) {
      nativeActive = false;
      unawaited(_stopNative());
    }
    unawaited(_hwdecProbe?.cancel());
    _hwdecProbe = null;
    _loggedHwdec = false;
    unawaited(_completedSub?.cancel());
    _completedSub = null;
    _activeChannel = null;
    _player = null;
    _controller = null;
    channelId = null;
    loading = false;
    error = null;
    stream = null;
    if (!_disposed) notifyListeners();
    if (player != null) {
      await player.dispose();
      ResourceCounters.decMediaKitPlayers();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final token = _previewToken;
    if (token != null) {
      _previewOwner.release(token);
    }
    if (nativeActive) {
      nativeActive = false;
      unawaited(_stopNative());
    }
    unawaited(_hwdecProbe?.cancel());
    unawaited(_completedSub?.cancel());
    _activeChannel = null;
    final player = _player;
    if (player != null) {
      unawaited(
        player.dispose().then((_) => ResourceCounters.decMediaKitPlayers()),
      );
    }
    super.dispose();
  }
}

/// Renders the live preview's video: the native shared-engine platform view
/// when that path is active, else the embedded media_kit texture. Build this
/// only once the preview has loaded ([LivePreviewController.stream] != null) so
/// the media_kit player isn't spun up while the native path is still deciding.
class PreviewVideo extends StatelessWidget {
  final LivePreviewController preview;

  const PreviewVideo({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    if (preview.nativeActive) {
      return const AndroidView(viewType: 'iptvs/preview_view');
    }
    return Video(controller: preview.controller, controls: NoVideoControls);
  }
}
