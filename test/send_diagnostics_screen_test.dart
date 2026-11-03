// The send screen's two load-bearing properties are both about a remote:
// where focus lands on entry, and that nothing on the screen can trap it.
//
// Default focus is **Cancel**, not Send. Sending is irreversible — there is no
// unsend and, deliberately, no developer delete path — and its subject is the
// user's own viewing history. Every other confirm in this app autofocuses its
// primary action; this is the one place where a single stray OK on a remote
// must not publish anything. If this test starts failing because someone moved
// `autofocus: true` onto the Send button, the test is right.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/send_diagnostics_screen.dart';
import 'package:iptvs/theme.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool cloudAvailable,
    Future<String> Function(String body)? submit,
    Size size = const Size(1280, 720),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: SendDiagnosticsScreen(
          cloudAvailable: cloudAvailable,
          snapshot: 'iptvs diagnostics exported\nentries=1\n\n12:00:00 [a] b',
          submit: submit ?? (_) async => 'D-K7M3PQ',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The widget that currently holds primary focus, resolved to the button
  /// text under it — which is what a user on a remote actually sees ringed.
  String focusedButtonLabel(WidgetTester tester) {
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull, reason: 'something must hold focus on entry');
    final context = focused!.context;
    expect(context, isNotNull);
    final texts = find
        .descendant(of: find.byWidget(context!.widget), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();
    expect(texts, isNotEmpty, reason: 'the focused node must be a labelled control');
    return texts.first;
  }

  testWidgets('Cancel holds focus on entry, not Send', (tester) async {
    await pump(tester, cloudAvailable: true);

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Send to developer'), findsOneWidget);
    expect(focusedButtonLabel(tester), 'Cancel');
  });

  testWidgets('Cancel still holds focus when the LAN path is the only one', (
    tester,
  ) async {
    await pump(tester, cloudAvailable: false);

    expect(find.text('Send to developer'), findsNothing);
    expect(find.text('Share on Wi-Fi'), findsOneWidget);
    // The rule does not relax because the primary action changed: a user who
    // opened this screen to read the log still must not publish it by
    // pressing OK once.
    expect(focusedButtonLabel(tester), 'Cancel');
  });

  testWidgets('the consent text is present verbatim', (tester) async {
    await pump(tester, cloudAvailable: true);

    // Matched against the exported constant rather than a copy, so the two can
    // never drift — but each clause is also asserted individually, because the
    // whole point of the paragraph is that it names what is in the log. A
    // future edit that genericises it ("send anonymous diagnostics?") would
    // keep the constant test green and fail these.
    expect(find.text(kDiagnosticsConsentText), findsOneWidget);
    for (final clause in const [
      "IPTV provider's address",
      'source and profile names',
      'channel names',
      'times you watched',
      'Passwords and credentials are removed automatically',
      'stored for 30 days',
      'only the developer can read it',
    ]) {
      expect(
        kDiagnosticsConsentText,
        contains(clause),
        reason: 'the consent must still say: $clause',
      );
    }
  });

  testWidgets('there is no text field anywhere on the screen', (tester) async {
    await pump(tester, cloudAvailable: true);

    // A bare TextField traps D-pad focus on a television (CLAUDE.md). This
    // screen needs no input at all: the code that comes back is copied,
    // scanned or read out.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('a successful send shows the code and autofocuses Copy', (
    tester,
  ) async {
    await pump(tester, cloudAvailable: true);

    await tester.tap(find.text('Send to developer'));
    await tester.pumpAndSettle();

    expect(find.text('D-K7M3PQ'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(focusedButtonLabel(tester), 'Copy');
    // Still no input, even in the success state.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a failed send offers an autofocused Retry and the LAN option', (
    tester,
  ) async {
    await pump(
      tester,
      cloudAvailable: true,
      submit: (_) async => throw Exception('no network'),
    );

    await tester.tap(find.text('Send to developer'));
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Share on Wi-Fi'), findsOneWidget);
    // Retry autofocuses here and Cancel does not — the dangerous press is
    // already behind the user, and what is left is the action that moves them
    // forward (the same rule `SourceErrorView` follows).
    expect(focusedButtonLabel(tester), 'Try again');
    // `friendlyCloudError` genericises anything the server did not author, so
    // a raw exception's text must not reach the screen.
    expect(find.textContaining('no network'), findsNothing);
  });
}
