import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../data/net.dart';
import 'source.dart';

/// Below this payload size, parse inline; above it, decode + parse on a
/// background isolate. A real XMLTV guide is multi-MB (gzip-decode + a full XML
/// event parse building thousands of [Programme]s), which would otherwise stall
/// the UI thread on the ~3-hourly EPG refresh; small fixtures (tests, tiny
/// guides) stay inline to avoid isolate-spawn overhead. Mirrors the M3U/Xtream
/// offload.
const _isolateXmltvThreshold = 64 * 1024;

/// Parse XMLTV [bytes] (gzip-aware) into [Programme]s, keeping only programmes
/// whose XMLTV `channel` id maps — via [tvgIdToChannelId] — to one of our
/// channels. Used by M3U and Xtream sources.
Future<List<Programme>> parseXmltv(
  Uint8List bytes,
  Map<String, String> tvgIdToChannelId,
) {
  // A tiny gzip can expand into hundreds of MB, so compressed input always
  // goes to the worker even when it is below the ordinary isolate threshold.
  if (!isGzipBytes(bytes) && bytes.length < _isolateXmltvThreshold) {
    return _parseXmltvBytes((bytes, tvgIdToChannelId));
  }
  return compute(_parseXmltvBytes, (bytes, tvgIdToChannelId));
}

/// Top-level worker so it can run under [compute]. Takes a record of the raw
/// [Uint8List] bytes and the tvg-id → channel-id map (both sendable across the
/// isolate boundary), returns the mapped [Programme]s.
Future<List<Programme>> _parseXmltvBytes(
  (Uint8List, Map<String, String>) args,
) async {
  final (bytes, tvgIdToChannelId) = args;
  // A .xml.gz file arrives as raw gzip (magic 0x1f 0x8b) with no transfer
  // encoding, so decompress it ourselves.
  final data = isGzipBytes(bytes)
      ? decodeGzipBounded(bytes, kEpgWorkload.maximumDecodedBytes)
      : bytes;
  final xmlString = utf8.decode(data, allowMalformed: true);

  final out = <Programme>[];
  await Stream<String>.value(xmlString)
      .toXmlEvents()
      .normalizeEvents()
      .selectSubtreeEvents((e) => e.name == 'programme')
      .toXmlNodes()
      .expand((nodes) => nodes)
      .forEach((node) {
        if (node is! XmlElement) return;
        final tvgId = node.getAttribute('channel');
        if (tvgId == null) return;
        final channelId = tvgIdToChannelId[tvgId];
        if (channelId == null) return; // not one of our channels
        final start = parseXmltvTime(node.getAttribute('start'));
        final stop = parseXmltvTime(node.getAttribute('stop'));
        if (start == null || stop == null) return;
        out.add(
          Programme(
            channelId: channelId,
            start: start,
            stop: stop,
            title: node.getElement('title')?.innerText.trim() ?? '',
            description: node.getElement('desc')?.innerText.trim(),
          ),
        );
      });
  return out;
}

/// Parse an XMLTV timestamp ("YYYYMMDDHHMMSS +0100") into an absolute instant.
DateTime? parseXmltvTime(String? s) {
  if (s == null || s.length < 14) return null;
  try {
    var dt = DateTime.utc(
      int.parse(s.substring(0, 4)),
      int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)),
      int.parse(s.substring(8, 10)),
      int.parse(s.substring(10, 12)),
      int.parse(s.substring(12, 14)),
    );
    final tz = s.length > 14 ? s.substring(14).trim() : '';
    if (tz.length >= 5 && (tz[0] == '+' || tz[0] == '-')) {
      final sign = tz[0] == '-' ? -1 : 1;
      final oh = int.parse(tz.substring(1, 3));
      final om = int.parse(tz.substring(3, 5));
      dt = dt.subtract(Duration(hours: sign * oh, minutes: sign * om));
    }
    return dt;
  } catch (_) {
    return null;
  }
}
