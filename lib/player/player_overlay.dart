import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../sources/source.dart';
import '../theme.dart';

/// Embedded media_kit presentation. Playback lifecycle and platform handoff
/// stay in [PlayerScreen]; this widget only describes the visible controls.
class PlayerVideoSurface extends StatelessWidget {
  final VideoController controller;
  final String title;
  final Programme? epgNow;
  final Programme? epgNext;
  final bool isLive;
  final bool canFavorite;
  final bool favorite;
  final VoidCallback onBack;
  final VoidCallback onToggleFavorite;

  const PlayerVideoSurface({
    super.key,
    required this.controller,
    required this.title,
    required this.epgNow,
    required this.epgNext,
    required this.isLive,
    required this.canFavorite,
    required this.favorite,
    required this.onBack,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialDesktopVideoControlsTheme(
      normal: _desktopTheme(),
      fullscreen: _desktopTheme(),
      child: MaterialVideoControlsTheme(
        normal: _mobileTheme(),
        fullscreen: _mobileTheme(),
        child: Video(controller: controller),
      ),
    );
  }

  MaterialDesktopVideoControlsThemeData _desktopTheme() {
    return MaterialDesktopVideoControlsThemeData(
      seekBarThumbColor: AppColors.accent,
      seekBarPositionColor: AppColors.accent,
      toggleFullscreenOnDoublePress: true,
      displaySeekBar: !isLive,
      topButtonBar: _topBar(desktop: true),
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        const MaterialDesktopVolumeButton(),
        if (!isLive) const MaterialDesktopPositionIndicator(),
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
      displaySeekBar: !isLive,
      automaticallyImplySkipNextButton: false,
      automaticallyImplySkipPreviousButton: false,
      topButtonBar: _topBar(desktop: false),
    );
  }

  List<Widget> _topBar({required bool desktop}) => [
    desktop
        ? MaterialDesktopCustomButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          )
        : MaterialCustomButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
    const SizedBox(width: 8),
    Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (epgNow case final now?)
            Text(
              _programmeLine(now, epgNext),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
        ],
      ),
    ),
    if (isLive) ...[const SizedBox(width: 10), const _LiveBadge()],
    const Spacer(),
    if (canFavorite) ...[
      const SizedBox(width: 8),
      desktop
          ? MaterialDesktopCustomButton(
              onPressed: onToggleFavorite,
              icon: _favoriteIcon(),
            )
          : MaterialCustomButton(
              onPressed: onToggleFavorite,
              icon: _favoriteIcon(),
            ),
    ],
  ];

  Widget _favoriteIcon() => Icon(
    favorite ? Icons.star_rounded : Icons.star_outline_rounded,
    color: favorite ? AppColors.accent : Colors.white,
  );

  static String _hm(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static String _programmeLine(Programme now, Programme? next) {
    final current = '${_hm(now.start)} – ${_hm(now.stop)} · ${now.title}';
    if (next == null) return current;
    return '$current  •  Next ${_hm(next.start)} – ${_hm(next.stop)} · ${next.title}';
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
