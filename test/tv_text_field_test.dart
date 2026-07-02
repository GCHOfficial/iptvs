// Widget tests for TvTextField — guards the edit-mode behaviour and, critically,
// that it builds under a plain Navigator (it must not use Router-only APIs like
// BackButtonListener, which threw "context does not include a Router").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
          body: TvTextField(controller: controller, hintText: 'Search channels'),
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
}
