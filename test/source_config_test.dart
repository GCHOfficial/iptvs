import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  const base = SourceConfig(
    id: 'id1',
    kind: SourceKind.xtream,
    label: 'Provider',
    fields: {'host': 'http://h:80', 'username': 'u', 'password': 'p'},
  );

  group('stable source identity', () {
    test('build uses SourceConfig.id instead of provider credentials', () {
      expect(base.build().id, base.id);
      final changedCredentials = base.copyWith(
        fields: const {
          'host': 'https://different.invalid',
          'username': 'other',
          'password': 'new-secret',
        },
      );
      expect(changedCredentials.build().id, base.id);
    });

    test('legacy namespace exactly matches pre-PR4 derivation', () {
      expect(base.legacyCacheId, 'xtream:http://h:80|u');
      expect(
        base
            .copyWith(
              fields: const {
                'host': 'provider.invalid/',
                'username': 'alice',
                'password': 'secret',
              },
            )
            .legacyCacheId,
        'xtream:http://provider.invalid|alice',
      );
    });
  });

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

    test('build applies persisted catch-up overrides', () {
      final configured = base.copyWith(
        settings: const {
          'catchupTimezone': 'Europe/London',
          'catchupOffsetMinutes': 60,
          'catchupMaxDays': 14,
        },
      );
      final source = configured.build() as XtreamSource;
      expect(source.catchupCapability.timezone, 'Europe/London');
      expect(source.catchupCapability.fixedOffsetMinutes, 60);
      expect(
        source.catchupCapability.maxArchiveWindow,
        const Duration(days: 14),
      );
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

  // IPTVS-K/M/N: `build()` null-asserts credential fields, and the boot path
  // used to call it on the active source — a config that lost its secrets (a
  // cloud pull on an E2EE-locked device) crashed every launch. `tryBuild` is
  // what the boot path uses now.
  group('tryBuild refuses a credential-less config instead of throwing', () {
    SourceConfig of(SourceKind kind, Map<String, String> fields) =>
        SourceConfig(id: 'id1', kind: kind, label: 'L', fields: fields);

    final cases = <String, SourceConfig>{
      'm3u without playlistUrl': of(SourceKind.m3u, const {
        'epgUrl': 'http://guide.invalid/x.xml',
      }),
      'm3u with a blank playlistUrl': of(SourceKind.m3u, const {
        'playlistUrl': '  ',
      }),
      'stalker without mac': of(SourceKind.stalker, const {
        'portal': 'http://portal.invalid/c/',
      }),
      'stalker without portal': of(SourceKind.stalker, const {
        'mac': '00:1A:79:00:00:00',
      }),
      'xtream without password': of(SourceKind.xtream, const {
        'host': 'http://h:80',
        'username': 'u',
      }),
      'xtream without host': of(SourceKind.xtream, const {
        'username': 'u',
        'password': 'p',
      }),
    };
    cases.forEach((name, config) {
      test(name, () {
        expect(config.tryBuild(), isNull);
      });
    });

    test('the bare build() still throws there, which is why boot must not '
        'call it', () {
      expect(
        () => of(SourceKind.m3u, const {}).build(),
        throwsA(isA<TypeError>()),
      );
    });

    test('a complete config builds exactly as build() does', () {
      expect(base.tryBuild()?.id, base.build().id);
      expect(
        of(SourceKind.m3u, const {
          'playlistUrl': 'http://list.invalid/get.m3u',
        }).tryBuild(),
        isNotNull,
      );
      expect(of(SourceKind.demo, const {}).tryBuild(), isNotNull);
    });
  });
}
