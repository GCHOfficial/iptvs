// Tests for the LoadToken cancellation path introduced alongside streamed EPG
// batches: parseXmltvBatched stops yielding once its token is cancelled,
// AppDatabase.replaceEpgStream rolls back a cancelled feed instead of
// committing a half-fed guide, and LibraryRepository skips a stale
// channel-cache write when its token was cancelled mid-load.

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xmltv.dart';

import 'support/workload_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});

  group('parseXmltvBatched cancellation', () {
    test(
      'stops yielding further batches once the token is cancelled',
      () async {
        const channelCount = 40;
        const perChannel = 60; // large enough to force multiple batches
        final bytes = WorkloadFixtures.xmltv(
          channelCount: channelCount,
          programmesPerChannel: perChannel,
        );
        expect(bytes.length, greaterThan(64 * 1024));
        final map = {
          for (var i = 0; i < channelCount; i++) 'channel.$i': 'ch$i',
        };
        final token = LoadToken();

        final received = <List<Programme>>[];
        Future<void> drain() async {
          await for (final batch in parseXmltvBatched(
            bytes,
            map,
            batchSize: 500,
            token: token,
          )) {
            received.add(batch);
            // Simulate a newer load superseding this one right after the
            // first batch arrives.
            token.cancel();
          }
        }

        await expectLater(drain(), throwsA(isA<LoadCancelledException>()));
        // Exactly one batch was yielded before cancellation stopped the feed.
        expect(received.length, 1);
      },
    );
  });

  group('AppDatabase.replaceEpgStream cancellation', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('iptvs_epg_cancel_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    String dbPath() => '${tempDir.path}/iptv.db';

    test(
      'a stream that throws LoadCancelledException rolls back, retaining the prior guide',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h) => DateTime.utc(2024, 1, 1, h);

        // Seed the sources row + a good guide first.
        await db.replaceLibrary(
          'src1',
          'Src',
          const [Category(id: 'c1', title: 'News')],
          const [Channel(id: 'ch1', name: 'One', categoryId: 'c1')],
        );
        await db.replaceEpg('src1', [
          Programme(channelId: 'ch1', start: t(10), stop: t(11), title: 'Good'),
        ]);
        final before = await db.lastEpgSynced('src1');
        expect(before, isNotNull);

        Stream<List<Programme>> cancelledMidFeed() async* {
          yield [
            Programme(
              channelId: 'ch1',
              start: t(12),
              stop: t(13),
              title: 'Partial',
            ),
          ];
          throw const LoadCancelledException();
        }

        await expectLater(
          db.replaceEpgStream('src1', cancelledMidFeed()),
          throwsA(isA<LoadCancelledException>()),
        );

        // The delete + partial batch both rolled back with the transaction —
        // the prior guide and its sync timestamp are untouched.
        final result = await db.nowNext(
          'src1',
          t(10).add(const Duration(minutes: 30)),
        );
        expect(result.now['ch1']?.title, 'Good');
        expect(await db.lastEpgSynced('src1'), before);
        await db.close();
      },
    );
  });

  group('LibraryRepository cancellation', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('iptvs_repo_cancel_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    String dbPath() => '${tempDir.path}/iptv.db';

    test(
      'a token cancelled between the fetch and the cache write skips the stale write',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        // Seed a prior cache the stale write must not clobber.
        await db.replaceLibrary(
          'fake',
          'Fake',
          const [Category(id: 'test', title: 'Test streams')],
          const [Channel(id: 'old', name: 'Old', categoryId: 'test')],
        );

        final token = LoadToken();
        // channels() cancels the token as a side effect, simulating a newer
        // load superseding this one while the fetch was still in flight.
        final source = _CancelingSource(tokenToCancel: token);
        final repo = LibraryRepository(source: source, db: db);
        repo.loadToken = token;

        final snapshot = await repo.load(forceRefresh: true);

        // The returned snapshot reflects what the source fetched — matches
        // "the controller already discarded this by generation" semantics —
        // but the cache write itself was skipped.
        expect(snapshot.channels.map((c) => c.id), ['new']);
        expect((await db.readChannels('fake')).map((c) => c.id), ['old']);
        await db.close();
      },
    );

    test(
      'a cancelled EPG batch stream is swallowed, not surfaced as a load error',
      () async {
        final db = await AppDatabase.openAt(dbPath());
        DateTime t(int h) => DateTime.utc(2024, 1, 1, h);
        await db.replaceLibrary(
          'fake',
          'Fake',
          const [Category(id: 'test', title: 'Test streams')],
          const [Channel(id: 'a', name: 'A', categoryId: 'test')],
        );
        await db.replaceEpg('fake', [
          Programme(channelId: 'a', start: t(10), stop: t(11), title: 'Good'),
        ]);
        final t0 = await db.lastEpgSynced('fake');
        expect(t0, isNotNull);

        final source = _BatchedFakeSource(
          batchesBuilder: () async* {
            yield [
              Programme(
                channelId: 'a',
                start: t(12),
                stop: t(13),
                title: 'Partial',
              ),
            ];
            throw const LoadCancelledException();
          },
        );
        final repo = LibraryRepository(source: source, db: db);

        // load() must not throw despite the cancellation sentinel — the
        // outer catch treats it as an ordinary EPG-refresh skip, and the
        // prior good guide + timestamp survive untouched.
        await repo.load(forceRefresh: true);

        final result = await db.nowNext(
          'fake',
          t(10).add(const Duration(minutes: 30)),
        );
        expect(result.now['a']?.title, 'Good');
        expect(await db.lastEpgSynced('fake'), t0);
        await db.close();
      },
    );
  });
}

/// [DemoSource] subclass whose `channels()` cancels a given token as a side
/// effect — simulating a newer load superseding this one while the channel
/// fetch was still in flight — then returns a distinguishable channel list.
class _CancelingSource extends DemoSource {
  _CancelingSource({required this.tokenToCancel}) : super(sourceId: 'fake');

  final LoadToken tokenToCancel;

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    tokenToCancel.cancel();
    return const [Channel(id: 'new', name: 'New', categoryId: 'test')];
  }
}

/// [DemoSource] subclass that additionally implements [BatchedEpgSource],
/// always returning a caller-supplied canned batch stream regardless of the
/// requested channels/token — enough to exercise
/// `LibraryRepository._ensureEpg`'s batched-EPG branch.
class _BatchedFakeSource extends DemoSource implements BatchedEpgSource {
  _BatchedFakeSource({required this.batchesBuilder}) : super(sourceId: 'fake');

  final Stream<List<Programme>> Function() batchesBuilder;

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) => batchesBuilder();
}
