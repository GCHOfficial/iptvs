import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../sources/source.dart';
import '../theme.dart';

/// The narrow slice of a media_kit [Player] the embedded overlay reads and
/// drives. Extracted as an interface purely so the overlay can be widget-tested
/// without a real libmpv engine (constructing a [Player] needs libmpv, which is
/// absent under plain `flutter test`): production wraps the real [Player] in
/// [PlayerBackedEmbeddedControls], tests supply a stub. Keeps the same
/// `.stream`/`.state` accessor shape the widget already used, so the body is
/// unchanged beyond the field rename.
abstract class EmbeddedControls {
  PlayerStream get stream;
  PlayerState get state;
  Future<void> setVolume(double volume);
  Future<void> seek(Duration to);
  Future<void> setRate(double rate);
  Future<void> setAudioTrack(AudioTrack track);
  Future<void> setSubtitleTrack(SubtitleTrack track);
}

/// Production [EmbeddedControls] backed by a real media_kit [Player].
class PlayerBackedEmbeddedControls implements EmbeddedControls {
  const PlayerBackedEmbeddedControls(this._player);
  final Player _player;

  @override
  PlayerStream get stream => _player.stream;
  @override
  PlayerState get state => _player.state;
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> seek(Duration to) => _player.seek(to);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);
  @override
  Future<void> setAudioTrack(AudioTrack track) => _player.setAudioTrack(track);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _player.setSubtitleTrack(track);
}

/// Embedded media_kit presentation. Playback lifecycle and platform handoff
/// stay in [PlayerScreen]; this widget only describes the visible controls.
class PlayerVideoSurface extends StatefulWidget {
  final Player player;
  final VideoController controller;
  final String title;
  final String? sourceName;
  final Programme? epgNow;
  final Programme? epgNext;
  final bool isLive;
  final bool canFavorite;
  final bool favorite;
  final bool liveSynced;

  /// Maps colorimetry to the badge/info label. Injected by [PlayerScreen]
  /// (its `_dynamicRangeLabel`, which folds in the async HDR10+ probe) so the
  /// label logic stays single-sourced in `dynamicRangeLabelFrom` — this file
  /// can't import player_screen.dart without a cycle.
  final String Function(VideoParams params) dynamicRangeLabel;
  final VoidCallback onBack;
  final VoidCallback onToggleFavorite;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onGoLive;
  final Future<void> Function() onCycleAspect;

  const PlayerVideoSurface({
    super.key,
    required this.player,
    required this.controller,
    required this.title,
    required this.sourceName,
    required this.epgNow,
    required this.epgNext,
    required this.isLive,
    required this.canFavorite,
    required this.favorite,
    required this.liveSynced,
    required this.dynamicRangeLabel,
    required this.onBack,
    required this.onToggleFavorite,
    required this.onPlayPause,
    required this.onGoLive,
    required this.onCycleAspect,
  });

  @override
  State<PlayerVideoSurface> createState() => PlayerVideoSurfaceState();
}

class PlayerVideoSurfaceState extends State<PlayerVideoSurface> {
  VideoState? _videoState;
  late final EmbeddedControls _controls = PlayerBackedEmbeddedControls(
    widget.player,
  );
  final GlobalKey<EmbeddedPlayerControlsState> _controlsKey = GlobalKey();

  void togglePlayerFullscreen() {
    final state = _videoState;
    if (state != null && state.mounted) {
      unawaited(toggleFullscreen(state.context));
    }
  }

  /// Single-press Back/Escape peel for the embedded overlay, called by
  /// [PlayerScreen]'s Escape binding: closes the info panel if open (returns
  /// true — the press is consumed) so the exit only happens once there's
  /// nothing left to peel. No-op (false) on the non-desktop default-controls
  /// path where the overlay isn't mounted.
  bool handleBackPeel() => _controlsKey.currentState?.handleBackPeel() ?? false;

