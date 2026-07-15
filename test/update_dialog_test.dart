import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_service.dart';
import 'package:iptvs/screens/update_flow.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/release_notes_view.dart';

/// Guards the TV-remote behaviour of the update prompt: the modal must open with
/// its primary action already focused, so a D-pad OK acts immediately instead
/// of being swallowed until the user presses an arrow. Mirrors the app's other
/// focus regression tests (`channel_list_focus_test.dart`).
void main() {
  final release = ReleaseInfo(
    version: '1.5.0',
    tagName: 'v1.5.0',
    name: 'iptvs 1.5.0',
    notes: 'Some release notes.',
    htmlUrl: Uri.parse('https://github.com/GCHOfficial/iptvs/releases'),
  );

  /// Pumps a host with a button that opens the update dialog, then opens it.
  /// [onResult] receives the user's choice once the dialog closes.
  Future<void> openDialog(
    WidgetTester tester, {
    ValueChanged<UpdateChoice?>? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final choice = await showUpdateDialog(
                    context,
                    release,
                    '1.4.0',
                  );
                  onResult?.call(choice);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Update available — 1.5.0'), findsOneWidget);
  }

  testWidgets('primary action holds focus when the dialog opens', (
    tester,
  ) async {
    await openDialog(tester);
    // The primary action is the dialog's only FilledButton (Skip/Later are
    // TextButtons). Its label is platform-dependent ('Update' where an in-app
    // install is possible, else 'View release'); assert on the button, not text.
    expect(find.byType(FilledButton), findsOneWidget);
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(
      focused!.context!.findAncestorWidgetOfExactType<FilledButton>(),
      isNotNull,
      reason: 'the autofocused node should sit under the primary action button',
    );
  });

  testWidgets('OK/Enter on the focused primary action returns update', (
    tester,
  ) async {
    UpdateChoice? result;
    await openDialog(tester, onResult: (c) => result = c);

    // No arrow press first — a TV OK should activate the pre-focused button.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, UpdateChoice.update);
  });

  testWidgets('all three choices are present and labelled', (tester) async {
    await openDialog(tester);
    expect(find.text('Skip this version'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    // The primary action (labelled 'Update' or 'View release' by platform).
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('the changelog renders formatted, not as raw markdown', (
    tester,
  ) async {
    await openDialog(tester);
    expect(find.byType(ReleaseNotesView), findsOneWidget);
  });

  testWidgets('D-pad Up/Down stay trapped inside the dialog', (tester) async {
    await openDialog(tester);

    // Up enters the focusable changelog region…
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'update.notes');

    // …and Down leaves it back to the actions — never onto anything behind the
    // modal barrier (the reported "focus escapes and I can scroll the channels").
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<AlertDialog>(),
      isNotNull,
    );

    // Mash Down a few more times: focus must remain within the dialog.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<AlertDialog>(),
      isNotNull,
      reason: 'no vertical arrow escapes the dialog',
    );
  });

  testWidgets('cached update resume defaults to Install', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showPendingUpdateDialog(context, '1.5.0');
              },
              child: const Text('resume'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('resume'));
    await tester.pumpAndSettle();

    expect(find.text('Update ready to install — 1.5.0'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<FilledButton>(),
      isNotNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
