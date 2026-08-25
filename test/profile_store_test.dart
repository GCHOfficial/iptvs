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

  test('snapshot restore preview reports effects without source fields', () {
    const current = ProfileSnapshot(
      sourcesJson: [
        {
          'id': 'keep',
          'label': 'Current',
          'fields': {'password': 'must-not-appear'},
        },
        {'id': 'remove', 'label': 'Remove', 'fields': {}},
      ],
      activeSourceId: 'remove',
      metadataJson: {'provider': 'tmdb'},
    );
    const target = ProfileSnapshot(
      sourcesJson: [
        {'id': 'keep', 'label': 'Current', 'fields': {}},
        {
          'id': 'add',
          'label': 'Living room',
          'fields': {'url': 'https://user:secret@example.invalid'},
        },
      ],
      activeSourceId: 'add',
      metadataJson: {'provider': 'tvdb'},
      managedIds: ['add'],
    );

    final preview = previewSnapshotRestore(current, target);
    expect(preview.sourcesAdded, 1);
    expect(preview.sourcesRemoved, 1);
    expect(preview.sourcesRetained, 1);
    expect(preview.activeSourceLabel, 'Living room');
    expect(preview.metadataChanges, isTrue);
    expect(preview.managedSources, 1);
    expect(preview.toString(), isNot(contains('must-not-appear')));
    expect(preview.toString(), isNot(contains('secret')));
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
      expect(shouldShowPickerAtStartup(ProfilePickerStartup.auto, 0), isTrue);
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

    test('an ownerless device overrides every mode', () {
      // Profiles exist but none is active — the state left behind by deleting
      // the active profile. The picker is the only thing that can restore a
      // snapshot, so short-circuiting past it boots into a library no profile
      // owns, and with one profile left `auto` would never open it again.
      for (final mode in ProfilePickerStartup.values) {
        for (final count in [1, 5]) {
          expect(
            shouldShowPickerAtStartup(mode, count, hasActiveProfile: false),
            isTrue,
            reason: '$mode with $count profiles',
          );
        }
      }
      // A fresh install (no profiles at all) keeps its per-mode answer.
      expect(
        shouldShowPickerAtStartup(
          ProfilePickerStartup.off,
          0,
          hasActiveProfile: false,
        ),
        isFalse,
      );
      expect(
        shouldShowPickerAtStartup(ProfilePickerStartup.off, 1),
        isFalse,
        reason: 'an owned single profile still boots straight through',
      );
    });

    test('a locked active profile overrides every mode', () {
      // Otherwise the gate would exist only for accounts that happen to have
      // several profiles and have left the picker on — which is not a gate.
      for (final mode in ProfilePickerStartup.values) {
        for (final count in [1, 5]) {
          expect(
            shouldShowPickerAtStartup(mode, count, activeProfileLocked: true),
            isTrue,
            reason: '$mode with $count profiles',
          );
        }
      }
      expect(
        shouldShowPickerAtStartup(
          ProfilePickerStartup.off,
          1,
          activeProfileLocked: false,
        ),
        isFalse,
        reason: 'an open profile still boots straight through',
      );
    });
  });

  group('profile PINs', () {
    test('the verifier round-trips and an absent one stays absent', () {
      const open = LocalProfile(id: 'p1', name: 'Alice', colorIndex: 0);
      expect(open.locked, isFalse);
      expect(open.toJson().containsKey('pin'), isFalse);
      expect(LocalProfile.fromJson(open.toJson()).locked, isFalse);

      final locked = open.withPin('pbkdf2-sha256\$1\$c2FsdA==\$aGFzaA==');
      expect(locked.locked, isTrue);
      final restored = LocalProfile.fromJson(locked.toJson());
      expect(restored.pin, locked.pin);
      expect(restored.name, 'Alice');
    });

    test('withPin(null) clears it, and withSnapshot carries it', () {
      const open = LocalProfile(id: 'p1', name: 'Alice', colorIndex: 0);
      final locked = open.withPin('x');
      expect(locked.withPin(null).locked, isFalse);
      expect(
        locked.withSnapshot(const ProfileSnapshot()).pin,
        'x',
        reason: 'switching profiles must not silently unlock one',
      );
    });

    test('a blank stored pin reads as no pin', () {
      // Both stores normalise empty to absent, so a row written by either one
      // has to mean the same thing here.
      final blank = LocalProfile.fromJson({
        'id': 'p1',
        'name': 'Alice',
        'pin': '   ',
      });
      expect(blank.locked, isFalse);
    });
  });

  group('CloudProfileLock', () {
    test('round-trips, and a verifier-less entry is dropped', () {
      const lock = CloudProfileLock(verifier: 'v', name: 'Family');
      final restored = CloudProfileLock.fromJson(lock.toJson());
      expect(restored?.verifier, 'v');
      expect(restored?.name, 'Family');
      // The cache holds *locked* profiles only: an entry with no verifier is
      // meaningless, and reading one as a lock would shut a profile nobody
      // locked.
      expect(CloudProfileLock.fromJson({'name': 'Family'}), isNull);
      expect(CloudProfileLock.fromJson({'pin': '', 'name': 'x'}), isNull);
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
