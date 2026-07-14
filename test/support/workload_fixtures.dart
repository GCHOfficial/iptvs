import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Deterministic, credential-free provider workloads used by parser tests and
/// opt-in performance baselines.
///
/// Keep these generated rather than committing multi-megabyte payloads. The
/// `.invalid` host names are reserved for examples and cannot resolve on the
/// public internet.
abstract final class WorkloadFixtures {
  static String m3uPlaylist(int channelCount) {
    final out = StringBuffer(
      '#EXTM3U url-tvg="https://guide.example.invalid/guide.xml"\n',
    );
    for (var i = 0; i < channelCount; i++) {
      out
        ..writeln(
          '#EXTINF:-1 tvg-id="channel.$i" '
          'tvg-logo="https://images.example.invalid/$i.png" '
          'group-title="Group ${i % 50}",Channel $i',
        )
        ..writeln('https://stream.example.invalid/live/$i.ts');
    }
    return out.toString();
  }

  static Uint8List xtreamLiveJson(int itemCount) => _jsonArray(
    itemCount,
    (i) => {
      'stream_id': i + 1,
      'name': 'Live $i',
      'stream_icon': 'https://images.example.invalid/live/$i.png',
      'category_id': '${i % 50}',
      'epg_channel_id': 'channel.$i',
      'tv_archive': i.isEven ? 1 : 0,
      'tv_archive_duration': i.isEven ? 7 : 0,
    },
  );

  static Uint8List xtreamVodJson(int itemCount) => _jsonArray(
    itemCount,
    (i) => {
      'stream_id': i + 1,
      'name': 'Movie $i',
      'stream_icon': 'https://images.example.invalid/movie/$i.png',
      'category_id': '${i % 25}',
      'container_extension': 'mkv',
      'rating': '${5 + (i % 5)}.0',
    },
  );

  static Uint8List xtreamSeriesJson(int itemCount) => _jsonArray(
    itemCount,
    (i) => {
      'series_id': i + 1,
      'name': 'Series $i',
      'cover': 'https://images.example.invalid/series/$i.png',
      'category_id': '${i % 25}',
      'rating': '${5 + (i % 5)}.0',
    },
  );

  static Uint8List stalkerChannelsJson(int itemCount, {int? malformedEvery}) {
    final items = List<Map<String, Object?>>.generate(itemCount, (i) {
      if (malformedEvery != null && i > 0 && i % malformedEvery == 0) {
        return {
          'name': null,
          'cmd': 42,
          'tv_genre_id': {'unexpected': true},
        };
      }
      return {
        'id': '${i + 1}',
        'name': 'Stalker $i',
        'number': i + 1,
        'tv_genre_id': '${i % 50}',
        'logo': 'https://images.example.invalid/stalker/$i.png',
        'cmd': 'ffmpeg https://stream.example.invalid/stalker/$i',
        'tv_archive_duration': i.isEven ? 3 : 0,
      };
    }, growable: false);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'js': {'total_items': itemCount, 'data': items},
        }),
      ),
    );
  }

  static Uint8List xmltv({
    required int channelCount,
    required int programmesPerChannel,
    bool gzip = false,
  }) {
    final out = StringBuffer('<?xml version="1.0"?><tv>');
    for (var channel = 0; channel < channelCount; channel++) {
      out.write(
        '<channel id="channel.$channel"><display-name>Channel $channel'
        '</display-name></channel>',
      );
      for (var programme = 0; programme < programmesPerChannel; programme++) {
        final start = DateTime.utc(2026, 1, 1).add(Duration(hours: programme));
        final stop = start.add(const Duration(hours: 1));
        out.write(
          '<programme channel="channel.$channel" '
          'start="${_xmltvTime(start)} +0000" '
          'stop="${_xmltvTime(stop)} +0000">'
          '<title>Programme $channel-$programme</title>'
          '<desc>Fixture description</desc></programme>',
        );
      }
    }
    out.write('</tv>');
    final bytes = utf8.encode(out.toString());
    return Uint8List.fromList(gzip ? GZipCodec().encode(bytes) : bytes);
  }

  /// A small compressed payload with a deliberately high expansion ratio.
  /// PR 3 uses this to prove decoded-size limits without storing bomb data.
  static Uint8List highRatioGzip({int decodedBytes = 8 * 1024 * 1024}) {
    final out = BytesBuilder(copy: false);
    const block =
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final encodedBlock = utf8.encode(block);
    while (out.length < decodedBytes) {
      final remaining = decodedBytes - out.length;
      out.add(
        remaining >= encodedBlock.length
            ? encodedBlock
            : encodedBlock.sublist(0, remaining),
      );
    }
    return Uint8List.fromList(GZipCodec().encode(out.takeBytes()));
  }

  static Uint8List _jsonArray(
    int itemCount,
    Map<String, Object?> Function(int index) item,
  ) => Uint8List.fromList(
    utf8.encode(jsonEncode(List.generate(itemCount, item, growable: false))),
  );

  static String _xmltvTime(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}'
      '${value.hour.toString().padLeft(2, '0')}'
      '${value.minute.toString().padLeft(2, '0')}'
      '${value.second.toString().padLeft(2, '0')}';
}
