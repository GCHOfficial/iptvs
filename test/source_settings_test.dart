import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/source_settings_screen.dart';

void main() {
  group('bulkToggleHidden', () {
    test('hide adds the affected ids to the current set (union)', () {
      final next = bulkToggleHidden({'a'}, ['b', 'c'], hide: true);
      expect(next, {'a', 'b', 'c'});
    });

    test('show removes the affected ids (difference)', () {
      final next = bulkToggleHidden({'a', 'b', 'c'}, ['b', 'c'], hide: false);
      expect(next, {'a'});
    });

    test('hide leaves off-screen (unaffected) ids untouched', () {
      // 'x' is hidden but not in the filtered subset — must survive.
      final next = bulkToggleHidden({'x'}, ['a', 'b'], hide: true);
      expect(next, {'x', 'a', 'b'});
    });

    test('show only reveals ids in the affected subset', () {
      final next = bulkToggleHidden({'x', 'a'}, ['a'], hide: false);
      expect(next, {'x'});
    });

    test('does not mutate the input set', () {
      final current = {'a'};
      bulkToggleHidden(current, ['b'], hide: true);
      expect(current, {'a'});
    });

    test('empty affected is a no-op for both directions', () {
      expect(bulkToggleHidden({'a'}, const [], hide: true), {'a'});
      expect(bulkToggleHidden({'a'}, const [], hide: false), {'a'});
    });
  });

  group('nextStreamExtension', () {
    test('cycles unset -> ts -> m3u8 -> unset', () {
      expect(nextStreamExtension(null), 'ts');
      expect(nextStreamExtension('ts'), 'm3u8');
      expect(nextStreamExtension('m3u8'), null);
    });

    test('an unrecognised stored value is treated as unset', () {
      // Same fallback resolveXtreamStreamExtension applies — anything outside
      // {null, 'ts', 'm3u8'} starts the cycle over rather than getting stuck.
      expect(nextStreamExtension('mkv'), 'ts');
    });
  });
}
