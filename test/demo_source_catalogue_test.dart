import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late DemoSource source;

  setUp(() => source = DemoSource());

  test('reports every demo capability and separates live categories', () async {
    expect(source.sourceCapabilities.epg, CapabilityAvailability.supported);
    expect(source.sourceCapabilities.catchup, CapabilityAvailability.supported);
    expect(source.catchupCapability.supported, isTrue);

    final categories = await source.categories();
    expect(categories.map((category) => category.id), [
      'open-simulcasts',
      'playback-lab',
    ]);
    expect(await source.channels(categoryId: 'open-simulcasts'), hasLength(2));
    expect(await source.channels(categoryId: 'playback-lab'), hasLength(4));
  });

  test('generates now/next and past guide rows for archive channels', () async {
    final channels = await source.channels();
    final guide = await source.epg(channels);
    expect(guide, hasLength(channels.length * 9));
    expect(
      guide.where((programme) => programme.channelId == 'bbb'),
      hasLength(9),
    );
    expect(
      guide.any((programme) => programme.start.isBefore(DateTime.now())),
      isTrue,
    );

    final bbb = channels.first;
    final past = guide
        .where((programme) => programme.channelId == bbb.id)
        .firstWhere((programme) => programme.start.isBefore(DateTime.now()));
    final archive = await source.resolveArchive(bbb, past);
    expect(archive.isLive, isFalse);
    expect(archive.url, contains('x36xhzz'));
  });

  test('populates movies and both series hierarchies with metadata', () async {
    final movieCategories = await source.mediaCategories(ContentKind.movie);
    expect(movieCategories, hasLength(2));
    final movies = await source.mediaItems(ContentKind.movie);
    expect(movies, hasLength(4));
    expect(
      movies.every(
        (movie) =>
            movie.poster != null &&
            movie.backdrop != null &&
            movie.description != null &&
            movie.year != null &&
            movie.rating != null &&
            movie.durationSeconds != null,
      ),
      isTrue,
    );

    final series = await source.mediaItems(ContentKind.series);
    expect(
      series.map((item) => item.id),
      containsAll(['demo-series-1', 'caminandes']),
    );
    final codecSeasons = await source.mediaItems(
      ContentKind.season,
      parent: series.firstWhere((item) => item.id == 'demo-series-1'),
    );
    expect(codecSeasons, hasLength(2));
    final episodes = await source.mediaItems(
      ContentKind.episode,
      parent: codecSeasons.first,
    );
    expect(episodes, hasLength(3));
    expect(
      episodes.every((episode) => episode.extra['urlKey'] != null),
      isTrue,
    );
  });

  test(
    'searches movies and series without returning everything for empty text',
    () async {
      expect(
        await source.searchMedia(ContentKind.movie, 'sintel'),
        hasLength(1),
      );
      expect(
        await source.searchMedia(ContentKind.series, 'camin'),
        hasLength(1),
      );
      expect(await source.searchMedia(ContentKind.movie, ''), isEmpty);
      expect(await source.searchMedia(ContentKind.episode, 'bunny'), isEmpty);
    },
  );

  test('resolves VOD and simulated-live rows with explicit liveness', () async {
    final channels = await source.channels();
    expect((await source.resolve(channels.first)).isLive, isTrue);
    expect((await source.resolve(channels[2])).isLive, isFalse);

    final movies = await source.mediaItems(ContentKind.movie);
    final spring = movies.firstWhere((movie) => movie.id == 'movie-spring');
    final stream = await source.resolveMedia(spring);
    expect(stream.isLive, isFalse);
    expect(stream.url, contains('video.blender.org'));
    expect(
      () => source.resolveMedia(
        const MediaItem(id: 'x', title: 'x', kind: ContentKind.series),
      ),
      throwsUnsupportedError,
    );
  });
}
