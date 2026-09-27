// The quick list's pure value layer: the window arithmetic four renderers
// depend on, the preformatted time labels they must not re-derive, and the
// frozen `setQuickList` payload shape (docs/player.md "Live zapping — the
// quick list").

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/zap_quick_list.dart';

void main() {
  group('zapWindowStart', () {
    test('a list shorter than the window is never offset', () {
      for (var total = 0; total <= kZapWindowRows; total++) {
        for (var selected = 0; selected < total; selected++) {
          expect(
            zapWindowStart(total: total, selected: selected),
            0,
            reason: 'total=$total selected=$selected',
          );
        }
      }
    });

    test('centres the cursor in the middle of a long list', () {
      expect(
        zapWindowStart(total: 1000, selected: 500),
        500 - kZapWindowRows ~/ 2,
      );
    });

    test('clamps at both ends instead of running off the list', () {
      expect(zapWindowStart(total: 1000, selected: 0), 0);
      expect(zapWindowStart(total: 1000, selected: 3), 0);
      expect(zapWindowStart(total: 1000, selected: 999), 1000 - kZapWindowRows);
      expect(
        zapWindowStart(total: 250000, selected: 249999),
        250000 - kZapWindowRows,
      );
    });

    test('the window always contains the cursor, at every index', () {
      // The property that matters: a window that misses the cursor draws a
      // list with no visible selection, which on a remote reads as a frozen
      // screen.
      for (final total in const [1, 2, 39, 40, 41, 97, 250000]) {
        for (final selected in <int>{0, 1, total ~/ 2, total - 2, total - 1}) {
          if (selected < 0 || selected >= total) continue;
          final start = zapWindowStart(total: total, selected: selected);
          final end = start + kZapWindowRows;
          expect(start, greaterThanOrEqualTo(0));
          expect(
            selected,
            allOf(greaterThanOrEqualTo(start), lessThan(end)),
            reason: 'total=$total selected=$selected start=$start',
          );
          expect(start, lessThanOrEqualTo(total));
        }
      }
    });

    test('a degenerate window never produces a negative start', () {
      expect(zapWindowStart(total: 100, selected: 50, window: 0), 0);
      expect(zapWindowStart(total: 100, selected: 50, window: -3), 0);
      expect(zapWindowStart(total: 0, selected: 0), 0);
    });
  });

  group('time labels', () {
    test('are 24-hour and zero-padded, with the strip en dash', () {
      final start = DateTime(2024, 3, 4, 9, 5);
      final stop = DateTime(2024, 3, 4, 21, 30);
      expect(zapTimeLabel(start), '09:05');
      expect(zapTimeLabel(stop), '21:30');
      expect(zapTimeRangeLabel(start, stop), '09:05 – 21:30');
    });
  });

  group('payload', () {
    ZapQuickListRow row(int i) => ZapQuickListRow(
      index: i,
      id: 'r$i',
      label: 'Row $i',
      kind: ZapQuickListRowKind.programme,
      secondary: '10:00 – 11:00',
      badge: 'CATCH-UP',
      selected: i == 1,
      archive: true,
      past: true,
    );

    test('the closed state is a tear-down instruction, not an absence', () {
      final payload = ZapQuickListState.closed.toPayload();
      expect(payload['open'], isFalse);
      expect(payload['rows'], isEmpty);
      expect(payload['total'], 0);
    });

    test('carries every field a renderer needs, and survives JSON', () {
      final state = ZapQuickListState(
        open: true,
        mode: ZapQuickListMode.schedule,
        heading: 'BBC One',
        rows: [row(0), row(1), row(2)],
        selectedIndex: 1,
        windowStart: 0,
        total: 3,
        revision: 9,
      );
      final decoded =
          jsonDecode(jsonEncode(state.toPayload())) as Map<String, Object?>;
      expect(decoded['mode'], 'schedule');
      expect(decoded['heading'], 'BBC One');
      expect(decoded['selectedIndex'], 1);
      expect(decoded['windowStart'], 0);
      expect(decoded['total'], 3);
      expect(decoded['loading'], isFalse);
      expect(decoded['revision'], 9);
      final rows = decoded['rows']! as List<Object?>;
      final second = rows[1]! as Map<String, Object?>;
      expect(second['index'], 1);
      expect(second['id'], 'r1');
      expect(second['label'], 'Row 1');
      expect(second['kind'], 'programme');
      expect(second['secondary'], '10:00 – 11:00');
      expect(second['badge'], 'CATCH-UP');
      expect(second['selected'], isTrue);
      expect(second['playing'], isFalse);
      expect(second['archive'], isTrue);
      expect(second['past'], isTrue);
      expect(second['live'], isFalse);
      // Absent rather than null: a renderer tests presence, so an optional
      // string must not arrive as a null it has to special-case.
      expect((rows[0]! as Map<String, Object?>).containsKey('secondary'), true);
      expect(decoded.containsKey('emptyLabel'), isFalse);
    });

    test('selectedInWindow is the offset a renderer scrolls by', () {
      final state = ZapQuickListState(
        open: true,
        mode: ZapQuickListMode.channels,
        heading: 'All channels',
        rows: [row(100), row(101), row(102)],
        selectedIndex: 101,
        windowStart: 100,
        total: 5000,
      );
      expect(state.selectedInWindow, 1);
      expect(ZapQuickListState.closed.selectedInWindow, -1);
      expect(ZapQuickListState.closed.isEmpty, isTrue);
    });

    test('value equality holds, so an unchanged push can be skipped', () {
      final a = ZapQuickListState(
        open: true,
        mode: ZapQuickListMode.channels,
        heading: 'A',
        rows: [row(0)],
        selectedIndex: 0,
        windowStart: 0,
        total: 1,
      );
      final b = ZapQuickListState(
        open: true,
        mode: ZapQuickListMode.channels,
        heading: 'A',
        rows: [row(0)],
        selectedIndex: 0,
        windowStart: 0,
        total: 1,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