  @override
  Widget build(BuildContext context) {
    // Desktop embedded surfaces (Linux always; Windows for the SDR
    // preview→fullscreen handoff, where the native HWND path is skipped) use
    // the full-featured Flutter overlay so they stay at parity with the native
    // Windows GDI / Android Compose overlays. Other embedded fallbacks (Android,
    // macOS) keep media_kit's default Material controls.
    if (Platform.isLinux || Platform.isWindows) {
      return Video(
        controller: widget.controller,
        controls: (state) {
          _videoState = state;
          return EmbeddedPlayerControls(
            key: _controlsKey,
            controls: _controls,
            title: widget.title,
            sourceName: widget.sourceName,
            epgNow: widget.epgNow,
            epgNext: widget.epgNext,
            isLive: widget.isLive,
            canFavorite: widget.canFavorite,
            favorite: widget.favorite,
            liveSynced: widget.liveSynced,
            dynamicRangeLabel: widget.dynamicRangeLabel,
            onBack: widget.onBack,
            onToggleFavorite: widget.onToggleFavorite,
            onPlayPause: widget.onPlayPause,
            onGoLive: widget.onGoLive,
            onCycleAspect: widget.onCycleAspect,
            onToggleFullscreen: togglePlayerFullscreen,
          );
        },
      );
    }
    return MaterialDesktopVideoControlsTheme(
      normal: _desktopTheme(),
      fullscreen: _desktopTheme(),
      child: MaterialVideoControlsTheme(
        normal: _mobileTheme(),
        fullscreen: _mobileTheme(),
        child: Video(controller: widget.controller),
      ),
    );
  }

  MaterialDesktopVideoControlsThemeData _desktopTheme() {
    return MaterialDesktopVideoControlsThemeData(
      seekBarThumbColor: AppColors.accent,
      seekBarPositionColor: AppColors.accent,
      toggleFullscreenOnDoublePress: true,
      displaySeekBar: !widget.isLive,
      topButtonBar: _topBar(desktop: true),
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        const MaterialDesktopVolumeButton(),
        if (!widget.isLive) const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
      ],
    );
  }

  MaterialVideoControlsThemeData _mobileTheme() {
    return MaterialVideoControlsThemeData(
      seekBarThumbColor: AppColors.accent,
      seekBarPositionColor: AppColors.accent,
      buttonBarButtonColor: Colors.white,
      backdropColor: Colors.black.withValues(alpha: 0.20),
      displaySeekBar: !widget.isLive,
      automaticallyImplySkipNextButton: false,
      automaticallyImplySkipPreviousButton: false,
      topButtonBar: _topBar(desktop: false),
    );
  }

  List<Widget> _topBar({required bool desktop}) => [
    desktop
        ? MaterialDesktopCustomButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
          )
        : MaterialCustomButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
          ),
    const SizedBox(width: 8),
    Flexible(
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
          if (widget.epgNow case final now?)
            Text(
              _programmeLine(now, widget.epgNext),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
        ],
      ),
    ),
    if (widget.isLive) ...[const SizedBox(width: 10), const _LiveBadge()],
    const Spacer(),
    if (widget.canFavorite) ...[
      const SizedBox(width: 8),
      desktop
          ? MaterialDesktopCustomButton(
              onPressed: widget.onToggleFavorite,
              icon: _favoriteIcon(),
            )
          : MaterialCustomButton(
              onPressed: widget.onToggleFavorite,
              icon: _favoriteIcon(),
            ),
    ],
  ];

  Widget _favoriteIcon() => Icon(
    widget.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
    color: widget.favorite ? AppColors.accent : Colors.white,
  );

  static String _hm(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static String _programmeLine(Programme now, Programme? next) {
    final current = '${_hm(now.start)} – ${_hm(now.stop)} · ${now.title}';
    if (next == null) return current;
    return '$current  •  Next ${_hm(next.start)} – ${_hm(next.stop)} · ${next.title}';
  }
}

/// Full-featured Flutter overlay for the embedded media_kit surface, shared by
/// Linux (X11 and Wayland) and the Windows SDR preview→fullscreen handoff (which
/// stays on the embedded texture rather than the native HWND). It drives the
/// shared media_kit [Player] directly — no platform native bridge — while
/// exposing the same controls and stream information as the Windows native GDI
/// overlay, so the two Windows paths stay at parity.
/// Public only so it can be widget-tested directly with a stub
/// [EmbeddedControls] (no libmpv engine); in the app it is built solely by
/// [PlayerVideoSurface].
class EmbeddedPlayerControls extends StatefulWidget {
  const EmbeddedPlayerControls({
    super.key,
    required this.controls,
    required this.title,
    required this.sourceName,
    required this.epgNow,
    required this.epgNext,
    required this.isLive,
    required this.canFavorite,
    required this.favorite,
    required this.liveSynced,
    required this.dynamicRangeLabel,
    required this.onBack,
    required this.onToggleFavorite,
    required this.onPlayPause,
    required this.onGoLive,
    required this.onCycleAspect,
    required this.onToggleFullscreen,
  });

