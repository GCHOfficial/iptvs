// The aspect cycle used to be private to `_PlayerScreenState`, so the Kotlin
// and Swift sides were pinned and the Dart side was not. It is shared and
// public now, which is what makes these possible.
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/player/aspect_mode.dart';

void main() {
  group('the cycle', () {
    test('is the five modes every surface renders, in order', () {
      expect(
        kAspectModes.map((m) => m.label),
        ['Fit', 'Fill', 'Stretch', '16:9', '4:3'],
      );
    });

    test('Fill crops and Stretch distorts — they are not the same mode', () {
      // The distinction is the whole reason both exist. Fill keeps the
      // picture's shape and loses the edges; Stretch keeps every pixel and
      // loses the shape. Collapsing them is easy and silently removes the mode
      // users ask for by name.
      final fill = kAspectModes[aspectModeIndexOf('Fill')];
      final stretch = kAspectModes[aspectModeIndexOf('Stretch')];

      expect(fill.fit, BoxFit.cover);
      expect(fill.panscan, '1.0');
      expect(fill.keepaspect, 'yes');

      expect(stretch.fit, BoxFit.fill);
      expect(stretch.keepaspect, 'no');
      expect(stretch.panscan, '0.0');
    });

    test('every mode restores keepaspect unless it is Stretch', () {
      // The modes are cycled, so leaving Stretch has to undo it on the very
      // next press — a mode that only sets what it needs leaves the picture
      // distorted in Fit.
      for (final mode in kAspectModes) {
        expect(
          mode.keepaspect,
          mode.label == 'Stretch' ? 'no' : 'yes',
          reason: mode.label,
        );
      }
    });

    test('a forced ratio letterboxes whatever shape it produces', () {
      for (final label in ['16:9', '4:3']) {
        final mode = kAspectModes[aspectModeIndexOf(label)];
        expect(mode.aspect, label);
        expect(mode.fit, BoxFit.contain);
        expect(mode.panscan, '0.0');
      }
    });
  });

  group('aspectModeIndexOf', () {
    test('finds a label regardless of case', () {
      expect(aspectModeIndexOf('Fit'), 0);
      expect(aspectModeIndexOf('stretch'), 2);
      expect(aspectModeIndexOf('4:3'), 4);
    });

    test('reports -1 for anything it does not know', () {
      // A label a *newer* build wrote must not resolve to an arbitrary mode.
      expect(aspectModeIndexOf(null), -1);
      expect(aspectModeIndexOf(''), -1);
      expect(aspectModeIndexOf('Zoom'), -1);
    });
  });

  group('the default', () {
    tearDown(() => debugIsTelevision = false);

    test('is Fill on a television', () {
      // A TV screen is a fixed shape that usually matches the content, so Fill
      // and Fit are identical there — they differ only on 4:3 material, where
      // filling the screen is what a television viewer expects.
      debugIsTelevision = true;
      expect(kAspectModes[defaultAspectModeIndex()].label, 'Fill');
    });

    test('follows the platform when it is not a television', () {
      debugIsTelevision = false;
      final expected = Platform.isAndroid || Platform.isIOS ? 'Fill' : 'Fit';
      expect(kAspectModes[defaultAspectModeIndex()].label, expected);
    });

    test('is Fit on this desktop host', () {
      // Guarded so it states what it means rather than passing vacuously.
      if (Platform.isAndroid || Platform.isIOS) return;
      debugIsTelevision = false;
      expect(
        kAspectModes[defaultAspectModeIndex()].label,
        'Fit',
        reason: 'a desktop window is an arbitrary shape, so cropping it is '
            'wrong — the crop would change every time it is resized',
      );
    });
  });

  group('resolveAspectModeIndex', () {
    tearDown(() => debugIsTelevision = false);

    test('honours a stored choice over the default', () {
      debugIsTelevision = true; // default would be Fill
      expect(kAspectModes[resolveAspectModeIndex('Fit')].label, 'Fit');
      expect(kAspectModes[resolveAspectModeIndex('4:3')].label, '4:3');
    });

    test('falls back to the default when nothing is stored', () {
      debugIsTelevision = true;
      expect(kAspectModes[resolveAspectModeIndex(null)].label, 'Fill');
    });

    test('falls back when the stored label is one this build lost', () {
      // Rather than throwing or landing on index 0 by accident.
      debugIsTelevision = true;
      expect(kAspectModes[resolveAspectModeIndex('Zoom')].label, 'Fill');
    });

    test('always returns an index that is in range', () {
      for (final label in [null, '', 'Fit', 'nonsense', '4:3']) {
        final index = resolveAspectModeIndex(label);
        expect(index, inInclusiveRange(0, kAspectModes.length - 1));
      }
    });
  });
}
