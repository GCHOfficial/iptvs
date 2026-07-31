import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  // `AVPlayer` cannot play a naked continuous MPEG-TS stream, so the container
  // this source asks the panel for is what decides whether iOS live playback
  // lands on AVPlayer (real HDR, PiP, AirPlay) or on the permanently-SDR libmpv
  // fallback. See docs/ios.md "The `streamExtension` lever".
  group('resolveXtreamStreamExtension', () {
    test('defaults to ts off iOS and to m3u8 on iOS', () {
      expect(resolveXtreamStreamExtension(null, isIOS: false), 'ts');
      expect(resolveXtreamStreamExtension(null, isIOS: true), 'm3u8');
    });

    test('an explicit override wins on both platforms', () {
      // The escape hatch matters because a panel that does not serve the chosen
      // container answers 404 — and Dart's engineFailed fallback reopens the
      // *same* URL on mpv, so a wrong default is a dead channel, not a degraded
      // one.
      expect(resolveXtreamStreamExtension('ts', isIOS: true), 'ts');
      expect(resolveXtreamStreamExtension('m3u8', isIOS: false), 'm3u8');
      expect(resolveXtreamStreamExtension('  M3U8 ', isIOS: false), 'm3u8');
    });

    test('an unrecognised override falls back to the platform default', () {
      for (final bad in ['', '   ', 'mkv', '.ts', 'ts?x']) {
        expect(resolveXtreamStreamExtension(bad, isIOS: false), 'ts', reason: bad);
        expect(resolveXtreamStreamExtension(bad, isIOS: true), 'm3u8', reason: bad);
      }
    });
  });

  group('XtreamSource stream extension', () {
    // The suite runs on a desktop VM, so `Platform.isIOS` is false throughout:
    // these pin that the iOS default cannot leak into any other platform's URLs.
    test('live and timeshift URLs use ts by default off iOS', () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
      );
      expect(source.streamExtension, 'ts');
      final live = await source.resolve(
        const Channel(id: '7', name: 'Ch', extra: {'streamId': '7'}),
      );
      expect(live.url, 'http://host.tv/live/u/p/7.ts');
      await source.dispose();
    });

    test('an explicit m3u8 reaches both the live and timeshift URLs', () async {
      final source = XtreamSource(
        sourceId: 'x',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        streamExtension: 'm3u8',
      );
      final channel = const Channel(
        id: '7',
        name: 'Ch',
        extra: {'streamId': '7'},
      );
      final live = await source.resolve(channel);
      expect(live.url, 'http://host.tv/live/u/p/7.m3u8');

      final archive = await source.resolveArchive(
        channel,
        Programme(
          channelId: '7',
          title: 'Show',
          start: DateTime(2026, 7, 31, 20),
          stop: DateTime(2026, 7, 31, 21),
        ),
      );
      expect(archive.url, endsWith('/7.m3u8'));
      expect(archive.isLive, isFalse);
      await source.dispose();
    });

    test('SourceConfig plumbs the per-source settings override through', () {
      final source =
          const SourceConfig(
                id: 'x',
                kind: SourceKind.xtream,
                label: 'Panel',
                fields: {
                  'host': 'http://host.tv',
                  'username': 'u',
                  'password': 'p',
                },
                settings: {'streamExtension': 'm3u8'},
              ).build()
              as XtreamSource;
      expect(source.streamExtension, 'm3u8');
      source.dispose();
    });

    test('SourceConfig without the setting keeps the platform default', () {
      final source =
          const SourceConfig(
                id: 'x',
                kind: SourceKind.xtream,
                label: 'Panel',
                fields: {
                  'host': 'http://host.tv',
                  'username': 'u',
                  'password': 'p',
                },
              ).build()
              as XtreamSource;
      expect(source.streamExtension, 'ts');
      source.dispose();
    });
  });

  group('xtreamCredentialsFromUrl', () {
    test('uses an M3U expiry hint when player API omits exp_date', () async {
      final source = XtreamSource(
        sourceId: 'test',
        host: 'http://host.tv',
        username: 'u',
        password: 'p',
        playlistExpiryHint: '2026-09-01T00:00:00.000',
        debugApi: (_) async => {
          'user_info': {'exp_date': '0'},
        },
      );
      expect((await source.subscriptionExpiry()).date, DateTime(2026, 9, 1));
      await source.dispose();
    });

    test('extracts creds from get.php query params', () {
      final c = xtreamCredentialsFromUrl(
        Uri.parse(
          'http://panel.example.com:8080/get.php?username=u1&password=p1&type=m3u_plus',
        ),
      );
      expect(c, isNotNull);
      expect(c!.host, 'http://panel.example.com:8080');
      expect(c.username, 'u1');
      expect(c.password, 'p1');
    });

    test('extracts creds from userInfo form', () {
      final c = xtreamCredentialsFromUrl(
        Uri.parse('http://u2:p2@host.tv/get.php'),
      );
      expect(c, isNotNull);
      expect(c!.host, 'http://host.tv');
      expect(c.username, 'u2');
      expect(c.password, 'p2');
    });

    test('returns null without credentials', () {
      expect(
        xtreamCredentialsFromUrl(Uri.parse('http://host.tv/list.m3u')),
        isNull,
      );
    });

    test('returns null for empty host', () {
      expect(
        xtreamCredentialsFromUrl(Uri.parse('?username=u&password=p')),
        isNull,
      );
    });
  });
}
