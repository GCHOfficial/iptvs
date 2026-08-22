// The Favorites ordering rule: catalog reading order, derived — never stored.
//
// Favorites are a set keyed by `(source_id, kind, item_id)` and synced as a
// delta, so there is nowhere to put a user-chosen sequence and no way for two
// devices to agree on one. The order therefore has to come from the catalog the
// user already browses: source order, then category order, then the channel
// order inside a category.

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/favorites_order.dart';

/// A stand-in for a favorited row: the two ranks plus the identity under test.
typedef _Row = ({String id, String source, String? category});

void main() {
  _Row row(String id, {String source = 's1', String? category}) =>
      (id: id, source: source, category: category);

  List<String> order(
    List<_Row> rows, {
    List<String> sources = const ['s1', 's2'],
    List<String> categories = const ['news', 'sport', 'kids'],
    bool withSourceRank = true,
  }) {
    final sourceRanks = catalogRanks(sources);
    final categoryRanks = catalogRanks(categories);
    return orderedByCatalog(
      rows,
      sourceRank: withSourceRank
          ? (_Row r) => rankOf(sourceRanks, r.source)
          : null,
      categoryRank: (_Row r) => rankOf(categoryRanks, r.category),
    ).map((r) => r.id).toList();
  }

  group('category order', () {
    test('groups by the category order, not by insertion', () {
      // The reported bug, in miniature: favouriting Pro before TVR1 must not
      // move Pro above TVR1 when the catalog lists TVR1 first.
      expect(
        order([
          row('pro', category: 'sport'),
          row('tvr1', category: 'news'),
        ]),
        ['tvr1', 'pro'],
      );
    });

    test('keeps the given order inside one category', () {
      // The caller filters straight out of the catalog, so the incoming order
      // is already the channel order — it must survive as the tie-break.
      expect(
        order([
          row('c1', category: 'news'),
          row('c2', category: 'news'),
          row('c3', category: 'news'),
        ]),
        ['c1', 'c2', 'c3'],
      );
    });

    test('is stable across a list long enough to trip an unstable sort', () {
      // `List.sort` is introsort and is *not* stable; on a single-category list
      // every comparison falls through to the tie-break, which is exactly where
      // an implicit one would let rows shuffle between rebuilds.
      final rows = [for (var i = 0; i < 200; i++) row('c$i', category: 'news')];
      expect(order(rows), [for (var i = 0; i < 200; i++) 'c$i']);
    });

    test('interleaved categories collapse into category blocks', () {
      expect(
        order([
          row('a', category: 'kids'),
          row('b', category: 'news'),
          row('c', category: 'kids'),
          row('d', category: 'sport'),
          row('e', category: 'news'),
        ]),
        // news, sport, kids — the reference order, each block in given order.
        ['b', 'e', 'd', 'a', 'c'],
      );
    });
  });

  group('unranked rows', () {
    test('an unknown category sorts last, not first', () {
      // A favorite whose category the provider has since dropped is still a
      // deliberate pick — it stays in the list, at the end. Ranking it 0 or -1
      // would put the least identifiable rows at the top.
      expect(
        order([
          row('ghost', category: 'deleted-category'),
          row('tvr1', category: 'news'),
        ]),
        ['tvr1', 'ghost'],
      );
    });

    test('a null category sorts last and keeps its relative order', () {
      expect(
        order([
          row('u1'),
          row('tvr1', category: 'news'),
          row('u2'),
        ]),
        ['tvr1', 'u1', 'u2'],
      );
    });
  });

  group('source order', () {
    test('the source rank dominates the category rank', () {
      // Without this the cross-source view interleaves providers by raw channel
      // number, which reads as no order at all beside a source chip.
      expect(
        order([
          row('b-news', source: 's2', category: 'news'),
          row('a-kids', source: 's1', category: 'kids'),
        ]),
        ['a-kids', 'b-news'],
      );
    });

    test('follows the user arrangement of the sources screen', () {
      final rows = [
        row('from-s1', source: 's1', category: 'news'),
        row('from-s2', source: 's2', category: 'news'),
      ];
      expect(order(rows, sources: const ['s1', 's2']), [
        'from-s1',
        'from-s2',
      ]);
      // Reordering the sources screen reorders the favorites with it.
      expect(order(rows, sources: const ['s2', 's1']), [
        'from-s2',
        'from-s1',
      ]);
    });

    test('a deleted source sorts last rather than jumping to the top', () {
      expect(
        order(
          [
            row('orphan', source: 'gone', category: 'news'),
            row('kept', source: 's1', category: 'kids'),
          ],
          sources: const ['s1'],
        ),
        ['kept', 'orphan'],
      );
    });

    test('a single-source view ignores the source rank entirely', () {
      expect(
        order(
          [
            row('pro', source: 'whatever', category: 'sport'),
            row('tvr1', source: 'other', category: 'news'),
          ],
          withSourceRank: false,
        ),
        ['tvr1', 'pro'],
      );
    });
  });

  group('catalogRanks', () {
    test('ranks by position', () {
      expect(catalogRanks(['a', 'b', 'c']), {'a': 0, 'b': 1, 'c': 2});
    });

    test('a duplicate id keeps its first position', () {
      // A provider that lists the same category twice shouldn't move every
      // channel in it down to the later slot.
      expect(catalogRanks(['a', 'b', 'a']), {'a': 0, 'b': 1});
    });

    test('rankOf reports the unranked sentinel for a miss and for null', () {
      final ranks = catalogRanks(['a']);
      expect(rankOf(ranks, 'a'), 0);
      expect(rankOf(ranks, 'nope'), kUnrankedCatalogPosition);
      expect(rankOf(ranks, null), kUnrankedCatalogPosition);
    });
  });

  group('degenerate inputs', () {
    test('an empty or single-item list is returned untouched', () {
      expect(order(const []), isEmpty);
      expect(order([row('only', category: 'news')]), ['only']);
      // Even when that single item is unrankable.
      expect(order([row('only', category: 'gone')]), ['only']);
    });
  });
}
