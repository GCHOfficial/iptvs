import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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

  /// Label of the aspect mode playback is *currently* in ("Fit"/"Fill"/"16:9"/
  /// "4:3"). Rendered as the aspect control's text, exactly as all four native
  /// overlays do — Dart owns the mode sequence (`PlayerScreen._aspectModes`),
  /// so this overlay showing a bare icon left it the only surface that hid the
  /// state it is itself the source of truth for.
  final String aspectLabel;

  /// How the embedded surface frames the picture for the current aspect mode.
  ///
  /// The embedded path is composited by **Flutter**, not by mpv: `media_kit`'s
  /// `Video` draws the texture with a `BoxFit`, so the mpv `panscan`/
  /// `keepaspect` properties that frame the *native* surfaces do not reach it.
  /// Both come off the same `_AspectMode`, so the two surfaces — which swap on
  /// one machine depending only on whether the stream is HDR — cannot end up
  /// framing differently.
  final BoxFit videoFit;

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

  /// Overrides [PlayerVideoSurfaceState.togglePlayerFullscreen] for the
  /// on-screen button and the pointer double-tap.
  ///
  /// `media_kit_video`'s `toggleFullscreen` drives its own window handling,
  /// which does nothing under this app's custom Windows runner — so the button
  /// was dead on the whole Windows SDR preview→fullscreen path while still
  /// advertising itself. [PlayerScreen] supplies a handler that goes through
  /// the runner's own `setFullscreen` channel there, and leaves this null
  /// wherever the embedded toggle is the right one.
  final VoidCallback? onRequestFullscreen;

  const PlayerVideoSurface({
    super.key,
    this.onRequestFullscreen,
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
    required this.aspectLabel,
    required this.videoFit,
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
    final override = widget.onRequestFullscreen;
    if (override != null) {
      override();
      return;
    }
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

  /// Brings the chrome back on **any** input, called by every one of
  /// [PlayerScreen]'s keyboard bindings.
  ///
  /// Without this a keyboard-only user could strand the overlay hidden: the
  /// chrome auto-hides after 4 s, Space then pauses, and `_scheduleHide` bails
  /// on `!playing` — so nothing was left that could set `_visible` back to
  /// true except a mouse hover or a tap. Arrow-key seeking was invisible for
  /// the same reason. Every other overlay in the app (Android, Windows GDI,
  /// the Linux Lua OSD) already reveals on any key; this brings the embedded
  /// path in line. No-op where the overlay isn't mounted.
  void revealChrome() => _controlsKey.currentState?.revealChrome();

  // Keyboard counterparts of the overlay's own buttons. These exist so the
  // embedded surface answers the same keys as the Linux native mpv/Lua OSD:
  // `m`/`i`/`s`/volume were bound there and nowhere here, so on Linux the same
  // physical key did different things depending on whether the stream happened
  // to be HDR-on-Wayland (native) or anything else (embedded).
  void toggleMute() => _controlsKey.currentState?.toggleMute();
  void adjustVolume(double delta) =>
      _controlsKey.currentState?.adjustVolume(delta);
  void toggleInfo() => _controlsKey.currentState?.toggleInfo();
  void toggleOverlayFavorite() => _controlsKey.currentState?.toggleFavorite();

  @override
  Widget build(BuildContext context) {
    // Embedded surfaces that get the full-featured Flutter overlay, so they
    // stay at parity with the native Windows GDI / Android Compose / iOS UIKit
    // overlays:
    //  * Linux — always (the embedded path is the default fullscreen path).
    //  * Windows — the SDR preview→fullscreen handoff, where the native HWND
    //    path is skipped.
    //  * iOS — the **mpv engine** path (`selectIosEngine`). That is not a rare
    //    fallback: an extension-less Stalker/MAG `create_link` locator routes
    //    to mpv by rule, so for a Stalker user this overlay *is* the player.
    //    media_kit's stock Material controls were wrong there twice over — they
    //    ignore `isLive` and expose the HLS live window as a scrubbable
    //    duration, violating "Live = no seek bar", and they carry none of the
    //    app's chrome (EPG, badges, go-to-live, favorite, track menus).
    // Android keeps media_kit's default Material controls: its embedded surface
    // is a true fallback (only reached when `HdrPlayerActivity` can't launch)
    // and it must stay usable from an Android TV D-pad, which this overlay's
    // Material sliders/menus are not built for.
    //
    // [touch] tunes the overlay for a finger instead of a pointer — see the
    // flag's doc on [EmbeddedPlayerControls].
    if (Platform.isLinux || Platform.isWindows || Platform.isIOS) {
      return Video(
        controller: widget.controller,
        fit: widget.videoFit,
        controls: (state) {
          _videoState = state;
          return EmbeddedPlayerControls(
            key: _controlsKey,
            controls: _controls,
            touch: Platform.isIOS,
            title: widget.title,
            sourceName: widget.sourceName,
            epgNow: widget.epgNow,
            epgNext: widget.epgNext,
            isLive: widget.isLive,
            canFavorite: widget.canFavorite,
            favorite: widget.favorite,
            liveSynced: widget.liveSynced,
            aspectLabel: widget.aspectLabel,
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
        child: Video(controller: widget.controller, fit: widget.videoFit),
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
    required this.aspectLabel,
    required this.dynamicRangeLabel,
    required this.onBack,
    required this.onToggleFavorite,
    required this.onPlayPause,
    required this.onGoLive,
    required this.onCycleAspect,
    required this.onToggleFullscreen,
    this.touch = false,
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

  /// Current aspect mode label — see [PlayerVideoSurface.aspectLabel].
  final String aspectLabel;
  final String Function(VideoParams params) dynamicRangeLabel;
  final VoidCallback onBack;
  final VoidCallback onToggleFavorite;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onGoLive;
  final Future<void> Function() onCycleAspect;

  /// Enters/exits fullscreen. Injected (rather than calling media_kit's
  /// `toggleFullscreen(context)` inline) so the double-tap and fullscreen-button
  /// behavior is exercisable in a widget test without a `Video` ancestor.
  ///
  /// Unused when [touch] is set — the route is already fullscreen there, so the
  /// control and the double-tap gesture are both absent (see [touch]).
  final VoidCallback onToggleFullscreen;

  /// Tunes the overlay for a **finger** rather than a mouse pointer. False
  /// everywhere but iOS, so Linux/Windows keep their existing pointer behavior
  /// byte-for-byte; every difference below is additive and gated on this flag.
  ///
  /// Four things change, each to agree with the native iOS
  /// `IptvsPlayerViewController` this overlay now sits beside (the two are
  /// reached by different *streams* on the same device — AVPlayer vs mpv — so a
  /// user can meet both in one session and they must not behave differently):
  ///
  ///  1. **Tap is the Back ladder.** With no hardware Back and no hover, touch
  ///     is the ladder's input (docs/tv-navigation.md, Back-ladder section):
  ///     a tap peels the info panel, else *hides* visible chrome, else reveals
  ///     it. That is Swift's `playerTapAction` — `nextPlayerBackAction` with the
  ///     terminal rung swapped from exit to show — reproduced here. On a pointer
  ///     platform a tap only ever *shows* (hover already handles reveal, and
  ///     hiding out from under the cursor is wrong), which is why this is gated.
  ///     The explicit control still exits outright, skipping the ladder, exactly
  ///     as the back arrow does on Windows/Linux and the **X** does on native
  ///     iOS — it takes that platform's glyph and label here.
  ///  2. **No fullscreen affordance.** The Flutter route *is* fullscreen on iOS;
  ///     media_kit's `toggleFullscreen` would push a second route with its own
  ///     `Video`, above the one [PlayerScreen] owns. The native controller has
  ///     no fullscreen button either. Dropping the double-tap recognizer also
  ///     makes rung 1 resolve immediately instead of after `kDoubleTapTimeout`.
  ///  3. **≥44pt hit targets** (Apple HIG) in *both* axes, instead of the 44×40
  ///     / 34×32 chips sized for a cursor. 44 is a floor, not a target: the
  ///     roomy metrics sit at 48 and the dense ones (item 5) sit exactly on 44,
  ///     never below.
  ///  4. **Two-row reflow**, the same reparenting the native overlay's
  ///     `applyCompactLayout` does: below [kTouchReflowWidth] the badges get
  ///     their own row under the title and the button cluster its own row under
  ///     the transport. A phone in portrait cannot fit either on one line, and
  ///     the alternative is a `RenderFlex` overflow. The trigger is
  ///     [kTouchReflowWidth] (560, the native breakpoint) and **not**
  ///     [kCompactControlsWidth] (720, the pointer feature-collapse threshold)
  ///     — sharing the pointer number reflowed a landscape phone the native
  ///     overlay keeps on one row. Above the reflow width the touch transport
  ///     is wrapped in an `Expanded` rather than separated by a `Spacer`, so
  ///     the free space lands after the transport and the cluster stays hard
  ///     right.
  ///  5. **Dense vertical metrics below [kShortOverlayHeight]** — a phone in
  ///     landscape is 320–440pt tall, and the desktop-sized paddings left it
  ///     with 49pt of visible video. Padding and icon sizes shrink; the control
  ///     set does not change and the VOD seek slider (the one real drag target)
  ///     keeps its height. See [EmbeddedOverlayMetrics].
  ///  6. **The info panel is banded between the two bars** rather than placed
  ///     at a hard-coded offset, and scrolls when the card cannot fit. See
  ///     [_infoPanel].
  ///  7. **Dynamic Type is clamped** to [kTouchMaxTextScale] — the native
  ///     controller ignores it outright, and unclamped it overflows the chrome
  ///     column on a landscape phone.
  ///
  /// Auto-hide timing is deliberately *not* varied: this overlay's flat 4s sits
  /// between the native controller's 3.5s (VOD) and 4.5s (live), and a shared
  /// widget diverging by half a second buys nothing.
  final bool touch;

  @override
  State<EmbeddedPlayerControls> createState() => EmbeddedPlayerControlsState();
}

// ---------------------------------------------------------------------------
// Badge labels
//
// The top-bar badges are the same six facts on every surface, so they are
// formatted by the same rules everywhere: Kotlin `PlayerUiState.resolutionBadge`
// /`hdrBadge`/`fpsBadge`/`sourceBadge`, Swift `BadgeFormatting`, the Windows GDI
// `ResolutionBadge`/`HdrBadge`/`FormatFps`/`TruncateBadge`, and these. This
// overlay used to format them its own way — `3840×2160` where every native says
// `4K`, `50.00 FPS` where they say `50fps`, the *full* dynamic-range label
// (including a bare `SDR` badge no native shows) where they show a compact
// `HDR10`/`DV` or nothing — which, on Windows, meant the SDR and HDR surfaces of
// the same channel disagreed about what the picture was.
//
// Public and pure so they can be tested directly (`test/player_overlay_test.dart`).
// ---------------------------------------------------------------------------

/// `4K`/`1440p`/`1080p`/`720p`/`SD`, or null when the size isn't known yet.
/// The thresholds are deliberately loose (a 1088-tall stream is still 1080p).
String? resolutionBadgeLabel({int? width, int? height}) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  if (height >= 2000 || width >= 3500) return '4K';
  if (height >= 1400 || width >= 2400) return '1440p';
  if (height >= 1000 || width >= 1800) return '1080p';
  if (height >= 700 || width >= 1200) return '720p';
  return 'SD';
}

/// Compact HDR badge from an already-formatted dynamic-range label
/// (`dynamicRangeLabelFrom`), or null when the stream is SDR/unknown — no
/// overlay in the app badges "SDR", it simply says nothing.
String? hdrBadgeLabel(String dynamicRange) {
  if (dynamicRange.toLowerCase().contains('dolby')) return 'DV';
  if (dynamicRange.contains('HDR10+')) return 'HDR10+';
  if (dynamicRange.contains('HDR10')) return 'HDR10';
  if (dynamicRange.contains('HLG')) return 'HLG';
  if (dynamicRange.startsWith('HDR')) return 'HDR';
  return null;
}

/// `50fps` / `23.976fps`, or null when the rate isn't known.
String? fpsBadgeLabel(double? fps) =>
    fps == null || fps <= 0 ? null : '${trimmedDecimal(fps)}fps';

/// A number the way every player label in this repo renders one: rounded to 3
/// decimals, then stripped of trailing zeros (`25`, `23.976`, `0.75`).
String trimmedDecimal(double value) {
  final rounded = (value * 1000).round() / 1000;
  if (rounded == rounded.truncateToDouble()) return rounded.toInt().toString();
  var text = rounded.toStringAsFixed(3);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}

/// Source name, truncated so a long provider label can't crowd the bar; null
/// when blank.
String? sourceBadgeLabel(String? name) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  return trimmed.length > 20 ? '${trimmed.substring(0, 19)}…' : trimmed;
}

/// The clock badge. Pointer surfaces (Windows/Linux) carry the **dated** form
/// their native counterparts do (GDI `%a %d %b · %H:%M`, Android TV's
/// `EEE d MMM · HH:mm`); the touch surface stays bare `HH:mm`, matching the iOS
/// controller's `playerClockHm`. Weekday/month names are hand-rolled English
/// rather than localized — the C-locale `wcsftime` the GDI overlay uses prints
/// exactly these, and parity with the surface next door is the point.
String playerClockLabel(DateTime now, {required bool dated}) {
  final hm =
      '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}';
  if (!dated) return hm;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  // Unpadded day ("Sat 8 Aug"), matching Kotlin's `EEE d MMM · HH:mm` — checked
  // against the Compose overlay on an Android TV emulator, which is also why
  // the GDI overlay's `%d` became `%#d`.
  return '${days[now.weekday - 1]} ${now.day} ${months[now.month - 1]} · $hm';
}

/// Width below which the control row can no longer carry its optional pieces:
/// the volume slider collapses to the mute button and "Go to live" drops its
/// text label. Applies on **both** paths, and is measured against the bar's
/// *inner* constraints (inside its padding), which is where it has always been
/// evaluated — deriving it from the surface size instead would shift the
/// effective collapse point by the bar's 32–40pt of padding.
///
/// This is a *feature-collapse* threshold, not a reflow one. The touch reflow
/// has its own, narrower [kTouchReflowWidth].
const double kCompactControlsWidth = 720;

/// Width below which the touch layout reflows onto two rows: the badges get
/// their own row under the title, and the button cluster its own row under the
/// transport.
///
/// Deliberately equal to the native iOS overlay's `PlayerDimens.compactWidth`
/// (`PlayerControlsView.applyCompactLayout`), because the two overlays are
/// reached by different *streams* on the same device — AVPlayer vs mpv — and a
/// user who meets both in one session must not see them reflow at different
/// widths. This used to reuse [kCompactControlsWidth]'s 720, which reflowed a
/// 667×375 phone in landscape (iPhone SE/8 class) that the native overlay keeps
/// on one row: stacking rows is exactly the wrong answer on the *shortest*
/// surface the app targets, and it left 49pt of visible video.
const double kTouchReflowWidth = 560;

/// Upper bound on text scaling inside the touch overlay chrome.
///
/// The native `IptvsPlayerViewController` sizes every label with a fixed
/// `UIFont.systemFont(ofSize:)` — no `UIFontMetrics`, no `preferredFont` — so it
/// ignores Dynamic Type outright. A user meets both overlays on one device
/// (AVPlayer vs mpv on the same channel), so the Flutter one growing to 2× while
/// the native one stays put is itself a parity break, on top of being a layout
/// one: at 2× the two bars alone exceed a 375–393pt-tall landscape phone and the
/// chrome column overflows.
///
/// 1.3 rather than 1.0 deliberately keeps *some* of the accessibility benefit —
/// it is the largest bound at which the worst real surface (667×375, VOD, full
/// control set) still fits — instead of matching native's total refusal to
/// scale. The chrome is icons and short badges; the readable content here is the
/// video.
///
/// Pointer platforms are untouched: they have no Dynamic Type equivalent driving
/// this, and their windows are never short enough for it to bind.
const double kTouchMaxTextScale = 1.3;

/// Height below which the touch layout switches to its dense vertical metrics.
///
/// Separates "phone in landscape" (320–440pt tall across the whole iPhone
/// range) from everything else: the shortest iPhone *portrait* height is 568
/// and iPad landscape is 768/834, so an iPad in landscape correctly keeps the
/// roomy metrics. Density is purely vertical — it never changes which controls
/// exist, and never takes a hit target below Apple's 44pt floor.
const double kShortOverlayHeight = 500;

/// The vertical metrics the overlay chrome is laid out with, resolved once per
/// build from the surface size and [EmbeddedPlayerControls.touch].
///
/// Exists so the *pointer* path is size-invariant **by construction** rather
/// than by inspection: `EmbeddedOverlayMetrics.of(anySize, touch: false)`
/// returns one fixed token set at every size, so a regression that leaks a
/// touch-only metric onto Linux/Windows is a failing pure test rather than
/// something a reviewer has to catch by eye. It also mirrors the native
/// overlay's model — a `PlayerDimens` token table plus one `isCompact`
/// decision — so the two layouts can be compared by reading two tables.
@immutable
class EmbeddedOverlayMetrics {
  const EmbeddedOverlayMetrics._({
    required this.reflow,
    required this.dense,
    required this.topPadTop,
    required this.topPadBottom,
    required this.badgeGap,
    required this.epgGap,
    required this.bottomPadTop,
    required this.bottomPadBottom,
    required this.buttonWidth,
    required this.buttonHeight,
    required this.buttonCompactWidth,
    required this.buttonCompactHeight,
    required this.buttonIcon,
    required this.buttonCompactIcon,
    required this.infoPanelWidth,
    required this.infoPanelPad,
    required this.infoRowPad,
  });

  /// Resolves the metrics for a surface. [touch] is the only thing that can
  /// make the result size-dependent: with it false, every size maps to the same
  /// instance-equal token set (the pointer path's shipped values).
  factory EmbeddedOverlayMetrics.of(Size surface, {required bool touch}) {
    if (!touch) return _pointer;
    final dense = surface.height < kShortOverlayHeight;
    return EmbeddedOverlayMetrics._(
      reflow: surface.width < kTouchReflowWidth,
      dense: dense,
      topPadTop: dense ? 6 : 12,
      topPadBottom: dense ? 10 : 28,
      badgeGap: dense ? 4 : 8,
      // The live EPG strip's internal gaps (title row / progress / next). 6 is
      // the value all three native overlays use (Compose `Spacer(6.dp)`, the
      // iOS `epgStrip` stack spacing, the GDI strip's 30/46px row offsets);
      // dense shaves it for a landscape phone, where the strip now costs three
      // rows instead of one.
      epgGap: dense ? 4 : 6,
      bottomPadTop: dense ? 14 : 36,
      bottomPadBottom: dense ? 8 : 14,
      // A finger needs Apple's 44pt minimum in *both* axes. 44 is the floor,
      // not a target: the roomy mode sits above it and dense sits exactly on
      // it, so no touch control is ever smaller than a fingertip.
      buttonWidth: dense ? 44 : 48,
      buttonHeight: dense ? 44 : 48,
      buttonCompactWidth: 44,
      buttonCompactHeight: 44,
      buttonIcon: dense ? 20 : 22,
      buttonCompactIcon: dense ? 18 : 20,
      // Matches the native `PlayerDimens.infoPanelWidth`.
      infoPanelWidth: 260,
      infoPanelPad: dense ? 14 : 18,
      infoRowPad: dense ? 2 : 4,
    );
  }

  /// The pointer path's metrics: the values Linux and Windows have shipped,
  /// returned for every surface size.
  static const _pointer = EmbeddedOverlayMetrics._(
    reflow: false,
    dense: false,
    topPadTop: 12,
    topPadBottom: 28,
    badgeGap: 8,
    epgGap: 6,
    bottomPadTop: 36,
    bottomPadBottom: 14,
    // Deliberately shorter than they are wide — fine for a cursor, and not for
    // a thumb, which is what [EmbeddedOverlayMetrics.of] overrides under touch.
    buttonWidth: 44,
    buttonHeight: 40,
    buttonCompactWidth: 34,
    buttonCompactHeight: 32,
    buttonIcon: 20,
    buttonCompactIcon: 18,
    infoPanelWidth: 320,
    infoPanelPad: 18,
    infoRowPad: 4,
  );

  /// Two-row reflow (badges under the title, cluster under the transport).
  /// Always false on the pointer path.
  final bool reflow;

  /// Dense vertical metrics for a short (landscape-phone) surface. Always false
  /// on the pointer path.
  final bool dense;

  final double topPadTop;
  final double topPadBottom;
  final double badgeGap;

  /// Vertical gap between the live EPG strip's three rows (title+range,
  /// programme progress, "Next ·"). See [_liveEpgStrip].
  final double epgGap;
  final double bottomPadTop;
  final double bottomPadBottom;
  final double buttonWidth;
  final double buttonHeight;
  final double buttonCompactWidth;
  final double buttonCompactHeight;
  final double buttonIcon;
  final double buttonCompactIcon;
  final double infoPanelWidth;
  final double infoPanelPad;
  final double infoRowPad;

  @override
  bool operator ==(Object other) =>
      other is EmbeddedOverlayMetrics &&
      other.reflow == reflow &&
      other.dense == dense &&
      other.topPadTop == topPadTop &&
      other.topPadBottom == topPadBottom &&
      other.badgeGap == badgeGap &&
      other.epgGap == epgGap &&
      other.bottomPadTop == bottomPadTop &&
      other.bottomPadBottom == bottomPadBottom &&
      other.buttonWidth == buttonWidth &&
      other.buttonHeight == buttonHeight &&
      other.buttonCompactWidth == buttonCompactWidth &&
      other.buttonCompactHeight == buttonCompactHeight &&
      other.buttonIcon == buttonIcon &&
      other.buttonCompactIcon == buttonCompactIcon &&
      other.infoPanelWidth == infoPanelWidth &&
      other.infoPanelPad == infoPanelPad &&
      other.infoRowPad == infoRowPad;

  @override
  int get hashCode => Object.hash(
    reflow,
    dense,
    topPadTop,
    topPadBottom,
    badgeGap,
    epgGap,
    bottomPadTop,
    bottomPadBottom,
    buttonWidth,
    buttonHeight,
    buttonCompactWidth,
    buttonCompactHeight,
    buttonIcon,
    buttonCompactIcon,
    infoPanelWidth,
    infoPanelPad,
    infoRowPad,
  );
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

  /// True while a track/subtitle/speed `PopupMenuButton` route is open.
  ///
  /// Cancelling the timer in `_show(keep: true)` is not enough on its own:
  /// `_playingSub` re-arms one on the next `playing` edge, which a live stream
  /// produces routinely. Without this flag the bars would be pulled out from
  /// under an open menu — and because the bars are removed from the tree when
  /// `_visible` goes false, `PopupMenuButton`'s `showMenu(...).then` guards on
  /// `mounted` and drops the result: the user's track selection would be
  /// silently discarded. See [_scheduleHide].
  bool _menuOpen = false;

  /// Resolved at the top of every [build] and read by the layout helpers below,
  /// rather than threaded through eight signatures. Size-invariant (and equal
  /// to the shipped pointer values) whenever `widget.touch` is false.
  EmbeddedOverlayMetrics _m = EmbeddedOverlayMetrics._pointer;

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
    // `keep` must *cancel*, not merely skip re-arming. `_scheduleHide` owns the
    // only other `_hideTimer.cancel()`, so skipping it left an already-armed
    // timer running — open a menu one second after the chrome appeared and the
    // bars still vanished three seconds later, taking the open menu's own
    // button out of the tree with them. `PopupMenuButton` guards its result
    // callback on `mounted`, so that dropped the selection *and* left
    // `_menuOpen` pinned true, after which the overlay never auto-hid again.
    if (keep) {
      _hideTimer?.cancel();
      return;
    }
    _scheduleHide();
  }

  /// Public counterpart of [_show] for [PlayerVideoSurfaceState.revealChrome] —
  /// see its doc for why any keyboard input has to reach here.
  void revealChrome() => _show();

  /// Mute/unmute — the keyboard counterpart of the volume button.
  void toggleMute() {
    final volume = widget.controls.state.volume;
    unawaited(widget.controls.setVolume(volume > 0 ? 0 : 100));
    _show();
  }

  /// Nudge the volume by [delta] (media_kit's scale is 0–100).
  void adjustVolume(double delta) {
    final volume = (widget.controls.state.volume + delta).clamp(0.0, 100.0);
    unawaited(widget.controls.setVolume(volume));
    _show();
  }

  /// Open/close the info panel.
  void toggleInfo() {
    setState(() => _showInfo = !_showInfo);
    _show();
  }

  /// Toggle the favorite star, when this stream can be favorited at all.
  void toggleFavorite() {
    if (!widget.canFavorite) return;
    widget.onToggleFavorite();
    _show();
  }

  void _onMenuOpened() {
    _menuOpen = true;
    _show(keep: true);
  }

  void _onMenuClosed() {
    _menuOpen = false;
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    // `_menuOpen` matters because `_playingSub` calls this on *every* `playing`
    // transition, including the buffering→playing edge a live stream produces
    // routinely — so an open track/subtitle/speed menu would otherwise have
    // the bars yanked out from under it 4 s later. Android pins via
    // `state.pinned`, iOS via `AutoHidePolicy.shouldSchedule(pinned:)` and the
    // Lua OSD via `not open_menu`; this overlay was the only one that didn't.
    if (!widget.controls.state.playing || _showInfo || _menuOpen) return;
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

  void _hideNow() {
    _hideTimer?.cancel();
    if (_visible && mounted) setState(() => _visible = false);
  }

  /// One tap on the scrim / exposed video area.
  ///
  /// Under [EmbeddedPlayerControls.touch] this is the iOS Back ladder, and it
  /// is deliberately the same table as Swift's `playerTapAction`
  /// (`PlayerBackPolicy.swift`): info panel first, then hide visible chrome,
  /// else reveal it. (The list menus are modal `PopupMenuButton` routes whose
  /// own barrier eats the outside tap, so they self-close on the same single
  /// press — they are the ladder's first rung in effect, just not one this
  /// handler ever sees.) On a pointer platform the terminal rung stays
  /// "reveal", since hover already reveals and hiding under the cursor is not
  /// what any desktop player does.
  void _handleSurfaceTap() {
    if (_showInfo) {
      handleBackPeel();
      return;
    }
    if (widget.touch && _visible) {
      _hideNow();
      return;
    }
    _show();
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
    _m = EmbeddedOverlayMetrics.of(
      MediaQuery.sizeOf(context),
      touch: widget.touch,
    );
    final overlay = _buildOverlay(context);
    // Bound Dynamic Type inside the chrome — see [kTouchMaxTextScale]. Applied
    // here (above the whole subtree) rather than per-label so nothing can be
    // added later that escapes it. No-op on the pointer path.
    return widget.touch
        ? MediaQuery.withClampedTextScaling(
            maxScaleFactor: kTouchMaxTextScale,
            child: overlay,
          )
        : overlay;
  }

  Widget _buildOverlay(BuildContext context) {
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
              // (tap-outside-to-dismiss), then — on touch only — hides visible
              // chrome, else reveals it. See [_handleSurfaceTap].
              onTap: _handleSurfaceTap,
              // No double-tap recognizer under touch: there is no fullscreen to
              // toggle on iOS, and without one in the arena the show/hide tap
              // resolves immediately instead of after kDoubleTapTimeout.
              onDoubleTap: widget.touch ? null : widget.onToggleFullscreen,
            ),
          ),
          // The pointer path keeps its two independently-`Positioned` bars and
          // the fixed-offset info panel — the tree Linux and Windows ship.
          // Touch replaces all three with one full-height column, so the panel
          // is banded between the bars by construction (see [_touchChrome]).
          if (!widget.touch) ...[
            if (_visible) ...[_topBar(), _bottomBar(context)],
            if (_showInfo) _infoPanel(),
          ] else
            _touchChrome(context),
        ],
      ),
    );
  }

  /// The touch chrome: top bar, a flexible band, bottom bar — top to bottom in
  /// one column.
  ///
  /// The band exists to hold the info panel. Placing the panel at a hard-coded
  /// `top:` offset meant duplicating the top bar's height as a literal, which
  /// was wrong by ~74pt the moment the badges reflowed onto their own row (it
  /// opened *inside* the bar), and it had no lower bound at all, so on a
  /// landscape phone the card ran straight through the bottom bar. Banding it
  /// between the two bars mirrors the native overlay's
  /// `infoPanel.top == topBar.bottom + 12` / `bottom <= bottomBar.top - 12` and
  /// cannot drift when either bar changes height.
  ///
  /// Where this deliberately diverges from native: the card scrolls instead of
  /// being allowed to overlap. UIKit resolves the same squeeze by lowering the
  /// constraint priority, because it has no scroll fallback there; on a 375pt
  /// landscape phone the full card genuinely cannot fit, and scrolling is the
  /// better answer.
  ///
  /// The band must **not** absorb taps: `Column`, `Align` and an empty
  /// `SizedBox` all decline to hit-test their empty area, so a press between
  /// the bars still reaches the background gesture layer and drives the Back
  /// ladder (docs/tv-navigation.md). Do not wrap it in anything opaque.
  Widget _touchChrome(BuildContext context) => Positioned.fill(
    child: Column(
      // Tight width for the children, matching what `Positioned(left: 0,
      // right: 0)` gave the bars — the default (`center`) would let each bar
      // shrink to its intrinsic width and strand its gradient mid-screen.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_visible) _topBarBody(),
        Expanded(
          child: _showInfo
              ? Padding(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    12,
                    20 + _barInsets.right,
                    12,
                  ),
                  child: Align(
                    alignment: Alignment.topRight,
                    // Keeps the card's natural height while it fits, scrolls
                    // once it doesn't.
                    child: SingleChildScrollView(child: _infoPanelCard()),
                  ),
                )
              : const SizedBox.expand(),
        ),
        if (_visible) _bottomBarBody(context),
      ],
    ),
  );

  /// System-bar/cutout insets for the overlay chrome.
  ///
  /// This overlay is the Android *fallback* path (used when `HdrPlayerActivity`
  /// can't be launched), and it renders in the ordinary Flutter window, which
  /// under edge-to-edge enforcement is **not** immersive — nothing here calls
  /// `SystemChrome.setEnabledSystemUIMode`, so the status and navigation bars
  /// genuinely sit over the video. Without this the Back button hides under the
  /// status bar and the scrubber under the navigation bar. Zero on desktop.
  EdgeInsets get _barInsets => MediaQuery.paddingOf(context);

  /// Under [EmbeddedPlayerControls.touch], makes a bar swallow taps that miss
  /// its controls.
  ///
  /// The bars are `Container`s, which don't hit-test themselves, so a tap on
  /// the gradient between two buttons falls through to the background layer —
  /// harmless while that layer only ever *shows* the chrome, but under the touch
  /// ladder it would hide everything the user was reaching for. UIKit's bars
  /// absorb by default, so this is also what keeps the two iOS overlays
  /// agreeing. Left untouched on pointer platforms, where that fall-through is
  /// also what carries double-tap-to-fullscreen over the bars.
  Widget _absorbChromeTaps(Widget bar) => widget.touch
      ? GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _show,
          child: bar,
        )
      : bar;

  // Both bars keep their gradient full-bleed (it has to reach the screen edge to
  // stay readable over video) and inset only their content — the same split the
  // native Compose overlay uses.
  //
  // The pointer path anchors each bar with its own `Positioned`; the touch path
  // stacks the same two bodies in a column (see [_touchChrome]). Only the
  // wrapper differs — the bodies below are shared verbatim.
  Widget _topBar() =>
      Positioned(left: 0, right: 0, top: 0, child: _topBarBody());

  Widget _topBarBody() => _absorbChromeTaps(
    Container(
      padding: EdgeInsets.fromLTRB(
        16 + _barInsets.left,
        _m.topPadTop + _barInsets.top,
        16 + _barInsets.right,
        _m.topPadBottom,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a narrow touch surface the badges can't share the row with the
          // title: capped at 0.55 of a ~390pt bar they leave the title ~30pt.
          // Give them their own row instead — the same reparenting the native
          // iOS overlay's `applyCompactLayout` does with its
          // `compactBadgeRow`, and at the same width, so the two agree. The
          // two halves of that reflow move together: see [_m].reflow.
          final stackBadges = _m.reflow;
          final titleRow = Row(
            children: [
              _button(
                // The explicit exit control takes the host platform's glyph:
                // an X on iOS, matching the native controller's `xmark`
                // (docs/tv-navigation.md). Same role either way — it skips
                // the ladder and exits outright.
                widget.touch ? Icons.close : Icons.arrow_back,
                widget.touch ? 'Exit' : 'Back',
                widget.onBack,
              ),
              const SizedBox(width: 8),
              // Title only — the programme lives in the bottom bar's EPG strip
              // ([_liveEpgStrip]), exactly as all three native overlays lay it
              // out. This used to carry a second, compacted "HH:mm – HH:mm ·
              // now • Next …" line under the title, which was the single most
              // visible way the Windows SDR overlay didn't look like the
              // Windows GDI one it is supposed to be at parity with.
              Expanded(
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
              ),
              const SizedBox(width: 8),
              // Badges are capped to a fraction of the bar and wrap onto a
              // second line when the window is narrow, so a full EPG + long
              // resolution/HDR/FPS/source/clock set can never overflow the
              // row.
              if (!stackBadges)
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
            ],
          );
          if (!stackBadges) return titleRow;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleRow,
              SizedBox(height: _m.badgeGap),
              Wrap(spacing: 6, runSpacing: 6, children: _badges()),
            ],
          );
        },
      ),
    ),
  );

  /// Top-right badge cluster, in the order every native overlay uses: source,
  /// LIVE, resolution, dynamic range, fps, clock (Kotlin `TopBadges`, iOS
  /// `badgesStack`, the Windows GDI cluster). The **LIVE pill belongs here**,
  /// not in the bottom bar where this overlay used to keep it — that placement
  /// was the other half of the Windows SDR/HDR mismatch, and it left the bottom
  /// bar showing a lone pill on a channel with no guide data.
  List<Widget> _badges() {
    final params = widget.controls.state.videoParams;
    final resolution = resolutionBadgeLabel(
      width: params.w ?? widget.controls.state.width,
      height: params.h ?? widget.controls.state.height,
    );
    final hdr = hdrBadgeLabel(widget.dynamicRangeLabel(params));
    final fps = fpsBadgeLabel(_realVideoTrack().fps);
    final source = sourceBadgeLabel(widget.sourceName);
    return [
      if (source != null) _badge(source),
      if (widget.isLive) _LiveBadge(synced: widget.liveSynced),
      if (resolution != null) _badge(resolution),
      if (hdr != null) _badge(hdr),
      if (fps != null) _badge(fps),
      _badge(playerClockLabel(DateTime.now(), dated: !widget.touch)),
    ];
  }

  Widget _bottomBar(BuildContext context) =>
      Positioned(left: 0, right: 0, bottom: 0, child: _bottomBarBody(context));

  Widget _bottomBarBody(BuildContext context) => _absorbChromeTaps(
    Container(
      // The gradient fills this (bottom-anchored) container. It ramps to a
      // solid dark value by ~45% down — where the two-row live bar (progress +
      // controls) begins — instead of fading linearly to dark only at the very
      // bottom, so both rows sit on a real backdrop rather than near-transparent
      // scrim. The top inset sets how high the transparent fade starts.
      padding: EdgeInsets.fromLTRB(
        20 + _barInsets.left,
        _m.bottomPadTop,
        20 + _barInsets.right,
        _m.bottomPadBottom + _barInsets.bottom,
      ),
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
          if (widget.isLive) _liveEpgStrip() else _positionRebuild(_seekBar),
          // A live channel with no guide renders no strip at all, so it gets no
          // gap either — the natives shrink the whole bar in that case
          // (`BottomControlsHeight`), and a floating gap above the transport is
          // the closest this stacked layout gets to that.
          SizedBox(
            height: widget.isLive
                ? (widget.epgNow == null ? 0 : _m.epgGap + 2)
                : 4,
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // Below this width the fixed controls + volume slider stop
              // fitting alongside the left/right split, so collapse the two
              // widest optional pieces: the volume slider (mute stays) and the
              // "Go to live" text label (its icon stays).
              final compact = constraints.maxWidth < kCompactControlsWidth;
              // A pointer row that has already dropped its optional pieces
              // is also no longer guaranteed to *fit*: a VOD row at a 500pt
              // window measures ~523pt of controls against ~460pt of inner
              // width and overflowed outright, because the pointer path
              // never reflows and the time label was rigid. Below the same
              // feature-collapse threshold the pointer path therefore takes
              // the third branch below (see [_bottomBarBody]'s row
              // selection) and lets the label shrink. Above it, nothing
              // changes — the `Spacer` layout stays byte-for-byte.
              final narrowPointer = !widget.touch && compact;
              // Even collapsed, a phone in portrait can't fit the transport and
              // the right-hand cluster on one line (they overflow at ~390pt as
              // soon as a stream carries a second audio track). Split them onto
              // two rows, exactly as the native iOS overlay's
              // `applyCompactLayout` reparents its cluster into `secondaryRow`
              // — and at the same width, which `compact` (720) was not.
              final twoRow = _m.reflow;
              final transport = <Widget>[
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
                if (!widget.isLive)
                  // Flexible wherever the row can be width-starved: always
                  // under touch, and on the pointer path only once it is
                  // narrow enough to take the `Expanded`-transport branch.
                  // It must **not** be flexible in the wide pointer branch —
                  // there it would share the free space with the `Spacer` and
                  // drag the cluster left, which is exactly why that branch
                  // keeps the rigid label.
                  widget.touch || narrowPointer
                      ? Flexible(child: _positionRebuild(_timeLabel))
                      : _positionRebuild(_timeLabel),
              ];
              final cluster = <Widget>[
                // "Go to live", as a plain text chip — the same control every
                // other overlay now draws, in the same chip chrome as the
                // aspect label beside it. It used to be a Material
                // `TextButton.icon` (the one Material-themed control left in a
                // row of app chips), while Android/iOS/Windows labelled the
                // same button **"LIVE"** — a second "LIVE" on a screen that
                // already carries the LIVE *status* badge in the top bar, and a
                // label that never said what pressing it does. All four
                // surfaces already declared "Go to live" as the control's
                // accessible name, so this only makes the visible label agree
                // with what they were telling a screen reader. Below the
                // compact width it collapses to its icon (the natives never
                // reach that width, and the accessible name is unchanged).
                if (widget.isLive && !widget.liveSynced)
                  compact
                      ? _button(
                          Icons.skip_next,
                          'Go to live',
                          () => unawaited(widget.onGoLive()),
                        )
                      : _textButton(
                          'Go to live',
                          'Go to live',
                          () => unawaited(widget.onGoLive()),
                        ),
                // The favorite star, immediately after "Go to live" — the
                // slot the Android overlay puts it in
                // (`RightCluster`). It used to sit in the top bar among the
                // badges at *compact* size, which made it a different size from
                // every other control on two of the three surfaces and a
                // different size again from Android's. Here it is an ordinary
                // member of this row and takes the row's geometry, so all three
                // overlays draw one star in one place at one size.
                if (widget.canFavorite)
                  _button(
                    widget.favorite
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    widget.favorite ? 'Remove favorite' : 'Add favorite',
                    widget.onToggleFavorite,
                    color: widget.favorite ? AppColors.accent : Colors.white,
                  ),
                if (_audioTracks().length > 1) _audioMenu(),
                // Only when the stream actually carries a subtitle track:
                // media_kit always reports the synthetic `auto`/`no` pair, so
                // an unconditional button opened a menu offering nothing but
                // "Auto"/"Off" on the majority of live IPTV channels. Same
                // predicate as Android's `showSubtitleButton`, iOS's
                // `PlayerChromeState.showSubtitleButton` and the Windows
                // overlay's `!subtitle_tracks.empty()`.
                if (_subtitleTracks().isNotEmpty) _subtitleMenu(),
                if (!widget.isLive) _speedMenu(),
                // The *current* mode as the button's text, matching all four
                // native overlays (Android `TextControlButton`, iOS
                // `PlayerTextButton`, the Windows `DrawTextButton`, the Lua
                // `text_button`). Dart owns the mode sequence, so an icon
                // here made the only surface that knows the answer the only
                // one not showing it — with four modes the user cycled blind.
                _textButton(
                  widget.aspectLabel,
                  'Cycle aspect ratio',
                  () => unawaited(widget.onCycleAspect()),
                  semanticsLabel: 'Aspect ratio, ${widget.aspectLabel}',
                ),
                _button(Icons.info_outline, 'Stream information', () {
                  setState(() => _showInfo = !_showInfo);
                  _show(keep: _showInfo);
                }),
                // The iOS route is already fullscreen and media_kit's
                // `toggleFullscreen` would push a second `Video` route above
                // the one PlayerScreen owns — the native controller has no
                // fullscreen button either.
                if (!widget.touch)
                  _button(
                    Icons.fullscreen,
                    'Fullscreen (F)',
                    widget.onToggleFullscreen,
                  ),
              ];
              if (!twoRow) {
                // Three deliberately separate one-row branches. They are not
                // collapsed because the `Expanded`-vs-`Spacer` choice is
                // load-bearing in opposite directions at the two ends of the
                // width range.
                //
                // 1. Touch, at/above the reflow width. Moving the touch
                //    reflow down to 560 puts 560–720 on one row, where a
                //    `Spacer` is no longer safe: it shares the free space
                //    with the (now `Flexible`) time label and, on a VOD
                //    stream at ~667pt, the transport + cluster overflow
                //    outright. An `Expanded` transport gives the free space
                //    to the left group only, keeping the cluster hard right.
                if (widget.touch) {
                  return Row(
                    children: [
                      Expanded(child: Row(children: transport)),
                      ...cluster,
                    ],
                  );
                }
                // 2. A *narrow* pointer window (a small or resized Linux/
                //    Windows window). Same shape as branch 1 and for the same
                //    reason: the pointer path never reflows, so below the
                //    feature-collapse width the only thing left that can
                //    absorb a squeeze is the `Flexible` time label — and it
                //    can only do that inside a bounded group. With the wide
                //    branch's `Spacer` a 500pt VOD row overflowed by ~60pt.
                if (narrowPointer) {
                  return Row(
                    children: [
                      Expanded(child: Row(children: transport)),
                      ...cluster,
                    ],
                  );
                }
                // 3. A wide pointer window — the shipped Linux/Windows
                //    layout, unchanged. Here the row always fits, the label
                //    is rigid, and the `Spacer` is the right way to split the
                //    two groups.
                return Row(
                  children: [...transport, const Spacer(), ...cluster],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: transport),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: cluster,
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
                  semanticFormatterCallback: (value) => '${value.round()}%',
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
      // Without this a screen reader announces the raw millisecond count
      // ("4425000") on every scrub step. Both natives announce a time.
      semanticFormatterCallback: (value) =>
          _duration(Duration(milliseconds: value.round())),
      onChanged: duration <= Duration.zero
          ? null
          : (value) => unawaited(
              widget.controls.seek(Duration(milliseconds: value.round())),
            ),
    );
  }

  /// The live EPG strip, where the VOD scrubber sits — three stacked rows:
  /// programme title + its `HH:mm – HH:mm` range, a thin elapsed-progress bar,
  /// then the next programme.
  ///
  /// This is a **structural copy of the three native overlays** (Kotlin
  /// `LiveEpgStrip`, iOS `epgStrip`, the Windows GDI `epg_title`/`epg_time`/
  /// `epg_progress`/`epg_next` rects), because this overlay is what the Windows
  /// *SDR* path shows and it must look like the GDI overlay the same user sees
  /// on an HDR channel. It replaced a one-row `LIVE ▸ progress ▸ title` layout
  /// that shared no geometry, no typography and no field order with any of
  /// them, and pushed the programme labels into the top bar instead.
  ///
  /// No guide for this channel → the strip is *omitted*, not rendered empty: a
  /// progress bar stuck at 0.0 reads as "still loading" forever, and all three
  /// natives drop it in this case too (`HasLiveEpg`, `epgStrip.isHidden`,
  /// `state.epgNow?.let`). The LIVE pill is unaffected — it lives in the top
  /// bar's badge cluster ([_badges]), the way every native overlay carries it.
  Widget _liveEpgStrip() {
    final now = widget.epgNow;
    if (now == null) return const SizedBox.shrink();
    final total = now.stop.difference(now.start).inSeconds;
    final elapsed = DateTime.now().difference(now.start).inSeconds;
    final progress = total <= 0 ? 0.0 : (elapsed / total).clamp(0.0, 1.0);
    final next = widget.epgNext;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // The title gives way (it is the only elastic piece); the range is
            // rigid, matching the natives' compression-resistance split.
            Expanded(
              child: Text(
                now.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _programmeRange(now),
              maxLines: 1,
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          ],
        ),
        SizedBox(height: _m.epgGap),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(value: progress, minHeight: 4),
        ),
        if (next != null) ...[
          SizedBox(height: _m.epgGap),
          Text(
            'Next · ${_programmeRange(next)} · ${next.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textLo, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// `HH:mm – HH:mm` for a programme, the one range format every overlay in the
  /// app renders (Kotlin `clockHm`, Swift `playerEpgRangeLabel`, the GDI
  /// `FormatClockHm` pair, the Lua `hm_ms` pair).
  static String _programmeRange(Programme programme) =>
      '${_hm(programme.start)} – ${_hm(programme.stop)}';

  Widget _timeLabel() => Text(
    '${_duration(widget.controls.state.position)} / ${_duration(widget.controls.state.duration)}',
    // Inert on a pointer platform (the label is never width-constrained
    // there); under the touch two-row layout it keeps a long `1:23:45 /
    // 2:00:00` on one line instead of wrapping the transport row.
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(color: Colors.white70),
  );

  // The menu buttons carry their accessible name on the `Icon` rather than on
  // the `PopupMenuButton`: its `tooltip` becomes `semanticsTooltip`, which is a
  // *hint*, not a name, so the control announced as an unnamed button. An
  // `Icon.semanticLabel` merges into the enclosing button node instead — the
  // standard way to name an icon-only Material button, and it leaves the
  // button's own tap semantics (which open the menu) intact.
  Widget _audioMenu() => PopupMenuButton<String>(
    tooltip: 'Audio track',
    icon: const Icon(
      Icons.audiotrack,
      color: Colors.white,
      semanticLabel: 'Audio track',
    ),
    onOpened: _onMenuOpened,
    onCanceled: _onMenuClosed,
    onSelected: (id) {
      final track = _audioTracks().firstWhere((track) => track.id == id);
      unawaited(widget.controls.setAudioTrack(track));
      _onMenuClosed();
    },
    itemBuilder: (_) => [
      for (final track in _audioTracks())
        PopupMenuItem(value: track.id, child: Text(_audioLabel(track))),
    ],
  );

  Widget _subtitleMenu() {
    // The full list (including the synthetic Auto/Off entries) — turning
    // subtitles off is a real choice. Whether the *button* exists at all is
    // decided by [_subtitleTracks], which counts only real tracks.
    final tracks = widget.controls.state.tracks.subtitle;
    return PopupMenuButton<String>(
      tooltip: 'Subtitles',
      icon: const Icon(
        Icons.subtitles,
        color: Colors.white,
        semanticLabel: 'Subtitles',
      ),
      onOpened: _onMenuOpened,
      onCanceled: _onMenuClosed,
      onSelected: (id) {
        final track = tracks.firstWhere((track) => track.id == id);
        unawaited(widget.controls.setSubtitleTrack(track));
        _onMenuClosed();
      },
      itemBuilder: (_) => [
        for (final track in tracks)
          PopupMenuItem(value: track.id, child: Text(_subtitleLabel(track))),
      ],
    );
  }

  Widget _speedMenu() => PopupMenuButton<double>(
    tooltip: 'Playback speed',
    icon: const Icon(
      Icons.speed,
      color: Colors.white,
      semanticLabel: 'Playback speed',
    ),
    onOpened: _onMenuOpened,
    onCanceled: _onMenuClosed,
    onSelected: (rate) {
      unawaited(widget.controls.setRate(rate));
      _onMenuClosed();
    },
    itemBuilder: (_) => [
      for (final rate in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
        PopupMenuItem(
          value: rate,
          child: Text(rate == 1 ? 'Normal (1.0×)' : '$rate×'),
        ),
    ],
  );

  /// The label/value pairs the info card renders, read off the live player
  /// state. Split out of [_infoPanel] so both the pointer wrapper and the touch
  /// band build the same card from the same source.
  /// Only rows the player can actually answer. A row whose value is unknown is
  /// **omitted**, not rendered as a placeholder: all three native info panels
  /// drop blank rows, and "Resolution 0×0" / "Video Unknown" read as broken
  /// playback rather than as missing metadata — which they routinely are during
  /// the first moments of a load, before the first frame decodes.
  List<(String, String)> _infoRows() {
    final params = widget.controls.state.videoParams;
    final video = _realVideoTrack();
    final audio = _realAudioTrack();
    final width = params.w ?? video.w;
    final height = params.h ?? video.h;
    final range = widget.dynamicRangeLabel(params);
    final videoCodec = _codecOrNull(video.codec);
    final audioLine = [
      _codecOrNull(audio.codec),
      audio.channels,
    ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    return <(String, String)>[
      if (width != null && height != null && width > 0 && height > 0)
        ('Resolution', '$width×$height'),
      if (range.isNotEmpty) ('Dynamic range', range),
      if (videoCodec != null) ('Video', videoCodec),
      if (audioLine.isNotEmpty) ('Audio', audioLine),
      if (video.fps case final fps? when fps > 0)
        ('Frame rate', '${fps.toStringAsFixed(3)} FPS'),
    ];
  }

  /// The pointer path's info panel: the card at a fixed offset below the top
  /// bar. Unused under [EmbeddedPlayerControls.touch] — see [_touchChrome].
  Widget _infoPanel() {
    return Positioned(
      // Tracks the (inset) top bar so the panel stays below it, not under the
      // status bar — see [_barInsets]. This 76 is a *literal* for the top
      // bar's height, which only holds because the pointer bar never reflows;
      // the touch path bands the card between the real bars instead, since
      // there the number went stale the moment the badges stacked. See
      // [_touchChrome].
      top: 76 + _barInsets.top,
      right: 20 + _barInsets.right,
      child: _infoPanelCard(),
    );
  }

  /// The stream-information card itself, shared by the pointer path's
  /// fixed-offset [Positioned] and the touch path's band.
  Widget _infoPanelCard() {
    final content = _infoRows();
    return SizedBox(
      // The full width is wider than the usable width of a small phone in
      // portrait once both insets and the right offset are taken out, so clamp
      // rather than let the card run off the left edge. No-op on any
      // desktop-sized surface.
      width: math.min(
        _m.infoPanelWidth,
        MediaQuery.sizeOf(context).width -
            _barInsets.horizontal -
            40, // the 20pt right offset, mirrored as a left margin
      ),
      // Absorb taps so a press on the panel itself doesn't fall through to the
      // background tap-outside handler and immediately re-close it.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Material(
          color: AppColors.panel.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(AppRadius.tile),
          child: Padding(
            padding: EdgeInsets.all(_m.infoPanelPad),
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
                for (final row in content)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: _m.infoRowPad),
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
    String? semanticsLabel,
  }) => _chrome(
    tooltip: tooltip,
    semanticsLabel: semanticsLabel,
    onPressed: onPressed,
    compact: compact,
    active: active,
    // A finger needs Apple's 44pt minimum in *both* axes, which is the floor
    // every touch value in [EmbeddedOverlayMetrics] respects — the dense
    // short-surface mode sits exactly on it. The pointer sizes are deliberately
    // shorter than they are wide, which is fine for a cursor and not for a
    // thumb.
    child: SizedBox(
      width: compact ? _m.buttonCompactWidth : _m.buttonWidth,
      height: compact ? _m.buttonCompactHeight : _m.buttonHeight,
      child: Icon(
        icon,
        size: compact ? _m.buttonCompactIcon : _m.buttonIcon,
        color: color ?? (active ? Colors.white : AppColors.textHi),
      ),
    ),
  );

  /// The text-labelled sibling of [_button] — the aspect-mode control, whose
  /// *label is its state*, matching all four native overlays. Keeps the same
  /// chip styling and the same ≥44pt floor (as a *minimum*, so a wider label
  /// like "16:9" grows the chip instead of clipping).
  Widget _textButton(
    String label,
    String tooltip,
    VoidCallback onPressed, {
    String? semanticsLabel,
  }) => _chrome(
    tooltip: tooltip,
    semanticsLabel: semanticsLabel,
    onPressed: onPressed,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: _m.buttonWidth,
        minHeight: _m.buttonHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );

  /// Shared chip chrome for [_button]/[_textButton]: the rounded translucent
  /// fill matching the native Windows GDI / Android Compose overlays (rather
  /// than a bare Material `IconButton`), plus the accessible name.
  ///
  /// **The name has to be a `label`, not the `Tooltip`.** Flutter maps a
  /// tooltip to `semanticsTooltip`, which is a *hint* — every control here
  /// therefore announced as an unnamed button with a trailing description,
  /// while both native overlays set real names. This matters most on iOS's mpv
  /// path, which for a Stalker/MAG portal is the primary player.
  ///
  /// `excludeSemantics` + an explicit `onTap` is deliberate: it collapses the
  /// Tooltip's and the `InkWell`'s own annotations into this single node, so
  /// the label can't be announced twice or land beside a second, unnamed
  /// button node. Semantics exclusion doesn't affect hit testing, so the
  /// pointer/touch path is unchanged.
  Widget _chrome({
    required String tooltip,
    required String? semanticsLabel,
    required VoidCallback onPressed,
    required Widget child,
    bool compact = false,
    bool active = false,
  }) {
    void handle() {
      _show();
      onPressed();
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 3),
      child: Semantics(
        label: semanticsLabel ?? tooltip,
        button: true,
        onTap: handle,
        excludeSemantics: true,
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
            child: InkWell(onTap: handle, child: child),
          ),
        ),
      ),
    );
  }

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

  /// Real subtitle tracks — the synthetic `auto`/`no` pair media_kit always
  /// reports is excluded, so "the stream has subtitles" means what it says.
  /// Empty on most live IPTV channels, which is why the button is gated on it.
  List<SubtitleTrack> _subtitleTracks() => widget.controls.state.tracks.subtitle
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

  /// [_codec] without the "Unknown" placeholder — the info panel omits a row it
  /// can't answer rather than filling it in.
  static String? _codecOrNull(String? codec) =>
      codec == null || codec.isEmpty ? null : codec.toUpperCase();
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
    // `liveRegion` so a screen reader announces the reconnect when it appears:
    // this widget is the only signal that playback dropped and is being
    // re-established, and it is otherwise silent — it never takes focus and
    // nothing else on the route changes.
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
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
