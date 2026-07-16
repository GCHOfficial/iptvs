// Tests for parseXmltvBatched: the streamed, bounded-batch counterpart of
// parseXmltv used for large XMLTV guides. Proves batch flattening matches the
// single-list parser exactly, batch sizes are respected, malformed elements
// are skipped the same way on both paths, and a genuinely invalid payload
// throws on both the inline and the background-isolate path.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/sources/xmltv.dart';

import 'support/workload_fixtures.dart';

void main() {
  Map<String, String> channelMap(int channelCount) => {
    for (var i = 0; i < channelCount; i++) 'channel.$i': 'ch$i',
  };

  group('parseXmltvBatched', () {
    test(
      'flattened batches match parseXmltv exactly for a large guide',
      () async {
        const channelCount = 40;
        const perChannel = 60; // 2400 programmes: comfortably above the
        // isolate threshold, so this exercises the isolate-streaming path.
        final bytes = WorkloadFixtures.xmltv(
          channelCount: channelCount,
          programmesPerChannel: perChannel,
        );
        expect(bytes.length, greaterThan(64 * 1024));
        final map = channelMap(channelCount);

        final expected = await parseXmltv(bytes, map);
        final batches = await parseXmltvBatched(
          bytes,
          map,
          batchSize: 500,
        ).toList();
        final flattened = batches.expand((b) => b).toList();

        expect(flattened.length, expected.length);
        expect(
          flattened.map((p) => '${p.channelId}|${p.start}|${p.title}').toList(),
          expected.map((p) => '${p.channelId}|${p.start}|${p.title}').toList(),
        );
      },
    );

    test(
      'batch sizes are respected: all but the last equal batchSize',
      () async {
        const channelCount = 40;
        const perChannel = 60;
        final bytes = WorkloadFixtures.xmltv(
          channelCount: channelCount,
          programmesPerChannel: perChannel,
        );
        expect(bytes.length, greaterThan(64 * 1024));
        final map = channelMap(channelCount);
        const batchSize = 500;

        final batches = await parseXmltvBatched(
          bytes,
          map,
          batchSize: batchSize,
        ).toList();

        expect(batches.length, greaterThan(1));
        for (final batch in batches.take(batches.length - 1)) {
          expect(batch.length, batchSize);
        }
        expect(batches.last, isNotEmpty);
        expect(batches.last.length, lessThanOrEqualTo(batchSize));
        expect(
          batches.fold<int>(0, (sum, b) => sum + b.length),
          channelCount * perChannel,
        );
      },
    );

    test('skips malformed elements the same way parseXmltv does', () async {
      Uint8List xmltv(String programmes) => Uint8List.fromList(
        utf8.encode('<?xml version="1.0"?><tv>$programmes</tv>'),
      );
      String good(String channel, {required String title}) =>
          '<programme channel="$channel" start="20240101120000 +0000" '
          'stop="20240101130000 +0000"><title>$title</title></programme>';
      String missingStart(String channel) =>
          '<programme channel="$channel" stop="20240101130000 +0000">'
          '<title>NoStart</title></programme>';
      String missingChannel() =>
          '<programme start="20240101120000 +0000" '
          'stop="20240101130000 +0000"><title>NoChannel</title></programme>';

      final bytes = xmltv(
        good('tvg.one', title: 'One') +
            missingStart('tvg.one') +
            missingChannel() +
            good('tvg.unknown', title: 'Unmapped') +
            good('tvg.one', title: 'Two'),
      );
      final map = {'tvg.one': 'ch1'};

      final inline = await parseXmltv(bytes, map);
      final batched = await parseXmltvBatched(
        bytes,
        map,
        batchSize: 1,
      ).toList();
      final flattened = batched.expand((b) => b).toList();

      expect(inline.map((p) => p.title), ['One', 'Two']);
      expect(flattened.map((p) => p.title), inline.map((p) => p.title));
    });

    test('a truncated/invalid XML payload throws on both paths', () async {
      final bytes = Uint8List.fromList(
        utf8.encode('<?xml version="1.0"?><tv><programme channel="tvg.one"'),
      );
      final map = {'tvg.one': 'ch1'};

      await expectLater(parseXmltv(bytes, map), throwsA(anything));
      await expectLater(
        parseXmltvBatched(bytes, map).toList(),
        throwsA(anything),
      );
    });

    test(
      'a truncated large payload throws via the isolate path, forwarded as XmltvParseException',
      () async {
        const channelCount = 40;
        const perChannel = 60;
        final bytes = WorkloadFixtures.xmltv(
          channelCount: channelCount,
          programmesPerChannel: perChannel,
        );
        expect(bytes.length, greaterThan(64 * 1024));
        // Cut the payload mid-document so it's well above the isolate
        // threshold but no longer well-formed XML.
        final truncated = Uint8List.sublistView(bytes, 0, bytes.length ~/ 2);
        final map = channelMap(channelCount);

        await expectLater(parseXmltv(truncated, map), throwsA(anything));
        await expectLater(
          parseXmltvBatched(truncated, map).toList(),
          throwsA(isA<XmltvParseException>()),
        );
      },
    );
  });
}
