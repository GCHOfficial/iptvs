import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/diagnostics_log.dart';
import '../sources/source.dart';
import '../theme.dart';

/// Plays a resolved [StreamInfo] using media_kit (libmpv under the hood, so it
/// handles HEVC / AC-3 / MPEG-TS that an HTML video element can't). Controls
/// are media_kit's adaptive set, themed to match the app.
class PlayerScreen extends StatefulWidget {
  final String title;
  final StreamInfo stream;

  const PlayerScreen({super.key, required this.title, required this.stream});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const MethodChannel _nativeHdrPlayer = MethodChannel(
    'iptvs/native_hdr_player',
  );

  late final Player _player = Player(
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
      : VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _error;
  late final bool _isLive = widget.stream.isLive;
  late bool _nativePlaybackLaunched = _usesWindowsNativeSurface;
  bool _isNativeFullscreen = false;
  bool _nativeControlsVisible = true;
  bool _nativeTeardownScheduled = false;
  DateTime? _ignoreNativeInputUntil;
  int? _windowsNativeSurface;

  bool get _usesWindowsNativeSurface => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _nativeHdrPlayer.setMethodCallHandler(_handleNativeHdrMethodCall);
    }

    // Show errors once as an overlay rather than a stream of snackbars.
    _subs.add(
      _player.stream.error.listen((message) {
        _logPlayback('error ${_redactPlayback(message)}');
        if (!mounted) return;
        setState(() => _error = message);
      }),
    );
    _subs.add(
      _player.stream.log.listen((entry) {
        if (entry.level == 'warn' || entry.level == 'error') {
          _logPlayback('${entry.level} ${entry.prefix}: ${entry.text}');
        }
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
        _logPlayback(
          'video format=${params.hwPixelformat ?? params.pixelformat} '
          'w=${params.w} h=${params.h} display=${params.dw}x${params.dh}',
        );
      }),
    );
    // Clear the error overlay once playback actually starts.
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (playing && _error != null && mounted) setState(() => _error = null);
        _syncWindowsNativeControlState();
      }),
    );
    _subs.add(
      _player.stream.position.listen((_) => _syncWindowsNativeControlState()),
    );
    _subs.add(
      _player.stream.duration.listen((_) => _syncWindowsNativeControlState()),
    );
    _subs.add(
      _player.stream.volume.listen((_) => _syncWindowsNativeControlState()),
    );

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
      return;
    }

    int? nativeWindowHandle;
    if (_usesWindowsNativeSurface) {
      nativeWindowHandle = await _createWindowsNativeHdrSurface();
      if (nativeWindowHandle == null && mounted) {
        setState(() => _nativePlaybackLaunched = false);
      }
    } else if (mounted) {
      setState(() => _nativePlaybackLaunched = false);
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
    await _player.open(
      Media(
        widget.stream.url,
        httpHeaders: widget.stream.headers.isEmpty
            ? null
            : widget.stream.headers,
      ),
    );
    // Insurance against a muted/zero-volume default.
    await _player.setVolume(100);
    _showNativeControls();
  }

  Future<bool> _tryOpenNativeHdrPlayer() async {
    if (!Platform.isAndroid) return false;
    try {
      final opened = await _nativeHdrPlayer.invokeMethod<bool>('open', {
        'url': widget.stream.url,
        'title': widget.title,
        'headers': widget.stream.headers,
        'isLive': widget.stream.isLive,
        'subtitles': widget.stream.subtitles
            .map(
              (subtitle) => {
                'url': subtitle.url,
                'label': subtitle.label,
                if (subtitle.language != null) 'language': subtitle.language,
              },
            )
            .toList(growable: false),
      });
      _logPlayback(
        opened == true
            ? 'native hdr player launched platform=android'
            : 'native hdr player unavailable platform=android',
      );
      return opened == true;
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
      final handle = await _nativeHdrPlayer.invokeMethod<int>('createSurface', {
        'topInset': 0,
        'bottomInset': 0,
      });
      if (handle == null || handle == 0) {
        _logPlayback('native hdr surface unavailable platform=windows');
        return null;
      }
      _windowsNativeSurface = handle;
      if (mounted) setState(() => _nativePlaybackLaunched = true);
      await _syncWindowsNativeControlState();
      _logPlayback('native hdr surface created platform=windows hwnd=$handle');
      return handle;
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
    try {
      unawaited(_player.setVolume(0));
      unawaited(_player.pause());
      await _nativeHdrPlayer.invokeMethod<bool>('prepareExit');
      _windowsNativeSurface = null;
      _isNativeFullscreen = false;
      _nativeControlsVisible = true;
    } catch (error) {
      _logPlayback('native hdr prepare exit failed: $error');
    }
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
    switch (command) {
      case 'back':
        _back();
        break;
      case 'playPause':
        final wasPlaying = _player.state.playing;
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
      case 'subtitles':
        await _syncWindowsNativeControlState();
        break;
      case 'show':
        break;
    }
    await _syncWindowsNativeControlState();
  }

  Future<void> _syncWindowsNativeControlState() async {
    if (!Platform.isWindows || _windowsNativeSurface == null) return;
    try {
      await _nativeHdrPlayer.invokeMethod<bool>('setControlState', {
        'title': widget.title,
        'isLive': _isLive,
        'playing': _player.state.playing,
        'fullscreen': _isNativeFullscreen,
        'positionMs': _player.state.position.inMilliseconds.toDouble(),
        'durationMs': _player.state.duration.inMilliseconds.toDouble(),
        'volume': _player.state.volume,
        'selectedSubtitleId': _player.state.track.subtitle.id,
        'subtitles': _nativeSubtitleTrackPayload(),
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
    return _nativeSubtitleTracks()
        .map((track) => {'id': track.id, 'label': _subtitleTrackLabel(track)})
        .toList(growable: false);
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

  Widget _playbackSurface() {
    if (_controller == null) return _nativePlaybackOverlay();
    return _nativePlaybackLaunched ? _nativePlaybackOverlay() : _video(context);
  }

  Future<void> _configureNativePlayer(
    NativePlayer platform,
    int? nativeWindowHandle,
  ) async {
    final options = _isLive
        ? const <String, String>{
            // IPTV live streams do not benefit from a disk file cache, and it
            // can fail on restricted temp/cache paths before playback starts.
            'cache-on-disk': 'no',
            'demuxer-max-back-bytes': '0',
            'network-timeout': '15',
            'demuxer-lavf-analyzeduration': '3',
            'demuxer-lavf-probesize': '10000000',
            'demuxer-lavf-o':
                'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
                'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],'
                'analyzeduration=3000000,probesize=10000000',
          }
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
            'vo': 'gpu',
            'gpu-api': 'd3d11',
            'gpu-context': 'd3d11',
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
        : !Platform.isWindows
        ? const <String, String>{
            // Flutter's texture path is effectively SDR outside native HDR
            // surfaces. Ask mpv to map HDR/10-bit sources into a normal SDR
            // target instead of relying on passthrough the texture may not
            // expose correctly.
            'target-prim': 'bt.709',
            'target-trc': 'bt.1886',
            'target-peak': '100',
            'tone-mapping': 'bt.2390',
            'hdr-compute-peak': 'yes',
          }
        : const <String, String>{};

    final nativeWindowOptions = nativeWindowHandle == null
        ? const <String, String>{}
        : <String, String>{
            'wid': nativeWindowHandle.toString(),
            'force-window': 'yes',
            'keepaspect-window': 'yes',
          };

    for (final entry in {
      ...options,
      ...videoOptions,
      ...nativeWindowOptions,
    }.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (error) {
        _logPlayback('warn mpv option ${entry.key} failed: $error');
      }
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

  @override
  void dispose() {
    if (Platform.isWindows) {
      _nativeHdrPlayer.setMethodCallHandler(null);
    }
    for (final s in _subs) {
      s.cancel();
    }
    if (Platform.isWindows && _windowsNativeSurface != null) {
      _scheduleWindowsNativeTeardown();
    }
    _disposePlayerNonBlocking();
    super.dispose();
  }

  void _disposePlayerNonBlocking() {
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
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _seekBy(int seconds) {
    if (_isLive) return; // live has no meaningful timeline to seek
    final pos = _player.state.position + Duration(seconds: seconds);
    _player.seek(pos < Duration.zero ? Duration.zero : pos);
  }

  Widget _title() => Flexible(
    child: Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

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
      backgroundColor: Colors.black,
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
          displaySeekBar: !_isLive,
          automaticallyImplySkipNextButton: false,
          automaticallyImplySkipPreviousButton: false,
          topButtonBar: _topBar(desktop: false),
        ),
        fullscreen: MaterialVideoControlsThemeData(
          seekBarThumbColor: AppColors.accent,
          seekBarPositionColor: AppColors.accent,
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

  Widget _nativePlaybackOverlay() {
    if (Platform.isWindows) {
      return const ColoredBox(color: Colors.black);
    }
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hdr_on, color: AppColors.accent, size: 48),
          const SizedBox(height: 12),
          Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Playing in the native HDR player',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textLo),
          ),
          const SizedBox(height: 16),
          if (!Platform.isWindows) ...[
            const SizedBox(height: 16),
            _nativeActions(),
          ],
        ],
      ),
    );
  }

  Widget _nativeActions() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: _back,
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back'),
        ),
      ],
    );
  }

  String _redactPlayback(String value) {
    final urlMatch = RegExp(
      r'https?://\S+',
      caseSensitive: false,
    ).firstMatch(value);
    if (urlMatch != null) {
      final redactedUrl = _redactPlaybackUrl(urlMatch.group(0)!);
      return value.replaceRange(urlMatch.start, urlMatch.end, redactedUrl);
    }
    return _redactPlaybackUrl(value);
  }

  String _redactPlaybackUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    if (!uri.hasAuthority && !value.contains('/')) return value;
    final cleanSegments = uri.pathSegments.map((segment) {
      final looksSecret =
          segment.length > 18 ||
          RegExp(r'^[A-Za-z0-9_-]{12,}$').hasMatch(segment);
      return looksSecret ? '<redacted>' : segment;
    }).toList();
    final path = cleanSegments.join('/');
    final authority = uri.hasAuthority
        ? '${uri.scheme}://${uri.authority}'
        : '';
    final prefix = authority.isNotEmpty
        ? authority
        : (uri.scheme.isNotEmpty ? '${uri.scheme}:' : '');
    return '$prefix/${path.replaceAll(RegExp(r'/+'), '/')}';
  }

  void _logPlayback(String message) {
    DiagnosticsLog.instance.add('player', message);
    developer.log(message, name: 'iptvs.player');
    debugPrint('[iptvs.player] $message');
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
