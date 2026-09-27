import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/live_zap_controller.dart';
import 'package:iptvs/player/zap_command.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

/// Short enough that a test doesn't wait on real remote-control timing, long
/// enough that "several presses inside one settle" is expressible.
const _settle = Duration(milliseconds: 40);
const _digits = Duration(milliseconds: 40);
const _past = Duration(milliseconds: 120);

SourceConfig _config(String id, {Map<String, dynamic> settings = const {}}) =>
    SourceConfig(
      id: id,
      kind: SourceKind.m3u,
      label: id,
      fields: const {'playlistUrl': 'https://example.invalid/p.m3u'},
      settings: settings,
    );

Channel _channel(String id, {int? number}) =>
    Channel(id: id, name: 'Channel $id', number: number);

class _FakeCatalog implements ZapCatalog {
  _FakeCatalog({this.failFor = const <String>{}});

  /// Channel ids whose resolve throws — the failed-zap path.
  Set<String> failFor;

  final List<String> resolved = [];

  /// Shared ordering trace, when a test cares *when* a resolve happened
  /// relative to the stop/play calls rather than only that it happened.
  List<String>? trace;
  final List<String> logs = [];
  final Map<String, bool> favorites = {};
  final List<(String, String)> aspectWrites = [];
  final Map<String, ({Programme? now, Programme? next})> epg = {};

  /// Held open so a test can keep a resolve in flight for as long as it
  /// likes — deterministic where a timed delay would race the test's own
  /// clock.
  Completer<void>? resolveGate;

  @override
  Future<StreamInfo> resolve(ZapEntry entry) async {
    resolved.add('${entry.sourceId}/${entry.channelId}');
    trace?.add('resolve ${entry.channelId}');
    final gate = resolveGate;
    if (gate != null) await gate.future;
    if (failFor.contains(entry.channelId)) {
      throw StateError('resolve refused for ${entry.channelId}');
    }
    return StreamInfo(
      url: 'https://${entry.sourceId}.invalid/${entry.channelId}.ts',
      isLive: true,
    );
  }

  @override
  ({Programme? now, Programme? next}) epgFor(ZapEntry entry) =>
      epg['${entry.sourceId}/${entry.channelId}'] ??
      (now: null, next: null);

  @override
  bool isFavorite(ZapEntry entry) =>
      favorites['${entry.sourceId}/${entry.channelId}'] ?? false;

  @override
  Future<void> setFavorite(ZapEntry entry, bool value) async {
    favorites['${entry.sourceId}/${entry.channelId}'] = value;
  }

  @override
  String? aspectLabelFor(ZapEntry entry) =>
      entry.config.settings['aspectMode']?.toString();

  @override
  Future<void> persistAspect(ZapEntry entry, String label) async {
    aspectWrites.add((entry.sourceId, label));
  }

  @override
  BufferPreset bufferPresetFor(ZapEntry entry) =>
      bufferPresetFromName(entry.config.settings['bufferPreset']?.toString());

  @override
  void log(String note) => logs.add(note);
}

/// Records what the player surface was asked to do, in order — the stop/play
/// ordering is a correctness property, not an implementation detail.
class _Surface {
  final List<String> events = [];

  void attach(LiveZapController controller) {
    controller.onStopCurrent = () async => events.add('stop');
    controller.onPlay = (stream, entry) async =>
        events.add('play ${entry.channelId}');
    controller.onChannelChanged = (entry) =>
        events.add('changed ${entry.channelId}');
  }
}

LiveZapController _controller({
  List<Channel>? channels,
  int initialIndex = 0,
  _FakeCatalog? catalog,
  SourceConfig? config,
  Duration messageDuration = _digits,
}) {
  final source = config ?? _config('src');
  final list =
      channels ??
      [
        _channel('a', number: 1),
        _channel('b', number: 2),
        _channel('c', number: 3),
      ];
  return LiveZapController(
    entries: zapEntriesOf(list, config: source, sourceName: source.label),
    initialIndex: initialIndex,
    catalog: catalog ?? _FakeCatalog(),
    settleDelay: _settle,
    digitCommitDelay: _digits,
    messageDuration: messageDuration,
  );
}

