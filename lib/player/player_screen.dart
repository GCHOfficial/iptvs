import 'dart:async';

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
    ),
  );
  late final VideoController _controller = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _error;

  @override
  void initState() {
    super.initState();

    // Show errors once as an overlay rather than a stream of snackbars.
    _subs.add(_player.stream.error.listen((message) {
      if (!mounted) return;
      setState(() => _error = message);
    }));
    // Clear the error overlay once playback actually starts.
    _subs.add(_player.stream.playing.listen((playing) {
      if (playing && _error != null && mounted) setState(() => _error = null);
    }));

    _open();
  }

  Future<void> _open() async {
    if (mounted) setState(() => _error = null);

    // Keep a backward cache so scrubbing back through a VOD doesn't refetch
    // already-downloaded data. (Forward cache comes from bufferSize above.)
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('demuxer-max-back-bytes', '48MiB');
    }

    // headers carry things like a MAG User-Agent for Stalker; empty for plain HLS.
    await _player.open(
      Media(
        widget.stream.url,
        httpHeaders: widget.stream.headers.isEmpty ? null : widget.stream.headers,
      ),
    );
    // Insurance against a muted/zero-volume default.
    await _player.setVolume(100);
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
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
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
        topButtonBar: [
          MaterialDesktopCustomButton(
            onPressed: _back,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 8),
          _title(),
          const Spacer(),
        ],
        bottomButtonBar: _desktopBottomBar(),
      ),
      fullscreen: MaterialDesktopVideoControlsThemeData(
        seekBarThumbColor: AppColors.accent,
        seekBarPositionColor: AppColors.accent,
        toggleFullscreenOnDoublePress: true,
        bottomButtonBar: _desktopBottomBar(),
      ),
      child: MaterialVideoControlsTheme(
        normal: MaterialVideoControlsThemeData(
          seekBarThumbColor: AppColors.accent,
          seekBarPositionColor: AppColors.accent,
          buttonBarButtonColor: Colors.white,
          automaticallyImplySkipNextButton: false,
          automaticallyImplySkipPreviousButton: false,
          topButtonBar: [
            MaterialCustomButton(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 8),
            _title(),
            const Spacer(),
          ],
        ),
        fullscreen: const MaterialVideoControlsThemeData(
          seekBarThumbColor: AppColors.accent,
          seekBarPositionColor: AppColors.accent,
          automaticallyImplySkipNextButton: false,
          automaticallyImplySkipPreviousButton: false,
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
}