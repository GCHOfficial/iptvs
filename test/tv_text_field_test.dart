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
