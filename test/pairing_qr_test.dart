// Layout net for the pairing QR, across every window size and text scale the
// app supports.
//
// `layout_overflow_test.dart` is deliberately scoped to the three fixed-extent
// browsing surfaces, so the cloud-sync screen has no coverage there — and the
// QR is the one thing on it with a hard pixel size. Two ways that can go wrong
// and neither shows up at one window size:
//
//  * `QrImageView` falls back to `constraints.biggest.shortestSide` when no
//    `size` is given, which is infinite inside a Column; and a fixed `size`
//    wider than the incoming constraints gets clamped on **width only**, which
//    draws a non-square symbol no scanner will read.
//  * The caption is the only text on the plate, and a baked-in line break lands
//    correctly at exactly one width.
//
// Loads the real Inter font for the same reason `layout_overflow_test` does:
// `flutter_test`'s default font lays every line out at exactly 1.0 x fontSize,
// which hides the entire class of wrapping bugs this is looking for.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/pairing_qr.dart';

Future<void> _loadInterFont() async {
  final loader = FontLoader('Inter');
  for (final path in const [
    'android/app/src/main/res/font/inter_regular.ttf',
    'android/app/src/main/res/font/inter_semibold.ttf',
    'android/app/src/main/res/font/inter_bold.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) {
      fail('Inter face missing at $path — see the file header.');
    }
    loader.addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadInterFont);

  final link = pairingPanelLink(CloudConfig.panelUrl, 'ECA6EVMU');

  /// Mirrors the pairing card: a scrolling column with 20 px of horizontal
  /// padding, which is what [PairingQrView] budgets for.
  Future<void> pumpCard(
    WidgetTester tester,
    Size size,
    double textScale,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          backgroundColor: AppColors.panel,
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [Center(child: PairingQrView(link: link))],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 360x640 is a small phone; 960x540 is the logical viewport an Android TV
  // commonly reports (see docs/tv-navigation.md); the rest are the desktop
  // window sizes the other layout tests sweep.
  //
  // The first two are the ones that earn their keep: a split-screen / freeform
  // window narrower than `maxSide` plus its chrome is the only place the size
  // clamp does anything, and it is where a fixed 180 px box got clamped on
  // width alone and drew a rectangle instead of a square.
  const sizes = <Size>[
    Size(200, 480),
    Size(240, 520),
    Size(360, 640),
    Size(411, 731),
    Size(1000, 600),
    Size(960, 540),
    Size(1280, 720),
    Size(1920, 1080),
  ];

  for (final size in sizes) {
    for (final textScale in const [1.0, 1.3, 2.0]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} at text scale '
          '$textScale lays out cleanly', (tester) async {
        await pumpCard(tester, size, textScale);

        expect(
          tester.takeException(),
          isNull,
          reason: 'the pairing QR must not overflow at any supported size',
        );

        final plate = tester.getRect(find.byType(QrImageView).first);
        expect(
          plate.width,
          closeTo(plate.height, 0.5),
          reason: 'a non-square symbol is one no scanner will read — which is '
              'exactly what a fixed size clamped on width alone produces',
        );
        expect(plate.width, lessThanOrEqualTo(PairingQrView.maxSide));
        expect(plate.width, greaterThanOrEqualTo(PairingQrView.minSide));

        // The whole plate has to fit the card's content width, or the white
        // ground is clipped through the quiet zone the scanner needs.
        final view = tester.getRect(find.byType(PairingQrView));
        expect(view.left, greaterThanOrEqualTo(-0.5));
        expect(view.right, lessThanOrEqualTo(size.width + 0.5));
      });
    }
  }

  testWidgets('a link too long to render costs the QR, not the screen', (
    tester,
  ) async {
    // This is the case `QrValidator.validate` alone does *not* catch: it walks
    // versions 1..39 and returns the largest when nothing fits, reporting
    // `valid`, and the InputTooLongException then surfaces inside the painter
    // where no errorStateBuilder can reach it. Without the length bound this
    // took the whole pairing screen down.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingQrView(link: 'https://x/?code=${'a' * 3000}'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('scan this'), findsNothing);
  });

  testWidgets('a link just past the cap is dropped, just under it renders', (
    tester,
  ) async {
    Future<void> pumpLink(String value) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PairingQrView(link: value))),
      );
      await tester.pumpAndSettle();
    }

    const prefix = 'https://example.test/?code=';
    final justOver = prefix.padRight(PairingQrView.maxLinkLength + 1, 'A');
    await pumpLink(justOver);
    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsNothing);

    final justUnder = prefix.padRight(PairingQrView.maxLinkLength, 'A');
    await pumpLink(justUnder);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the cap must sit below the encoder ceiling, not on it — a link '
          'at the limit still has to encode',
    );
    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('the caption carries no baked-in line break', (tester) async {
    // A hard newline reads correctly at exactly one width, and this widget is
    // shown from a 360 px phone at text scale 2.0 to a 1080p television.
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PairingQrView(link: link))),
    );
    await tester.pumpAndSettle();

    final caption = tester.widget<Text>(find.textContaining('scan this'));
    expect(caption.data, isNotNull);
    expect(caption.data, isNot(contains('\n')));
  });
}
