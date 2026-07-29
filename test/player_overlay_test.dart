import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_overlay.dart';
import 'package:iptvs/sources/source.dart';
import 'package:media_kit/media_kit.dart';

/// Widget-level coverage for [EmbeddedPlayerControls] — the shared Flutter
/// overlay used by Linux and the Windows SDR preview→fullscreen handoff. It is
/// driven through the [EmbeddedControls] seam with a pure stub, so the test
/// needs no libmpv engine and runs everywhere (a real media_kit [Player] can't
/// be constructed under plain `flutter test`).
///
/// Pins three behaviors called out in review:
///  1. Gesture layering/latency (guards commit aa01efb) — the double-tap
///     recognizer is a sibling *behind* the bars, so a control tap fires without
///     waiting out `kDoubleTapTimeout`; taps on the exposed video area show the
///     chrome; a double-tap toggles fullscreen.
///  2. The live-vs-VOD control set.
///  3. Responsive collapse below 720px, with no RenderFlex overflow on a narrow
///     surface carrying a full EPG + every badge, plus the favorite star gating.
void main() {
  Future<_StubControls> pumpOverlay(
    WidgetTester tester, {
    required bool isLive,
    PlayerState state = const PlayerState(),
    bool canFavorite = false,
    bool favorite = false,
    bool liveSynced = true,
    Programme? epgNow,
    Programme? epgNext,
    String? sourceName,
    double width = 1000,
    double height = 720,
    EdgeInsets padding = EdgeInsets.zero,
    String Function(VideoParams params)? dynamicRangeLabel,
    VoidCallback? onPlayPause,
    VoidCallback? onToggleFullscreen,
    VoidCallback? onToggleFavorite,
    VoidCallback? onGoLive,
  }) async {
    // Size the whole test surface (not a nested SizedBox) so the overlay fills
    // it and `getCenter` lands on-screen; the width drives the <720 compact
    // logic and the badge wrap.
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stub = _StubControls(state: state);
    addTearDown(stub.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // Inside the Scaffold so this is exactly the padding the overlay
          // reads (edge-to-edge system-bar insets on Android).
          body: MediaQuery(
            data: MediaQueryData(size: Size(width, height), padding: padding),
            child: EmbeddedPlayerControls(
              controls: stub,
              title: 'Channel One',
              sourceName: sourceName,
              epgNow: epgNow,
              epgNext: epgNext,
              isLive: isLive,
              canFavorite: canFavorite,
              favorite: favorite,
              liveSynced: liveSynced,
              dynamicRangeLabel: dynamicRangeLabel ?? (_) => '',
              onBack: () {},
              onToggleFavorite: onToggleFavorite ?? () {},
              onPlayPause: () async => onPlayPause?.call(),
              onGoLive: () async => onGoLive?.call(),
              onCycleAspect: () async {},
              onToggleFullscreen: onToggleFullscreen ?? () {},
            ),
          ),
        ),
      ),
    );
    // A single frame — never pumpAndSettle: the overlay holds a periodic clock
    // timer, and settling would also mask the double-tap latency this pins.
    await tester.pump();
    return stub;
  }

  group('edge-to-edge system-bar insets', () {
    // This overlay is the Android fallback when the native player Activity
    // can't launch, and it renders in the ordinary (non-immersive) Flutter
    // window — so under edge-to-edge enforcement the status/navigation bars sit
    // over the video. Insets default to zero in tests, which is exactly why a
    // regression here would otherwise be invisible.
    testWidgets('the bars inset their controls by the system-bar padding', (
      tester,
    ) async {
      const inset = EdgeInsets.fromLTRB(0, 48, 0, 60);

      await pumpOverlay(tester, isLive: false);
      final backTop = tester.getTopLeft(find.byIcon(Icons.arrow_back)).dy;
      final playBottom = tester.getBottomLeft(find.byIcon(Icons.play_arrow)).dy;

      await pumpOverlay(tester, isLive: false, padding: inset);
      final insetBackTop = tester.getTopLeft(find.byIcon(Icons.arrow_back)).dy;
      final insetPlayBottom = tester
          .getBottomLeft(find.byIcon(Icons.play_arrow))
          .dy;

      // Back moves down out of the status bar; the transport moves up out of
      // the navigation bar. Without the fix both would be unchanged.
      expect(insetBackTop - backTop, inset.top);
      expect(playBottom - insetPlayBottom, inset.bottom);
    });
  });

  group('gesture layering + latency', () {
    testWidgets('a control tap fires without waiting out the double-tap '
        'timeout (double-tap recognizer stays a sibling behind the bars)', (
      tester,
    ) async {
      var playPauseCalls = 0;
      await pumpOverlay(
        tester,
        isLive: false,
        onPlayPause: () => playPauseCalls++,
      );

      // Not playing → the play button shows play_arrow.
      await tester.tap(find.byIcon(Icons.play_arrow));
      // Well under kDoubleTapTimeout (300ms). If the double-tap recognizer were
      // an ancestor of the bars it would hold the arena and delay this press to
      // the full timeout — the aa01efb "heavy overlay" regression.
      await tester.pump(const Duration(milliseconds: 50));
      expect(playPauseCalls, 1);
    });

    testWidgets('double-tapping the exposed video area toggles fullscreen', (
      tester,
    ) async {
      var fullscreenCalls = 0;
      await pumpOverlay(
        tester,
        isLive: false,
        onToggleFullscreen: () => fullscreenCalls++,
      );

      final center = tester.getCenter(find.byType(EmbeddedPlayerControls));
      await tester.tapAt(center);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(center);
      // Flush the double-tap recognizer's own timers before the test ends.
      await tester.pump(const Duration(milliseconds: 350));
      expect(fullscreenCalls, 1);
    });

    testWidgets('tapping the exposed video area re-shows hidden controls', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        state: const PlayerState(playing: true),
      );

      // Playing → the chrome auto-hides after its 4s timer.
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byIcon(Icons.pause), findsNothing);

      // A tap on the exposed video area brings the chrome back. The background
      // detector also owns double-tap, so a single tap only resolves after
      // kDoubleTapTimeout (~300ms) — pump past it.
      await tester.tapAt(tester.getCenter(find.byType(EmbeddedPlayerControls)));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });
  });

  group('live vs VOD control set', () {
    testWidgets('live shows a LIVE badge and no VOD affordances', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, epgNow: _programme('News'));

      expect(find.text('LIVE'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // No seek/skip/speed/position — those belong to VOD.
      expect(find.byIcon(Icons.replay_10), findsNothing);
      expect(find.byIcon(Icons.forward_10), findsNothing);
      expect(find.byIcon(Icons.speed), findsNothing);
      // Synced → no "Go to live".
      expect(find.text('Go to live'), findsNothing);
      expect(find.byIcon(Icons.skip_next), findsNothing);
    });

    testWidgets('a live stream behind the edge shows "Go to live"', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, liveSynced: false);
      // Wide surface → the labelled button, not the collapsed icon.
      expect(find.text('Go to live'), findsOneWidget);
    });

    testWidgets('VOD shows the seek bar, ±10s, speed menu and position, no '
        'LIVE badge', (tester) async {
      await pumpOverlay(tester, isLive: false);

      expect(find.text('LIVE'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
      expect(find.byIcon(Icons.speed), findsOneWidget);
      // Seek bar (VOD) + volume slider (wide) = two Sliders; live has only the
      // volume slider.
      expect(find.byType(Slider), findsNWidgets(2));
    });
  });

  group('responsive collapse + favorite star', () {
    testWidgets('below 720px the volume slider and "Go to live" collapse', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, liveSynced: false, width: 500);

      // Volume slider gone (mute button stays); no seek bar on live either.
      expect(find.byType(Slider), findsNothing);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      // "Go to live" collapses to its icon.
      expect(find.text('Go to live'), findsNothing);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
    });

    testWidgets('a narrow surface with full EPG + all badges never overflows', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        liveSynced: false,
        canFavorite: true,
        width: 500,
        sourceName: 'Provider Network HD',
        epgNow: _programme(
          'A Very Long Currently Airing Programme Title That Runs On',
        ),
        epgNext: _programme('An Equally Long Up-Next Programme Title Here'),
        state: const PlayerState(
          width: 3840,
          height: 2160,
          videoParams: VideoParams(
            w: 3840,
            h: 2160,
            gamma: 'pq',
            primaries: 'bt.2020',
          ),
          tracks: Tracks(
            video: [VideoTrack('1', null, null, codec: 'hevc', fps: 50)],
          ),
        ),
        dynamicRangeLabel: (_) => 'HDR10 · PQ',
      );

      // Resolution / HDR / FPS / source / clock all present …
      expect(find.text('3840×2160'), findsOneWidget);
      expect(find.text('HDR10 · PQ'), findsOneWidget);
      expect(find.text('50.00 FPS'), findsOneWidget);
      // … and no RenderFlex overflow from any of it.
      expect(tester.takeException(), isNull);
    });

    testWidgets('favorite star appears only when canFavorite and reflects '
        'state', (tester) async {
      var favoriteToggles = 0;

      // Not favorited → outline star, toggles the callback.
      await pumpOverlay(
        tester,
        isLive: true,
        canFavorite: true,
        favorite: false,
        onToggleFavorite: () => favoriteToggles++,
      );
      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      await tester.tap(find.byIcon(Icons.star_outline_rounded));
      await tester.pump();
      expect(favoriteToggles, 1);

      // Favorited → filled star.
      await pumpOverlay(
        tester,
        isLive: true,
        canFavorite: true,
        favorite: true,
      );
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(find.byIcon(Icons.star_outline_rounded), findsNothing);

      // Not favoritable → no star at all.
      await pumpOverlay(tester, isLive: true, canFavorite: false);
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    });
  });

  group('info panel tap-outside dismiss', () {
    testWidgets('opening then tapping outside closes the info panel', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: false);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pump();
      expect(find.text('Stream information'), findsOneWidget);

      // Tap the exposed video area (outside the panel) → panel closes. The
      // background detector owns double-tap too, so the single tap resolves
      // only after kDoubleTapTimeout (~300ms).
      await tester.tapAt(tester.getCenter(find.byType(EmbeddedPlayerControls)));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Stream information'), findsNothing);
    });
  });
}

