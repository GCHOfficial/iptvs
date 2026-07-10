import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_service.dart';
import 'package:iptvs/screens/update_flow.dart';
import 'package:iptvs/theme.dart';

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
                  final choice = await showUpdateDialog(context, release, '1.4.0');
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
}
