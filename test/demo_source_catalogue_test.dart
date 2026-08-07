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
    // Assert the *properties* the guide has to have rather than a slot count.
    // The count used to be pinned at 9 per channel (±2 h), which meant the
    // guide silently expired about two hours into a session and looked like
    // broken EPG. Pinning the window width again would just re-freeze whatever
    // number is current; these three checks are what actually make the demo
    // source useful as a guide stand-in.
    final now = DateTime.now();
    expect(guide, isNotEmpty);
    expect(
      guide.every((programme) => programme.stop.isAfter(programme.start)),
      isTrue,
    );
    for (final channel in channels) {
      final rows = guide.where((p) => p.channelId == channel.id);
      expect(
        rows.any((p) => !p.start.isAfter(now) && p.stop.isAfter(now)),
        isTrue,
        reason: '${channel.id} must have a *current* programme',
      );
      expect(
        rows.any((p) => p.stop.isBefore(now)),
        isTrue,
        reason: '${channel.id} must have a past programme for catch-up',
      );
      expect(
        rows.any((p) => p.start.isAfter(now)),
        isTrue,
        reason: '${channel.id} must have a future programme for next/guide',
      );
    }
    // Wide enough to outlast a long session, not merely the next few minutes.
    final furthest = guide
        .map((p) => p.stop)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    expect(furthest.difference(now).inHours, greaterThanOrEqualTo(12));

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

  test('every advertised playable row has a secure stream mapping', () async {
    for (final channel in await source.channels()) {
      final stream = await source.resolve(channel);
      expect(stream.url, startsWith('https://'), reason: channel.name);
    }

    for (final movie in await source.mediaItems(ContentKind.movie)) {
      final stream = await source.resolveMedia(movie);
      expect(stream.url, startsWith('https://'), reason: movie.title);
    }

    for (final series in await source.mediaItems(ContentKind.series)) {
      final seasons = await source.mediaItems(
        ContentKind.season,
        parent: series,
      );
      expect(seasons, isNotEmpty, reason: series.title);
      for (final season in seasons) {
        final episodes = await source.mediaItems(
          ContentKind.episode,
          parent: season,
        );
        expect(episodes, isNotEmpty, reason: season.title);
        for (final episode in episodes) {
          final stream = await source.resolveMedia(episode);
          expect(stream.url, startsWith('https://'), reason: episode.title);
        }
      }
    }
  });
}