void main() {
  group('cursor', () {
    test('Up walks down the list and wraps; Down walks up and wraps', () async {
      // The player wraps **both** ways, unlike the live tab (where Up escapes
      // to another pane instead). There is nothing to escape to here.
      final controller = _controller();
      addTearDown(controller.dispose);
      expect(controller.current.channelId, 'a');
      controller.channelUp();
      expect(controller.current.channelId, 'b');
      controller.channelUp();
      controller.channelUp();
      expect(controller.current.channelId, 'a', reason: 'Up wraps');
      controller.channelDown();
      expect(controller.current.channelId, 'c', reason: 'Down wraps');
    });

    test('the banner follows the cursor immediately, playback waits', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      final surface = _Surface()..attach(controller);

      controller.channelUp();
      expect(controller.current.channelId, 'b');
      expect(controller.playing.channelId, 'a', reason: 'not settled yet');
      expect(surface.events, isEmpty);
      expect(catalog.resolved, isEmpty);

      await Future<void>.delayed(_past);
      expect(controller.playing.channelId, 'b');
      expect(surface.events, ['stop', 'changed b', 'play b']);
    });

    test('a held key costs one resolve, not one per channel passed', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      final surface = _Surface()..attach(controller);

      controller.channelUp();
      controller.channelUp();
      controller.channelUp();
      controller.channelDown();
      await Future<void>.delayed(_past);

      expect(catalog.resolved, ['src/c']);
      expect(surface.events, ['stop', 'changed c', 'play c']);
      expect(controller.zapCount, 1);
    });

    test('a move back to the playing channel resolves nothing', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);

      controller.channelUp();
      controller.channelDown();
      await Future<void>.delayed(_past);
      expect(catalog.resolved, isEmpty);
      expect(controller.zapped, isFalse);
    });

    test('the stream is stopped before the next one is resolved', () async {
      // Provider accounts are single-connection: resolving while the old
      // stream still holds the slot is what a portal refuses.
      final order = <String>[];
      final catalog = _FakeCatalog()..trace = order;
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      controller.onStopCurrent = () async => order.add('stop');
      controller.onPlay = (_, _) async => order.add('play');

      controller.channelUp();
      await Future<void>.delayed(_past);
      expect(order, ['stop', 'resolve b', 'play']);
    });
  });

  group('previous channel', () {
    test('toggles between the last two channels actually played', () async {
      final controller = _controller();
      addTearDown(controller.dispose);
      _Surface().attach(controller);

      // Nothing has played but the launch channel yet.
      controller.previousChannel();
      await Future<void>.delayed(_past);
      expect(controller.playing.channelId, 'a');

      controller.channelUp(); // -> b
      await Future<void>.delayed(_past);
      expect(controller.playing.channelId, 'b');

      controller.previousChannel();
      await Future<void>.delayed(_past);
      expect(controller.playing.channelId, 'a');

      controller.previousChannel();
      await Future<void>.delayed(_past);
      expect(controller.playing.channelId, 'b');
    });
  });

  group('channel-number entry', () {
    test('commits on its own after the idle delay', () async {
      final controller = _controller();
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      controller.appendDigit(3);
      expect(controller.digitBuffer, '3');
      expect(controller.playing.channelId, 'a');
      await Future<void>.delayed(_past);
      expect(controller.digitBuffer, '');
      expect(controller.playing.channelId, 'c');
    });

    test('OK commits it early', () async {
      final controller = _controller();
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      controller.appendDigit(2);
      expect(
        controller.handleCommand(const ZapCommand(ZapCommandKind.activate)),
        isTrue,
      );
      expect(controller.digitBuffer, '');
      // Committed immediately: a typed number is a specific destination, so
      // there is no scan to coalesce and no settle to wait out.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.playing.channelId, 'b');
    });

    test('OK with no pending number is not consumed', () {
      final controller = _controller();
      addTearDown(controller.dispose);
      expect(
        controller.handleCommand(const ZapCommand(ZapCommandKind.activate)),
        isFalse,
      );
    });

    test('a miss says so and leaves playback alone', () async {
      // The search is the zap range only: a jump outside it would leave
      // Up/Down walking a list the playing channel is not in.
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      controller.appendDigit(9);
      controller.appendDigit(9);
      controller.commitDigits();
      expect(controller.message, 'No channel 99');
      await Future<void>.delayed(_past);
      expect(catalog.resolved, isEmpty);
      expect(controller.playing.channelId, 'a');
      expect(controller.message, isNull, reason: 'the note is transient');
    });

    test('the buffer is capped, and Back clears it', () {
      final controller = _controller();
      addTearDown(controller.dispose);
      for (var i = 0; i < 8; i++) {
        controller.appendDigit(1);
      }
      expect(controller.digitBuffer, '1111');
      expect(
        controller.handleCommand(const ZapCommand(ZapCommandKind.back)),
        isTrue,
      );
      expect(controller.digitBuffer, '');
      expect(
        controller.handleCommand(const ZapCommand(ZapCommandKind.back)),
        isFalse,
        reason: 'Back is only ours while a number is half-typed',
      );
    });

    test('a duplicate number resolves to the first match in list order', () {
      final controller = _controller(
        channels: [
          _channel('a', number: 5),
          _channel('b', number: 5),
          _channel('c'),
        ],
      );
      addTearDown(controller.dispose);
      controller.appendDigit(5);
      controller.commitDigits();
      expect(controller.current.channelId, 'a');
    });
  });

  group('a zap that fails', () {
    test('reverts the cursor and brings the old channel back', () async {
      // The old stream was already stopped to free the connection, so
      // reporting the failure is not enough — it has to be restored.
      final catalog = _FakeCatalog(failFor: {'b'});
      final controller = _controller(
        catalog: catalog,
        // Long enough that the note is still up when the revert finishes —
        // its expiry has its own coverage below.
        messageDuration: const Duration(seconds: 5),
      );
      addTearDown(controller.dispose);
      final surface = _Surface()..attach(controller);

      controller.channelUp();
      await Future<void>.delayed(_past);

      expect(controller.playing.channelId, 'a');
      expect(controller.index, controller.playingIndex);
      expect(controller.message, contains('Channel b'));
      expect(catalog.resolved, ['src/b', 'src/a']);
      expect(surface.events, ['stop', 'play a']);
      expect(controller.zapped, isFalse);
    });
  });

  group('single-flight', () {
    test('resolveCurrent stands down while a zap is settling', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      final gate = Completer<void>();
      catalog.resolveGate = gate;

      controller.channelUp();
      await Future<void>.delayed(_past);
      expect(controller.settling, isTrue);
      // Null is the caller's "keep the locator we hold" answer, which is the
      // pre-existing behaviour for an unusable re-resolve.
      expect(await controller.resolveCurrent(), isNull);
      catalog.resolveGate = null;
      gate.complete();
      await Future<void>.delayed(_past);
      expect(controller.settling, isFalse);
      expect(catalog.resolved, ['src/b']);
    });

    test('two settles never overlap; the later cursor wins', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      final gate = Completer<void>();
      catalog.resolveGate = gate;

      controller.channelUp(); // -> b
      await Future<void>.delayed(_past);
      expect(catalog.resolved, ['src/b']);
      // A second move lands while b's resolve is still in flight. It must not
      // start a second create_link beside it.
      controller.channelUp(); // -> c
      await Future<void>.delayed(_past);
      expect(catalog.resolved, ['src/b']);
      catalog.resolveGate = null;
      gate.complete();
      await Future<void>.delayed(_past);
      expect(catalog.resolved, ['src/b', 'src/c']);
      expect(controller.playing.channelId, 'c');
    });

    test('resolveCurrent answers for the channel now playing', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      controller.channelUp();
      await Future<void>.delayed(_past);
      catalog.resolved.clear();
      final fresh = await controller.resolveCurrent();
      expect(fresh, isNotNull);
      expect(catalog.resolved, ['src/b']);
    });
  });

  group('cross-source range', () {
    final alpha = _config('alpha', settings: {'aspectMode': 'Fit'});
    final beta = _config(
      'beta',
      settings: {'aspectMode': '16:9', 'bufferPreset': 'high'},
    );

    LiveZapController build(_FakeCatalog catalog) => LiveZapController(
      entries: [
        ZapEntry(
          channel: _channel('a', number: 1),
          config: alpha,
          sourceName: 'Alpha',
        ),
        ZapEntry(
          channel: _channel('a', number: 1),
          config: beta,
          sourceName: 'Beta',
        ),
      ],
      initialIndex: 0,
      catalog: catalog,
      settleDelay: _settle,
      digitCommitDelay: _digits,
      messageDuration: _digits,
    );

    test('resolves through the owning source, not the active one', () async {
      // The two entries share a channel id — the exact collision the
      // cross-source Favorites view puts in one list.
      final catalog = _FakeCatalog();
      final controller = build(catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);
      controller.channelUp();
      await Future<void>.delayed(_past);
      expect(catalog.resolved, ['beta/a']);
      expect(controller.sourceName, 'Beta');
    });

    test('favourite and aspect follow the channel now playing', () async {
      final catalog = _FakeCatalog();
      final controller = build(catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);

      await controller.setFavorite(true);
      expect(catalog.favorites, {'alpha/a': true});

      controller.channelUp();
      await Future<void>.delayed(_past);

      expect(controller.aspectLabel, '16:9');
      expect(controller.bufferPreset, BufferPreset.high);
      await controller.setFavorite(true);
      expect(catalog.favorites, {'alpha/a': true, 'beta/a': true});
      await controller.persistAspect('Fill');
      expect(catalog.aspectWrites, [('beta', 'Fill')]);
    });

    test('a favorite command sets the state absolutely', () async {
      final catalog = _FakeCatalog();
      final controller = build(catalog);
      addTearDown(controller.dispose);
      expect(
        controller.handleCommand(const ZapCommand(ZapCommandKind.favorite, 1)),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(catalog.favorites['alpha/a'], isTrue);
      controller.handleCommand(const ZapCommand(ZapCommandKind.favorite, 0));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(catalog.favorites['alpha/a'], isFalse);
    });
  });

  group('presentation', () {
    test('title / EPG / banner read the cursor and the playing row', () async {
      final catalog = _FakeCatalog();
      final start = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      catalog.epg['src/b'] = (
        now: Programme(
          channelId: 'b',
          title: 'Now on B',
          start: start,
          stop: start.add(const Duration(hours: 1)),
        ),
        next: null,
      );
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);

      controller.channelUp();
      // The banner is the cursor's, so a held key acknowledges each press.
      final banner = controller.bannerPayload();
      expect(banner['channelName'], 'Channel b');
      expect(banner['channelNumber'], 2);
      expect(banner['epgNowTitle'], 'Now on B');
      expect(banner['position'], 2);
      expect(banner['total'], 3);
      // The title is the *playing* channel's until the zap settles, because
      // that is what is on screen.
      expect(controller.title, 'Channel a');
      await Future<void>.delayed(_past);
      expect(controller.title, 'Channel b');
      expect(controller.epg.now?.title, 'Now on B');
    });

    test('the digit buffer and a miss ride on the banner', () {
      final controller = _controller();
      addTearDown(controller.dispose);
      controller.appendDigit(1);
      controller.appendDigit(2);
      expect(controller.bannerPayload()['digits'], '12');
      controller.commitDigits();
      expect(controller.bannerPayload()['message'], 'No channel 12');
    });
  });

  group('quick-list commands', () {
    test('are not consumed yet, so a surface keeps its own behaviour', () {
      // Phase 6 wires these; until then Left must fall through rather than
      // swallow the key into a no-op.
      final controller = _controller();
      addTearDown(controller.dispose);
      for (final kind in const [
        ZapCommandKind.openList,
        ZapCommandKind.closeList,
        ZapCommandKind.move,
      ]) {
        expect(controller.handleCommand(ZapCommand(kind, 1)), isFalse);
      }
    });
  });

  group('teardown', () {
    test('a settle landing after dispose touches no surface', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      final surface = _Surface()..attach(controller);
      final gate = Completer<void>();
      catalog.resolveGate = gate;
      controller.channelUp();
      await Future<void>.delayed(_past);
      expect(surface.events, ['stop']);
      controller.dispose();
      gate.complete();
      await Future<void>.delayed(_past);
      expect(surface.events, ['stop']);
    });

    test('a pending move is dropped by dispose', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      _Surface().attach(controller);
      controller.channelUp();
      controller.dispose();
      await Future<void>.delayed(_past);
      expect(catalog.resolved, isEmpty);
    });
  });

  group('cursorEpg / bannerRevision', () {
    test('cursorEpg follows the cursor while epg stays on the playing entry '
        'during an unsettled move', () async {
      final catalog = _FakeCatalog();
      final start = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      catalog.epg['src/a'] = (
        now: Programme(
          channelId: 'a',
          title: 'Now on A',
          start: start,
          stop: start.add(const Duration(hours: 1)),
        ),
        next: null,
      );
      catalog.epg['src/b'] = (
        now: Programme(
          channelId: 'b',
          title: 'Now on B',
          start: start,
          stop: start.add(const Duration(hours: 1)),
        ),
        next: null,
      );
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);

      controller.channelUp();
      // Not settled yet: epg (playing) is still A's, cursorEpg (cursor) is
      // already B's.
      expect(controller.epg.now?.title, 'Now on A');
      expect(controller.cursorEpg.now?.title, 'Now on B');

      await Future<void>.delayed(_past);
      expect(controller.epg.now?.title, 'Now on B');
      expect(controller.cursorEpg.now?.title, 'Now on B');
    });

    test('bannerRevision strictly increases on channel up, digit, message, '
        'settling transition', () async {
      final catalog = _FakeCatalog();
      final controller = _controller(catalog: catalog);
      addTearDown(controller.dispose);
      _Surface().attach(controller);

      final r0 = controller.bannerRevision;
      controller.channelUp();
      final r1 = controller.bannerRevision;
      expect(r1, greaterThan(r0));

      controller.appendDigit(1);
      final r2 = controller.bannerRevision;
      expect(r2, greaterThan(r1));

      controller.appendDigit(9);
      controller.commitDigits(); // no channel 19 -> message shown
      final r3 = controller.bannerRevision;
      expect(r3, greaterThan(r2));

      // The settling transition (true, then false once resolved) each bump
      // the revision too.
      await Future<void>.delayed(_past);
      final r4 = controller.bannerRevision;
      expect(r4, greaterThan(r3));
    });
  });

  group('zapEntriesOf', () {
    test('wraps a channel list without materialising it', () {
      final config = _config('src');
      final channels = List.generate(1000, (i) => _channel('c$i', number: i));
      final entries = zapEntriesOf(
        channels,
        config: config,
        sourceName: 'Src',
      );
      expect(entries.length, 1000);
      expect(entries[7].channelId, 'c7');
      expect(entries[7].sourceName, 'Src');
      expect(entries[7].config, same(config));
      expect(() => entries[0] = entries[1], throwsUnsupportedError);
      expect(() => entries.length = 2, throwsUnsupportedError);
    });
  });
}
