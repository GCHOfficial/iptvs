import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../data/load_token.dart';
import '../data/net.dart';
import 'source.dart';

/// Below this payload size, parse inline; above it, decode + parse on a
/// background isolate. A real XMLTV guide is multi-MB (gzip-decode + a full XML
/// event parse building thousands of [Programme]s), which would otherwise stall
/// the UI thread on the ~3-hourly EPG refresh; small fixtures (tests, tiny
/// guides) stay inline to avoid isolate-spawn overhead. Mirrors the M3U/Xtream
/// offload.
const _isolateXmltvThreshold = 64 * 1024;

/// Bytes handed to the XML event parser at a time.
///
/// The parser is fed a *chunked* stream rather than one big string: decoding a
/// 100 MB guide with `utf8.decode` would materialise a UTF-16 copy roughly
/// twice the decoded byte size, held live alongside the compressed and decoded
/// bytes for the whole parse — the dominant term in the worker's peak RSS, and
/// an OOM candidate on a 2 GiB TV box. Chunking bounds that copy to one chunk
/// at a time. 256 KiB is large enough that per-chunk overhead is noise.
const _xmlChunkBytes = 256 * 1024;

/// Feed [data] to the XML parser in bounded pieces.
///
/// Correctness note: this is only safe because both stages buffer across chunk
/// boundaries. [Utf8Decoder] in chunked mode carries an incomplete multi-byte
/// sequence into the next chunk, and the `xml` package's event decoder keeps a
/// `carry` string so a tag or attribute split across two chunks still parses.
/// Splitting the bytes naively into separate `utf8.decode` calls would corrupt
/// any non-ASCII character that straddles a boundary — which is most of a
/// real-world guide's programme titles.
Stream<String> _decodeChunked(Uint8List data) {
  Stream<List<int>> chunks() async* {
    for (var i = 0; i < data.length; i += _xmlChunkBytes) {
      final end = i + _xmlChunkBytes;
      yield Uint8List.sublistView(
        data,
        i,
        end < data.length ? end : data.length,
      );
    }
  }

  return chunks().transform(const Utf8Decoder(allowMalformed: true));
}

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
  final out = <Programme>[];
  await _decodeChunked(data)
      .toXmlEvents()
      .normalizeEvents()
      .selectSubtreeEvents((e) => e.name == 'programme')
      .toXmlNodes()
      .expand((nodes) => nodes)
      .forEach((node) {
        final programme = _programmeFromNode(node, tvgIdToChannelId);
        if (programme != null) out.add(programme);
      });
  return out;
}

/// Builds a [Programme] from one `<programme>` XML node, or null when the
/// node should be skipped: not an element, no `channel` attribute, the
/// `channel` doesn't map to one of our channels, or `start`/`stop` don't
/// parse. Shared by [_parseXmltvBytes] and the [parseXmltvBatched] worker so
/// the element-handling rules live in exactly one place.
Programme? _programmeFromNode(
  XmlNode node,
  Map<String, String> tvgIdToChannelId,
) {
  if (node is! XmlElement) return null;
  final tvgId = node.getAttribute('channel');
  if (tvgId == null) return null;
  final channelId = tvgIdToChannelId[tvgId];
  if (channelId == null) return null; // not one of our channels
  final start = parseXmltvTime(node.getAttribute('start'));
  final stop = parseXmltvTime(node.getAttribute('stop'));
  if (start == null || stop == null) return null;
  return Programme(
    channelId: channelId,
    start: start,
    stop: stop,
    title: node.getElement('title')?.innerText.trim() ?? '',
    description: node.getElement('desc')?.innerText.trim(),
  );
}

/// Below this many buffered programmes, [parseXmltvBatched] flushes a batch.
/// Small compared to [_isolateXmltvThreshold]'s byte threshold, but the two
/// are independent knobs: this one just bounds how much a single guide
/// ingest holds in memory/transaction-batch at once.
const _defaultEpgBatchSize = 1000;

