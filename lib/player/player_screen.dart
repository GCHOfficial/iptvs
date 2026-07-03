import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/app_database.dart';
import '../data/diagnostics_log.dart';
import '../data/net.dart';
import '../sources/source.dart';
import '../theme.dart';
import 'mpv_options.dart';

/// Identifies what's playing for the VOD resume store: where to save
/// positions and where to resume from. Absent for live streams and anything
/// the caller doesn't want remembered.
class PlaybackContext {
  final AppDatabase db;
  final String sourceId;
  final ContentKind kind;
  final String itemId;

  /// Saved position to resume at (read by the caller before pushing the
  /// player); null/zero plays from the top.
  final Duration? resumeFrom;

  const PlaybackContext({
    required this.db,
    required this.sourceId,
    required this.kind,
    required this.itemId,
    this.resumeFrom,
  });
}

/// Plays a resolved [StreamInfo] using media_kit (libmpv under the hood, so it
/// handles HEVC / AC-3 / MPEG-TS that an HTML video element can't). Controls
/// are media_kit's adaptive set, themed to match the app.
class PlayerScreen extends StatefulWidget {
  final String title;
  final StreamInfo stream;

  /// Active source's display name, shown as a badge in the player overlay.
  final String? sourceName;

  /// EPG now/next for a live channel (a one-shot snapshot taken at play time),
  /// surfaced in the overlay instead of the VOD scrubber. Null for VOD.
  final Programme? epgNow;
  final Programme? epgNext;

  /// An already-open [Player]/[VideoController] to adopt instead of opening
  /// [stream] fresh — passed when coming from a live preview that's already
  /// playing this exact stream, so going fullscreen doesn't restart playback.
  /// [PlayerScreen] does not own an adopted player: it never disposes it, that
  /// stays the caller's responsibility. Ignored on Android when the native HDR
  /// player launches (a separate Activity/hardware surface — no live decode
  /// session can be handed to it) and, on Windows, only skips reopening the
  /// media if the native HDR surface can still be created for the adopted
  /// player; otherwise it falls back to a fresh open.
  final Player? existingPlayer;
  final VideoController? existingController;

  /// Android: the live preview is already playing this exact stream on the
  /// *shared native engine*, and the native fullscreen Activity should adopt
  /// it — moving only the video output to its own surface — instead of
  /// reloading the stream. This is the seamless preview → fullscreen handoff:
  /// audio, decoder and buffer are never interrupted. Mutually exclusive with
  /// [existingPlayer] (that's the media_kit adoption used off Android).
  final bool adoptNativePreview;

  /// VOD resume context — where to persist playback positions and where to
  /// start. Null for live streams (never persisted) and untracked playback.
  final PlaybackContext? playback;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.stream,
    this.sourceName,
    this.epgNow,
    this.epgNext,
    this.existingPlayer,
    this.existingController,
    this.adoptNativePreview = false,
    this.playback,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const MethodChannel _nativeHdrPlayer = MethodChannel(
    'iptvs/native_hdr_player',
  );

  // Ceilings for the lifecycle-critical native calls. Without these, a native
  // side that connects but never replies (surface creation wedged, engine
  // init hung) would leave the awaiting Dart future pending forever — the
  // player route couldn't fall back to the embedded surface or be popped, so
  // the app looks frozen. On timeout we take the same fallback path as an
  // unavailable/failed native player.
  static const Duration _nativeOpenTimeout = Duration(seconds: 10);
  static const Duration _nativeExitTimeout = Duration(seconds: 3);

  late final Player _player =
      widget.existingPlayer ??
      Player(
        configuration: PlayerConfiguration(
          vo: _usesWindowsNativeSurface ? 'null' : null,
          osc: _usesWindowsNativeSurface,
          // 64 MB forward demuxer cache (default is 32) — smoother VOD seeking.
          bufferSize: 64 * 1024 * 1024,
          logLevel: MPVLogLevel.warn,
        ),
      );
  late final VideoController? _controller = _usesWindowsNativeSurface
      ? null
      : (widget.existingController ?? VideoController(_player));

  /// False when [_player] was adopted from an existing preview — it's owned by
  /// the caller (e.g. [LivePreviewController]), so this screen must never
  /// dispose it.
  bool get _ownsPlayer => widget.existingPlayer == null;

  /// True once this screen has re-pointed an adopted player's video output at
  /// the Windows native HDR surface. That leaves the player's mpv `vo`/`wid`
  /// pointed at a surface this route is about to tear down, so it's no longer
  /// safe for the caller to keep using for embedded (texture) rendering —
  /// reported back via the pop result so the caller discards it.
  bool _didWindowsHotSwap = false;
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _error;
  late final bool _isLive = widget.stream.isLive;
  // Live-edge sync for the Windows overlay: false once the user pauses live (and
  // falls behind), true again after go-to-live. Greys the LIVE badge + shows the
  // go-to-live button.
  bool _liveSynced = true;
  // Live reconnect watchdog (Windows / embedded media_kit; Android reconnects in
  // its native Activity). Reload the source when a live stream stalls or errors.
  bool _buffering = false;
  bool _reconnecting = false;
  int _stalledSinceMs = 0;
  int _lastReconnectMs = 0;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  static const int _kStallReconnectMs = 8000;
  static const int _kMaxBackoffMs = 30000;
  late bool _nativePlaybackLaunched = _usesWindowsNativeSurface;
  // Android adopted-handoff: set once the native launch failed and the
  // embedded fallback is taking over (ends the transparent handoff window).
  bool _nativeLaunchFailed = false;
  bool _isNativeFullscreen = false;
  bool _nativeControlsVisible = true;
  bool _nativeTeardownScheduled = false;
  bool _loggedActiveVo = false;
  bool _loggedHwdec = false;
  String? _lastVideoParamsLog;
  // HDR10+ detection (Windows/mpv). mpv has no clean "has HDR10+" flag, so we
  // infer it from the ST2094-40 scene dynamic-metadata sub-properties — which are
  // zero for plain HDR10 and, unlike max-pq-y, aren't synthesised by
  // `hdr-compute-peak`. Conservative: stays false (→ "HDR10 · PQ") on any
  // absence/error, only flips true once a PQ stream clearly carries scene metadata.
  bool _hdr10Plus = false;
  bool _probingHdr10Plus = false;
  DateTime? _ignoreNativeInputUntil;
  int? _windowsNativeSurface;
  // VOD resume plumbing (null when untracked / live).
  Timer? _positionPersistTimer;
  Duration? _pendingEmbeddedResume;
  // Index into [_aspectModes]. Starts at "Fill" to match the panscan=1.0 the
  // native surface is configured with in [_configureNativePlayer].
  int _aspectModeIndex = 1;

  static const List<double> _speedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  static const List<_AspectMode> _aspectModes = <_AspectMode>[
    _AspectMode('Fit', '0.0', 'no'),
    _AspectMode('Fill', '1.0', 'no'),
    _AspectMode('16:9', '0.0', '16:9'),
    _AspectMode('4:3', '0.0', '4:3'),
  ];

