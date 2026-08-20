import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme.dart';

/// The cloud-sync pairing code rendered as a scannable link to the panel.
///
/// A separate widget rather than a method on `CloudSyncScreen` so its layout can
/// be swept across window sizes and text scales without standing up a
/// `SourceStore`, an `AppDatabase` and a fake `CloudSync` — see
/// `test/pairing_qr_test.dart`. The pairing screen is not covered by
/// `layout_overflow_test.dart`, which is scoped to the three fixed-extent
/// browsing surfaces.
///
/// Deliberately *beside* the printed code and link on that screen, never
/// instead of them: a QR is no use to someone pairing from the same machine,
/// and a phone camera pointed at a lit TV panel across a room is exactly where
/// a scan fails.
class PairingQrView extends StatelessWidget {
  const PairingQrView({super.key, required this.link});

  /// The panel URL carrying the pairing code (`pairingPanelLink`).
  final String link;

  /// Comfortable size on a television, and small enough that the whole plate
  /// still fits a narrow phone once [_chromeAllowance] is taken off.
  static const double maxSide = 180;

  /// Below this a version 3–5 symbol's modules get too few pixels each to
  /// survive a camera; the screen is barely usable at such a width anyway, so
  /// the QR stops shrinking rather than becoming decorative.
  static const double minSide = 120;

  /// White quiet zone around the modules. Explicit, because `QrImageView`'s own
  /// default padding would sit *inside* the size we compute and eat into the
  /// symbol instead of surrounding it.
  static const double plateInset = 12;

  /// Horizontal space the surrounding card spends before this widget gets any:
  /// the pairing card's 20 px each side, plus this plate's own inset each side.
  static const double _chromeAllowance = 40 + plateInset * 2;

  /// Longest link this will encode, and the reason is legibility rather than
  /// the encoder's own ceiling.
  ///
  /// A symbol only scans if its modules survive the camera — roughly 3 device
  /// pixels each — so at [maxSide] the usable budget is about 60 modules, i.e.
  /// somewhere around version 11. A link that needs more than this produces a
  /// denser symbol than a phone can read off a lit television, which is the
  /// only place this is ever pointed. The real panel link is ~50 characters, so
  /// the cap only ever fires on a misconfigured `PANEL_URL`.
  ///
  /// It is also what makes the encode *safe*. [QrValidator.validate] is
  /// optimistic: `QrCode.fromData` picks a version via
  /// `_calculateTypeNumberFromData`, which walks 1..39 and simply returns the
  /// largest when nothing fits instead of failing — so validation reports
  /// **valid** for a payload that throws `InputTooLongException` the moment it
  /// is really encoded, deep inside the painter where no `errorStateBuilder`
  /// can catch it. Bounding the input well below any version's capacity puts
  /// that path out of reach rather than trusting a guard that doesn't hold.
  static const int maxLinkLength = 300;

  @override
  Widget build(BuildContext context) {
    // A payload this can't render must cost the QR, not the screen — the code
    // and the printed link above it are what actually pair the device.
    if (link.length > maxLinkLength) return const SizedBox.shrink();
    // Second net, for everything that isn't length (a malformed payload the
    // encoder rejects outright).
    final validation = QrValidator.validate(
      data: link,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    );
    if (!validation.isValid) return const SizedBox.shrink();

    // Sized against the window rather than the incoming constraints: this sits
    // in a `Center` inside a scroll view, so its slot is as wide as the card and
    // says nothing about how much room the *plate* can afford.
    final side = (MediaQuery.sizeOf(context).width - _chromeAllowance).clamp(
      minSide,
      maxSide,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(plateInset),
          decoration: BoxDecoration(
            // An explicit white plate with the module colours pinned dark.
            // `QrImageView`'s background defaults to transparent, which on this
            // screen's dark card would be dark-on-dark: visibly present, and
            // scannable as nothing.
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SizedBox.square(
            dimension: side,
            child: QrImageView(
              data: link,
              size: side,
              padding: EdgeInsets.zero,
              // Medium rather than the package default (low): this is read off
              // a lit panel by a hand-held camera, through glare and moiré. The
              // payload is short enough that the redundancy costs a version at
              // most.
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
              semanticsLabel:
                  'QR code that opens the panel with this pairing code '
                  'filled in',
            ),
          ),
        ),
        const SizedBox(height: 8),
        // No hard-wrapped line: the caption has to read sensibly from a 320 px
        // phone at text scale 2.0 up to a television, and a baked-in newline
        // only lands correctly at one of those. The cap keeps the measure
        // readable on the wide end instead of stretching to the card.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: const Text(
            'Or scan this with your phone — the panel opens with the code '
            'already filled in',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textLo, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
