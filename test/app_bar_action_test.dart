// AppBar actions name themselves on the wide layout (every TV, wide windows),
// where a remote can't hover a tooltip, and stay icon-only on a phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/app_bar_action.dart';

void main() {
  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          appBar: AppBar(
            title: const Text('A source with a fairly long name'),
            actions: [
              AppBarAction(
                label: 'Last channel',
                icon: Icons.swap_horiz_rounded,
                onPressed: () {},
              ),
              AppBarAction(
                label: 'Sources',
                icon: Icons.dns_outlined,
                onPressed: () {},
              ),
              AppBarAction(
                label: 'Diagnostics',
                icon: Icons.bug_report_outlined,
                onPressed: () {},
              ),
              AppBarAction(
                label: 'Help',
                tooltip: 'Help & about',
                icon: Icons.help_outline,
                onPressed: () {},
              ),
              AppBarAction(
                label: 'Refresh',
                tooltip: 'Refresh from source',
                icon: Icons.refresh,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('wide layout shows the labels', (tester) async {
    await pumpAt(tester, const Size(kWideLayoutMinWidth, 700));
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.byTooltip('Refresh from source'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layout is icon-only with the label as tooltip', (
    tester,
  ) async {
    await pumpAt(tester, const Size(400, 800));
    expect(find.text('Sources'), findsNothing);
    expect(find.byTooltip('Sources'), findsOneWidget);
    expect(find.byTooltip('Help & about'), findsOneWidget);
    expect(find.byType(IconButton), findsNWidgets(5));
  });
}
