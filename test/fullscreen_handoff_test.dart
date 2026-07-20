import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/channel_list_screen.dart';

/// Pure-logic coverage for `decideFullscreenHandoff`, the classification
/// behind `_ChannelListScreenState._openLivePlayer`'s preview→fullscreen
/// handoff (see docs/player.md "Preview→fullscreen handoff" and "Live
/// preview + seamless handoff (Android)").
///
/// Linux policy (mirrors Android's "default engine, escalate only when
/// needed"): the embedded media_kit path is the seamless default and the
/// native mpv window is used *only* for a Wayland HDR source, where its
/// non-adoptable separate-process handoff (a fresh Stalker `create_link` and
/// stream reopen) is the honest cost of real HDR passthrough. So
/// [FullscreenHandoff.stopResolveFresh] fires only when both `linuxNativeLikely`
/// (Wayland-gated in [LinuxNativeSession.nativeLikelyAvailable]) and
/// `streamLikelyHdr` hold; SDR and X11 stay [FullscreenHandoff.adoptEmbedded].
/// A source that starts SDR and turns out HDR still escalates later, inside
/// `PlayerScreen._maybeEscalateLinuxNative`.
void main() {
  group('Linux native discovery gate', () {
    test('probes only for an adoptable same-channel HDR preview', () {
      expect(
        shouldProbeLinuxNativeForHandoff(
          isLinux: true,
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          streamLikelyHdr: true,
        ),
        isTrue,
      );
    });

    test('ordinary and SDR opens never pay the native discovery cost', () {
      for (final values in [
        (reuse: false, same: true, stream: true, hdr: true),
        (reuse: true, same: false, stream: true, hdr: true),
        (reuse: true, same: true, stream: false, hdr: true),
        (reuse: true, same: true, stream: true, hdr: false),
      ]) {
        expect(
          shouldProbeLinuxNativeForHandoff(
            isLinux: true,
            reusePreview: values.reuse,
            sameChannelPreview: values.same,
            previewHasStream: values.stream,
            streamLikelyHdr: values.hdr,
          ),
          isFalse,
        );
      }
    });
  });

  group('decideFullscreenHandoff', () {
    test('Android native preview adopts seamlessly', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: true,
          nativePreviewActive: true,
          linuxNativeLikely: false,
          previewPlaying: true,
        ),
        FullscreenHandoff.adoptNative,
      );
    });

    test(
      'Android media_kit-fallback preview (same channel) pauses, not adopts',
      () {
        expect(
          decideFullscreenHandoff(
            reusePreview: true,
            sameChannelPreview: true,
            previewHasStream: true,
            isAndroid: true,
            nativePreviewActive: false,
            linuxNativeLikely: false,
            previewPlaying: true,
          ),
          FullscreenHandoff.pausePreview,
        );
      },
    );

    test('non-Android embedded media_kit preview adopts seamlessly when the '
        'native path is not in play', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: false,
          previewPlaying: true,
        ),
        FullscreenHandoff.adoptEmbedded,
      );
    });

    test('Wayland HDR: native mpv about to be used, same-channel handoff stops '
        'and re-resolves instead of adopting (real HDR passthrough cost)', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: true,
          previewPlaying: true,
          streamLikelyHdr: true,
        ),
        FullscreenHandoff.stopResolveFresh,
      );
    });

    test('Wayland SDR: native path available but the source is SDR — the '
        'native window buys nothing, so adopt embedded seamlessly', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: true,
          previewPlaying: true,
          streamLikelyHdr: false,
        ),
        FullscreenHandoff.adoptEmbedded,
      );
    });

    test(
      'X11 never stopResolveFresh: linuxNativeLikely is already false on X11 '
      '(Wayland-gated), so even an HDR source stays embedded/seamless',
      () {
        expect(
          decideFullscreenHandoff(
            reusePreview: true,
            sameChannelPreview: true,
            previewHasStream: true,
            isAndroid: false,
            nativePreviewActive: false,
            linuxNativeLikely: false,
            previewPlaying: true,
            streamLikelyHdr: true,
          ),
          FullscreenHandoff.adoptEmbedded,
        );
      },
    );

    test('different-channel preview (last-channel zap / EPG-grid play) is '
        'stopped outright, on any platform', () {
      for (final isAndroid in [true, false]) {
        for (final linuxNativeLikely in [true, false]) {
          expect(
            decideFullscreenHandoff(
              reusePreview: false,
              sameChannelPreview: false,
              previewHasStream: false,
              isAndroid: isAndroid,
              nativePreviewActive: false,
              linuxNativeLikely: linuxNativeLikely,
              previewPlaying: true,
            ),
            FullscreenHandoff.stopPreview,
            reason: 'isAndroid=$isAndroid linuxNativeLikely=$linuxNativeLikely',
          );
        }
      }
    });

    test('no preview running at all resolves to none', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: false,
          previewHasStream: false,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: false,
          previewPlaying: false,
        ),
        FullscreenHandoff.none,
      );
    });

    test('reusePreview=false but coincidentally the same channel still pauses '
        '(not adopted, since reusePreview forbids adoption)', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: false,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: false,
          previewPlaying: true,
        ),
        FullscreenHandoff.pausePreview,
      );
    });

    test('a still-loading same-channel preview (no stream yet) is paused, not '
        'adopted or stop-resolved', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: false,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: true,
          previewPlaying: true,
        ),
        FullscreenHandoff.pausePreview,
      );
    });

    test('linuxNativeLikely only matters when the preview is actually being '
        'adopted for the same channel', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: false,
          previewHasStream: false,
          isAndroid: false,
          nativePreviewActive: false,
          linuxNativeLikely: true,
          previewPlaying: true,
        ),
        FullscreenHandoff.stopPreview,
      );
    });

    test('Android adoption takes priority over an (impossible in practice) '
        'linuxNativeLikely=true', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: true,
          nativePreviewActive: true,
          linuxNativeLikely: true,
          previewPlaying: true,
        ),
        FullscreenHandoff.adoptNative,
      );
    });

    test('Android non-native fallback never selects stopResolveFresh even if '
        'linuxNativeLikely is (impossibly) true', () {
      expect(
        decideFullscreenHandoff(
          reusePreview: true,
          sameChannelPreview: true,
          previewHasStream: true,
          isAndroid: true,
          nativePreviewActive: false,
          linuxNativeLikely: true,
          previewPlaying: true,
        ),
        FullscreenHandoff.pausePreview,
      );
    });
  });

  group('FullscreenHandoffDerived', () {
    // _openLivePlayer derives every downstream boolean from the decision via
    // these getters (a duplicate raw-input formula at the call site once
    // desynced from the decision across an await) — pin the full matrix so a
    // new enum value or getter edit can't silently shift a handoff behavior.
    const expected = {
      FullscreenHandoff.adoptNative: (
        seamless: true,
        adoptsEmbeddedPreview: false,
        adoptsNativePreview: true,
        stopsAndResolvesFresh: false,
        pausesPreview: false,
        stopsPreview: false,
      ),
      FullscreenHandoff.adoptEmbedded: (
        seamless: true,
        adoptsEmbeddedPreview: true,
        adoptsNativePreview: false,
        stopsAndResolvesFresh: false,
        pausesPreview: false,
        stopsPreview: false,
      ),
      FullscreenHandoff.stopResolveFresh: (
        seamless: false,
        adoptsEmbeddedPreview: false,
        adoptsNativePreview: false,
        stopsAndResolvesFresh: true,
        pausesPreview: false,
        stopsPreview: false,
      ),
      FullscreenHandoff.pausePreview: (
        seamless: false,
        adoptsEmbeddedPreview: false,
        adoptsNativePreview: false,
        stopsAndResolvesFresh: false,
        pausesPreview: true,
        stopsPreview: false,
      ),
      FullscreenHandoff.stopPreview: (
        seamless: false,
        adoptsEmbeddedPreview: false,
        adoptsNativePreview: false,
        stopsAndResolvesFresh: false,
        pausesPreview: false,
        stopsPreview: true,
      ),
      FullscreenHandoff.none: (
        seamless: false,
        adoptsEmbeddedPreview: false,
        adoptsNativePreview: false,
        stopsAndResolvesFresh: false,
        pausesPreview: false,
        stopsPreview: false,
      ),
    };

    test('covers every FullscreenHandoff value', () {
      expect(expected.keys, containsAll(FullscreenHandoff.values));
    });

    for (final entry in expected.entries) {
      test('${entry.key.name} derives the expected booleans', () {
        final decision = entry.key;
        expect(decision.seamless, entry.value.seamless, reason: 'seamless');
        expect(
          decision.adoptsEmbeddedPreview,
          entry.value.adoptsEmbeddedPreview,
          reason: 'adoptsEmbeddedPreview',
        );
        expect(
          decision.adoptsNativePreview,
          entry.value.adoptsNativePreview,
          reason: 'adoptsNativePreview',
        );
        expect(
          decision.stopsAndResolvesFresh,
          entry.value.stopsAndResolvesFresh,
          reason: 'stopsAndResolvesFresh',
        );
        expect(
          decision.pausesPreview,
          entry.value.pausesPreview,
          reason: 'pausesPreview',
        );
        expect(
          decision.stopsPreview,
          entry.value.stopsPreview,
          reason: 'stopsPreview',
        );
      });
    }
  });
}
