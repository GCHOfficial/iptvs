import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/xmltv.dart';

import 'support/workload_fixtures.dart';

void main() {
  test('generated M3U fixture is deterministic and parseable', () {
    final first = WorkloadFixtures.m3uPlaylist(12);
    final second = WorkloadFixtures.m3uPlaylist(12);

    expect(first, second);
    final parsed = parseM3uPlaylist(first);
    expect(parsed.channels, hasLength(12));
    expect(parsed.categories, hasLength(12));
    expect(parsed.channels.first.name, 'Channel 0');
    expect(parsed.channels.last.extra['tvgId'], 'channel.11');
  });

  test('generated Xtream fixtures are valid JSON arrays', () {
    for (final bytes in [
      WorkloadFixtures.xtreamLiveJson(12),
      WorkloadFixtures.xtreamVodJson(12),
      WorkloadFixtures.xtreamSeriesJson(12),
    ]) {
      expect(jsonDecode(utf8.decode(bytes)), hasLength(12));
    }
  });

  test('generated Stalker fixture includes controlled malformed rows', () {
    final decoded =
        jsonDecode(
              utf8.decode(
                WorkloadFixtures.stalkerChannelsJson(12, malformedEvery: 5),
              ),
            )
            as Map<String, dynamic>;
    final js = decoded['js'] as Map<String, dynamic>;
    final rows = js['data'] as List<dynamic>;

    expect(rows, hasLength(12));
    expect((rows[5] as Map<String, dynamic>)['id'], isNull);
    expect((rows[10] as Map<String, dynamic>)['cmd'], 42);
  });

  test('generated XMLTV fixture parses in plain and gzip forms', () async {
    final channelMap = {
      for (var i = 0; i < 4; i++) 'channel.$i': 'channel-id-$i',
    };

    for (final gzip in [false, true]) {
      final programmes = await parseXmltv(
        WorkloadFixtures.xmltv(
          channelCount: 4,
          programmesPerChannel: 3,
          gzip: gzip,
        ),
        channelMap,
      );
      expect(programmes, hasLength(12));
      expect(programmes.first.channelId, 'channel-id-0');
      expect(programmes.last.title, 'Programme 3-2');
    }
  });

  test('high-ratio gzip fixture expands to the requested size', () {
    const decodedBytes = 256 * 1024;
    final compressed = WorkloadFixtures.highRatioGzip(
      decodedBytes: decodedBytes,
    );

    expect(compressed.length, lessThan(decodedBytes ~/ 10));
    expect(GZipCodec().decode(compressed), hasLength(decodedBytes));
  });
}