  bool get _usesWindowsNativeSurface => Platform.isWindows;

  /// Android adopted-handoff window: this route (pushed non-opaque by the
  /// caller) stays fully transparent so the channel list — including the
  /// preview's frozen last frame — remains visible until the native Activity's
  /// first frame covers it. No black flash in between. Ends if the native
  /// launch fails and the embedded fallback needs a real surface.
  bool get _transparentHandoff =>
      Platform.isAndroid && widget.adoptNativePreview && !_nativeLaunchFailed;

  @override
  void initState() {
    super.initState();
    // Both native-player platforms call back over this channel: Windows sends
    // input/control/closed events for its GDI overlay; Android sends `nativeClosed`
    // when its native Activity finishes. Without the Android handler, backing out
    // of the native player leaves this route stranded on the black overlay until a
    // second Back press — register it so `nativeClosed` pops us straight to the list.
    if (Platform.isWindows || Platform.isAndroid) {
      _nativeHdrPlayer.setMethodCallHandler(_handleNativeHdrMethodCall);
    }

    // Show errors once as an overlay rather than a stream of snackbars. On a live
    // stream, auto-reconnect instead of surfacing a terminal error.
    _subs.add(
      _player.stream.error.listen((message) {
        _logPlayback('error ${_redactPlayback(message)}');
        if (!mounted) return;
        if (_isLive) {
          _reconnectLive(force: true);
        } else {
          setState(() => _error = message);
        }
      }),
    );
    // Track buffering for the live reconnect watchdog.
    _subs.add(_player.stream.buffering.listen((value) => _buffering = value));
    if (_isLive) {
      _reconnectTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _pollLiveReconnect(),
      );
    }
    // VOD resume: persist the position periodically (plus on dispose and via
    // the native player's nativeClosed payload), so a crash mid-film loses at
    // most half a minute.
    if (widget.playback != null && !_isLive) {
      _positionPersistTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _persistPlaybackPosition(),
      );
      final resume = widget.playback!.resumeFrom;
      if (resume != null && resume > Duration.zero) {
        _pendingEmbeddedResume = resume;
      }
    }
    // Embedded resume: seek once the duration is known (a cold seek right
    // after open can land before the demuxer is ready).
    _subs.add(
      _player.stream.duration.listen((duration) {
        final resume = _pendingEmbeddedResume;
        if (resume == null || _nativePlaybackLaunched) return;
        if (duration <= Duration.zero) return;
        _pendingEmbeddedResume = null;
        if (resume < duration) {
          _logPlayback('resume seek to ${resume.inSeconds}s');
          unawaited(_player.seek(resume));
        }
      }),
    );
    _subs.add(
      _player.stream.log.listen((entry) {
        if (entry.level != 'warn' && entry.level != 'error') return;
        // ffmpeg-prefixed lines (UDTA/timescale demux noise, alternating
        // `hevc: Could not find ref with POC …` / `Error constructing the frame
        // RPS` decode complaints) are non-fatal diagnostics, amplified by the
        // shared libav av_log callback relaying the native engine's software
        // decode out through media_kit's log stream. Drop them at both warn and
        // error level — genuine fatal playback failures arrive on stream.error,
        // not here. Keep non-ffmpeg warnings/errors.
        if (entry.prefix.contains('ffmpeg')) return;
        _logPlaybackDeduped('${entry.level} ${entry.prefix}: ${entry.text}');
      }),
    );
    _subs.add(
      _player.stream.audioParams.listen((params) {
        _logPlayback(
          'audio format=${params.format} channels=${params.channels} '
          'rate=${params.sampleRate}',
        );
      }),
    );
    _subs.add(
      _player.stream.track.listen((track) {
        _logPlayback(
          'selected tracks video=${_trackSummary(track.video)} '
          'audio=${_trackSummary(track.audio)}',
        );
        _syncWindowsNativeControlState();
      }),
    );
    _subs.add(
      _player.stream.tracks.listen((tracks) {
        final audio = tracks.audio
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(_trackSummary)
            .join('; ');
        final video = tracks.video
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(_trackSummary)
            .join('; ');
        final subtitles = tracks.subtitle
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(_trackSummary)
            .join('; ');
        _logPlayback(
          'available tracks video=[${video.isEmpty ? 'none' : video}] '
          'audio=[${audio.isEmpty ? 'none' : audio}] '
          'subtitles=[${subtitles.isEmpty ? 'none' : subtitles}] '
          'externalSubtitles=${widget.stream.subtitles.length}',
        );
        _syncWindowsNativeControlState();
      }),
    );
    _subs.add(
      _player.stream.videoParams.listen((params) {
        // mpv re-emits identical video-params repeatedly; only log on change so
        // the exportable diagnostics log stays readable.
        final line =
            'video format=${params.hwPixelformat ?? params.pixelformat} '
            'w=${params.w} h=${params.h} display=${params.dw}x${params.dh} '
            'primaries=${params.primaries} gamma=${params.gamma} '
            'sigPeak=${params.sigPeak} matrix=${params.colormatrix} '
            'levels=${params.colorlevels}';
        if (line != _lastVideoParamsLog) {
          _lastVideoParamsLog = line;
          _logPlayback(line);
        }
        unawaited(_logActiveVideoOutput());
        unawaited(_probeHdr10Plus(params));
      }),
    );
    // Clear the error overlay once playback actually starts.
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (playing && _error != null && mounted) setState(() => _error = null);
        _syncWindowsNativeControlState();
      }),
    );
    // Continuous streams (position ticks several times a second, duration/
    // volume piggyback on them) go through the throttle — shipping the full
    // control-state map over the MethodChannel per tick is pure churn while
    // the overlay is hidden, and 2 Hz is plenty for a visible scrubber.
    // Discrete events (track change, play/pause, user commands) keep calling
    // _syncWindowsNativeControlState directly so the overlay never lags input.
    _subs.add(_player.stream.position.listen((_) => _requestControlSync()));
    _subs.add(_player.stream.duration.listen((_) => _requestControlSync()));
    _subs.add(_player.stream.volume.listen((_) => _requestControlSync()));

    _open();
  }

  Future<void> _open() async {
    if (mounted) setState(() => _error = null);
    _showNativeControls(scheduleHide: false);
    _logPlayback(
      'open live=$_isLive url=${_redactPlayback(widget.stream.url)} '
      'surface=${_usesWindowsNativeSurface ? 'native-windows' : 'embedded'} '
      'headers=${widget.stream.headers.keys.join(',')}',
    );

    if (await _tryOpenNativeHdrPlayer()) {
      if (mounted) setState(() => _nativePlaybackLaunched = true);
      // The native Activity now owns playback of this stream from scratch —
      // an adopted (preview) player isn't rendered anywhere and would just
      // waste decode/bandwidth (and, if unmuted, double up audio) left
      // running behind it.
      if (widget.existingPlayer != null) unawaited(_player.pause());
      return;
    }

    // Adopted-handoff path that failed to launch natively: the preview's shared
    // engine was deliberately left playing (seamless handoff), but this route is
    // now about to open the stream itself — silence the engine or the audio
    // doubles up behind the embedded fallback.
    if (widget.adoptNativePreview) {
      try {
        await const MethodChannel(
          'iptvs/native_preview',
        ).invokeMethod<void>('pause');
      } catch (_) {}
    }

    int? nativeWindowHandle;
    if (_usesWindowsNativeSurface) {
      nativeWindowHandle = await _createWindowsNativeHdrSurface();
      if (nativeWindowHandle == null && mounted) {
        setState(() => _nativePlaybackLaunched = false);
      }
    } else if (mounted) {
      setState(() {
        _nativePlaybackLaunched = false;
        _nativeLaunchFailed = true;
      });
    }

    // Keep a backward cache so scrubbing back through a VOD doesn't refetch
    // already-downloaded data. (Forward cache comes from bufferSize above.)
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await _configureNativePlayer(platform, nativeWindowHandle);
    }

    // headers carry things like a MAG User-Agent for Stalker; empty for plain HLS.
    if (widget.stream.headers.isNotEmpty && platform is NativePlayer) {
      await _setNativeHeaderOptions(platform, widget.stream.headers);
    }

    // An adopted player is already open and playing this exact stream — the
    // preview it came from resolved and opened it moments ago. On Windows that
    // only holds once the native HDR surface above was actually created (the
    // properties just applied re-pointed its video output at that surface); if
    // surface creation failed, fall through to a fresh open like any other
    // Windows playback. Off Windows there's no separate surface to switch —
    // the embedded VideoController already adopted the same player/controller.
    final adopting = widget.existingPlayer != null;
    final canSkipOpen =
        adopting && (!_usesWindowsNativeSurface || nativeWindowHandle != null);
    if (canSkipOpen && _usesWindowsNativeSurface) _didWindowsHotSwap = true;
    if (!canSkipOpen) {
      await _player.open(
        Media(
          widget.stream.url,
          httpHeaders: widget.stream.headers.isEmpty
              ? null
              : widget.stream.headers,
        ),
      );
    }
    // Insurance against a muted/zero-volume default.
    await _player.setVolume(100);
    if (canSkipOpen) await _player.play();
    _showNativeControls();
  }

  Future<bool> _tryOpenNativeHdrPlayer() async {
    if (!Platform.isAndroid) return false;
    try {
      final opened = await _nativeHdrPlayer
          .invokeMethod<bool>('open', {
            'url': widget.stream.url,
            'title': widget.title,
            if (widget.sourceName != null) 'sourceName': widget.sourceName,
            'headers': widget.stream.headers,
            'isLive': widget.stream.isLive,
            'adoptShared': widget.adoptNativePreview,
            'resumeMs': widget.playback?.resumeFrom?.inMilliseconds ?? 0,
            ..._epgPayload(),
            'subtitles': widget.stream.subtitles
                .map(
                  (subtitle) => {
                    'url': subtitle.url,
                    'label': subtitle.label,
                    if (subtitle.language != null)
                      'language': subtitle.language,
                  },
                )
                .toList(growable: false),
          })
          .timeout(_nativeOpenTimeout);
      _logPlayback(
        opened == true
            ? 'native hdr player launched platform=android'
            : 'native hdr player unavailable platform=android',
      );
      return opened == true;
    } on TimeoutException {
      _logPlayback('native hdr player timed out platform=android');
      return false;
    } on MissingPluginException catch (error) {
      _logPlayback('native hdr player missing: $error');
      return false;
    } on PlatformException catch (error) {
      _logPlayback('native hdr player failed: ${error.code} ${error.message}');
      return false;
    }
  }

  Future<int?> _createWindowsNativeHdrSurface() async {
    if (!Platform.isWindows) return null;
    try {
      final handle = await _nativeHdrPlayer
          .invokeMethod<int>('createSurface', {'topInset': 0, 'bottomInset': 0})
          .timeout(_nativeOpenTimeout);
      if (handle == null || handle == 0) {
        _logPlayback('native hdr surface unavailable platform=windows');
        return null;
      }
      _windowsNativeSurface = handle;
      if (mounted) setState(() => _nativePlaybackLaunched = true);
      await _syncWindowsNativeControlState();
      _logPlayback('native hdr surface created platform=windows hwnd=$handle');
      return handle;
    } on TimeoutException {
      _logPlayback('native hdr surface timed out platform=windows');
      return null;
    } on MissingPluginException catch (error) {
      _logPlayback('native hdr surface missing: $error');
      return null;
    } on PlatformException catch (error) {
      _logPlayback('native hdr surface failed: ${error.code} ${error.message}');
      return null;
    }
  }

  void _scheduleWindowsNativeTeardown({bool prepared = false}) {
    if (!Platform.isWindows || _nativeTeardownScheduled) return;
    _nativeTeardownScheduled = true;
    if (!prepared) unawaited(_prepareWindowsNativeExit());
  }

  Future<void> _prepareWindowsNativeExit() async {
    if (!Platform.isWindows) return;
    unawaited(_player.setVolume(0));
    unawaited(_player.pause());
    try {
      await _nativeHdrPlayer
          .invokeMethod<bool>('prepareExit')
          .timeout(_nativeExitTimeout);
    } on TimeoutException {
      _logPlayback('native hdr prepare exit timed out platform=windows');
    } catch (error) {
      _logPlayback('native hdr prepare exit failed: $error');
    }
    // Tear down our own tracking regardless of the native reply — we're
    // leaving the native surface, so a hung/failed prepareExit must not strand
    // the Dart state (and block the route pop) with a stale surface handle.
    _windowsNativeSurface = null;
    _isNativeFullscreen = false;
    _nativeControlsVisible = true;
  }

  Future<void> _setNativeFullscreen(bool fullscreen) async {
    if (!Platform.isWindows) return;
    try {
      final changed = await _nativeHdrPlayer.invokeMethod<bool>(
        'setFullscreen',
        {'fullscreen': fullscreen, 'pinControls': !_player.state.playing},
      );
      if (mounted) {
        setState(() => _isNativeFullscreen = changed ?? fullscreen);
      }
      await _syncWindowsNativeControlState();
      _showNativeControls(scheduleHide: _player.state.playing);
    } catch (error) {
      _logPlayback('native fullscreen failed: $error');
    }
  }

  Future<void> _toggleNativeFullscreen() async {
    if (!_usesWindowsNativeSurface) return;
    _showNativeControls(scheduleHide: _player.state.playing);
    await _setNativeFullscreen(!_isNativeFullscreen);
  }

  // Windows always-on-top mini-player: a compact frameless topmost window,
  // draggable by its video area. Toggled with the M key; the native side owns
  // the geometry and restores the previous placement on exit.
  bool _isNativeMiniPlayer = false;

  Future<void> _toggleNativeMiniPlayer() async {
    if (!_usesWindowsNativeSurface) return;
    try {
      final mini = await _nativeHdrPlayer.invokeMethod<bool>('setMiniPlayer', {
        'mini': !_isNativeMiniPlayer,
      });
      _isNativeMiniPlayer = mini ?? !_isNativeMiniPlayer;
      _logPlayback('native mini-player=$_isNativeMiniPlayer');
      await _syncWindowsNativeControlState();
    } catch (error) {
      _logPlayback('native mini-player failed: $error');
    }
  }

  Future<dynamic> _handleNativeHdrMethodCall(MethodCall call) async {
    if (call.method == 'nativeInput') {
      final ignoreUntil = _ignoreNativeInputUntil;
      if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
        return;
      }
      _showNativeControls();
    } else if (call.method == 'nativeControl') {
      final command = call.arguments?.toString();
      if (command != null) await _handleNativeControlCommand(command);
    } else if (call.method == 'nativeClosed') {
      // The native Activity reports its final VOD position on exit; persist it
      // as the resume point (live playback sends no args).
      final args = call.arguments;
      final playback = widget.playback;
      if (playback != null && args is Map) {
        final positionMs = (args['positionMs'] as num?)?.toInt();
        final durationMs = (args['durationMs'] as num?)?.toInt();
        if (positionMs != null && durationMs != null && durationMs > 0) {
          unawaited(
            playback.db.savePlaybackPosition(
              playback.sourceId,
              playback.kind,
              playback.itemId,
              position: Duration(milliseconds: positionMs),
              duration: Duration(milliseconds: durationMs),
            ),
          );
        }
      }
      await _finishAndroidNativePlayback();
    }
  }

  Future<void> _finishAndroidNativePlayback() async {
    if (!Platform.isAndroid || !mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      setState(() => _nativePlaybackLaunched = false);
    }
  }

  void _showNativeControls({bool scheduleHide = true}) {
    if (!_usesWindowsNativeSurface) return;
    if (mounted && !_nativeControlsVisible) {
      setState(() => _nativeControlsVisible = true);
    } else {
      _nativeControlsVisible = true;
    }
    unawaited(
      _nativeHdrPlayer.invokeMethod<bool>('showControls', {
        'visible': true,
        'scheduleHide': scheduleHide,
      }),
    );
  }

  void _handlePlaybackInput() {
    if (_usesWindowsNativeSurface) _showNativeControls();
  }

  Future<void> _handleNativeControlCommand(String command) async {
    if (command.startsWith('seekPercent:')) {
      final ratio = double.tryParse(command.substring('seekPercent:'.length));
      final duration = _player.state.duration;
      if (ratio != null && duration > Duration.zero) {
        await _player.seek(
          Duration(
            milliseconds: (duration.inMilliseconds * ratio.clamp(0.0, 1.0))
                .round(),
          ),
        );
      }
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('volumePercent:')) {
      final ratio = double.tryParse(command.substring('volumePercent:'.length));
      if (ratio != null) {
        await _player.setVolume((ratio.clamp(0.0, 1.0) * 100).roundToDouble());
      }
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('subtitleTrack:')) {
      final id = command.substring('subtitleTrack:'.length);
      await _selectNativeSubtitleTrack(id);
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('audioTrack:')) {
      final id = command.substring('audioTrack:'.length);
      await _selectNativeAudioTrack(id);
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('speed:')) {
      final rate = double.tryParse(command.substring('speed:'.length));
      if (rate != null) await _player.setRate(rate);
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('menu:')) {
      // The native overlay owns menu open/close state; refresh so the menu it
      // just opened renders the latest track/option list.
      await _syncWindowsNativeControlState();
      return;
    }
    switch (command) {
      case 'back':
        _back();
        break;
      case 'playPause':
        final wasPlaying = _player.state.playing;
        if (_isLive && wasPlaying) {
          _liveSynced = false; // pausing live -> behind
        }
        await _player.playOrPause();
        if (wasPlaying) _showNativeControls(scheduleHide: false);
        break;
      case 'seekBack':
        _seekBy(-10);
        break;
      case 'seekForward':
        _seekBy(10);
        break;
      case 'muteToggle':
        final volume = _player.state.volume;
        await _player.setVolume(volume > 0 ? 0 : 100);
        break;
      case 'fullscreen':
        await _toggleNativeFullscreen();
        break;
      case 'aspect':
        await _cycleNativeAspect();
        break;
      case 'goLive':
        // Live IPTV streams are usually non-seekable ("Cannot seek in this
        // stream"), so reopen the source instead of seeking — reconnecting drops
        // the buffer and resumes at the live edge.
        if (_isLive) {
          await _player.open(
            Media(
              widget.stream.url,
              httpHeaders: widget.stream.headers.isEmpty
                  ? null
                  : widget.stream.headers,
            ),
          );
          _liveSynced = true;
        }
        break;
      case 'info':
        // The native overlay owns the info-panel open state; refresh so it
        // renders with the latest metadata.
        await _syncWindowsNativeControlState();
        break;
      case 'show':
        break;
    }
    await _syncWindowsNativeControlState();
  }

  // Watchdog: a live stream stuck buffering past the threshold gets reloaded.
  void _pollLiveReconnect() {
    if (!_isLive || !mounted) return;
    if (!_buffering) {
      _stalledSinceMs = 0;
      _reconnectAttempt = 0;
      if (_reconnecting) {
        _reconnecting = false;
        _onReconnectingChanged();
      }
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_stalledSinceMs == 0) _stalledSinceMs = now;
    if (now - _stalledSinceMs >= _kStallReconnectMs) {
      unawaited(_reconnectLive(force: false));
    }
  }

  /// Reload the live source to reconnect, with capped backoff between attempts.
  /// [force] (a hard error) skips the stall threshold but still rate-limits.
  Future<void> _reconnectLive({required bool force}) async {
    if (!_isLive || !mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final attemptGap = ((_reconnectAttempt + 1) * _kStallReconnectMs).clamp(
      0,
      _kMaxBackoffMs,
    );
    final minGap = force ? _kStallReconnectMs : attemptGap;
    if (_lastReconnectMs != 0 && now - _lastReconnectMs < minGap) return;
    _reconnectAttempt++;
    _lastReconnectMs = now;
    _stalledSinceMs = now;
    _liveSynced = true; // a reconnect reopens at the live edge
    if (!_reconnecting) {
      _reconnecting = true;
      _onReconnectingChanged();
    }
    _logPlayback('live reconnect attempt=$_reconnectAttempt force=$force');
    try {
      await _player.open(
        Media(
          widget.stream.url,
          httpHeaders: widget.stream.headers.isEmpty
              ? null
              : widget.stream.headers,
        ),
      );
    } catch (error) {
      _logPlayback('live reconnect failed: ${_redactPlayback('$error')}');
    }
  }

  void _onReconnectingChanged() {
    if (_usesWindowsNativeSurface) {
      if (_reconnecting) _showNativeControls(scheduleHide: false);
      unawaited(_syncWindowsNativeControlState());
    } else if (mounted) {
      setState(() {});
    }
  }

  // Coalesces continuous-stream control-state syncs (see initState) to 2 Hz.
  // Note the native overlay auto-hides on its own timer without telling Dart,
  // so visibility can't gate this — the throttle alone does the work. Any
  // user action syncs directly, so the overlay never reappears stale.
  Timer? _controlSyncThrottle;

  void _requestControlSync() {
    if (!Platform.isWindows || _windowsNativeSurface == null) return;
    if (_controlSyncThrottle?.isActive ?? false) return;
    _controlSyncThrottle = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      unawaited(_syncWindowsNativeControlState());
    });
  }

  Future<void> _syncWindowsNativeControlState() async {
    if (!Platform.isWindows || _windowsNativeSurface == null) return;
    try {
      await _nativeHdrPlayer.invokeMethod<bool>('setControlState', {
        'title': widget.title,
        if (widget.sourceName != null) 'sourceName': widget.sourceName,
        ..._epgPayload(),
        'isLive': _isLive,
        'liveSynced': _liveSynced,
        'reconnecting': _reconnecting,
        'playing': _player.state.playing,
        'fullscreen': _isNativeFullscreen,
        'positionMs': _player.state.position.inMilliseconds.toDouble(),
        'durationMs': _player.state.duration.inMilliseconds.toDouble(),
        'volume': _player.state.volume,
        'selectedSubtitleId': _player.state.track.subtitle.id,
        'subtitleTracks': _nativeSubtitleTrackPayload(),
        'selectedAudioId': _player.state.track.audio.id,
        'audioTracks': _nativeAudioTrackPayload(),
        'selectedSpeedId': _speedId(_player.state.rate),
        'speedOptions': _speedOptionPayload(),
        'aspectLabel': _aspectModes[_aspectModeIndex].label,
        ..._streamInfoPayload(),
      });
    } catch (error) {
      _logPlayback('native hdr control state failed: $error');
    }
  }

  Future<void> _selectNativeSubtitleTrack(String id) async {
    final tracks = _nativeSubtitleTracks();
    SubtitleTrack? selected;
    for (final track in tracks) {
      if (track.id == id) {
        selected = track;
        break;
      }
    }
    if (selected == null) return;
    _logPlayback(
      'native subtitle select id=${selected.id} '
      'label=${_subtitleTrackLabel(selected)}',
    );
    await _player.setSubtitleTrack(selected);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      final properties = selected.id == 'no'
          ? const <String, String>{
              'sid': 'no',
              'secondary-sid': 'no',
              'sub-visibility': 'no',
            }
          : <String, String>{
              if (selected.id == 'auto') 'sid': 'auto',
              if (int.tryParse(selected.id) != null) 'sid': selected.id,
              'sub-visibility': 'yes',
              'sub-ass': 'yes',
              'sub-use-margins': 'no',
            };
      for (final entry in properties.entries) {
        try {
          await platform.setProperty(entry.key, entry.value);
        } catch (error) {
          _logPlayback(
            'warn mpv subtitle option ${entry.key}=${entry.value} failed: '
            '$error',
          );
        }
      }
    }
  }

  List<Map<String, String>> _nativeSubtitleTrackPayload() {
    final tracks = _nativeSubtitleTracks();
    // Only surface the subtitles button when there is something to pick beyond
    // the Auto/Off defaults (e.g. most live IPTV has none).
    final hasReal = tracks.any(
      (track) => track.id != 'auto' && track.id != 'no',
    );
    if (!hasReal) return const [];
    return tracks
        .map((track) => {'id': track.id, 'label': _subtitleTrackLabel(track)})
        .toList(growable: false);
  }

  List<AudioTrack> _nativeAudioTracks() {
    return _player.state.tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .toList();
  }

  List<Map<String, String>> _nativeAudioTrackPayload() {
    final tracks = _nativeAudioTracks();
    // Switching is only meaningful with at least two real tracks.
    if (tracks.length < 2) return const [];
    return tracks
        .map((track) => {'id': track.id, 'label': _audioTrackLabel(track)})
        .toList(growable: false);
  }

  String _audioTrackLabel(AudioTrack track) {
    final parts = <String>[];
    final language = track.language?.trim();
    if (language != null && language.isNotEmpty) {
      parts.add(language.toUpperCase());
    }
    final title = track.title?.trim();
    if (title != null && title.isNotEmpty) parts.add(title);
    final codec = _codecLabel(track.codec);
    if (codec.isNotEmpty) parts.add(codec);
    final channels = _channelsLabel(track);
    if (channels.isNotEmpty) parts.add(channels);
    if (parts.isEmpty) return 'Audio ${track.id}';
    return parts.join(' · ');
  }

  Future<void> _selectNativeAudioTrack(String id) async {
    AudioTrack? selected;
    for (final track in _nativeAudioTracks()) {
      if (track.id == id) {
        selected = track;
        break;
      }
    }
    if (selected == null) return;
    _logPlayback(
      'native audio select id=${selected.id} '
      'label=${_audioTrackLabel(selected)}',
    );
    await _player.setAudioTrack(selected);
  }

  String _speedId(double rate) => rate.toStringAsFixed(2);

  String _speedLabel(double rate) {
    if (rate == 1.0) return 'Normal (1.0×)';
    final text = rate == rate.roundToDouble()
        ? rate.toStringAsFixed(1)
        : rate.toString();
    return '$text×';
  }

  List<Map<String, String>> _speedOptionPayload() {
    if (_isLive) return const [];
    return _speedOptions
        .map((rate) => {'id': _speedId(rate), 'label': _speedLabel(rate)})
        .toList(growable: false);
  }

  Future<void> _cycleNativeAspect() async {
    _aspectModeIndex = (_aspectModeIndex + 1) % _aspectModes.length;
    final mode = _aspectModes[_aspectModeIndex];
    final platform = _player.platform;
    if (platform is NativePlayer) {
      final properties = <String, String>{
        'panscan': mode.panscan,
        'video-aspect-override': mode.aspect,
      };
      for (final entry in properties.entries) {
        try {
          await platform.setProperty(entry.key, entry.value);
        } catch (error) {
          _logPlayback('warn mpv aspect ${entry.key} failed: $error');
        }
      }
    }
    _logPlayback('native aspect mode=${mode.label}');
    await _syncWindowsNativeControlState();
  }

  // The selected track often reads as the `auto` placeholder (null codec/fps)
  // even while a concrete track is playing, so fall back to the first real
  // track for the info panel's codec/fps/channels.
  VideoTrack _infoVideoTrack() {
    final selected = _player.state.track.video;
    if (selected.codec != null || selected.fps != null) return selected;
    for (final track in _player.state.tracks.video) {
      if (track.id != 'auto' && track.id != 'no') return track;
    }
    return selected;
  }

  AudioTrack _infoAudioTrack() {
    final selected = _player.state.track.audio;
    if (selected.codec != null || selected.channels != null) return selected;
    for (final track in _player.state.tracks.audio) {
      if (track.id != 'auto' && track.id != 'no') return track;
    }
    return selected;
  }

  // Live EPG now/next snapshot for the native overlays. Epoch values are passed
  // as doubles (ms) so they survive the MethodChannel without int32 truncation.
  Map<String, Object?> _epgPayload() {
    final now = widget.epgNow;
    final next = widget.epgNext;
    return {
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

  Map<String, Object?> _streamInfoPayload() {
    final params = _player.state.videoParams;
    final video = _infoVideoTrack();
    final audio = _infoAudioTrack();
    return {
      'videoWidth': params.w ?? video.w ?? 0,
      'videoHeight': params.h ?? video.h ?? 0,
      'fps': video.fps ?? 0.0,
      'dynamicRange': _dynamicRangeLabel(params),
      'videoCodec': _codecLabel(video.codec),
      'audioCodec': _codecLabel(audio.codec),
      'audioChannels': _channelsLabel(audio),
    };
  }

  String _dynamicRangeLabel(VideoParams params) {
    final gamma = params.gamma?.toLowerCase() ?? '';
    final primaries = params.primaries?.toLowerCase() ?? '';
    final matrix = params.colormatrix?.toLowerCase() ?? '';
    if (matrix.contains('dolby') || gamma.contains('dolby')) {
      return 'Dolby Vision';
    }
    if (gamma.contains('pq')) return _hdr10Plus ? 'HDR10+ · PQ' : 'HDR10 · PQ';
    if (gamma.contains('hlg')) return 'HLG';
    if (primaries.contains('2020')) return 'HDR · BT.2020';
    if (gamma.isEmpty && primaries.isEmpty) return '';
    return 'SDR';
  }

  /// Best-effort HDR10+ detection for the Windows/mpv path (see [_hdr10Plus]).
  ///
  /// mpv exposes no "has HDR10+" flag, so we read the ST2094-40 per-scene
  /// dynamic-metadata sub-properties. These are non-zero only when the stream
  /// actually carries dynamic metadata and — unlike `max-pq-y`/`sig-peak` — are
  /// not synthesised by `hdr-compute-peak`, so they don't false-positive on plain
  /// HDR10. Any missing property / error leaves us at "HDR10 · PQ".
  Future<void> _probeHdr10Plus(VideoParams params) async {
    if (!Platform.isWindows) return;
    final gamma = params.gamma?.toLowerCase() ?? '';
    if (!gamma.contains('pq')) {
      // Not PQ -> can't be HDR10+. Clear any stale detection from a prior stream.
      _hdr10Plus = false;
      return;
    }
    if (_hdr10Plus || _probingHdr10Plus) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _probingHdr10Plus = true;
    try {
      for (final prop in const [
        'video-params/scene-max-r',
        'video-params/scene-max-g',
        'video-params/scene-max-b',
        'video-params/scene-avg',
      ]) {
        final raw = (await platform.getProperty(prop)).trim();
        final value = double.tryParse(raw);
        if (value != null && value > 0) {
          _hdr10Plus = true;
          _logPlayback('hdr10+ detected via $prop=$value');
          unawaited(_syncWindowsNativeControlState());
          break;
        }
      }
    } catch (_) {
      // Property unavailable on this mpv build -> stay at HDR10 (conservative).
    } finally {
      _probingHdr10Plus = false;
    }
  }

  String _codecLabel(String? codec) {
    if (codec == null || codec.trim().isEmpty) return '';
    switch (codec.toLowerCase()) {
      case 'hevc':
        return 'HEVC';
      case 'h264':
        return 'H.264';
      case 'mpeg2video':
        return 'MPEG-2';
      case 'av1':
        return 'AV1';
      case 'vp9':
        return 'VP9';
      case 'eac3':
        return 'E-AC3';
      case 'ac3':
        return 'AC3';
      case 'aac':
        return 'AAC';
      case 'mp3':
        return 'MP3';
      default:
        return codec.toUpperCase();
    }
  }

  String _channelsLabel(AudioTrack track) {
    final channels = track.channels?.trim();
    if (channels != null && channels.isNotEmpty) return channels;
    final count = track.audiochannels ?? track.channelscount;
    if (count != null && count > 0) {
      if (count == 1) return 'Mono';
      if (count == 2) return 'Stereo';
      return '$count ch';
    }
    return '';
  }

  List<SubtitleTrack> _nativeSubtitleTracks() {
    final external = widget.stream.subtitles.map(
      (subtitle) => SubtitleTrack.uri(
        subtitle.url,
        title: subtitle.label,
        language: subtitle.language,
      ),
    );
    final real = _player.state.tracks.subtitle
        .where((track) => track.id != 'auto' && track.id != 'no')
        .toList();
    final seen = <String>{'auto', 'no'};
    final merged = <SubtitleTrack>[SubtitleTrack.auto(), SubtitleTrack.no()];
    for (final track in [...external, ...real]) {
      if (seen.add(track.id)) merged.add(track);
    }
    return merged;
  }

  String _subtitleTrackLabel(SubtitleTrack track) {
    if (track.id == 'auto') return 'Auto';
    if (track.id == 'no') return 'Off';
    final title = track.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    final language = track.language?.trim();
    if (language != null && language.isNotEmpty) return language.toUpperCase();
    return 'Subtitle ${track.id}';
  }

  Widget _reconnectingChip() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadius.tile),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Reconnecting…',
              style: TextStyle(color: AppColors.textHi, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playbackSurface() {
    // Transparent while the adopted-handoff Activity launches/plays — the
    // route below (channel list + frozen preview frame) shows through instead
    // of a black flash.
    if (_transparentHandoff) return const SizedBox.expand();
    if (_controller == null) return _nativePlaybackOverlay();
    return _nativePlaybackLaunched ? _nativePlaybackOverlay() : _video(context);
  }

  Future<void> _configureNativePlayer(
    NativePlayer platform,
    int? nativeWindowHandle,
  ) async {
    final options = _isLive
        ? kLiveMpvOptions
        : const <String, String>{
            // File-cache creation can fail for provider HTTP URLs on Windows,
            // and mpv still has the in-memory buffer configured above.
            'cache-on-disk': 'no',
            'demuxer-max-back-bytes': '48MiB',
            'network-timeout': '15',
          };

    final videoOptions = nativeWindowHandle != null
        ? const <String, String>{
            // On Windows, prefer mpv's D3D11 path and advertise HDR metadata
            // to the display stack. With a native HWND, mpv presents directly
            // instead of round-tripping frames through Flutter's SDR texture.
            'vid': 'auto',
            // gpu-next is libplacebo's renderer; it has the modern HDR and
            // Dolby Vision (P5/P8) handling the legacy 'gpu' VO lacks. Requires
            // a libplacebo-enabled libmpv (see windows/libmpv/README.md);
            // falls back to 'gpu' when that build isn't present.
            'vo': 'gpu-next,gpu',
            'gpu-api': 'd3d11',
            'gpu-context': 'd3d11',
            // Hardware-decode on the GPU. `auto-safe` lets mpv negotiate the
            // best working method (d3d11va zero-copy with this d3d11 path) and
            // fall back cleanly to software when a codec/driver combo isn't
            // supported — forcing `d3d11va` could half-init and stall/desync.
            // 4K HEVC/10-bit is too heavy for software decode, so we want HW.
            'hwdec': 'auto-safe',
            // 10-bit swapchain so HDR/10-bit output isn't truncated to 8-bit,
            // without forcing the desktop into HDR globally.
            'd3d11-output-format': 'rgb10_a2',
            'osd-level': '1',
            'target-colorspace-hint': 'yes',
            'tone-mapping': 'auto',
            'hdr-compute-peak': 'yes',
            'panscan': '1.0',
            'sub-ass': 'yes',
            'sub-visibility': 'yes',
            'secondary-sub-visibility': 'yes',
            'sub-use-margins': 'no',
          }
        : embeddedVideoOptionsForPlatform();

    final nativeWindowOptions = nativeWindowHandle == null
        ? const <String, String>{}
        : <String, String>{
            'wid': nativeWindowHandle.toString(),
            'force-window': 'yes',
            'keepaspect-window': 'yes',
          };

    // Order matters: options apply sequentially, and `wid` must land before
    // `vo`/`force-window`. Setting `vo=gpu-next` on an already-playing player
    // (the preview hot-swap) with no `wid` yet makes mpv create the VO in its
    // *own* top-level window, then recreate it into the child surface when
    // `wid` arrives — visible as a stray window popping up during the
    // preview → fullscreen handoff.
    await applyMpvOptions(platform, {
      ...options,
      ...nativeWindowOptions,
      ...videoOptions,
    }, onWarn: (message) => _logPlayback('warn $message'));
  }

  // Logs which video output / decoder mpv actually initialized — tells us
  // whether `gpu-next` loaded or fell back to `gpu`, and the active colorspace.
  Future<void> _logActiveVideoOutput() async {
    if (_loggedActiveVo && _loggedHwdec) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      if (!_loggedActiveVo) {
        final vo = await platform.getProperty('current-vo');
        if (vo.isNotEmpty) {
          _loggedActiveVo = true;
          _logPlayback('active vo=$vo');
        }
      }
      // The decoder initializes a beat after the VO, so hwdec-current is often
      // still empty on the first videoParams event — only log it (once) once it's
      // actually engaged, so an empty reading isn't mistaken for software decode.
      if (!_loggedHwdec) {
        final hwdec = await platform.getProperty('hwdec-current');
        if (hwdec.isNotEmpty && hwdec != 'no') {
          _loggedHwdec = true;
          _logPlayback('active hwdec=$hwdec');
        }
      }
    } catch (error) {
      _loggedActiveVo = true;
      _loggedHwdec = true;
      _logPlayback('warn query active vo failed: $error');
    }
  }

  Future<void> _setNativeHeaderOptions(
    NativePlayer platform,
    Map<String, String> headers,
  ) async {
    final userAgent = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .map((entry) => entry.value)
        .firstOrNull;
    if (userAgent != null && userAgent.isNotEmpty) {
      try {
        await platform.setProperty('user-agent', userAgent);
      } catch (error) {
        _logPlayback('warn mpv user-agent failed: $error');
      }
    }
    final referrer = headers.entries
        .where((entry) {
          final key = entry.key.toLowerCase();
          return key == 'referer' || key == 'referrer';
        })
        .map((entry) => entry.value)
        .firstOrNull;
    if (referrer != null && referrer.isNotEmpty) {
      try {
        await platform.setProperty('referrer', referrer);
      } catch (error) {
        _logPlayback('warn mpv referrer failed: $error');
      }
    }
  }

  /// Persist the embedded player's current VOD position. Not used while the
  /// Android native Activity plays (its position arrives via `nativeClosed`).
  void _persistPlaybackPosition() {
    final playback = widget.playback;
    if (playback == null || _isLive) return;
    if (Platform.isAndroid && _nativePlaybackLaunched) return;
    final position = _player.state.position;
    final duration = _player.state.duration;
    if (duration <= Duration.zero) return;
    unawaited(
      playback.db.savePlaybackPosition(
        playback.sourceId,
        playback.kind,
        playback.itemId,
        position: position,
        duration: duration,
      ),
    );
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _nativeHdrPlayer.setMethodCallHandler(null);
    }
    _positionPersistTimer?.cancel();
    _persistPlaybackPosition();
    _reconnectTimer?.cancel();
    _controlSyncThrottle?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _flushDedup();
    if (Platform.isWindows && _windowsNativeSurface != null) {
      _scheduleWindowsNativeTeardown();
    }
    _disposePlayerNonBlocking();
    super.dispose();
  }

  void _disposePlayerNonBlocking() {
    if (!_ownsPlayer) return;
    final platform = _player.platform;
    if (Platform.isWindows && platform is NativePlayer) {
      unawaited(platform.dispose(synchronized: false));
    } else {
      unawaited(_player.dispose());
    }
  }

  void _back() {
    unawaited(_exitAndPop());
  }

  Future<void> _exitAndPop() async {
    if (Platform.isWindows && _nativePlaybackLaunched) {
      await _prepareWindowsNativeExit();
      _scheduleWindowsNativeTeardown(prepared: true);
    }
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(_didWindowsHotSwap);
    }
  }

  void _seekBy(int seconds) {
    if (_isLive) return; // live has no meaningful timeline to seek
    final pos = _player.state.position + Duration(seconds: seconds);
    _player.seek(pos < Duration.zero ? Duration.zero : pos);
  }

  Widget _title() {
    final now = widget.epgNow;
    final next = widget.epgNext;
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (now != null) ...[
            const SizedBox(height: 2),
            Text(
              '${_hm(now.start)} – ${_hm(now.stop)} · ${now.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          ],
          if (next != null)
            Text(
              'Next · ${_hm(next.start)} – ${_hm(next.stop)} · ${next.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textLo, fontSize: 11),
            ),
        ],
      ),
    );
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  List<Widget> _desktopBottomBar() => [
    const MaterialDesktopPlayOrPauseButton(),
    const MaterialDesktopVolumeButton(),
    if (!_isLive) const MaterialDesktopPositionIndicator(),
    const Spacer(),
    const MaterialDesktopFullscreenButton(),
  ];

  List<Widget> _topBar({required bool desktop}) => [
    desktop
        ? MaterialDesktopCustomButton(
            onPressed: _back,
            icon: const Icon(Icons.arrow_back),
          )
        : MaterialCustomButton(
            onPressed: _back,
            icon: const Icon(Icons.arrow_back),
          ),
    const SizedBox(width: 8),
    _title(),
    if (_isLive) ...[const SizedBox(width: 10), const _LiveBadge()],
    const Spacer(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _transparentHandoff ? Colors.transparent : Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _handlePlaybackInput();
            _back();
          },
          const SingleActivator(LogicalKeyboardKey.space): () {
            _handlePlaybackInput();
            _player.playOrPause();
          },
          const SingleActivator(LogicalKeyboardKey.select): () {
            _handlePlaybackInput();
            _player.playOrPause();
          },
          const SingleActivator(LogicalKeyboardKey.enter): () {
            _handlePlaybackInput();
            _player.playOrPause();
          },
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () {
            _handlePlaybackInput();
            _player.playOrPause();
          },
          const SingleActivator(LogicalKeyboardKey.mediaPlay): () {
            _handlePlaybackInput();
            _player.play();
          },
          const SingleActivator(LogicalKeyboardKey.mediaPause): () {
            _handlePlaybackInput();
            _player.pause();
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            _handlePlaybackInput();
            _seekBy(-10);
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            _handlePlaybackInput();
            _seekBy(10);
          },
          const SingleActivator(LogicalKeyboardKey.keyF): () {
            _handlePlaybackInput();
            _toggleNativeFullscreen();
          },
          const SingleActivator(LogicalKeyboardKey.keyM): () {
            _handlePlaybackInput();
            _toggleNativeMiniPlayer();
          },
        },
        child: Listener(
          onPointerHover: (_) => _handlePlaybackInput(),
          onPointerDown: (_) => _handlePlaybackInput(),
          onPointerMove: (_) => _handlePlaybackInput(),
          child: Focus(
            autofocus: true,
            child: Stack(
              children: [
                Positioned.fill(child: _playbackSurface()),
                if (_error != null) Positioned.fill(child: _errorOverlay()),
                // Windows draws its own "Reconnecting…" in the native overlay;
                // this covers the embedded media_kit path.
                if (_reconnecting && !_usesWindowsNativeSurface)
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Center(child: _reconnectingChip()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _video(BuildContext context) {
    return MaterialDesktopVideoControlsTheme(
      normal: MaterialDesktopVideoControlsThemeData(
        seekBarThumbColor: AppColors.accent,
        seekBarPositionColor: AppColors.accent,
        toggleFullscreenOnDoublePress: true,
        displaySeekBar: !_isLive,
        topButtonBar: _topBar(desktop: true),
        bottomButtonBar: _desktopBottomBar(),
      ),
      fullscreen: MaterialDesktopVideoControlsThemeData(
        seekBarThumbColor: AppColors.accent,
        seekBarPositionColor: AppColors.accent,
        toggleFullscreenOnDoublePress: true,
        displaySeekBar: !_isLive,
        topButtonBar: _topBar(desktop: true),
        bottomButtonBar: _desktopBottomBar(),
      ),
      child: MaterialVideoControlsTheme(
        normal: MaterialVideoControlsThemeData(
          seekBarThumbColor: AppColors.accent,
          seekBarPositionColor: AppColors.accent,
          buttonBarButtonColor: Colors.white,
          backdropColor: Colors.black.withValues(alpha: 0.20),
          displaySeekBar: !_isLive,
          automaticallyImplySkipNextButton: false,
          automaticallyImplySkipPreviousButton: false,
          topButtonBar: _topBar(desktop: false),
        ),
        fullscreen: MaterialVideoControlsThemeData(
          seekBarThumbColor: AppColors.accent,
          seekBarPositionColor: AppColors.accent,
          backdropColor: Colors.black.withValues(alpha: 0.20),
          displaySeekBar: !_isLive,
          automaticallyImplySkipNextButton: false,
          automaticallyImplySkipPreviousButton: false,
          topButtonBar: _topBar(desktop: false),
        ),
        child: Video(controller: _controller!),
      ),
    );
  }

  Widget _errorOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.textLo, size: 48),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textLo),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _back,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
              FilledButton.icon(
                onPressed: _open,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // The native player (Android Activity / Windows HWND) renders over this route
  // and owns its own controls; this surface is only ever visible for the launch
  // flicker and is auto-popped on `nativeClosed`. Keep it a bare black fill — no
  // labels or buttons that would read as a stray extra screen.
  Widget _nativePlaybackOverlay() => const ColoredBox(color: Colors.black);

  // Redaction lives in net.dart (redactText) so the preview controller and
  // any other user-visible error path share the same scrubbing.
  String _redactPlayback(String value) => redactText(value);

  void _logPlayback(String message) {
    DiagnosticsLog.instance.add('player', message);
    developer.log(message, name: 'iptvs.player');
    debugPrint('[iptvs.player] $message');
  }

  // Collapses runs of identical messages (e.g. the hundreds of repeated
  // `hevc: Could not find ref with POC …` errors from bad DV P5 muxing) into a
  // single line plus a `(×N)` summary, so the exportable diagnostics stay
  // readable. Non-repeating lines pass straight through.
  String? _lastDedupMessage;
  int _dedupCount = 0;

  void _logPlaybackDeduped(String message) {
    if (message == _lastDedupMessage) {
      _dedupCount++;
      return;
    }
    _flushDedup();
    _lastDedupMessage = message;
    _logPlayback(message);
  }

  void _flushDedup() {
    if (_dedupCount > 0 && _lastDedupMessage != null) {
      _logPlayback('$_lastDedupMessage (×${_dedupCount + 1})');
    }
    _lastDedupMessage = null;
    _dedupCount = 0;
  }

  String _trackSummary(dynamic track) {
    final codec = track.codec == null ? '' : ' codec=${track.codec}';
    final decoder = track.decoder == null ? '' : ' decoder=${track.decoder}';
    final channels = track.channels == null
        ? ''
        : ' channels=${track.channels}';
    final rate = track.samplerate == null ? '' : ' rate=${track.samplerate}';
    final size = track.w == null || track.h == null
        ? ''
        : ' ${track.w}x${track.h}';
    return '${track.id}$codec$decoder$channels$rate$size';
  }
}

/// A video framing mode for the Windows native surface. [panscan] maps to mpv's
/// `panscan` (0 = letterbox/fit, 1 = crop to fill) and [aspect] to
/// `video-aspect-override` (`no` clears any forced display aspect).
class _AspectMode {
  final String label;
  final String panscan;
  final String aspect;
  const _AspectMode(this.label, this.panscan, this.aspect);
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.live,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 8, color: Colors.white),
          SizedBox(width: 5),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