Programme _programme(String title) => Programme(
  channelId: 'c1',
  start: DateTime(2026, 1, 1, 20),
  stop: DateTime(2026, 1, 1, 21),
  title: title,
);

/// Pure [EmbeddedControls] stub — no libmpv. Only the streams the overlay
/// actually listens to carry real broadcast controllers; the rest are empty
/// (`Stream<Never>` is assignable to any `Stream<T>`), and mutating state is
/// injected via [PlayerState].
class _StubControls implements EmbeddedControls {
  _StubControls({this.state = const PlayerState()});

  @override
  final PlayerState state;

  final _playing = StreamController<bool>.broadcast();
  final _tracks = StreamController<Tracks>.broadcast();
  final _track = StreamController<Track>.broadcast();
  final _videoParams = StreamController<VideoParams>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _position = StreamController<Duration>.broadcast();

  @override
  late final PlayerStream stream = PlayerStream(
    const Stream<Never>.empty(), // playlist
    _playing.stream,
    const Stream<Never>.empty(), // completed
    _position.stream,
    const Stream<Never>.empty(), // duration
    _volume.stream,
    const Stream<Never>.empty(), // rate
    const Stream<Never>.empty(), // pitch
    const Stream<Never>.empty(), // buffering
    const Stream<Never>.empty(), // bufferingPercentage
    const Stream<Never>.empty(), // buffer
    const Stream<Never>.empty(), // playlistMode
    const Stream<Never>.empty(), // shuffle
    const Stream<Never>.empty(), // audioParams
    _videoParams.stream,
    const Stream<Never>.empty(), // audioBitrate
    const Stream<Never>.empty(), // audioDevice
    const Stream<Never>.empty(), // audioDevices
    _track.stream,
    _tracks.stream,
    const Stream<Never>.empty(), // width
    const Stream<Never>.empty(), // height
    const Stream<Never>.empty(), // subtitle
    const Stream<Never>.empty(), // log
    const Stream<Never>.empty(), // error
  );

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  Future<void> dispose() async {
    await _playing.close();
    await _tracks.close();
    await _track.close();
    await _videoParams.close();
    await _volume.close();
    await _position.close();
  }
}
