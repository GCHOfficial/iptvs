import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/legal_screen.dart';
import 'package:iptvs/widgets/focusable_card.dart';

void main() {
  testWidgets('exposes support, source, privacy, and cloud deletion paths', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pump();

    expect(find.text('Help & about'), findsOneWidget);

    // Every link is a D-pad-navigable FocusableCard with a real handler, so a
    // TV remote can reach and activate it.
    for (final label in const [
      'Support',
      'Source code & issues',
      'Privacy policy',
      'Delete cloud account',
    ]) {
      expect(find.text(label), findsOneWidget);
      final card = tester.widget<FocusableCard>(
        find.ancestor(of: find.text(label), matching: find.byType(FocusableCard)),
      );
      expect(card.onTap, isNotNull);
    }
  });
}
