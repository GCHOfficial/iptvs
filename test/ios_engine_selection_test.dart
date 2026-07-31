import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/ios_engine.dart';

/// Pure-logic coverage for `selectIosEngine` — the iOS dual-engine routing
/// rule (docs/ios.md "What routes to which engine", docs/player.md "iOS").
///
/// The whole point of deciding this in Dart is that it's a pure function of the
/// resolved locator, so the routing table is pinned here at zero cost. A Swift
/// mirror (`packages/iptvs_ios_player/ios/Core/.../EngineSelection.swift`
/// `selectEngine`) carries the same table minus rule 1 (the session memo, which
/// is caller-side state, not a function of the URL) and has its own XCTest —
/// **the two are deliberately kept in agreement, so a change here needs the
/// Swift mirror and its test updated in the same PR.**
///
/// The load-bearing asymmetry: a wrong guess toward mpv costs *quality* (iOS
/// mpv is always tone-mapped SDR, no PiP), a wrong guess toward AVPlayer costs
/// a *visible failure and a reopen beat* on the app's most common path. So
/// anything not positively recognised routes to mpv.
void main() {
  setUp(IosEngineMemo.resetForTest);
  tearDown(IosEngineMemo.resetForTest);

  group('rule 3 — container routing table', () {
    const avPlayerExtensions = <String>[
      'm3u8',
      'mp4',
      'm4v',
      'mov',
      'm4a',
      'mp3',
      'aac',
    ];
    const mpvExtensions = <String>[
      'ts',
      'm2ts',
      'mkv',
      'avi',
      'flv',
      'webm',
      'mpg',
      'mpeg',
      'wmv',
      'vob',
      'divx',
      'rmvb',
      'ogv',
    ];

    for (final extension in avPlayerExtensions) {
      test('.$extension routes to AVPlayer', () {
        expect(
          selectIosEngine(url: 'http://host/live/stream.$extension'),
          IosPlaybackEngine.avPlayer,
          reason: extension,
        );
      });
    }

    for (final extension in mpvExtensions) {
      test('.$extension routes to mpv', () {
        expect(
          selectIosEngine(url: 'http://host/live/stream.$extension'),
          IosPlaybackEngine.mpv,
          reason: extension,
        );
      });
    }

    test('the two extension sets are disjoint (no ambiguous container)', () {
      final overlap = avPlayerExtensions
          .where(mpvExtensions.contains)
          .toList(growable: false);
      expect(overlap, isEmpty);
    });

    test('extension matching is case-insensitive', () {
      expect(
        selectIosEngine(url: 'http://host/movie/Film.MP4'),
        IosPlaybackEngine.avPlayer,
      );
      expect(
        selectIosEngine(url: 'http://host/live/1.TS'),
        IosPlaybackEngine.mpv,
      );
      expect(
        selectIosEngine(url: 'HTTP://HOST/live/1.M3U8'),
        IosPlaybackEngine.avPlayer,
      );
    });

    test('https and file schemes route the same way as http', () {
      expect(
        selectIosEngine(url: 'https://host/live/1.m3u8'),
        IosPlaybackEngine.avPlayer,
      );
      expect(
        selectIosEngine(url: 'file:///var/mobile/clip.mov'),
        IosPlaybackEngine.avPlayer,
      );
      expect(
        selectIosEngine(url: 'file:///var/mobile/clip.mkv'),
        IosPlaybackEngine.mpv,
      );
    });
  });

  group('query-string and fragment independence', () {
    // The extension has to come off the *path*, not the raw string: provider
    // URLs routinely carry tokens, and an `?token=…m3u8`-shaped query must
    // never flip the decision.
    test('a token query on a .ts live URL still routes to mpv', () {
      expect(
        selectIosEngine(url: 'http://host/live/user/pass/1.ts?token=abc123'),
        IosPlaybackEngine.mpv,
      );
    });

    test('a query on a .m3u8 URL still routes to AVPlayer', () {
      expect(
        selectIosEngine(url: 'http://host/live/1.m3u8?a=b'),
        IosPlaybackEngine.avPlayer,
      );
    });

    test('a query that merely mentions m3u8 does not win over a .ts path', () {
      expect(
        selectIosEngine(url: 'http://host/live/1.ts?fallback=stream.m3u8'),
        IosPlaybackEngine.mpv,
      );
    });

    test('a fragment is stripped too', () {
      expect(
        selectIosEngine(url: 'http://host/vod/movie.mp4#t=30'),
        IosPlaybackEngine.avPlayer,
      );
      expect(
        selectIosEngine(url: 'http://host/vod/movie.mkv#t=30'),
        IosPlaybackEngine.mpv,
      );
    });

    test('a dot in an earlier path segment is not the extension', () {
      expect(
        selectIosEngine(url: 'http://host/a.mp4/live/1.ts'),
        IosPlaybackEngine.mpv,
      );
    });
  });

  group('rule 4 — extension-less and unknown fall to mpv', () {
    test('a Stalker create_link-shaped extension-less locator routes to mpv', () {
      // This is the consequence docs/ios.md states plainly: MAG portals get
      // HDR only when create_link happens to return an .m3u8 URL.
      expect(
        selectIosEngine(url: 'http://portal.example/play/12345'),
        IosPlaybackEngine.mpv,
      );
    });

    test('an unknown extension routes to mpv', () {
      expect(
        selectIosEngine(url: 'http://host/live/1.strm'),
        IosPlaybackEngine.mpv,
      );
    });

    test('a trailing slash is not an extension', () {
      expect(
        selectIosEngine(url: 'http://host/live/1.m3u8/'),
        IosPlaybackEngine.avPlayer,
        reason: 'the last *non-empty* segment still carries the extension',
      );
      expect(selectIosEngine(url: 'http://host/live/'), IosPlaybackEngine.mpv);
    });

    test('no path at all routes to mpv', () {
      expect(selectIosEngine(url: 'http://host'), IosPlaybackEngine.mpv);
      expect(selectIosEngine(url: 'http://host/'), IosPlaybackEngine.mpv);
    });

    test('a dotfile last segment counts as no extension, not as its suffix', () {
      // `.mp4` is a filename, not an extension — the dot is at position 0, so
      // there is nothing before it to call a name. The Swift mirror was fixed
      // to match this; keep both sides in step.
      expect(selectIosEngine(url: 'http://host/live/.mp4'), IosPlaybackEngine.mpv);
    });

    test('a segment ending in a bare dot counts as no extension', () {
      expect(
        selectIosEngine(url: 'http://host/live/stream.'),
        IosPlaybackEngine.mpv,
      );
    });
  });

  group('rule 2 — scheme gate', () {
    test('non-http(s)/file schemes route to mpv even with a known extension', () {
      for (final url in const [
        'rtmp://host/live/1.mp4',
        'rtsp://host/live/1.mp4',
        'udp://238.0.0.1:1234',
        'rtp://238.0.0.1:1234',
        'mms://host/stream.mp4',
        'srt://host:9000',
      ]) {
        expect(
          selectIosEngine(url: url),
          IosPlaybackEngine.mpv,
          reason: url,
        );
      }
    });

    test('a schemeless or unparseable locator routes to mpv', () {
      for (final url in const ['', '   ', 'host/live/1.m3u8', '://nonsense']) {
        expect(
          selectIosEngine(url: url),
          IosPlaybackEngine.mpv,
          reason: '"$url"',
        );
      }
    });
  });

  group('rule 1 — session memo overrides the container', () {
    test('a memoised key forces mpv for a URL that would pick AVPlayer', () {
      const url = 'http://host/live/1.m3u8';
      expect(
        selectIosEngine(url: url, memoKey: 'ch-1'),
        IosPlaybackEngine.avPlayer,
        reason: 'not memoised yet',
      );
      expect(
        selectIosEngine(url: url, memoKey: 'ch-1', forcedMpv: const {'ch-1'}),
        IosPlaybackEngine.mpv,
      );
    });

    test('the memo is keyed, not global — other content is unaffected', () {
      expect(
        selectIosEngine(
          url: 'http://host/live/2.m3u8',
          memoKey: 'ch-2',
          forcedMpv: const {'ch-1'},
        ),
        IosPlaybackEngine.avPlayer,
      );
    });

    test('a null or empty memoKey opts out rather than matching anything', () {
      expect(
        selectIosEngine(
          url: 'http://host/live/1.m3u8',
          forcedMpv: const {'ch-1', ''},
        ),
        IosPlaybackEngine.avPlayer,
      );
      expect(
        selectIosEngine(
          url: 'http://host/live/1.m3u8',
          memoKey: '',
          forcedMpv: const {'ch-1', ''},
        ),
        IosPlaybackEngine.avPlayer,
      );
    });
  });

  group('IosEngineMemo', () {
    test('markMpvOnly records the key and selection then honours it', () {
      const url = 'http://host/live/1.m3u8';
      expect(
        selectIosEngine(
          url: url,
          memoKey: 'ch-9',
          forcedMpv: IosEngineMemo.forcedMpv,
        ),
        IosPlaybackEngine.avPlayer,
      );
      IosEngineMemo.markMpvOnly('ch-9');
      expect(IosEngineMemo.forcedMpv, contains('ch-9'));
      expect(
        selectIosEngine(
          url: url,
          memoKey: 'ch-9',
          forcedMpv: IosEngineMemo.forcedMpv,
        ),
        IosPlaybackEngine.mpv,
      );
    });

    test('markMpvOnly(null) and markMpvOnly("") are no-ops', () {
      IosEngineMemo.markMpvOnly(null);
      IosEngineMemo.markMpvOnly('');
      expect(IosEngineMemo.forcedMpv, isEmpty);
    });

    test('markMpvOnly is idempotent', () {
      IosEngineMemo.markMpvOnly('ch-1');
      IosEngineMemo.markMpvOnly('ch-1');
      expect(IosEngineMemo.forcedMpv, <String>{'ch-1'});
    });

    test('resetForTest clears the process-static memo', () {
      IosEngineMemo.markMpvOnly('ch-1');
      IosEngineMemo.markMpvOnly('ch-2');
      expect(IosEngineMemo.forcedMpv, hasLength(2));
      IosEngineMemo.resetForTest();
      expect(IosEngineMemo.forcedMpv, isEmpty);
    });
  });
}
