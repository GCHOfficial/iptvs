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

  testWidgets('renders inline code and italics without literal markers',
      (tester) async {
    await pump(
      tester,
      'Set `SUPABASE_URL` to enable sync — *optional*, and **safe** to skip.',
    );
    final text = renderedText(tester);

    expect(text, contains('SUPABASE_URL'));
    expect(text, contains('optional'));
    expect(text.contains('`'), isFalse, reason: 'code backticks stripped');
    expect(text.contains('*'), isFalse, reason: 'italic/bold markers stripped');

    // The code span carries the monospace style.
    final richTexts = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(ReleaseNotesView),
        matching: find.byType(RichText),
      ),
    );
    var sawCode = false;
    var sawItalic = false;
    for (final rt in richTexts) {
      rt.text.visitChildren((span) {
        final style = span.style;
        if (span is TextSpan && style != null) {
          if (span.text == 'SUPABASE_URL' && style.fontFamily == 'monospace') {
            sawCode = true;
          }
          if (span.text == 'optional' &&
              style.fontStyle == FontStyle.italic) {
            sawItalic = true;
          }
        }
        return true;
      });
    }
    expect(sawCode, isTrue, reason: 'inline code renders monospace');
    expect(sawItalic, isTrue, reason: '*italic* renders italic');
  });

  testWidgets('drops code fences and indents nested bullets', (tester) async {
    await pump(tester, '''
## Highlights
- **Live TV**: denser channel list
  - category rows tightened too
```
some fenced text
```
''');
    final text = renderedText(tester);

    expect(text, contains('denser channel list'));
    expect(text, contains('category rows tightened too'));
    expect(text, contains('some fenced text'));
    expect(text.contains('```'), isFalse, reason: 'fence markers dropped');

    // The nested bullet's row is inset further than the top-level one.
    double bulletLeftPad(String content) {
      final padding = tester.widget<Padding>(
        find
            .ancestor(
              of: find.byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText().contains(content),
              ),
              matching: find.byType(Padding),
            )
            .first, // nearest Padding ancestor = the bullet row's inset
      );
      return (padding.padding as EdgeInsets).left;
    }

    expect(
      bulletLeftPad('category rows tightened too'),
      greaterThan(bulletLeftPad('denser channel list')),
      reason: 'nested bullets inset one extra level',
    );
  });
}
