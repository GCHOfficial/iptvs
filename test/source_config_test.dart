import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

void main() {
  const base = SourceConfig(
    id: 'id1',
    kind: SourceKind.xtream,
    label: 'Provider',
    fields: {'host': 'http://h:80', 'username': 'u', 'password': 'p'},
  );

  group('settings serialization', () {
    test('omits settings from JSON when empty (legacy-compatible)', () {
      expect(base.toJson().containsKey('settings'), isFalse);
    });

    test('round-trips settings through JSON', () {
      final cfg = base.withHiddenCategories(ContentKind.live, {'a', 'b'});
      final round = SourceConfig.fromJson(cfg.toJson());
      expect(round.hiddenCategoryIds(ContentKind.live), {'a', 'b'});
      expect(round.id, base.id);
      expect(round.kind, base.kind);
      expect(round.fields, base.fields);
    });

    test('fromJson tolerates legacy JSON without a settings key', () {
      final legacy = {
        'id': 'id2',
        'kind': 'demo',
        'label': 'Demo',
        'fields': <String, String>{},
      };
      final cfg = SourceConfig.fromJson(legacy);
      expect(cfg.settings, isEmpty);
      expect(cfg.hiddenCategoryIds(ContentKind.live), isEmpty);
    });
  });

  group('hiddenCategoryIds / withHiddenCategories', () {
    test('defaults to an empty set per kind', () {
      expect(base.hiddenCategoryIds(ContentKind.live), isEmpty);
      expect(base.hiddenCategoryIds(ContentKind.movie), isEmpty);
      expect(base.hiddenCategoryIds(ContentKind.series), isEmpty);
    });

    test('tracks hidden ids independently per kind', () {
      final cfg = base
          .withHiddenCategories(ContentKind.live, {'live1'})
          .withHiddenCategories(ContentKind.movie, {'mov1', 'mov2'});
      expect(cfg.hiddenCategoryIds(ContentKind.live), {'live1'});
      expect(cfg.hiddenCategoryIds(ContentKind.movie), {'mov1', 'mov2'});
      expect(cfg.hiddenCategoryIds(ContentKind.series), isEmpty);
    });

    test('clearing a kind removes its entry; empty clears all settings', () {
      final hidden = base.withHiddenCategories(ContentKind.live, {'x'});
      expect(hidden.settings.containsKey('hiddenCategories'), isTrue);

      final cleared = hidden.withHiddenCategories(ContentKind.live, {});
      expect(cleared.hiddenCategoryIds(ContentKind.live), isEmpty);
      // No leftover empty map, so it serializes back to no settings.
      expect(cleared.toJson().containsKey('settings'), isFalse);
    });

    test('does not mutate the original config', () {
      base.withHiddenCategories(ContentKind.live, {'x'});
      expect(base.hiddenCategoryIds(ContentKind.live), isEmpty);
      expect(base.settings, isEmpty);
    });

    test('copyWith preserves settings unless overridden', () {
      final cfg = base.withHiddenCategories(ContentKind.series, {'s1'});
      final relabeled = cfg.copyWith(label: 'New');
      expect(relabeled.label, 'New');
      expect(relabeled.hiddenCategoryIds(ContentKind.series), {'s1'});
    });
  });
}
