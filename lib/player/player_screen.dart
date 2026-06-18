import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      // 64 MB forward demuxer cache (default is 32) — smoother VOD seeking.
      bufferSize: 64 * 1024 * 1024,
      logLevel: MPVLogLevel.warn,
    ),
  );
  late final VideoController _controller = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _error;
  late final bool _isLive = widget.stream.isLive;

  @override
  void initState() {
    super.initState();

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
        _logPlayback(
          'available tracks video=[${video.isEmpty ? 'none' : video}] '
          'audio=[${audio.isEmpty ? 'none' : audio}]',
        );
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
      }),
    );

    _open();
  }

  Future<void> _open() async {
    if (mounted) setState(() => _error = null);
    _logPlayback(
      'open live=$_isLive url=${_redactPlayback(widget.stream.url)} '
      'headers=${widget.stream.headers.keys.join(',')}',
    );

    // Keep a backward cache so scrubbing back through a VOD doesn't refetch
    // already-downloaded data. (Forward cache comes from bufferSize above.)
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await _configureNativePlayer(platform);
    }

    // headers carry things like a MAG User-Agent for Stalker; empty for plain HLS.
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
  }

  Future<void> _configureNativePlayer(NativePlayer platform) async {
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
            'cache-on-disk': 'yes',
            'demuxer-max-back-bytes': '48MiB',
            'network-timeout': '15',
          };

    for (final entry in options.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (error) {
        _logPlayback('warn mpv option ${entry.key} failed: $error');
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  void _back() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
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
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.space): () =>
              _player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.select): () =>
              _player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              _player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () =>
              _player.playOrPause(),
          const SingleActivator(LogicalKeyboardKey.mediaPlay): () =>
              _player.play(),
          const SingleActivator(LogicalKeyboardKey.mediaPause): () =>
              _player.pause(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _seekBy(-10),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _seekBy(10),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              Positioned.fill(child: _video(context)),
              if (_error != null) Positioned.fill(child: _errorOverlay()),
            ],
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
        child: Video(controller: _controller),
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
          FilledButton(onPressed: _open, child: const Text('Retry')),
        ],
      ),
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
