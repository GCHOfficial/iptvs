import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';

/// Pure-logic coverage for the shared colorimetry classifiers in
/// `player_screen.dart`: [dynamicRangeLabelFrom] (the single source of truth
/// for the HDR/SDR badge label on every platform) and [isHdrColorimetry] (the
/// PQ/HLG/DV/BT.2020 predicate that gates the Linux Wayland embedded→native
/// escalation and feeds `decideFullscreenHandoff`'s `streamLikelyHdr`).
void main() {
  group('dynamicRangeLabelFrom', () {
    test(
      'PQ gamma is HDR10 · PQ, upgraded to HDR10+ with dynamic metadata',
      () {
        expect(dynamicRangeLabelFrom(gamma: 'pq'), 'HDR10 · PQ');
        expect(
          dynamicRangeLabelFrom(gamma: 'pq', hdr10Plus: true),
          'HDR10+ · PQ',
        );
      },
    );

    test('HLG gamma is HLG', () {
      expect(dynamicRangeLabelFrom(gamma: 'hlg'), 'HLG');
    });

    test('Dolby Vision wins from either gamma or matrix', () {
      expect(dynamicRangeLabelFrom(matrix: 'dolbyvision'), 'Dolby Vision');
      expect(dynamicRangeLabelFrom(gamma: 'dolby'), 'Dolby Vision');
    });

    test('BT.2020 primaries without a PQ/HLG gamma is HDR · BT.2020', () {
      expect(dynamicRangeLabelFrom(primaries: 'bt.2020'), 'HDR · BT.2020');
    });

    test(
      'empty colorimetry is unknown (blank), populated-but-plain is SDR',
      () {
        expect(dynamicRangeLabelFrom(), '');
        expect(
          dynamicRangeLabelFrom(gamma: 'bt.1886', primaries: 'bt.709'),
          'SDR',
        );
      },
    );
  });

  group('isHdrColorimetry', () {
    test('true for PQ / HLG / Dolby Vision / BT.2020', () {
      expect(isHdrColorimetry(gamma: 'pq'), isTrue);
      expect(isHdrColorimetry(gamma: 'hlg'), isTrue);
      expect(isHdrColorimetry(matrix: 'dolbyvision'), isTrue);
      expect(isHdrColorimetry(primaries: 'bt.2020'), isTrue);
    });

    test('false for SDR and for unknown/empty colorimetry', () {
      expect(isHdrColorimetry(gamma: 'bt.1886', primaries: 'bt.709'), isFalse);
      // Unknown (not yet reported) params must not trigger a native escalation.
      expect(isHdrColorimetry(), isFalse);
      expect(isHdrColorimetry(gamma: '', primaries: '', matrix: ''), isFalse);
    });
  });
}
