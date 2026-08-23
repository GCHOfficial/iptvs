import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/sources/epg_guides.dart';
import 'package:iptvs/sources/source.dart';

final _t0 = DateTime.utc(2026, 1, 1, 12);

Programme _p(String channelId, {String title = 'x', int hour = 0}) => Programme(
  channelId: channelId,
  start: _t0.add(Duration(hours: hour)),
  stop: _t0.add(Duration(hours: hour + 1)),
  title: title,
);

/// A feed that yields [batches] in order, then optionally throws.
EpgGuideFeed _feed(
  List<List<Programme>> batches, {
  Object? throwAfter,
  String? url,
  void Function()? onOpen,
}) => EpgGuideFeed(
  url: url,
  open: () async* {
    onOpen?.call();
    for (final b in batches) {
      yield b;
    }
    if (throwAfter != null) throw throwAfter;
  },
);

Future<List<Programme>> _drain(
  List<EpgGuideFeed> guides, {
  LoadToken? token,
}) async {
  final out = <Programme>[];
  await for (final batch in mergeEpgGuides(guides, token: token)) {
    out.addAll(batch);
  }
  return out;
}

void main() {
  group('mergeEpgGuides', () {
    test('a single guide passes straight through', () async {
      final out = await _drain([
        _feed([
          [_p('a'), _p('b')],
          [_p('c')],
        ]),
      ]);
      expect(out.map((p) => p.channelId), ['a', 'b', 'c']);
    });

    test('a later guide fills only channels the earlier one missed', () async {
      final out = await _drain([
        _feed([
          [_p('a', title: 'primary')],
        ]),
        _feed([
          [_p('a', title: 'secondary'), _p('b', title: 'secondary')],
        ]),
      ]);
      expect(out.length, 2);
      // 'a' keeps the primary guide's programme; 'b' comes from the top-up.
      expect(
        out.map((p) => '${p.channelId}:${p.title}'),
        ['a:primary', 'b:secondary'],
      );
    });

    test('a guide is never filtered against itself', () async {
      // Two batches of the same channel from ONE guide: claims must only apply
      // once that guide is exhausted, or a guide would truncate itself at the
      // first batch boundary.
      final out = await _drain([
        _feed([
          [_p('a', hour: 0)],
          [_p('a', hour: 1)],
          [_p('a', hour: 2)],
        ]),
      ]);
      expect(out.length, 3);
    });

    test('claims accumulate across three guides', () async {
      final out = await _drain([
        _feed([
          [_p('a')],
        ]),
        _feed([
          [_p('b')],
        ]),
        _feed([
          [_p('a'), _p('b'), _p('c')],
        ]),
      ]);
      expect(out.map((p) => p.channelId), ['a', 'b', 'c']);
    });

    test('one guide failing is survivable — the others still land', () async {
      final out = await _drain([
        _feed([
          [_p('a')],
        ]),
        // Fails before yielding (404, refused, unreadable) — nothing of its own
        // is in the transaction, so it is skipped rather than fatal.
        _feed(const [], throwAfter: StateError('404'),
            url: 'http://x/epg.xml?user=u'),
        _feed([
          [_p('c')],
        ]),
      ]);
      expect(out.map((p) => p.channelId), ['a', 'c']);
    });

    test('the PROVIDER guide failing still lets a top-up through', () async {
      // The case the feature exists for: the provider's own guide is the
      // broken one, and the user added a third-party URL to replace it. A
      // hard-failing primary would block exactly that.
      final out = await _drain([
        _feed(const [], throwAfter: StateError('provider 502')),
        _feed([
          [_p('a'), _p('b')],
        ]),
      ]);
      expect(out.map((p) => p.channelId), ['a', 'b']);
    });

    test('every guide failing propagates, so the cached guide is kept',
        () async {
      // `replaceEpgStream` reads a normally-completed empty stream as a
      // successful *empty* guide — it would clear the cache and advance
      // `epg_synced_at`. Throwing is what rolls that back.
      expect(
        _drain([
          _feed(const [], throwAfter: StateError('down')),
          _feed(const [], throwAfter: StateError('also down')),
        ]),
        throwsStateError,
      );
    });

    test('a lone guide failing propagates', () async {
      expect(
        _drain([
          _feed([
            [_p('a')],
          ], throwAfter: StateError('provider down')),
        ]),
        throwsStateError,
      );
    });

    test('cancellation propagates from an optional guide', () async {
      expect(
        _drain([
          _feed([
            [_p('a')],
          ]),
          _feed([
            [_p('b')],
          ], throwAfter: const LoadCancelledException()),
        ]),
        throwsA(isA<LoadCancelledException>()),
      );
    });

    test('a cancelled token stops the merge with an error', () async {
      final token = LoadToken();
      token.cancel();
      expect(
        _drain([
          _feed([
            [_p('a')],
          ]),
        ], token: token),
        throwsA(isA<LoadCancelledException>()),
      );
    });

    test('a batch filtered down to nothing is not yielded', () async {
      final batches = <List<Programme>>[];
      await for (final b in mergeEpgGuides([
        _feed([
          [_p('a')],
        ]),
        _feed([
          [_p('a')], // entirely covered
          [_p('b')],
        ]),
      ])) {
        batches.add(b);
      }
      expect(batches.length, 2);
      expect(batches[1].single.channelId, 'b');
    });

    test('a later guide is not opened until the earlier ones are drained',
        () async {
      var secondOpened = false;
      final seen = <String>[];
      final stream = mergeEpgGuides([
        _feed([
          [_p('a')],
          [_p('b')],
        ]),
        _feed([
          [_p('c')],
        ], onOpen: () => secondOpened = true),
      ]);
      await for (final batch in stream) {
        // The second guide's download must not have started while the first is
        // still feeding — one HTTP body in flight at a time.
        if (batch.first.channelId != 'c') expect(secondOpened, isFalse);
        seen.add(batch.first.channelId);
      }
      expect(seen, ['a', 'b', 'c']);
      expect(secondOpened, isTrue);
    });

    test('no guides yields nothing', () async {
      expect(await _drain(const []), isEmpty);
    });
  });

  group('mergeEpgGuides failure policy', () {
    test('a guide that fails MID-FEED rethrows, even with a survivor',
        () async {
      // Its batches are already inside the caller's transaction and cannot be
      // taken back, so completing normally would commit a truncated guide as a
      // whole one — `replaceEpgStream` would drop the previous guide and
      // advance `epg_synced_at`, costing the user a complete guide over a
      // network drop.
      expect(
        _drain([
          _feed([
            [_p('a')],
          ], throwAfter: StateError('dropped 80% through')),
          _feed([
            [_p('b')],
          ]),
        ]),
        throwsStateError,
      );
    });

    test('a guide that fails BEFORE yielding is skipped', () async {
      // Nothing was written, so there is nothing to roll back — and this is the
      // case the feature turns on, where the provider's guide is the broken one.
      final out = await _drain([
        _feed(const [], throwAfter: StateError('404')),
        _feed([
          [_p('a')],
        ]),
      ]);
      expect(out.map((p) => p.channelId), ['a']);
    });

    test('a mid-feed failure rethrows even when it is the last guide',
        () async {
      expect(
        _drain([
          _feed([
            [_p('a')],
          ]),
          _feed([
            [_p('b')],
          ], throwAfter: StateError('dropped')),
        ]),
        throwsStateError,
      );
    });
  });
}
