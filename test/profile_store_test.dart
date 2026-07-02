// Pure-logic tests for the local-profile layer: snapshot/profile JSON
// round-trips, the boot-time picker decision, and the stable avatar colour
// derivation. Storage-level behaviour rides on flutter_secure_storage and is
// exercised on-device.
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/widgets/profile_avatar.dart';

void main() {
  group('ProfileSnapshot JSON', () {
    test('round-trips all fields', () {
      const snapshot = ProfileSnapshot(
        sourcesJson: [
          {'id': 'a', 'kind': 'demo', 'label': 'Demo', 'fields': {}},
          {
            'id': 'b',
            'kind': 'xtream',
            'label': 'X',
            'fields': {'url': 'http://x'},
          },
        ],
        activeSourceId: 'b',
        metadataJson: {'provider': 'tmdb', 'tmdbApiKey': 'k'},
        managedIds: ['b'],
      );
      final restored = ProfileSnapshot.fromJson(snapshot.toJson());
      expect(restored.sourcesJson, snapshot.sourcesJson);
      expect(restored.activeSourceId, 'b');
      expect(restored.metadataJson, snapshot.metadataJson);
      expect(restored.managedIds, ['b']);
    });

    test('defaults survive a round-trip (empty profile stays empty)', () {
      const snapshot = ProfileSnapshot();
      final restored = ProfileSnapshot.fromJson(snapshot.toJson());
      expect(restored.sourcesJson, isEmpty);
      expect(restored.activeSourceId, isNull);
      expect(restored.metadataJson, isNull);
      expect(restored.managedIds, isEmpty);
    });
  });

  group('LocalProfile JSON', () {
    test('round-trips with its snapshot', () {
      const profile = LocalProfile(
        id: 'p1',
        name: 'Kids',
        colorIndex: 3,
        snapshot: ProfileSnapshot(
          sourcesJson: [
            {'id': 'demo', 'kind': 'demo', 'label': 'Demo', 'fields': {}},
          ],
          activeSourceId: 'demo',
        ),
      );
      final restored = LocalProfile.fromJson(profile.toJson());
      expect(restored.id, 'p1');
      expect(restored.name, 'Kids');
      expect(restored.colorIndex, 3);
      expect(restored.snapshot.activeSourceId, 'demo');
      expect(restored.snapshot.sourcesJson, hasLength(1));
    });

    test('withSnapshot replaces only the snapshot', () {
      const profile = LocalProfile(id: 'p1', name: 'Kids', colorIndex: 3);
      final updated = profile.withSnapshot(
        const ProfileSnapshot(activeSourceId: 'x'),
      );
      expect(updated.id, 'p1');
      expect(updated.name, 'Kids');
      expect(updated.colorIndex, 3);
      expect(updated.snapshot.activeSourceId, 'x');
    });

    test('tolerates a missing snapshot key', () {
      final restored = LocalProfile.fromJson({'id': 'p2', 'name': 'Solo'});
      expect(restored.snapshot.sourcesJson, isEmpty);
      expect(restored.colorIndex, 0);
    });
  });

  group('shouldShowPickerAtStartup', () {
    test('auto shows only with more than one profile', () {
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.auto, 0), isFalse);
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.auto, 1), isFalse);
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.auto, 2), isTrue);
    });

    test('always shows regardless of count', () {
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.always, 0), isTrue);
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.always, 5), isTrue);
    });

    test('off never shows', () {
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.off, 0), isFalse);
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.off, 5), isFalse);
    });
  });

  group('profileColorIndexFor', () {
    test('is stable for a given id and within the palette', () {
      const id = '4d0244f4-9a3c-4c9e-9a1a-2f6e0f6f8b21';
      final first = profileColorIndexFor(id);
      expect(profileColorIndexFor(id), first);
      expect(first, inInclusiveRange(0, kProfileAvatarColors.length - 1));
    });

    test('does not depend on list position (differs across typical ids)', () {
      // Not guaranteed collision-free in general — just check the derivation
      // actually varies with the id rather than returning a constant.
      final indexes = {
        for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
          profileColorIndexFor(id),
      };
      expect(indexes.length, greaterThan(1));
    });
  });
}