/// Streamed counterpart of [parseXmltv]: yields [Programme]s in bounded
/// batches of up to [batchSize] instead of building one big list, so a very
/// large guide never holds its entire parsed result in memory at once and a
/// consumer (`AppDatabase.replaceEpgStream`) can commit incrementally inside
/// one transaction.
///
/// Below [_isolateXmltvThreshold] (and not gzip — a tiny gzip can expand into
/// hundreds of MB) this parses inline as a single batch, exactly like
/// [parseXmltv]'s inline path — isolate-spawn overhead isn't worth it for a
/// small guide. At/above the threshold, parsing runs on a background isolate
/// via a raw [Isolate.spawn] + [ReceivePort]: the worker flushes a batch
/// every [batchSize] programmes (and a final partial batch), then a `null`
/// done sentinel; a parse error is sent back as an [XmltvParseException] and
/// thrown here.
///
/// Flow-controlled to one in-flight batch: a [ReceivePort] has no backpressure
/// — the worker could otherwise keep parsing and `send()`-ing at full speed
/// regardless of how fast this side drains them, so a consumer slower than the
/// parser (e.g. `AppDatabase.replaceEpgStream`'s chunked inserts on a
/// low-memory TV device) would let the *entire* guide pile up as unread
/// isolate messages — exactly the peak-memory blowup streaming was meant to
/// avoid. See [_parseXmltvBatchedWorker] for the ack handshake this method's
/// other half of.
///
/// [token], when given, is checked between batches: once cancelled, the
/// stream stops yielding further batches and instead throws
/// [LoadCancelledException] — deliberately an error, not a quiet stream
/// close, so a transactional consumer sees a reason to roll back rather than
/// mistaking early termination for a complete guide. A worker blocked
/// waiting for an ack that will never come (because we threw instead of
/// acking) is simply killed by the `finally` below — it doesn't need to be
/// unblocked gracefully.
Stream<List<Programme>> parseXmltvBatched(
  Uint8List bytes,
  Map<String, String> tvgIdToChannelId, {
  int batchSize = _defaultEpgBatchSize,
  LoadToken? token,
}) async* {
  if (token?.isCancelled ?? false) throw const LoadCancelledException();

  if (!isGzipBytes(bytes) && bytes.length < _isolateXmltvThreshold) {
    yield await _parseXmltvBytes((bytes, tvgIdToChannelId));
    return;
  }

  final receivePort = ReceivePort();
  Isolate? isolate;
  // Set from the worker's handshake message (its first send) — the channel
  // this side acks each batch on, one at a time.
  SendPort? ackSendPort;
  try {
    isolate = await Isolate.spawn(_parseXmltvBatchedWorker, (
      receivePort.sendPort,
      bytes,
      tvgIdToChannelId,
      batchSize,
    ));
    await for (final message in receivePort) {
      if (message is SendPort) {
        // Handshake: the worker's ack channel. Not a batch — keep listening.
        ackSendPort = message;
        continue;
      }
      if (message == null) break; // done sentinel
      if (message is _XmltvBatchError) {
        throw XmltvParseException(message.message);
      }
      if (token?.isCancelled ?? false) {
        throw const LoadCancelledException();
      }
      yield message as List<Programme>;
      // An `async*` generator only resumes past `yield` once its own
      // consumer (here, `AppDatabase.replaceEpgStream`'s `await for`) has
      // finished processing this batch and asked for the next — so acking
      // here is exactly "the batch we just sent is done with", telling the
      // worker it may parse on and send the next one.
      ackSendPort?.send(null);
    }
  } finally {
    receivePort.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// Isolate entry point for [parseXmltvBatched]'s large-guide path. Decodes
/// (gzip-aware, mirroring [_parseXmltvBytes]) and event-parses [args]' bytes,
/// sending a `List<Programme>` batch to the main isolate every `batchSize`
/// programmes plus a final partial batch, then a `null` done sentinel. A
/// parse failure is caught and forwarded as an [_XmltvBatchError] — thrown
/// exceptions don't cross isolate boundaries on their own.
///
/// One in-flight batch by design: a bare [ReceivePort] has no backpressure —
/// without this, the worker would happily parse and `send()` at full CPU
/// speed regardless of how fast the other side drains the port, so a slow
/// consumer (chunked DB inserts on a low-memory TV device) would let the
/// entire guide queue up as unread messages, defeating the whole point of
/// streaming instead of building one big list. So: this worker opens its own
/// ack [ReceivePort], hands its [SendPort] to the caller as the very first
/// message (before any data), then after every `send()` of a batch — mid-feed
/// or the final partial one — blocks on one ack from [parseXmltvBatched]
/// before parsing on. `await for` (rather than the single-list path's
/// `forEach`) is what makes that mid-loop await possible.
void _parseXmltvBatchedWorker(
  (SendPort, Uint8List, Map<String, String>, int) args,
) async {
  final (sendPort, bytes, tvgIdToChannelId, batchSize) = args;
  final ackPort = ReceivePort();
  sendPort.send(ackPort.sendPort); // handshake: ack channel first
  final acks = StreamIterator<dynamic>(ackPort);
  try {
    final data = isGzipBytes(bytes)
        ? decodeGzipBounded(bytes, kEpgWorkload.maximumDecodedBytes)
        : bytes;
    var batch = <Programme>[];
    final nodes = _decodeChunked(data)
        .toXmlEvents()
        .normalizeEvents()
        .selectSubtreeEvents((e) => e.name == 'programme')
        .toXmlNodes()
        .expand((nodes) => nodes);
    await for (final node in nodes) {
      final programme = _programmeFromNode(node, tvgIdToChannelId);
      if (programme == null) continue;
      batch.add(programme);
      if (batch.length >= batchSize) {
        sendPort.send(batch);
        batch = <Programme>[];
        // Wait for the ack before parsing on. If the consumer went away
        // without acking (cancellation), it's a moot point in practice —
        // `parseXmltvBatched`'s `finally` kills this isolate outright — but
        // bail cleanly if the ack port ever closes instead.
        if (!await acks.moveNext()) return;
      }
    }
    if (batch.isNotEmpty) {
      sendPort.send(batch);
      if (!await acks.moveNext()) return;
    }
    sendPort.send(null);
  } catch (error) {
    sendPort.send(_XmltvBatchError(error.toString()));
  } finally {
    ackPort.close();
  }
}

/// Data-only marker sent back from [_parseXmltvBatchedWorker] when parsing
/// fails, since a thrown exception doesn't cross the isolate boundary as-is.
class _XmltvBatchError {
  final String message;
  const _XmltvBatchError(this.message);
}

/// Thrown by [parseXmltvBatched] when the background isolate's parse itself
/// fails (e.g. truncated/invalid XML). [parseXmltv]'s `compute()`-based path
/// surfaces the original error type instead — this one exists only because a
/// raw [Isolate.spawn] can't forward exceptions natively the way [compute]
/// does.
class XmltvParseException implements Exception {
  final String message;
  const XmltvParseException(this.message);

  @override
  String toString() => 'XmltvParseException: $message';
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
