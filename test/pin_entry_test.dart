// The profile-PIN dialog.
//
// Two input surfaces share one dialog and one piece of state, so what is pinned
// here is that neither surface is a special case: the keypad platforms get a
// pad and no IME, the desktop platforms get no pad and type into the same
// buffer, and hardware digits reach the buffer on both. The cooldown is pinned
// because it is the only thing standing between a four-digit PIN and an
// exhaustive search by a determined child.

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/widgets/pin_entry.dart';

void main() {
  // The wrong-PIN history outlives a dialog on purpose, so it also outlives a
  // test case unless it is cleared.
  setUp(debugResetPinAttempts);

  group('pinKeypadForPlatform', () {
    test('desktop types, everything else taps', () {
      expect(pinKeypadForPlatform(TargetPlatform.windows), isFalse);
      expect(pinKeypadForPlatform(TargetPlatform.linux), isFalse);
      expect(pinKeypadForPlatform(TargetPlatform.macOS), isFalse);
      expect(pinKeypadForPlatform(TargetPlatform.android), isTrue);
      expect(pinKeypadForPlatform(TargetPlatform.iOS), isTrue);
    });
  });

  // `debugDefaultTargetPlatformOverride` must be cleared *inside* the test body:
  // the framework checks the foundation debug vars before `addTearDown` runs.
  Future<void> asPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Open an unlock dialog and hand back a getter for its result.
  Future<bool? Function()> pumpUnlock(
    WidgetTester tester, {
    required String verifier,
  }) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                result = await promptUnlockProfile(
                  ctx,
                  profileName: 'Alice',
                  verifier: verifier,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    return () => result;
  }

  /// Reopen the dialog on the host already pumped by [pumpUnlock].
  ///
  /// Not a second `pumpUnlock`: re-pumping a fresh `MaterialApp` *updates* the
  /// existing element tree rather than replacing it, so the `Navigator` keeps
  /// its route stack and the previous dialog can still be on it.
  Future<void> reopen(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpFor(WidgetTester tester, {int frames = 10}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> tapPin(WidgetTester tester, String pin) async {
    for (var i = 0; i < pin.length; i++) {
      await tester.tap(find.text(pin[i]));
      await pumpFor(tester, frames: 4);
    }
    await pumpFor(tester);
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    const keys = <String, LogicalKeyboardKey>{
      '0': LogicalKeyboardKey.digit0,
      '1': LogicalKeyboardKey.digit1,
      '2': LogicalKeyboardKey.digit2,
      '4': LogicalKeyboardKey.digit4,
      '8': LogicalKeyboardKey.digit8,
    };
    for (var i = 0; i < pin.length; i++) {
      await tester.sendKeyEvent(keys[pin[i]]!);
      await pumpFor(tester, frames: 4);
    }
    await pumpFor(tester);
  }

  group('the keypad surface', () {
    testWidgets('the right PIN opens the profile', (tester) async {
      await asPlatform(TargetPlatform.android, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        expect(find.text('1'), findsOneWidget, reason: 'the pad is drawn');

        await tapPin(tester, '4821');
        expect(result(), isTrue);
      });
    });

    testWidgets('a wrong PIN says so and keeps the dialog open', (
      tester,
    ) async {
      await asPlatform(TargetPlatform.android, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        await tapPin(tester, '1111');

        expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
        expect(result(), isNull, reason: 'the dialog is still up');
      });
    });

    testWidgets('cancelling reports a refusal, not a success', (tester) async {
      await asPlatform(TargetPlatform.android, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        await tester.tap(find.text('Cancel'));
        await pumpFor(tester);
        expect(result(), isFalse);
      });
    });

    testWidgets('hardware digits work while the pad is on screen', (
      tester,
    ) async {
      // A TV remote's number keys: the event lands on whichever pad button has
      // focus and bubbles to the dialog.
      await asPlatform(TargetPlatform.android, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        await typePin(tester, '4821');
        expect(result(), isTrue);
      });
    });

    testWidgets('the whole pad is reachable with arrows and Select', (
      tester,
    ) async {
      // The remote's whole vocabulary: arrows and OK. This types 1-4-7-0 by
      // walking the left column and then crossing to the bottom row, which is
      // the one move the lattice does not make obvious — the cell under 7 is
      // the empty corner, so Down from 7 has to find 0 in the middle column.
      await asPlatform(TargetPlatform.android, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );

        Future<void> press(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await pumpFor(tester, frames: 4);
        }

        // 1 is autofocused, so the first press is Select.
        await press(LogicalKeyboardKey.enter);
        for (final _ in [1, 2, 3]) {
          await press(LogicalKeyboardKey.arrowDown);
          await press(LogicalKeyboardKey.enter);
        }
        await pumpFor(tester);

        // Four digits went in — a wrong PIN, but a *complete* one, which is
        // what proves every key on the walk was reachable and activatable.
        expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
        expect(result(), isNull);
      });
    });

    testWidgets('Right and Left cross the pad columns', (tester) async {
      await asPlatform(TargetPlatform.android, () async {
        await pumpUnlock(tester, verifier: hashProfilePin('4821'));

        Future<void> press(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await pumpFor(tester, frames: 4);
        }

        // 1 -> 2 -> 3 -> back to 2, entering 2 3 2 and then 1 to complete.
        await press(LogicalKeyboardKey.arrowRight);
        await press(LogicalKeyboardKey.enter);
        await press(LogicalKeyboardKey.arrowRight);
        await press(LogicalKeyboardKey.enter);
        await press(LogicalKeyboardKey.arrowLeft);
        await press(LogicalKeyboardKey.enter);
        await press(LogicalKeyboardKey.arrowLeft);
        await press(LogicalKeyboardKey.enter);
        await pumpFor(tester);

        expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      });
    });

    testWidgets('too many misses start a cooldown', (tester) async {
      await asPlatform(TargetPlatform.android, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        for (var i = 0; i < kPinAttemptsBeforeLockout; i++) {
          await tapPin(tester, '1111');
        }

        expect(find.textContaining('Too many attempts'), findsOneWidget);

        // And the cooldown really refuses input — the correct PIN does not open
        // the profile while it runs.
        await tapPin(tester, '4821');
        expect(result(), isNull);

        // Let the periodic countdown timer expire so the test does not end with
        // a pending timer.
        await tester.pump(kPinLockout + const Duration(seconds: 1));
        await tester.tap(find.text('Cancel'));
        await pumpFor(tester);
      });
    });
  });

  testWidgets('the wrong-PIN count survives closing the dialog', (tester) async {
    // The bypass this pins: four misses, Back, re-select the profile, four more
    // — indefinitely — because the counter lived in the dialog's own state.
    await asPlatform(TargetPlatform.android, () async {
      final verifier = hashProfilePin('4821');
      await pumpUnlock(tester, verifier: verifier);
      for (var i = 0; i < kPinAttemptsBeforeLockout - 1; i++) {
        await tapPin(tester, '1111');
      }
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await pumpFor(tester, frames: 30);

      // Reopened for the same profile: the next miss is the fifth, not the
      // first.
      await reopen(tester);
      await tapPin(tester, '1111');
      expect(find.textContaining('Too many attempts'), findsOneWidget);

      await tester.pump(kPinLockout + const Duration(seconds: 1));
      await tester.tap(find.text('Cancel'));
      await pumpFor(tester);
    });
  });

  testWidgets('a correct PIN forgives the misses before it', (tester) async {
    await asPlatform(TargetPlatform.android, () async {
      final verifier = hashProfilePin('4821');
      final result = await pumpUnlock(tester, verifier: verifier);
      for (var i = 0; i < kPinAttemptsBeforeLockout - 1; i++) {
        await tapPin(tester, '1111');
      }
      await tapPin(tester, '4821');
      expect(result(), isTrue);
      await pumpFor(tester, frames: 30);

      // Four fresh tries, not one: proving you know the PIN clears the history.
      await reopen(tester);
      for (var i = 0; i < kPinAttemptsBeforeLockout - 1; i++) {
        await tapPin(tester, '1111');
      }
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      expect(find.textContaining('Too many attempts'), findsNothing);
    });
  });

  group('the desktop surface', () {
    testWidgets('draws no pad and takes the keyboard', (tester) async {
      await asPlatform(TargetPlatform.windows, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        expect(find.text('1'), findsNothing, reason: 'no pad on desktop');
        expect(find.text('Type the digits on your keyboard.'), findsOneWidget);

        await typePin(tester, '4821');
        expect(result(), isTrue);
      });
    });

    testWidgets('backspace corrects a mistyped digit', (tester) async {
      await asPlatform(TargetPlatform.windows, () async {
        final result = await pumpUnlock(
          tester,
          verifier: hashProfilePin('4821'),
        );
        await typePin(tester, '482');
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await pumpFor(tester, frames: 4);
        await typePin(tester, '21');
        expect(result(), isTrue);
      });
    });
  });

  testWidgets('a verifier this build cannot read keeps the profile shut', (
    tester,
  ) async {
    await asPlatform(TargetPlatform.android, () async {
      final result = await pumpUnlock(tester, verifier: 'pbkdf2-sha999(bad)');
      expect(find.textContaining('newer version'), findsOneWidget);
      expect(find.text('1'), findsNothing, reason: 'nothing to type into');

      // With no pad there is nothing for the D-pad to land on, so Cancel takes
      // the focus: one OK press has to be enough to get out, or the remote is
      // stuck on a dialog it can do nothing with.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFor(tester);
      expect(result(), isFalse);
    });
  });

  testWidgets('choosing a PIN requires it twice', (tester) async {
    await asPlatform(TargetPlatform.android, () async {
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  chosen = await promptNewProfilePin(ctx, profileName: 'Alice');
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();

      await tapPin(tester, '4821');
      expect(find.text('Confirm the PIN'), findsOneWidget);

      await tapPin(tester, '4822');
      expect(find.textContaining('did not match'), findsOneWidget);
      expect(chosen, isNull);

      await tapPin(tester, '4821');
      await tapPin(tester, '4821');
      expect(chosen, '4821');
    });
  });
}
