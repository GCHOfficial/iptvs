// Widget tests for TvTextField — guards the edit-mode behaviour and, critically,
// that it builds under a plain Navigator (it must not use Router-only APIs like
// BackButtonListener, which threw "context does not include a Router").

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

void main() {
  testWidgets('builds under a Navigator (no Router) and shows its hint', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Search channels'), findsOneWidget);
  });

  testWidgets('tapping enters edit mode and accepts input', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(controller: controller, hintText: 'hint'),
        ),
      ),
    );

    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), 'hello');
    expect(controller.text, 'hello');
  });

  testWidgets('Back closes edit mode and restores focus to the search cell', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final cellFocus = RoutedFocusNode('search.cell');
    addTearDown(cellFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
            cellFocusNode: cellFocus,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TvTextField));
    await tester.pumpAndSettle();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.field',
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(focusRouteKey(FocusManager.instance.primaryFocus), 'search.cell');
    expect(find.byType(TvTextField), findsOneWidget);
  });

  // Regression guard for the recurring "hint sits high on Android" bug: with
  // prefix/suffix icons inside the InputDecoration, the InputDecorator's
  // dense-layout vertical centering differed between platforms. The icons now
  // live in a manually centered Row, and these assertions pin the geometry on
  // both platforms so a future decorator change can't silently reintroduce it.
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('hint is vertically centered in the cell on $platform', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: TvTextField(
                  controller: controller,
                  hintText: 'Search channels',
                  height: 40,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final cellRect = tester.getRect(
        find.descendant(
          of: find.byType(TvTextField),
          matching: find.byType(Container),
        ),
      );
      final hintRect = tester.getRect(find.text('Search channels'));
      expect(
        hintRect.center.dy,
        moreOrLessEquals(cellRect.center.dy, epsilon: 1.0),
        reason: 'hint must be vertically centered within the 40px cell',
      );

      // Typed text must share the hint's geometry.
      await tester.tap(find.byType(TvTextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bbc');
      await tester.pump();
      final textRect = tester.getRect(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        textRect.center.dy,
        moreOrLessEquals(cellRect.center.dy, epsilon: 1.0),
        reason: 'entered text must be vertically centered within the cell',
      );
    });
  }

  // Regression guard for the double-border bug: under the app theme (whose
  // InputDecorationTheme sets OutlineInputBorders), a decoration that leaves
  // any border slot null gets it filled by applyDefaults — the InputDecorator
  // then paints a second rounded box *inside* the cell's own border. The
  // InputDecoration.collapsed constructor only sets `border`, so reverting to
  // it reintroduces the bug; this pins every slot to InputBorder.none.
  testWidgets('inner field paints no border under the app theme', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TvTextField(controller: controller, hintText: 'hint'),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    final decoration = field.decoration!.applyDefaults(
      Theme.of(tester.element(find.byType(TextField))).inputDecorationTheme,
    );
    expect(decoration.border, InputBorder.none);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
    expect(decoration.errorBorder, InputBorder.none);
    expect(decoration.focusedErrorBorder, InputBorder.none);
    expect(decoration.disabledBorder, InputBorder.none);
    expect(decoration.filled, isFalse);
  });

  testWidgets('renders an external label when provided', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Paste key',
            label: 'TMDB API credential',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('TMDB API credential'), findsOneWidget);
  });

  // The clear (×) button is a sibling always-focusable stop *outside* the edit
  // barrier (the same pattern as the password show/hide toggle) — a suffixIcon
  // inside the barrier can never be reached by D-pad, which left the search
  // box's clear unusable on TV.
  testWidgets('clear button is a focusable D-pad stop and clears on OK', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'bbc');
    addTearDown(controller.dispose);
    var cleared = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'Search channels',
            showClear: true,
            onClear: () {
              cleared++;
              controller.clear();
            },
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.clear), findsOneWidget);

    // It's a real focus stop, reachable outside edit mode.
    final detector = tester.widget<FocusableActionDetector>(
      find
          .ancestor(
            of: find.byIcon(Icons.clear),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    final clearNode = detector.focusNode!;
    // Pin the release-safe route key the Back ladder branches on.
    expect(focusRouteKey(clearNode), 'TvTextField.clear');

    clearNode.requestFocus();
    await tester.pump();
    expect(
      clearNode.hasPrimaryFocus,
      isTrue,
      reason: 'the clear button must be focusable without entering edit mode',
    );

    // OK activates it: the field is cleared and focus is parked back on the
    // cell (the button disappears once the text empties).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(cleared, 1);
    expect(controller.text, isEmpty);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.cell',
      reason: 'after clearing, focus returns to the cell',
    );
  });

  testWidgets('a suffixIcon still renders when the clear button is off', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextField(
            controller: controller,
            hintText: 'hint',
            suffixIcon: const Icon(Icons.tune, size: 18),
            onClear: () {},
            // showClear defaults to false → the suffix slot falls back.
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byIcon(Icons.clear), findsNothing);
  });
}
