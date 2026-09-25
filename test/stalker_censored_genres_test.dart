// Adult ("censored") Stalker genres: many portals leave their channels out of
// `get_all_channels` and serve them only per genre through `get_ordered_list`.
// Reported by a user whose adult channels never appeared on a Stalker source.

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/stalker_source.dart';

void main() {
  Map<String, dynamic> row(String id, String genre) => {
    'id': id,
    'name': 'Channel $id',
    'number': int.parse(id),
    'tv_genre_id': genre,
    'cmd': 'ffmpeg http://stream.example.invalid/$id',
  };

  StalkerSource portal({
    required List<Map<String, dynamic>> genres,
    required List<Map<String, dynamic>> all,
    Map<String, List<Map<String, dynamic>>> perGenre = const {},
    List<String>? orderedGenres,
    bool orderedFails = false,
  }) => StalkerSource(
    sourceId: 'stalker-test',
    portal: 'http://example.invalid/c/',
    mac: '00:1A:79:12:34:56',
    diagnostics: false,
    debugApi: (params) async {
      switch (params['action']) {
        case 'get_all_channels':
          return {
            'js': {'data': all},
          };
        case 'get_genres':
          return {'js': genres};
        case 'get_ordered_list':
          orderedGenres?.add(params['genre']!);
          if (orderedFails) throw StalkerException('refused');
          final rows = perGenre[params['genre']] ?? const [];
          return {
            'js': {
              'total_items': rows.length,
              'max_page_items': 50,
              'data': [for (final r in rows) Map<String, dynamic>.from(r)],
            },
          };
      }
      return const {'js': null};
    },
  );

  test('backfills a censored genre get_all_channels omitted', () async {
    final asked = <String>[];
    final source = portal(
      genres: [
        {'id': '1', 'title': 'News'},
        {'id': '9', 'title': 'Night', 'censored': 1},
      ],
      all: [row('1', '1')],
      perGenre: {
        '9': [
          {'id': '90', 'name': 'Late', 'cmd': 'ffmpeg http://s/90'},
        ],
      },
      orderedGenres: asked,
    );

    final channels = await source.channels();

    expect(channels.map((c) => c.id), ['1', '90']);
    expect(channels.last.categoryId, '9');
    expect(asked, ['9'], reason: 'only the censored genre is fetched');
  });

  test('asks nothing more when the portal already included them', () async {
    final asked = <String>[];
    final source = portal(
      genres: [
        {'id': '1', 'title': 'News'},
        {'id': '9', 'title': 'Adult', 'censored': '1'},
      ],
      all: [row('1', '1'), row('90', '9')],
      orderedGenres: asked,
    );

    expect((await source.channels()).map((c) => c.id), ['1', '90']);
    expect(asked, isEmpty);
  });

  test('a failing backfill keeps the rest of the catalog', () async {
    final source = portal(
      genres: [
        {'id': '1', 'title': 'News'},
        {'id': '9', 'title': 'XXX'},
      ],
      all: [row('1', '1')],
      orderedFails: true,
    );

    expect((await source.channels()).map((c) => c.id), ['1']);
  });

  test('isCensoredStalkerGenre reads the flag and adult titles', () {
    bool censored(Map<String, dynamic> g) => isCensoredStalkerGenre(g);
    expect(censored({'title': 'Films', 'censored': 1}), isTrue);
    expect(censored({'title': 'Films', 'censored': true}), isTrue);
    expect(censored({'title': 'FR| ADULTE'}), isTrue);
    expect(censored({'title': 'XXX'}), isTrue);
    expect(censored({'title': 'Adults 18+'}), isTrue);
    expect(censored({'title': '+18'}), isTrue);
    expect(censored({'title': 'Sport', 'censored': 0}), isFalse);
    expect(censored({'title': 'Sport', 'censored': '0'}), isFalse);
    expect(censored({'title': 'Kids'}), isFalse);
    expect(censored({'title': 'UK 180'}), isFalse);
  });
}
