import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_overlay.dart';
import 'package:iptvs/sources/source.dart';
import 'package:media_kit/media_kit.dart';

/// Widget-level coverage for [EmbeddedPlayerControls] in **touch** mode — the
/// iOS mpv-engine path, which for a Stalker/MAG portal is the *only* player
/// (`selectIosEngine` routes every extension-less `create_link` locator to mpv),
/// not a fallback. Before this the branch fell through to media_kit's stock
/// Material controls, which put a scrubbable `00:04 / 00:30` on a live stream.
///
/// Pins the things that differ from the pointer path, all gated on `touch`:
///  1. Live = no seek bar / no position readout, the headline invariant.
///  2. The tap ladder agrees with the native `IptvsPlayerViewController`'s
///     `playerTapAction` (info → hide → show), and resolves on the first frame
///     because touch mode has no double-tap recognizer in the arena.
///  3. The explicit exit control skips the ladder (and wears the X).
///  4. No fullscreen affordance (the iOS route is already fullscreen).
///  5. ≥44pt hit targets, and no `RenderFlex` overflow at phone-portrait width
///     with a full control set.
///  6. The pointer path (touch: false) is unchanged by all of the above.
///
/// The sibling `player_overlay_test.dart` pins the pointer behavior and must
/// stay untouched; this file deliberately duplicates its harness rather than
/// refactoring a shared one.
void main() {
  Future<_StubControls> pumpOverlay(
    WidgetTester tester, {
    required bool isLive,
    bool touch = true,
    PlayerState state = const PlayerState(),
    bool canFavorite = false,
    bool favorite = false,
    bool liveSynced = true,
    Programme? epgNow,
    Programme? epgNext,
    String? sourceName,
    // iPhone-portrait logical size: the layout the desktop-shaped overlay had
    // never been asked to render.
    double width = 390,
    double height = 844,
    EdgeInsets padding = EdgeInsets.zero,
    String Function(VideoParams params)? dynamicRangeLabel,
    VoidCallback? onBack,
    VoidCallback? onPlayPause,
    VoidCallback? onToggleFullscreen,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final stub = _StubControls(state: state);
    addTearDown(stub.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(size: Size(width, height), padding: padding),
            child: EmbeddedPlayerControls(
              controls: stub,
              touch: touch,
              title: 'Channel One',
              sourceName: sourceName,
              epgNow: epgNow,
              epgNext: epgNext,
              isLive: isLive,
              canFavorite: canFavorite,
              favorite: favorite,
              liveSynced: liveSynced,
              dynamicRangeLabel: dynamicRangeLabel ?? (_) => '',
              onBack: onBack ?? () {},
              onToggleFavorite: () {},
              onPlayPause: () async => onPlayPause?.call(),
              onGoLive: () async {},
              onCycleAspect: () async {},
              onToggleFullscreen: onToggleFullscreen ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return stub;
  }

  Offset exposedVideo(WidgetTester tester) =>
      tester.getCenter(find.byType(EmbeddedPlayerControls));

  group('live = no seek bar (the reported bug)', () {
    testWidgets('a live stream on touch exposes no scrubber and no '
        'position/duration readout', (tester) async {
      // A real HLS live window reports a short finite duration — exactly what
      // media_kit's stock mobile controls turned into a draggable 30s timeline.
      await pumpOverlay(
        tester,
        isLive: true,
        epgNow: _programme('News'),
        state: const PlayerState(
          playing: true,
          duration: Duration(seconds: 30),
          position: Duration(seconds: 4),
        ),
      );

      expect(find.byType(Slider), findsNothing);
      expect(find.textContaining('0:30'), findsNothing);
      expect(find.textContaining(' / '), findsNothing);
      // What live gets instead: the LIVE pill + EPG programme progress.
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.replay_10), findsNothing);
      expect(find.byIcon(Icons.forward_10), findsNothing);
    });

    testWidgets('VOD on touch keeps exactly one Slider — the seek bar', (
      tester,
    ) async {
      // Phone-portrait is below the compact threshold, so the volume slider is
      // collapsed to the mute button and the only Slider left is the seek bar.
      await pumpOverlay(
        tester,
        isLive: false,
        state: const PlayerState(duration: Duration(minutes: 90)),
      );

      expect(find.byType(Slider), findsOneWidget);
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
      expect(find.text('LIVE'), findsNothing);
    });
  });

  group('tap ladder (parity with the native playerTapAction table)', () {
    testWidgets('tap hides visible chrome, tap again shows it — on the first '
        'frame, with no double-tap timeout to wait out', (tester) async {
      await pumpOverlay(tester, isLive: true);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      // Rung: controlsVisible → hideControls. No `pump(350ms)` here: with the
      // double-tap recognizer gone the tap resolves immediately, which is the
      // whole reason it is dropped in touch mode.
      await tester.tapAt(exposedVideo(tester));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);

      // Terminal rung: nothing left to peel → show (never exit; only the X
      // exits on iOS).
      await tester.tapAt(exposedVideo(tester));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('an open info panel is peeled first, and the chrome stays up', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pump();
      expect(find.text('Stream information'), findsOneWidget);

      await tester.tapAt(exposedVideo(tester));
      await tester.pump();
      // Info closed …
      expect(find.text('Stream information'), findsNothing);
      // … and that press was consumed by the info rung, so the chrome is still
      // there (one rung per press, as everywhere else in the app).
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('a tap on the bar background never hides the chrome', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true);

      // The cluster row is end-aligned, so the left of it is bare gradient.
      // A `Container` doesn't hit-test itself, so without the touch-mode
      // absorber this tap would fall through to the background layer and hide
      // everything the user was reaching for. UIKit's bars absorb it.
      final clusterY = tester.getCenter(find.byIcon(Icons.info_outline)).dy;
      await tester.tapAt(Offset(30, clusterY));
      await tester.pump();
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('the pointer path is unchanged: a tap only ever shows', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true, touch: false, width: 1000);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tapAt(exposedVideo(tester));
      // The pointer path still owns double-tap, so the tap resolves only after
      // kDoubleTapTimeout — and it re-shows rather than hiding.
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });

  group('exit control', () {
    testWidgets('touch wears the X and exits outright, skipping the ladder', (
      tester,
    ) async {
      var backCalls = 0;
      await pumpOverlay(tester, isLive: true, onBack: () => backCalls++);

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);

      // Even with a rung available (info open), the explicit control exits —
      // the same "the on-screen back button still exits directly" parity the
      // Windows/Linux overlays and the native iOS X keep.
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(backCalls, 1);
    });

    testWidgets('the pointer path keeps the back arrow', (tester) async {
      await pumpOverlay(tester, isLive: true, touch: false, width: 1000);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });

  group('no fullscreen affordance on touch', () {
    testWidgets('the fullscreen button is absent and double-tap does nothing', (
      tester,
    ) async {
      var fullscreenCalls = 0;
      await pumpOverlay(
        tester,
        isLive: false,
        onToggleFullscreen: () => fullscreenCalls++,
      );

      expect(find.byIcon(Icons.fullscreen), findsNothing);

      final center = exposedVideo(tester);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 350));
      expect(fullscreenCalls, 0);
    });

    testWidgets('the pointer path keeps it', (tester) async {
      await pumpOverlay(tester, isLive: false, touch: false, width: 1000);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    });
  });

  group('touch layout', () {
    testWidgets('hit targets are at least 44pt in both axes', (tester) async {
      await pumpOverlay(tester, isLive: true, canFavorite: true);

      for (final icon in [
        Icons.close,
        Icons.play_arrow,
        Icons.info_outline,
        Icons.star_outline_rounded,
      ]) {
        final size = tester.getSize(
          find.ancestor(of: find.byIcon(icon), matching: find.byType(InkWell)),
        );
        expect(
          size.width,
          greaterThanOrEqualTo(44.0),
          reason: '$icon is too narrow for a finger',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(44.0),
          reason: '$icon is too short for a finger',
        );
      }
    });

    testWidgets('a phone-portrait surface with the full live control set never '
        'overflows', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        liveSynced: false, // + "Go to live"
        canFavorite: true, // + star
        sourceName: 'Provider Network HD',
        epgNow: _programme('A Very Long Currently Airing Programme Title'),
        epgNext: _programme('An Equally Long Up-Next Programme Title Here'),
        // Two real audio tracks → the audio menu appears too. On one row this
        // is what pushed the cluster past a 390pt bar.
        state: const PlayerState(
          width: 1920,
          height: 1080,
          videoParams: VideoParams(w: 1920, h: 1080, gamma: 'pq'),
          tracks: Tracks(
            video: [VideoTrack('1', null, null, codec: 'hevc', fps: 50)],
            audio: [AudioTrack('1', null, 'eng'), AudioTrack('2', null, 'fra')],
          ),
        ),
        dynamicRangeLabel: (_) => 'HDR10 · PQ',
        padding: const EdgeInsets.fromLTRB(0, 47, 0, 34), // notch + indicator
      );

      expect(find.byIcon(Icons.audiotrack), findsOneWidget);
      expect(find.byIcon(Icons.subtitles), findsOneWidget);
      expect(find.byIcon(Icons.aspect_ratio), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      // Badges keep their own row under the title rather than squeezing it.
      expect(find.text('1920×1080'), findsOneWidget);
      expect(find.text('HDR10 · PQ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a phone-portrait VOD surface never overflows either', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: false,
        sourceName: 'Provider Network HD',
        state: const PlayerState(
          duration: Duration(hours: 2, minutes: 14),
          position: Duration(hours: 1, minutes: 23, seconds: 45),
          tracks: Tracks(
            audio: [AudioTrack('1', null, 'eng'), AudioTrack('2', null, 'fra')],
          ),
        ),
      );

      expect(find.byIcon(Icons.speed), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the safe area keeps the chrome clear of the notch and home '
        'indicator', (tester) async {
      const inset = EdgeInsets.fromLTRB(0, 47, 0, 34);

      await pumpOverlay(tester, isLive: true);
      final exitTop = tester.getTopLeft(find.byIcon(Icons.close)).dy;
      final playBottom = tester.getBottomLeft(find.byIcon(Icons.play_arrow)).dy;

      await pumpOverlay(tester, isLive: true, padding: inset);
      final insetExitTop = tester.getTopLeft(find.byIcon(Icons.close)).dy;
      final insetPlayBottom = tester
          .getBottomLeft(find.byIcon(Icons.play_arrow))
          .dy;

      expect(insetExitTop - exitTop, inset.top);
      expect(playBottom - insetPlayBottom, inset.bottom);
    });

    testWidgets('the info panel fits within a phone-portrait surface', (
      tester,
    ) async {
      await pumpOverlay(tester, isLive: true);
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pump();

      final panel = tester.getRect(find.text('Stream information'));
      expect(panel.left, greaterThanOrEqualTo(0.0));
      expect(panel.right, lessThanOrEqualTo(390.0));
      expect(tester.takeException(), isNull);
    });
  });
}

Programme _programme(String title) => Programme(
  channelId: 'c1',
  start: DateTime(2026, 1, 1, 20),
  stop: DateTime(2026, 1, 1, 21),
  title: title,
);

/// Pure [EmbeddedControls] stub — no libmpv. Mirrors the one in
/// `player_overlay_test.dart` (kept separate so that pinned file stays
/// byte-unmodified).
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
