// Pins that the changelog renders as tidy formatted text, not raw markdown —
// the reported "display the markdown so it looks better" for the update dialog.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/widgets/release_notes_view.dart';

void main() {
  // The plain text of everything ReleaseNotesView renders (it uses RichText,
  // which the default text finders skip).
  String renderedText(WidgetTester tester) {
    final buffer = StringBuffer();
    final richTexts = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(ReleaseNotesView),
        matching: find.byType(RichText),
      ),
    );
    for (final rt in richTexts) {
      buffer.writeln(rt.text.toPlainText());
    }
    return buffer.toString();
  }

  Future<void> pump(WidgetTester tester, String notes) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ReleaseNotesView(notes))),
  );

  testWidgets('renders headings, bold and bullets without literal markers',
      (tester) async {
    await pump(tester, '''
## What's Changed
* **TV UX**: stronger EPG cursor by @GCHOfficial in https://github.com/GCHOfficial/iptvs/pull/91
- Another fix

**Full Changelog**: https://github.com/GCHOfficial/iptvs/compare/v0.1.26...v0.1.27
''');

    final text = renderedText(tester);

    // Content survives…
    expect(text, contains("What's Changed"));
    expect(text, contains('TV UX'));
    expect(text, contains('Another fix'));
    expect(text, contains('Full Changelog'));

    // …but the markdown syntax is gone.
    expect(text.contains('##'), isFalse, reason: 'heading hashes stripped');
    expect(text.contains('**'), isFalse, reason: 'bold markers stripped');
    expect(
      text.contains('https://'),
      isFalse,
      reason: 'URLs are shortened to labels, not shown raw',
    );

    // Links become short labels.
    expect(text, contains('#91'));
    expect(text, contains('v0.1.26…v0.1.27'));
  });

  testWidgets('markdown links show their text, not the URL', (tester) async {
    await pump(tester, 'See the [release page](https://example.com/x) for more.');
    final text = renderedText(tester);
    expect(text, contains('release page'));
    expect(text.contains('https://'), isFalse);
    expect(text.contains(']('), isFalse);
  });

  testWidgets('empty notes render nothing to crash on', (tester) async {
    await pump(tester, '');
    expect(find.byType(ReleaseNotesView), findsOneWidget);
  });
}
