import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/sources/m3u_upgrade.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  SourceConfig m3u({
    String url = 'http://host:8080/get.php?username=u&password=p',
    Map<String, dynamic> settings = const {},
    String label = 'Romanian TV',
  }) => SourceConfig(
    id: 'src-1',
    kind: SourceKind.m3u,
    label: label,
    fields: {'playlistUrl': url},
    settings: settings,
  );

  /// A `player_api.php` reply that authenticates.
  Future<dynamic> authOk(Map<String, String> _) async => {
    'user_info': {'auth': 1, 'exp_date': '1790000000'},
    'server_info': {'timezone': 'Europe/Bucharest'},
  };

  List<String> m3uLog() => DiagnosticsLog.instance.entries
      .where((entry) => entry.scope == 'm3u')
      .map((entry) => entry.message)
      .toList();

  group('couldBeXtreamPanel', () {
    test('an Xtream credentials link qualifies', () {
      expect(couldBeXtreamPanel(m3u()), isTrue);
      expect(
        couldBeXtreamPanel(m3u(url: 'http://user:pass@host:8080/get.php')),
        isTrue,
      );
    });

    test('a plain playlist never pays for a probe', () {
      // This runs on every app start, so doing nothing cheaply for an ordinary
      // playlist is a requirement, not an optimisation.
      expect(couldBeXtreamPanel(m3u(url: 'http://host/playlist.m3u8')), isFalse);
      expect(couldBeXtreamPanel(m3u(url: 'not a url at all')), isFalse);
      expect(couldBeXtreamPanel(m3u(url: '')), isFalse);
    });

    test('a source that is already Xtream is not reconsidered', () {
      // What makes the load-time recursion terminate: the upgraded config
      // fails this immediately on the second pass.
      expect(
        couldBeXtreamPanel(
          const SourceConfig(
            id: 'src-1',
            kind: SourceKind.xtream,
            label: 'x',
            fields: {'host': 'http://host', 'username': 'u', 'password': 'p'},
          ),
        ),
        isFalse,
      );
    });
  });

  group('upgradeM3uToXtream', () {
    test('converts a panel that authenticates, keeping the identity', () async {
      final upgraded = await upgradeM3uToXtream(m3u(), debugApi: authOk);
      expect(upgraded, isNotNull);
      expect(upgraded!.kind, SourceKind.xtream);
      // Same id: the SQLite cache, favorites and playback positions are keyed
      // by it, so preserving it is what makes this an upgrade rather than a
      // new source that happens to look the same.
      expect(upgraded.id, 'src-1');
      expect(upgraded.label, 'Romanian TV');
      expect(upgraded.fields['host'], 'http://host:8080');
      expect(upgraded.fields['username'], 'u');
      expect(upgraded.fields['password'], 'p');
      // The playlist URL is deliberately not retained.
      expect(upgraded.fields.containsKey('playlistUrl'), isFalse);
      expect(m3uLog().last, contains('upgraded to xtream'));
    });

    test('carries per-source settings across', () async {
      // Hidden categories and catch-up overrides describe the subscription,
      // not the protocol used to read it.
      final upgraded = await upgradeM3uToXtream(
        m3u(settings: const {'catchupMaxDays': 7}),
        debugApi: authOk,
      );
      expect(upgraded!.settings['catchupMaxDays'], 7);
    });

    test('keeps a URL-only expiry the panel might not repeat', () async {
      final upgraded = await upgradeM3uToXtream(
        m3u(url: 'http://host:8080/get.php?username=u&password=p&exp=2026-09-01'),
        debugApi: authOk,
      );
      expect(
        upgraded!.fields['playlistExpiryHint'],
        DateTime(2026, 9, 1).toIso8601String(),
      );
    });

    test('leaves the source alone when the panel refuses', () async {
      // Fails closed: this rewrites the user's saved source, so anything short
      // of the panel actually answering must change nothing.
      final upgraded = await upgradeM3uToXtream(
        m3u(),
        debugApi: (_) async => {
          'user_info': {'auth': 0},
        },
      );
      expect(upgraded, isNull);
      expect(m3uLog().last, contains('did not authenticate'));
    });

    test('leaves the source alone when the panel is unreachable', () async {
      final upgraded = await upgradeM3uToXtream(
        m3u(),
        debugApi: (_) async => throw const FormatException('boom'),
      );
      expect(upgraded, isNull);
      final logged = m3uLog().last;
      expect(logged, contains('did not authenticate'));
      // The exception type triages it; its message can embed the URL.
      expect(logged, isNot(contains('boom')));
    });

    test('never touches a plain playlist or a non-M3U source', () async {
      var asked = false;
      Future<dynamic> spy(Map<String, String> _) async {
        asked = true;
        return authOk(const {});
      }

      expect(
        await upgradeM3uToXtream(
          m3u(url: 'http://host/playlist.m3u8'),
          debugApi: spy,
        ),
        isNull,
      );
      expect(
        await upgradeM3uToXtream(
          const SourceConfig(
            id: 'src-1',
            kind: SourceKind.xtream,
            label: 'x',
            fields: {'host': 'http://host', 'username': 'u', 'password': 'p'},
          ),
          debugApi: spy,
        ),
        isNull,
      );
      expect(asked, isFalse);
    });
  });
}
