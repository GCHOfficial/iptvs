// The disk-backed guide path: `xmltvGuideFeed` streams a download into a temp
// file, the worker parses it from there (inflating gzip on the fly), and the
// file is gone however the feed ends. Plus the event-level extractor's reading
// of the XMLTV shapes the DOM version used to handle.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/epg_guides.dart';
import 'package:iptvs/sources/epg_matching.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xmltv.dart';

import 'support/workload_fixtures.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('iptvs_feed_test'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Map<String, String> channelMap(int count) => {
    for (var i = 0; i < count; i++) 'channel.$i': 'ch$i',
  };

  EpgGuideFeed feedOf(
    Future<void> Function(Uri uri, File destination) download, {
    Map<String, String>? map,
  }) => xmltvGuideFeed(
    url: 'http://guide.example/epg.xml.gz',
    download: download,
    tvgIdToChannelId: map ?? channelMap(40),
    nameToChannelIds: const {},
    tempDirectory: temp,
  );

  group('xmltvGuideFeed', () {
    test('parses a gzip guide from disk and deletes the file', () async {
      final xml = WorkloadFixtures.xmltv(
        channelCount: 40,
        programmesPerChannel: 60,
      );
      final expected = await parseXmltv(xml, channelMap(40));
      final feed = feedOf((_, file) => file.writeAsBytes(gzip.encode(xml)));

      final got = (await feed.open().toList()).expand((b) => b).toList();

      expect(
        got.map((p) => '${p.channelId}|${p.start}|${p.title}'),
        expected.map((p) => '${p.channelId}|${p.start}|${p.title}'),
      );
      expect(temp.listSync(), isEmpty, reason: 'temp guide left behind');
    });

    test('deletes the file when the parse fails', () async {
      final xml = WorkloadFixtures.xmltv(
        channelCount: 40,
        programmesPerChannel: 60,
      );
      final truncated = Uint8List.sublistView(xml, 0, xml.length ~/ 2);
      final feed = feedOf((_, file) => file.writeAsBytes(truncated));

      await expectLater(feed.open().toList(), throwsA(anything));
      expect(temp.listSync(), isEmpty);
    });

    test('a size rejection names the way out', () async {
      final feed = feedOf(
        (_, _) async =>
            throw const HttpWorkloadException('epg is 900 MB, over the limit'),
      );
      await expectLater(
        feed.open().toList(),
        throwsA(
          isA<HttpWorkloadException>().having(
            (e) => e.message,
            'message',
            contains('per-country'),
          ),
        ),
      );
      expect(temp.listSync(), isEmpty);
    });
  });

  group('event-level extraction', () {
    Future<List<Programme>> parse(String body, Map<String, String> map) =>
        parseXmltv(
          Uint8List.fromList(
            utf8.encode('<?xml version="1.0"?><tv>$body</tv>'),
          ),
          map,
        );

    const times = 'start="20240101120000 +0000" stop="20240101130000 +0000"';

    test(
      'reads the first direct title and desc, CDATA and nesting included',
      () async {
        final progs = await parse(
          '<programme channel="a" $times>'
          '<title lang="en">  First <b>bold</b> &amp; <![CDATA[raw <x>]]> </title>'
          '<title lang="de">Zweite</title>'
          '<desc>About it</desc><desc>Ignored</desc>'
          '<credits><title>Not a title</title></credits>'
          '</programme>',
          {'a': 'chA'},
        );
        expect(progs, hasLength(1));
        expect(progs.single.title, 'First bold & raw <x>');
        expect(progs.single.description, 'About it');
      },
    );

    test(
      'a self-closing programme still counts, with an empty title',
      () async {
        final progs = await parse('<programme channel="a" $times/>', {
          'a': 'chA',
        });
        expect(progs.single.title, '');
        expect(progs.single.description, isNull);
      },
    );

    test(
      'unmatched programmes are skipped whole, nested elements included',
      () async {
        final progs = await parse(
          '<programme channel="other" $times><title>No</title>'
          '<credits><actor>x</actor></credits></programme>'
          '<programme channel="a" $times><title>Yes</title></programme>',
          {'a': 'chA'},
        );
        expect(progs.map((p) => p.title), ['Yes']);
      },
    );

    test('channels declared in the same chunk as the first programme match by '
        'name', () async {
      // Small enough to be one event list: a resolver frozen before the
      // declarations in that list were seen would miss the name match.
      final progs = await parseXmltv(
        Uint8List.fromList(
          utf8.encode(
            '<?xml version="1.0"?><tv>'
            '<channel id="g1"><display-name>Pro TV</display-name></channel>'
            '<programme channel="g1" $times><title>News</title></programme>'
            '</tv>',
          ),
        ),
        const {},
        nameToChannelIds: {
          normalizeChannelName('Pro TV'): ['chPro'],
        },
      );
      expect(progs.map((p) => p.channelId), ['chPro']);
    });
  });
}
