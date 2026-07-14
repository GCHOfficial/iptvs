import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/legal_screen.dart';

void main() {
  testWidgets('exposes privacy, support, and cloud deletion paths', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));

    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('Delete cloud account'), findsOneWidget);

    for (final label in const [
      'Privacy policy',
      'Support',
      'Delete cloud account',
    ]) {
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
      );
      expect(tile.onTap, isNotNull);
    }
  });
}
