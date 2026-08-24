// The spool exists so `AppDatabase.replaceEpgStream`'s transaction never spans
// a guide's download. These pin the contract that makes that safe: what comes
// out equals what went in, a failure leaves nothing behind, and the peak cost
// is one batch rather than the whole guide.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/programme_spool.dart';
import 'package:iptvs/sources/source.dart';

List<Programme> _batch(int from, int count) => [
  for (var i = from; i < from + count; i++)
    Programme(
      channelId: 'ch${i % 7}',
      start: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
      stop: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000 + 900),
      title: 'Programme $i — ünïcødé & "quotes"',
      description: i.isEven ? null : 'Description $i',
    ),
];

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('iptvs_spool_test'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<ProgrammeSpool> spool(Stream<List<Programme>> source) =>
      ProgrammeSpool.drain(source, directory: dir);

  test('replays every programme, in order, unchanged', () async {
    final input = [_batch(0, 3), _batch(3, 2), _batch(5, 4)];
    final s = await spool(Stream.fromIterable(input));
    addTearDown(s.dispose);

    final out = await s.read().toList();

    expect(out.length, 3, reason: 'one frame per batch');
    expect(out.expand((b) => b).length, 9);
    final flat = out.expand((b) => b).toList();
    final expected = input.expand((b) => b).toList();
    for (var i = 0; i < expected.length; i++) {
      expect(flat[i].channelId, expected[i].channelId);
      expect(flat[i].title, expected[i].title, reason: 'non-ASCII survives');
      expect(flat[i].description, expected[i].description);
      expect(flat[i].start, expected[i].start);
      expect(flat[i].stop, expected[i].stop);
    }
  });

  test('a null description stays null rather than becoming empty', () async {
    // The distinction reaches the UI: the details sheet renders a description
    // section only when there is one.
    final s = await spool(
      Stream.value([
        Programme(
          channelId: 'a',
          start: DateTime(2026, 1, 1),
          stop: DateTime(2026, 1, 2),
          title: 'No description',
        ),
      ]),
    );
    addTearDown(s.dispose);
    expect((await s.read().first).single.description, isNull);
  });

  test('counts what it spooled', () async {
    final s = await spool(Stream.fromIterable([_batch(0, 10), _batch(10, 5)]));
    addTearDown(s.dispose);
    expect(s.batches, 2);
    expect(s.programmes, 15);
    expect(s.bytes, greaterThan(0));
  });

  test('drops empty batches instead of spooling empty frames', () async {
    // `mergeEpgGuides` filters a batch down to nothing when a later guide's
    // channels were all claimed already. A frame for it would cost the ingest a
    // read and an insert round trip for no rows.
    final s = await spool(
      Stream.fromIterable([_batch(0, 2), <Programme>[], _batch(2, 1)]),
    );
    addTearDown(s.dispose);
    expect(s.batches, 2);
    expect(s.programmes, 3);
  });

  test('an empty guide spools successfully and replays as nothing', () async {
    // Success-empty is a real outcome — a source with no EPG data — and it must
    // still reach `replaceEpgStream`, which clears stale rows and advances the
    // sync time. Failing here would re-fetch that guide on every single load.
    final s = await spool(const Stream<List<Programme>>.empty());
    addTearDown(s.dispose);
    expect(s.batches, 0);
    expect(await s.read().toList(), isEmpty);
  });

  test('a failing source propagates and leaves no file behind', () async {
    Stream<List<Programme>> failing() async* {
      yield _batch(0, 2);
      throw StateError('guide died mid-feed');
    }

    await expectLater(spool(failing()), throwsStateError);
    expect(
      dir.listSync(),
      isEmpty,
      reason: 'a partial spool must not survive to be read as a whole guide',
    );
  });

  test('a cancelled source propagates its cancellation', () async {
    // Not swallowed into a short-but-successful guide: the caller distinguishes
    // "superseded" from "failed", and neither may commit.
    Stream<List<Programme>> cancelled() async* {
      yield _batch(0, 1);
      throw const LoadCancelledException();
    }

    await expectLater(
      spool(cancelled()),
      throwsA(isA<LoadCancelledException>()),
    );
    expect(dir.listSync(), isEmpty);
  });

  test('dispose removes the file and is safe to repeat', () async {
    final s = await spool(Stream.value(_batch(0, 1)));
    expect(dir.listSync(), hasLength(1));
    await s.dispose();
    expect(dir.listSync(), isEmpty);
    await s.dispose();
    expect(dir.listSync(), isEmpty);
  });

  test('two spools drained in the same microsecond do not collide', () async {
    // The filename carries a timestamp; on a coarse clock two refreshes started
    // together would otherwise write to the same path and read each other's
    // guide.
    final both = await Future.wait([
      spool(Stream.value(_batch(0, 2))),
      spool(Stream.value(_batch(100, 3))),
    ]);
    addTearDown(() => Future.wait(both.map((s) => s.dispose())));

    expect(dir.listSync(), hasLength(2));
    expect((await both[0].read().first).length, 2);
    expect((await both[1].read().first).length, 3);
  });

  test('read is re-runnable, so a retry does not need a second drain', () async {
    final s = await spool(Stream.value(_batch(0, 4)));
    addTearDown(s.dispose);
    expect((await s.read().toList()).expand((b) => b).length, 4);
    expect((await s.read().toList()).expand((b) => b).length, 4);
  });

  test('a truncated spool throws rather than replaying a short guide', () async {
    // The failure mode this guards against is the quiet one: a short read that
    // completes normally would be committed as a complete guide, dropping
    // everything the previous refresh had.
    final s = await spool(Stream.fromIterable([_batch(0, 50), _batch(50, 50)]));
    addTearDown(s.dispose);
    final file = dir.listSync().whereType<File>().single;
    final bytes = file.readAsBytesSync();
    file.writeAsBytesSync(bytes.sublist(0, bytes.length - 20));

    await expectLater(s.read().toList(), throwsStateError);
  });
}