  final EmbeddedControls controls;
  final String title;
  final String? sourceName;
  final Programme? epgNow;
  final Programme? epgNext;
  final bool isLive;
  final bool canFavorite;
  final bool favorite;
  final bool liveSynced;
  final String Function(VideoParams params) dynamicRangeLabel;
  final VoidCallback onBack;
  final VoidCallback onToggleFavorite;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onGoLive;
  final Future<void> Function() onCycleAspect;

  /// Enters/exits fullscreen. Injected (rather than calling media_kit's
  /// `toggleFullscreen(context)` inline) so the double-tap and fullscreen-button
  /// behavior is exercisable in a widget test without a `Video` ancestor.
  final VoidCallback onToggleFullscreen;

  @override
  State<EmbeddedPlayerControls> createState() => EmbeddedPlayerControlsState();
}

class EmbeddedPlayerControlsState extends State<EmbeddedPlayerControls> {
  Timer? _hideTimer;
  Timer? _clockTimer;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;
  StreamSubscription<VideoParams>? _paramsSub;
  bool _visible = true;
  bool _showInfo = false;

  @override
  void initState() {
    super.initState();
    _playingSub = widget.controls.stream.playing.listen((_) {
      if (mounted) setState(() {});
      _scheduleHide();
    });
    _tracksSub = widget.controls.stream.tracks.listen((_) => _refresh());
    _trackSub = widget.controls.stream.track.listen((_) => _refresh());
    _paramsSub = widget.controls.stream.videoParams.listen((_) => _refresh());
    _clockTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refresh(),
    );
    _scheduleHide();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _show({bool keep = false}) {
    if (!_visible && mounted) setState(() => _visible = true);
    if (!keep) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.controls.state.playing || _showInfo) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  /// Closes the info panel (the non-modal `Positioned` overlay). Shared by the
  /// tap-outside dismiss and [PlayerScreen]'s Escape peel; returns true when it
  /// had an open panel to close (so Escape consumes the press instead of
  /// exiting). The modal `PopupMenuButton` menus aren't a rung here — they
  /// dismiss themselves on outside-tap/Escape.
  bool handleBackPeel() {
    if (!_showInfo) return false;
    setState(() => _showInfo = false);
    _scheduleHide();
    return true;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _clockTimer?.cancel();
    _playingSub?.cancel();
    _tracksSub?.cancel();
    _trackSub?.cancel();
    _paramsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      onHover: (_) => _show(),
      child: Stack(
        children: [
          // Tap-to-show / double-tap-fullscreen lives on a background layer
          // *behind* the bars, not as an ancestor of them. A double-tap
          // recognizer holds the gesture arena for kDoubleTapTimeout (~300ms)
          // on every tap it can see; when it wrapped the whole overlay it
          // sat in the arena for every control press too, delaying each one
          // by that timeout and making the overlay feel heavy. As a sibling
          // below the bars it only sees taps on the exposed video area, so
          // button/menu taps resolve immediately.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Tapping the exposed video area closes an open info panel first
              // (tap-outside-to-dismiss), else just reveals the chrome.
              onTap: () {
                if (_showInfo) {
                  handleBackPeel();
                } else {
                  _show();
                }
              },
              onDoubleTap: widget.onToggleFullscreen,
            ),
          ),
          if (_visible) ...[_topBar(), _bottomBar(context)],
          if (_showInfo) _infoPanel(),
        ],
      ),
    );
  }

  Widget _topBar() => Positioned(
    left: 0,
    right: 0,
    top: 0,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            _button(Icons.arrow_back, 'Back', widget.onBack),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  if (widget.epgNow case final now?)
                    Text(
                      PlayerVideoSurfaceState._programmeLine(
                        now,
                        widget.epgNext,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textLo,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Badges are capped to a fraction of the bar and wrap onto a
            // second line when the window is narrow, so a full EPG + long
            // resolution/HDR/FPS/source/clock set can never overflow the row.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.55,
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: _badges(),
              ),
            ),
            if (widget.canFavorite) ...[
              const SizedBox(width: 10),
              _button(
                widget.favorite
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                widget.favorite ? 'Remove favorite' : 'Add favorite',
                widget.onToggleFavorite,
                color: widget.favorite ? AppColors.accent : Colors.white,
                compact: true,
              ),
            ],
          ],
        ),
      ),
    ),
  );

  List<Widget> _badges() {
    final params = widget.controls.state.videoParams;
    final width = params.w ?? widget.controls.state.width;
    final height = params.h ?? widget.controls.state.height;
    final video = _realVideoTrack();
    final items = <String>[
      if (width != null && height != null && width > 0 && height > 0)
        '$width×$height',
      if (widget.dynamicRangeLabel(params).isNotEmpty)
        widget.dynamicRangeLabel(params),
      if (video.fps case final fps? when fps > 0)
        '${fps.toStringAsFixed(2)} FPS',
      if (widget.sourceName case final source? when source.trim().isNotEmpty)
        source,
      _hm(DateTime.now()),
    ];
    return [for (final item in items) _badge(item)];
  }

  Widget _bottomBar(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: Container(
      // The gradient fills this (bottom-anchored) container. It ramps to a
      // solid dark value by ~45% down — where the two-row live bar (progress +
      // controls) begins — instead of fading linearly to dark only at the very
      // bottom, so both rows sit on a real backdrop rather than near-transparent
      // scrim. The top inset sets how high the transparent fade starts.
      padding: const EdgeInsets.fromLTRB(20, 36, 20, 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0x99000000), Color(0xCC000000)],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isLive) _liveProgress() else _positionRebuild(_seekBar),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              // Below this width the fixed controls + volume slider stop
              // fitting alongside the left/right split, so collapse the two
              // widest optional pieces: the volume slider (mute stays) and the
              // "Go to live" text label (its icon stays).
              final compact = constraints.maxWidth < 720;
              return Row(
                children: [
                  _button(
                    widget.controls.state.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                    widget.controls.state.playing ? 'Pause' : 'Play',
                    () => unawaited(widget.onPlayPause()),
                  ),
                  if (!widget.isLive) ...[
                    _button(Icons.replay_10, 'Back 10 seconds', () {
                      final next =
                          widget.controls.state.position -
                          const Duration(seconds: 10);
                      unawaited(
                        widget.controls.seek(
                          next < Duration.zero ? Duration.zero : next,
                        ),
                      );
                    }),
                    _button(Icons.forward_10, 'Forward 10 seconds', () {
                      unawaited(
                        widget.controls.seek(
                          widget.controls.state.position +
                              const Duration(seconds: 10),
                        ),
                      );
                    }),
                  ],
                  _volumeControls(context, showSlider: !compact),
                  if (!widget.isLive) _positionRebuild(_timeLabel),
                  const Spacer(),
                  if (widget.isLive && !widget.liveSynced)
                    compact
                        ? _button(
                            Icons.skip_next,
                            'Go to live',
                            () => unawaited(widget.onGoLive()),
                          )
                        : TextButton.icon(
                            onPressed: () => unawaited(widget.onGoLive()),
                            icon: const Icon(Icons.skip_next),
                            label: const Text('Go to live'),
                          ),
                  if (_audioTracks().length > 1) _audioMenu(),
                  _subtitleMenu(),
                  if (!widget.isLive) _speedMenu(),
                  _button(
                    Icons.aspect_ratio,
                    'Cycle aspect ratio',
                    () => unawaited(widget.onCycleAspect()),
                  ),
                  _button(Icons.info_outline, 'Stream information', () {
                    setState(() => _showInfo = !_showInfo);
                    _show(keep: _showInfo);
                  }),
                  _button(
                    Icons.fullscreen,
                    'Fullscreen (F)',
                    widget.onToggleFullscreen,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );

  /// Scopes per-position-tick rebuilds to the only widgets that actually read
  /// the position (the VOD seek bar and time label). The rest of the overlay
  /// rebuilds on its own coarser triggers (playing/tracks/videoParams/clock) —
  /// wrapping the whole Stack in this stream rebuilt every control several
  /// times a second, even for live streams that never render position at all.
  Widget _positionRebuild(Widget Function() builder) => StreamBuilder<Duration>(
    stream: widget.controls.stream.position,
    initialData: widget.controls.state.position,
    builder: (_, _) => builder(),
  );

  /// Mute toggle + volume slider, rebuilt from the volume stream so the thumb
  /// tracks the value live — the surrounding overlay doesn't listen to volume
  /// (it would rebuild every control on each drag tick), so without this the
  /// slider read a stale `state.volume` and appeared frozen.
  Widget _volumeControls(
    BuildContext context, {
    bool showSlider = true,
  }) => StreamBuilder<double>(
    stream: widget.controls.stream.volume,
    initialData: widget.controls.state.volume,
    builder: (context, snapshot) {
      final volume = (snapshot.data ?? 0).clamp(0.0, 100.0);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _button(
            volume == 0 ? Icons.volume_off : Icons.volume_up,
            'Mute',
            () => unawaited(widget.controls.setVolume(volume > 0 ? 0 : 100)),
          ),
          if (showSlider)
            SizedBox(
              width: 150,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: AppColors.accent,
                  inactiveTrackColor: AppColors.line,
                  thumbColor: AppColors.accent,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                // media_kit volume is 0–100; Slider's default max is 1.0 and it
                // asserts value <= max, so the range must be explicit.
                child: Slider(
                  max: 100,
                  value: volume,
                  onChanged: (value) {
                    _show(keep: true);
                    unawaited(widget.controls.setVolume(value));
                  },
                  onChangeEnd: (_) => _scheduleHide(),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _seekBar() {
    final duration = widget.controls.state.duration;
    final position = widget.controls.state.position;
    final maximum = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    return Slider(
      value: position.inMilliseconds.clamp(0, maximum.toInt()).toDouble(),
      max: maximum,
      onChanged: duration <= Duration.zero
          ? null
          : (value) => unawaited(
              widget.controls.seek(Duration(milliseconds: value.round())),
            ),
    );
  }

  Widget _liveProgress() {
    final now = widget.epgNow;
    final total = now?.stop.difference(now.start).inSeconds ?? 0;
    final elapsed = now == null
        ? 0
        : DateTime.now().difference(now.start).inSeconds;
    final progress = total <= 0 ? 0.0 : (elapsed / total).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          _LiveBadge(synced: widget.liveSynced),
          const SizedBox(width: 12),
          Expanded(child: LinearProgressIndicator(value: progress)),
          if (now != null) ...[
            const SizedBox(width: 12),
            // The title is width-capped and non-flex so the progress bar keeps
            // all the remaining width. A `Flexible` title shared the row ~50/50
            // with the `Expanded` bar, leaving the bar ending mid-screen with
            // dead space to its right.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
              child: Text(
                now.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _timeLabel() => Text(
    '${_duration(widget.controls.state.position)} / ${_duration(widget.controls.state.duration)}',
    style: const TextStyle(color: Colors.white70),
  );

  Widget _audioMenu() => PopupMenuButton<String>(
    tooltip: 'Audio track',
    icon: const Icon(Icons.audiotrack, color: Colors.white),
    onOpened: () => _show(keep: true),
    onCanceled: _scheduleHide,
    onSelected: (id) {
      final track = _audioTracks().firstWhere((track) => track.id == id);
      unawaited(widget.controls.setAudioTrack(track));
      _scheduleHide();
    },
    itemBuilder: (_) => [
      for (final track in _audioTracks())
        PopupMenuItem(value: track.id, child: Text(_audioLabel(track))),
    ],
  );

  Widget _subtitleMenu() {
    final tracks = widget.controls.state.tracks.subtitle;
    return PopupMenuButton<String>(
      tooltip: 'Subtitles',
      icon: const Icon(Icons.subtitles, color: Colors.white),
      onOpened: () => _show(keep: true),
      onCanceled: _scheduleHide,
      onSelected: (id) {
        final track = tracks.firstWhere((track) => track.id == id);
        unawaited(widget.controls.setSubtitleTrack(track));
        _scheduleHide();
      },
      itemBuilder: (_) => [
        for (final track in tracks)
          PopupMenuItem(value: track.id, child: Text(_subtitleLabel(track))),
      ],
    );
  }

  Widget _speedMenu() => PopupMenuButton<double>(
    tooltip: 'Playback speed',
    icon: const Icon(Icons.speed, color: Colors.white),
    onOpened: () => _show(keep: true),
    onCanceled: _scheduleHide,
    onSelected: (rate) {
      unawaited(widget.controls.setRate(rate));
      _scheduleHide();
    },
    itemBuilder: (_) => [
      for (final rate in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
        PopupMenuItem(
          value: rate,
          child: Text(rate == 1 ? 'Normal (1.0×)' : '$rate×'),
        ),
    ],
  );

  Widget _infoPanel() {
    final params = widget.controls.state.videoParams;
    final video = _realVideoTrack();
    final audio = _realAudioTrack();
    final rows = <(String, String)>[
      ('Resolution', '${params.w ?? video.w ?? 0}×${params.h ?? video.h ?? 0}'),
      (
        'Dynamic range',
        widget.dynamicRangeLabel(params).isEmpty
            ? 'Unknown'
            : widget.dynamicRangeLabel(params),
      ),
      ('Video', _codec(video.codec)),
      (
        'Audio',
        [
          _codec(audio.codec),
          audio.channels ?? '',
        ].where((e) => e.isNotEmpty).join(' · '),
      ),
      if (video.fps != null)
        ('Frame rate', '${video.fps!.toStringAsFixed(3)} FPS'),
    ];
    return Positioned(
      top: 76,
      right: 20,
      width: 320,
      // Absorb taps so a press on the panel itself doesn't fall through to the
      // background tap-outside handler and immediately re-close it.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Material(
          color: AppColors.panel.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(AppRadius.tile),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Stream information',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 115,
                          child: Text(
                            row.$1,
                            style: const TextStyle(color: AppColors.textLo),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row.$2,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Rounded-rect chip button matching the native Windows GDI / Android Compose
  // overlays (dark translucent fill, accent-tinted when active) rather than a
  // bare Material IconButton, so the embedded overlay reads the same across the
  // two Windows paths. [active] highlights a toggled control (e.g. an open
  // menu); [color] overrides the icon tint (e.g. the accent favourite star).
  Widget _button(
    IconData icon,
    String tooltip,
    VoidCallback onPressed, {
    Color? color,
    bool active = false,
    bool compact = false,
  }) => Padding(
    padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 3),
    child: Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? Color.alphaBlend(
                AppColors.accent.withValues(alpha: 0.30),
                AppColors.panel,
              )
            : AppColors.panel.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(compact ? 10 : 12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            _show();
            onPressed();
          },
          child: SizedBox(
            width: compact ? 34 : 44,
            height: compact ? 32 : 40,
            child: Icon(
              icon,
              size: compact ? 18 : 20,
              color: color ?? (active ? Colors.white : AppColors.textHi),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.panel.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xFFCED2E0),
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  List<AudioTrack> _audioTracks() => widget.controls.state.tracks.audio
      .where((track) => track.id != 'auto' && track.id != 'no')
      .toList(growable: false);

  VideoTrack _realVideoTrack() => widget.controls.state.tracks.video.firstWhere(
    (track) => track.id != 'auto' && track.id != 'no',
    orElse: () => widget.controls.state.track.video,
  );

  AudioTrack _realAudioTrack() =>
      _audioTracks().firstOrNull ?? widget.controls.state.track.audio;

  static String _audioLabel(AudioTrack track) => [
    track.language?.toUpperCase(),
    track.title,
    _codec(track.codec),
    track.channels,
  ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');

  static String _subtitleLabel(SubtitleTrack track) {
    if (track.id == 'auto') return 'Auto';
    if (track.id == 'no') return 'Off';
    return track.title?.trim().isNotEmpty == true
        ? track.title!
        : (track.language?.toUpperCase() ?? 'Subtitle ${track.id}');
  }

  static String _codec(String? codec) =>
      codec == null || codec.isEmpty ? 'Unknown' : codec.toUpperCase();
  static String _hm(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  static String _duration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minutes:$seconds'
        : '${value.inMinutes}:$seconds';
  }
}

class PlayerReconnectChip extends StatelessWidget {
  const PlayerReconnectChip({super.key});

  @override
  Widget build(BuildContext context) {
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
}

class PlayerErrorOverlay extends StatelessWidget {
  final String message;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  const PlayerErrorOverlay({
    super.key,
    required this.message,
    required this.onBack,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
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
            message,
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
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({this.synced = true});

  final bool synced;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: synced ? AppColors.live : Colors.white24,
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
