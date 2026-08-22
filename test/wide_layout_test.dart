// Which devices get the wide (two-pane) browsing layout.
//
// Everything about the browsing UI turns on this one predicate: the category
// side-pane, the live preview panel, and therefore whether the shared-engine
// preview path exists at all. It used to be a bare width comparison, and on a
// television that measures the wrong thing — logical width is physical pixels
// divided by the device pixel ratio, so a 3840 px screen reports 960 at dpr 4.0
// and 873 at dpr 4.4. A 4K TV therefore landed either side of the breakpoint
// depending on a density it chose for itself, and the phone layout it fell into
// was silent: every branch agreed, they were just all measuring the wrong thing.

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/device_class.dart';
import 'package:iptvs/theme.dart';

void main() {
  // Process-global by design (a device does not change class mid-run), so it
  // has to be put back or every later test in the suite inherits it.
  tearDown(() => debugIsTelevision = false);

  group('not a television', () {
    test('follows the width breakpoint', () {
      debugIsTelevision = false;
      expect(isWideLayout(const Size(kWideLayoutMinWidth, 600)), isTrue);
      expect(isWideLayout(const Size(kWideLayoutMinWidth - 1, 600)), isFalse);
    });

    test('a large phone in landscape still gets the phone layout', () {
      // The band the breakpoint exists to exclude — the reason the fix is TV
      // detection rather than simply lowering the number.
      debugIsTelevision = false;
      expect(isWideLayout(const Size(915, 412)), isFalse);
    });
  });

  group('television', () {
    test('is wide at every density a 4K panel can report', () {
      debugIsTelevision = true;
      // 3840 physical at dpr 4.0, 4.4 and 5.0 — the last two fall under the
      // breakpoint and used to render the handset UI on a 65-inch screen.
      for (final width in const [960.0, 872.7, 768.0]) {
        expect(
          isWideLayout(Size(width, width * 9 / 16)),
          isTrue,
          reason: 'a TV reporting ${width}dp must still be the ten-foot layout',
        );
      }
    });

    test('is wide even below the breakpoint entirely', () {
      debugIsTelevision = true;
      expect(isWideLayout(const Size(640, 360)), isTrue);
    });
  });

  test('detection defaults to false so non-Android is unaffected', () {
    // `detectDeviceClass` fails closed; nothing but an affirmative platform
    // answer may turn this on.
    expect(isTelevision, isFalse);
  });
}
