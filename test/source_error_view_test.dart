// The retry on a failed source load must be reachable from a TV remote.
//
// The live tab's body is a *selection model*, not a focus tree — its rows are
// not focus targets — and when a load fails there are no rows at all. Nothing
// in the error body was focusable on arrival, so on a television the "Try
// again" button was visible, was the only action on screen, and could not be
// pressed: the first OK went nowhere and there was nothing to arrow towards.
// A source that fails to load is exactly the moment a user cannot route around
// the problem, so this is pinned rather than left to the widget's own default.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/widgets/source_error_view.dart';

void main() {
  Future<void> pumpView(
    WidgetTester tester, {
    required VoidCallback onRetry,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceErrorView(
            message: "Couldn't load this source.\nThe source did not respond.",
            onRetry: onRetry,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the retry holds focus as soon as the error appears', (
    tester,
  ) async {
    await pumpView(tester, onRetry: () {});

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.autofocus, isTrue);
    expect(
      Focus.of(
        tester.element(find.text('Try again')),
        scopeOk: true,
      ).hasFocus,
      isTrue,
      reason: 'nothing else in this body can take focus, so the retry must',
    );
  });

  testWidgets('the first OK press retries', (tester) async {
    // The whole point: one press of the remote's select key, with no
    // navigation first, runs the retry.
    var retries = 0;
    await pumpView(tester, onRetry: () => retries++);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('the message is rendered verbatim', (tester) async {
    await pumpView(tester, onRetry: () {});
    expect(
      find.text("Couldn't load this source.\nThe source did not respond."),
      findsOneWidget,
    );
  });
}
