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
    double textScale = 1.0,
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
            data: MediaQueryData(
              size: Size(width, height),
              padding: padding,
              textScaler: TextScaler.linear(textScale),
            ),
            child: EmbeddedPlayerControls(
              controls: stub,
              touch: touch,
              title: 'Channel One',
              sourceName: sourceName,
              aspectLabel: 'Fill',
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
            // A real subtitle track, because the subtitle button is now gated
            // on one existing (most live IPTV channels carry none, and the
            // button used to open a menu holding only the synthetic
            // Auto/Off). This test measures the *widest* cluster, so it has
            // to be the case where every optional control is present.
            subtitle: [SubtitleTrack('3', null, 'eng')],
          ),
        ),
        dynamicRangeLabel: (_) => 'HDR10 · PQ',
        padding: const EdgeInsets.fromLTRB(0, 47, 0, 34), // notch + indicator
      );

      expect(find.byIcon(Icons.audiotrack), findsOneWidget);
      expect(find.byIcon(Icons.subtitles), findsOneWidget);
      // The aspect control renders its current mode as a text chip now (all
      // four native overlays do), so there is no icon to find.
      expect(find.text('Fill'), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      // Badges keep their own row under the title rather than squeezing it,
      // and carry the compact labels the native controller shows.
      expect(find.text('1080p'), findsOneWidget);
      expect(find.text('HDR10'), findsOneWidget);
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

  /// The short-landscape-phone fix (iPhone SE/8 class, 667×375 logical): before
  /// it, this surface reflowed onto two rows off [kCompactControlsWidth] (720)
  /// — the *pointer* feature-collapse threshold, not a reflow one — and kept
  /// desktop-sized vertical padding, leaving ~49pt (live) / ~23pt (VOD) of
  /// visible video, with the info panel opening inside the top bar and running
  /// through the bottom bar. [kTouchReflowWidth] (560, matching the native
  /// `PlayerDimens.compactWidth`) and [kShortOverlayHeight] (500, dense
  /// metrics) fix both independently of [kCompactControlsWidth], which keeps
  /// its old job unchanged.
  group('short landscape (the reported bug)', () {
    testWidgets(
      '667x375 puts the transport and the cluster back on one row',
      (tester) async {
        await pumpOverlay(
          tester,
          isLive: true,
          liveSynced: false,
          canFavorite: true,
          width: 667,
          height: 375,
          sourceName: 'Provider Network HD',
          epgNow: _programme('News'),
          epgNext: _programme('Next Up'),
          dynamicRangeLabel: (_) => 'HDR10 · PQ',
          state: const PlayerState(
            tracks: Tracks(
              audio: [
                AudioTrack('1', null, 'eng'),
                AudioTrack('2', null, 'fra'),
              ],
            ),
          ),
        );

        // 667 is above kTouchReflowWidth (560), so the transport (play_arrow)
        // and the cluster (info_outline) share the bottom bar's single row —
        // not stacked as they are in portrait (see the sibling test below).
        expect(
          tester.getCenter(find.byIcon(Icons.play_arrow)).dy,
          tester.getCenter(find.byIcon(Icons.info_outline)).dy,
          reason:
              '667pt is wider than kTouchReflowWidth (560); the transport '
              'and cluster must stay on one row',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('...and the badges rejoin the title row', (tester) async {
      await pumpOverlay(
        tester,
        isLive: true,
        liveSynced: false,
        canFavorite: true,
        width: 667,
        height: 375,
        sourceName: 'Provider Network HD',
        epgNow: _programme('News'),
        epgNext: _programme('Next Up'),
        dynamicRangeLabel: (_) => 'HDR10 · PQ',
        state: const PlayerState(
          tracks: Tracks(
            audio: [AudioTrack('1', null, 'eng'), AudioTrack('2', null, 'fra')],
          ),
        ),
      );

      // Badges sit inline in the title row (ConstrainedBox+Wrap, capped at
      // 0.55 of the bar) rather than on their own row underneath — the
      // opposite of the portrait stack, pinned separately below. The two
      // centres aren't pixel-identical (Wrap top-aligns its own run rather
      // than centering within the title row), but 15pt is nowhere near the
      // ~40pt+ gap a genuinely stacked badge row produces (see the portrait
      // non-regression test below).
      final badgeDy = tester.getCenter(find.text('Provider Network HD')).dy;
      final closeDy = tester.getCenter(find.byIcon(Icons.close)).dy;
      expect(
        (badgeDy - closeDy).abs(),
        lessThan(20.0),
        reason:
            'badges should share the title row with the exit button, not '
            'sit on a stacked row below it',
      );
    });

    testWidgets(
      'the chrome leaves a real video band on a 375pt-tall surface',
      (tester) async {
        Future<double> measureBand({required bool live}) async {
          await pumpOverlay(
            tester,
            isLive: live,
            liveSynced: false,
            canFavorite: true,
            width: 667,
            height: 375,
            sourceName: 'Provider Network HD',
            epgNow: live ? _programme('News') : null,
            epgNext: live ? _programme('Next Up') : null,
            dynamicRangeLabel: (_) => 'HDR10 · PQ',
            state: live
                ? const PlayerState(
                    playing: true,
                    tracks: Tracks(
                      audio: [
                        AudioTrack('1', null, 'eng'),
                        AudioTrack('2', null, 'fra'),
                      ],
                    ),
                  )
                : const PlayerState(
                    duration: Duration(hours: 1, minutes: 30),
                    tracks: Tracks(
                      audio: [
                        AudioTrack('1', null, 'eng'),
                        AudioTrack('2', null, 'fra'),
                      ],
                    ),
                  ),
          );
          final bars = chromeBands();
          expect(bars, findsNWidgets(2));
          final rects = [tester.getRect(bars.at(0)), tester.getRect(bars.at(1))]
            ..sort((a, b) => a.top.compareTo(b.top));
          return rects[1].top - rects[0].bottom;
        }

        final liveBand = await measureBand(live: true);
        final vodBand = await measureBand(live: false);

        // Measured on this build at 667x375 (dense metrics): live 209pt, VOD
        // 183pt. Pre-fix values were 49pt (live) / 23pt (VOD) — both several
        // times larger, confirming the fix is doing its job. The thresholds
        // below sit ~25% under each measured value, leaving headroom for
        // incidental layout drift without masking a real regression.
        expect(
          liveBand,
          greaterThan(155.0),
          reason:
              'measured 209pt on this build; pre-fix this surface left only '
              '49pt of visible video',
        );
        expect(
          vodBand,
          greaterThan(135.0),
          reason:
              'measured 183pt on this build; pre-fix this surface left only '
              '23pt of visible video',
        );
      },
    );

    testWidgets(
      'the info panel is banded between the bars and scrolls instead of '
      'overflowing',
      (tester) async {
        await pumpOverlay(
          tester,
          isLive: true,
          width: 667,
          height: 375,
          epgNow: _programme('News'),
        );

        await tester.tap(find.byIcon(Icons.info_outline));
        await tester.pump();

        final bars = chromeBands();
        expect(bars, findsNWidgets(2));
        final rects = [tester.getRect(bars.at(0)), tester.getRect(bars.at(1))]
          ..sort((a, b) => a.top.compareTo(b.top));
        final topBarBottom = rects[0].bottom;
        final bottomBarTop = rects[1].top;

        expect(find.byType(SingleChildScrollView), findsOneWidget);
        final panel = tester.getRect(find.byType(SingleChildScrollView));
        expect(
          panel.top,
          greaterThanOrEqualTo(topBarBottom),
          reason:
              'pre-fix the panel opened 74pt inside the top bar at a '
              'hard-coded top: 76 offset',
        );
        expect(
          panel.bottom,
          lessThanOrEqualTo(bottomBarTop),
          reason:
              'pre-fix the panel ran through the bottom bar, ending 3pt '
              'from the screen bottom',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '844x390 with landscape safe-area insets keeps controls off the '
      'sensor housing',
      (tester) async {
        await pumpOverlay(
          tester,
          isLive: true,
          width: 844,
          height: 390,
          padding: const EdgeInsets.fromLTRB(47, 0, 47, 21),
        );

        expect(
          tester.getTopLeft(find.byIcon(Icons.close)).dx,
          greaterThanOrEqualTo(47.0),
          reason: 'the exit control must clear the left safe-area inset',
        );
        expect(
          tester.getBottomLeft(find.byIcon(Icons.play_arrow)).dy,
          lessThanOrEqualTo(390.0 - 21.0),
          reason: 'the transport must clear the home-indicator inset',
        );
      },
    );

    testWidgets('hit targets stay >=44pt on a short landscape surface', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        isLive: true,
        canFavorite: true,
        width: 667,
        height: 375,
      );

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
          reason: '$icon is too narrow for a finger at 667x375',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(44.0),
          reason: '$icon is too short for a finger at 667x375',
        );
      }
    });

    testWidgets(
      'portrait keeps the two-row layout and the stacked badge row',
      (tester) async {
        await pumpOverlay(
          tester,
          isLive: true,
          liveSynced: false,
          canFavorite: true,
          sourceName: 'Provider Network HD',
          epgNow: _programme('News'),
          state: const PlayerState(
            tracks: Tracks(
              audio: [
                AudioTrack('1', null, 'eng'),
                AudioTrack('2', null, 'fra'),
              ],
            ),
          ),
        );

        // 390 is below kTouchReflowWidth (560), so this is the non-regression
        // twin of the two tests above: portrait must keep reflowing.
        expect(
          tester.getCenter(find.byIcon(Icons.play_arrow)).dy,
          isNot(tester.getCenter(find.byIcon(Icons.info_outline)).dy),
          reason:
              'portrait must keep the transport and cluster on separate rows',
        );

        final badgeDy = tester.getCenter(find.text('Provider Network HD')).dy;
        final closeDy = tester.getCenter(find.byIcon(Icons.close)).dy;
        expect(
          badgeDy,
          greaterThan(closeDy),
          reason:
              'badges must stay stacked under the title row at portrait '
              'width, not rejoin it the way they do at 667x375',
        );
      },
    );

    testWidgets('accessibility text scaling is clamped, so the chrome cannot '
        'outgrow a short surface', (tester) async {
      // Found by a stress sweep across every iOS surface × text scale: at 2x
      // Dynamic Type the two bars alone exceed a 375pt-tall landscape phone,
      // and the touch chrome *column* overflows where the old independently
      // `Positioned` bars silently overlapped instead. Clamping is also the
      // parity-correct answer — the native `IptvsPlayerViewController` sizes
      // every label with a fixed `UIFont.systemFont(ofSize:)` and ignores
      // Dynamic Type outright, so an unclamped Flutter overlay diverged from
      // the controller the same user reaches on AVPlayer-routed channels.
      await pumpOverlay(
        tester,
        isLive: false, // VOD carries the widest control set
        liveSynced: false,
        canFavorite: true,
        width: 667,
        height: 375,
        textScale: 2.0,
        sourceName: 'Provider Network HD',
        dynamicRangeLabel: (_) => 'HDR10 · PQ',
        state: const PlayerState(
          duration: Duration(hours: 2, minutes: 14),
          position: Duration(hours: 1, minutes: 23, seconds: 45),
          tracks: Tracks(
            audio: [AudioTrack('1', null, 'eng'), AudioTrack('2', null, 'fra')],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byIcon(Icons.play_arrow)),
      );
      expect(
        scaler.scale(10),
        lessThanOrEqualTo(10 * kTouchMaxTextScale),
        reason: 'the chrome must not scale past kTouchMaxTextScale',
      );
    });

    testWidgets('the pointer path is not clamped', (tester) async {
      // The clamp is touch-only: a desktop window is never short enough for
      // Dynamic Type to break it, and silently shrinking a Linux/Windows
      // user's text would be a regression in its own right.
      await pumpOverlay(
        tester,
        isLive: true,
        touch: false,
        width: 1000,
        height: 720,
        textScale: 2.0,
      );

      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byIcon(Icons.play_arrow)),
      );
      expect(scaler.scale(10), 20.0);
    });

    test('the pointer metrics are size-invariant', () {
      // The machine-checkable form of "the pointer path cannot regress": with
      // touch:false, EmbeddedOverlayMetrics.of must resolve to the exact same
      // fixed token set at every surface size — including across the two
      // touch-only thresholds (kTouchReflowWidth/kShortOverlayHeight) that
      // could otherwise leak a dense/reflow metric onto Linux/Windows.
      const wide = Size(1000, 720);
      const shortLandscape = Size(667, 375);
      const portrait = Size(390, 844);

      final metrics = EmbeddedOverlayMetrics.of(wide, touch: false);
      expect(
        EmbeddedOverlayMetrics.of(shortLandscape, touch: false),
        metrics,
      );
      expect(EmbeddedOverlayMetrics.of(portrait, touch: false), metrics);

      expect(metrics.buttonWidth, 44);
      expect(metrics.buttonHeight, 40);
      expect(metrics.bottomPadTop, 36);
      expect(metrics.reflow, isFalse);
      expect(metrics.dense, isFalse);
    });
  });
}

/// The overlay's two gradient-backed bars (top and bottom) — the containers
/// that carry the vertical chrome padding under test in the short-landscape
/// group above. Badges use a plain-color `BoxDecoration`, so a `gradient`
/// check is enough to isolate exactly the two bars without matching them.
Finder chromeBands() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).gradient is LinearGradient,
);

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
