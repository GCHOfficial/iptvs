import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/linux_native_session.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  group('LinuxNativeSession.buildOverlayStateCommand', () {
    test('encodes the iptvs-state JSON contract the Lua overlay parses', () {
      final command = LinuxNativeSession.buildOverlayStateCommand(
        title: 'BBC One HD',
        sourceName: 'My Provider',
        epgNow: null,
        epgNext: null,
        canFavorite: true,
        favorite: false,
        isLive: true,
        liveSynced: false,
        aspectLabel: '16:9',
      );

      expect(command, [
        'script-message-to',
        'iptvs_overlay',
        'iptvs-state',
        isA<String>(),
      ]);

      final payload = jsonDecode(command[3] as String) as Map<String, dynamic>;
      expect(payload['title'], 'BBC One HD');
      expect(payload['sourceName'], 'My Provider');
      expect(payload['canFavorite'], true);
      expect(payload['favorite'], false);
      expect(payload['isLive'], true);
      expect(payload['liveSynced'], false);
      // The overlay's aspect button label — pushed by every call site so the
      // Lua script never has to derive/guess the current mode itself.
      expect(payload['aspectLabel'], '16:9');
      // Reconnect indicator defaults to false when the call site omits it.
      expect(payload['reconnecting'], false);
      // HDR10+ badge upgrade defaults to false until the Dart-side ST2094-40
      // probe pushes it — the Lua overlay never derives it itself.
      expect(payload['hdr10Plus'], false);
      expect(payload.containsKey('epgNowTitle'), isFalse);
      expect(payload.containsKey('epgNextTitle'), isFalse);
    });

    test('carries the hdr10Plus flag for the dynamic-range badge', () {
      final command = LinuxNativeSession.buildOverlayStateCommand(
        title: 'BBC One HD',
        sourceName: 'My Provider',
        epgNow: null,
        epgNext: null,
        canFavorite: true,
        favorite: false,
        isLive: true,
        liveSynced: true,
        aspectLabel: '16:9',
        hdr10Plus: true,
      );

      final payload = jsonDecode(command[3] as String) as Map<String, dynamic>;
      expect(payload['hdr10Plus'], true);
    });

    test('carries the reconnecting flag for the overlay chip', () {
      final command = LinuxNativeSession.buildOverlayStateCommand(
        title: 'BBC One HD',
        sourceName: 'My Provider',
        epgNow: null,
        epgNext: null,
        canFavorite: true,
        favorite: false,
        isLive: true,
        liveSynced: true,
        aspectLabel: '16:9',
        reconnecting: true,
      );

      final payload = jsonDecode(command[3] as String) as Map<String, dynamic>;
      expect(payload['reconnecting'], true);
    });

    test('omits sourceName when absent and includes EPG now/next fields', () {
      final now = Programme(
        channelId: 'c1',
        start: DateTime.fromMillisecondsSinceEpoch(1000),
        stop: DateTime.fromMillisecondsSinceEpoch(2000),
        title: 'News at Ten',
      );
      final next = Programme(
        channelId: 'c1',
        start: DateTime.fromMillisecondsSinceEpoch(2000),
        stop: DateTime.fromMillisecondsSinceEpoch(3000),
        title: 'Weather',
      );

      final command = LinuxNativeSession.buildOverlayStateCommand(
        title: 'Some Movie',
        sourceName: null,
        epgNow: now,
        epgNext: next,
        canFavorite: false,
        favorite: false,
        isLive: false,
        liveSynced: true,
        aspectLabel: 'Fit',
      );

      final payload = jsonDecode(command[3] as String) as Map<String, dynamic>;
      expect(payload.containsKey('sourceName'), isFalse);
      expect(payload['aspectLabel'], 'Fit');
      expect(payload['epgNowTitle'], 'News at Ten');
      expect(payload['epgNowStartMs'], 1000);
      expect(payload['epgNowStopMs'], 2000);
      expect(payload['epgNextTitle'], 'Weather');
      expect(payload['epgNextStartMs'], 2000);
      expect(payload['epgNextStopMs'], 3000);
    });
  });

  group('LinuxNativeSession.buildHeaderFieldsCommand', () {
    test('sends headers as a native JSON list, not a comma-joined string', () {
      final command = LinuxNativeSession.buildHeaderFieldsCommand({
        'User-Agent': 'Mozilla/5.0 (KHTML, like Gecko) MAG254',
        'Referer': 'http://example.com/',
      });

      expect(command, [
        'set_property',
        'http-header-fields',
        isA<List<Object?>>(),
      ]);
      // A comma-join here would have split "(KHTML, like Gecko)" into two
      // bogus header lines — the whole point of sending a native list.
      expect(command[2], [
        'User-Agent: Mozilla/5.0 (KHTML, like Gecko) MAG254',
        'Referer: http://example.com/',
      ]);
    });

    test('round-trips through the same JSON encoding command() uses', () {
      final command = LinuxNativeSession.buildHeaderFieldsCommand({
        'User-Agent': 'Mozilla/5.0 (KHTML, like Gecko)',
      });
      final encoded = jsonEncode({'command': command});
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final headerList = (decoded['command'] as List)[2] as List;
      expect(headerList, ['User-Agent: Mozilla/5.0 (KHTML, like Gecko)']);
    });
  });

  group('LinuxNativeSession.applyPlaybackPropertyChange', () {
    test('caches time-pos and duration independently', () {
      (double?, double?) cached = (null, null);
      cached = LinuxNativeSession.applyPlaybackPropertyChange(
        cached,
        'time-pos',
        12.5,
      );
      expect(cached, (12.5, null));
      cached = LinuxNativeSession.applyPlaybackPropertyChange(
        cached,
        'duration',
        3600.0,
      );
      expect(cached, (12.5, 3600.0));
    });

    test('ignores non-numeric data and leaves the cache unchanged', () {
      const cached = (10.0, 200.0);
      final updated = LinuxNativeSession.applyPlaybackPropertyChange(
        cached,
        'time-pos',
        null,
      );
      expect(updated, cached);
    });

    test('leaves unrelated property names untouched', () {
      const cached = (10.0, 200.0);
      final updated = LinuxNativeSession.applyPlaybackPropertyChange(
        cached,
        'paused-for-cache',
        true,
      );
      expect(updated, cached);
    });
  });
}
