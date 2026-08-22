/// Ordering for the Favorites views.
///
/// Favorites carry **no order of their own, by design**: they are stored as a
/// set keyed by `(source_id, kind, item_id)` (`favorites`) and synced as a
/// delta of adds/removes (`push_favorites_delta`), precisely so two devices
/// touching different rows can't conflict. Nothing in that design has a place
/// to put a user-chosen sequence, and adding one would mean giving every
/// favorite a position that two devices could then disagree about — the exact
/// class of conflict the delta exists to avoid.
///
/// So the order has to be *derived*, and the only order a user has already
/// agreed to is the one they browse in: their source list, the category order
/// inside a source, and the channel order inside a category. This file is that
/// rule, kept pure so it can be tested without a database or a widget tree.
///
/// The alternative — insertion order — is what a plain set iteration or an
/// unordered query happens to produce, and it is what every other player is
/// *not* doing: favouriting Pro before TVR1 should not move Pro above TVR1 in
/// a list where TVR1 comes first.
library;

/// Rank given to an item whose category (or source) isn't in the reference
/// order at all — a favorite from a category the provider has since dropped,
/// or one whose `categoryId` is null. Sorts last, keeping its relative order
/// with its neighbours rather than being discarded.
///
/// Deliberately not `-1`/`0`: those sort *first*, which would put the least
/// identifiable rows at the top of the list.
const int kUnrankedCatalogPosition = 1 << 30;

/// Reorders [items] into catalog reading order — source order, then category
/// order, then whatever order [items] already had.
///
/// **Callers must pass [items] already in catalog order within a source**
/// (filtered straight out of `LibrarySnapshot.channels`, or out of a query
/// ordered the same way `readChannels` is). That incoming order is what
/// survives as the innermost tie-break, which is why there is no `itemRank`
/// parameter: reusing the order that is already correct is both cheaper than
/// building an index over a 250k-channel list and impossible to get out of step
/// with it.
///
/// [sourceRank] is null for a single-source view, where every row would score
/// the same anyway.
///
/// The tie-break is explicit because **`List.sort` is not stable in Dart** —
/// without it, favorites inside one category would shuffle between rebuilds on
/// exactly the list sizes where an unstable introsort starts partitioning.
List<T> orderedByCatalog<T>(
  List<T> items, {
  int Function(T item)? sourceRank,
  required int Function(T item) categoryRank,
}) {
  if (items.length < 2) return items;
  final decorated = [
    for (var i = 0; i < items.length; i++)
      (
        source: sourceRank == null ? 0 : sourceRank(items[i]),
        category: categoryRank(items[i]),
        given: i,
        value: items[i],
      ),
  ];
  decorated.sort((a, b) {
    final bySource = a.source.compareTo(b.source);
    if (bySource != 0) return bySource;
    final byCategory = a.category.compareTo(b.category);
    if (byCategory != 0) return byCategory;
    return a.given.compareTo(b.given);
  });
  return [for (final row in decorated) row.value];
}

/// Builds the id → position lookup [orderedByCatalog] ranks against.
///
/// A duplicate id keeps its **first** position: a provider that lists the same
/// category twice shouldn't move every channel in it to the later slot.
Map<String, int> catalogRanks(Iterable<String> orderedIds) {
  final ranks = <String, int>{};
  var index = 0;
  for (final id in orderedIds) {
    ranks.putIfAbsent(id, () => index);
    index++;
  }
  return ranks;
}

/// The rank of [id] in [ranks], or [kUnrankedCatalogPosition] when it isn't
/// there (including for a null id — an uncategorised favorite).
int rankOf(Map<String, int> ranks, String? id) =>
    id == null ? kUnrankedCatalogPosition : ranks[id] ?? kUnrankedCatalogPosition;
