import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:xml/xml_events.dart';

import '../data/load_token.dart';
import '../data/net.dart';
import 'epg_matching.dart';
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

/// [data] as a stream of bounded slices (views, not copies).
Stream<List<int>> _chunksOf(Uint8List data) async* {
  for (var i = 0; i < data.length; i += _xmlChunkBytes) {
    final end = i + _xmlChunkBytes;
    yield Uint8List.sublistView(data, i, end < data.length ? end : data.length);
  }
}

/// Where a guide's raw bytes are: in memory, or in a file a download streamed
/// to disk. Exactly one of the two is set. Both cross an isolate boundary
/// cheaply — a path is a string, and in-memory input is only ever small or a
/// test fixture.
typedef _GuideInput = ({Uint8List? bytes, String? path});

/// The guide's raw bytes, decompressed if it is gzip, as a stream.
///
/// **Nothing here holds the guide in memory.** The compressed bytes come off
/// disk 64 KiB at a time, gzip inflates them as they arrive, and the decoded
/// stream feeds the XML parser chunk by chunk — so a guide's size costs disk
/// and parse time, never RAM. Holding the whole compressed body and then the
/// whole decompressed body was what capped guides at 128 MB: an "all
/// countries" guide (~192 MB compressed, ~1.7 GB decompressed) was roughly
/// 1.9 GB of heap on hardware that is routinely a 2 GiB TV box.
///
/// [kEpgWorkload]'s decoded ceiling still applies, as a bound on *work* — a
/// tiny gzip can still expand without limit, and the count is kept here, on
/// the decoded stream, rather than trusted to any header.
Future<Stream<List<int>>> _decodedGuideBytes(_GuideInput input) async {
  final Stream<List<int>> raw;
  final bool gzipped;
  final bytes = input.bytes;
  if (bytes != null) {
    raw = _chunksOf(bytes);
    gzipped = isGzipBytes(bytes);
  } else {
    final file = File(input.path!);
    final handle = await file.open();
    try {
      gzipped = isGzipBytes(await handle.read(2));
    } finally {
      await handle.close();
    }
    raw = file.openRead();
  }
  final decoded = gzipped ? raw.transform(gzip.decoder) : raw;
  return _boundedBytes(decoded, kEpgWorkload.maximumDecodedBytes);
}

Stream<List<int>> _boundedBytes(Stream<List<int>> source, int maximum) async* {
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maximum) {
      throw HttpWorkloadException(
        'decoded guide is over the ${formatBytes(maximum)} limit',
      );
    }
    yield chunk;
  }
}

/// The guide as XML event lists, ready for [_GuideExtractor].
///
/// `validateNesting` is what makes a truncated download an error rather than
/// a short guide: the extractor only looks at the elements it wants, so
/// without it a body cut off between two programmes would parse "cleanly".
Future<Stream<List<XmlEvent>>> _guideEvents(_GuideInput input) async =>
    (await _decodedGuideBytes(input))
        .transform(const Utf8Decoder(allowMalformed: true))
        .toXmlEvents(validateNesting: true);

/// Parse XMLTV [bytes] (gzip-aware) into [Programme]s, keeping only programmes
/// on a channel that [XmltvChannelResolver] maps onto one of ours. Used by M3U
/// and Xtream sources.
///
/// [nameToChannelIds] (from `buildChannelNameIndex`) enables the name-matching
/// fallback for guide channels whose id isn't one of our `tvg-id`s — the whole
/// point of a *third-party* guide, whose ids never line up with the provider's.
/// Omitting it leaves exact `tvg-id` matching only.
Future<List<Programme>> parseXmltv(
  Uint8List bytes,
  Map<String, String> tvgIdToChannelId, {
  Map<String, List<String>> nameToChannelIds = const {},
}) {
  final args = (
    (bytes: bytes, path: null) as _GuideInput,
    tvgIdToChannelId,
    nameToChannelIds,
  );
  // A tiny gzip can expand into hundreds of MB, so compressed input always
  // goes to the worker even when it is below the ordinary isolate threshold.
  if (!isGzipBytes(bytes) && bytes.length < _isolateXmltvThreshold) {
    return _parseXmltvAll(args);
  }
  return compute(_parseXmltvAll, args);
}

/// Pulls programmes out of a stream of XMLTV events, one event at a time.
///
/// This replaced `selectSubtreeEvents(...).toXmlNodes()`, which built a full
/// DOM subtree for **every** `<programme>` in the guide and only then asked
/// whether its channel was one of ours. For a provider's own guide nearly
/// every programme is, so that cost little; for the guides users actually add
/// — a country or "all countries" file of which a playlist matches a few
/// hundred channels out of tens of thousands — nearly every programme is
/// thrown away, and building it first was most of the parse. Here a
/// programme's channel, start and stop are read off its *start tag*, and one
/// that can't contribute is skipped by depth-counting to its end tag: its text
/// is never even entity-decoded.
///
/// Doing it at event level is also what makes that early decision **sound**.
/// [XmltvChannelResolver] settles its claims at the first `resolve`, and must
/// have seen every `<channel>` declaration by then (the XMLTV DTD orders them
/// first). A `selectSubtreeEvents` predicate runs over a whole event *list*
/// before any node from that list reaches the handler, so a resolve from the
/// predicate could fire before the last channels in the same chunk were
/// declared. One sequential pass has no such window.
///
/// Matches the DOM version's reading exactly: a channel's names are its
/// direct `<display-name>` children, a programme's title and description are
/// its first direct `<title>`/`<desc>`, and an element's text is the
/// concatenation of all text and CDATA beneath it, trimmed.
class _GuideExtractor {
  _GuideExtractor(this.resolver);

  final XmltvChannelResolver resolver;

  /// Depth inside the element being captured or skipped; 0 when outside both.
  int _depth = 0;
  bool _skipping = false;

  // `<channel>` capture.
  bool _inChannel = false;
  String? _channelId;
  final List<String> _names = [];

  // `<programme>` capture.
  bool _inProgramme = false;
  List<String> _channelIds = const [];
  DateTime? _start;
  DateTime? _stop;
  String? _title;
  String? _desc;

  // The direct child whose text is being collected, if any.
  String? _field;
  final StringBuffer _text = StringBuffer();

  void add(XmlEvent event, List<Programme> out) {
    if (_skipping) {
      if (event is XmlStartElementEvent) {
        if (!event.isSelfClosing) _depth++;
      } else if (event is XmlEndElementEvent) {
        if (--_depth == 0) _skipping = false;
      }
      return;
    }
    if (_inChannel || _inProgramme) {
      _inside(event, out);
      return;
    }
    if (event is! XmlStartElementEvent) return;
    switch (event.name) {
      case 'channel':
        final id = _attribute(event, 'id');
        if (event.isSelfClosing) {
          if (id != null) resolver.declareChannel(id, const []);
          return;
        }
        _inChannel = true;
        _depth = 1;
        _channelId = id;
        _names.clear();
      case 'programme':
        final guideId = _attribute(event, 'channel');
        final channelIds = guideId == null
            ? const <String>[]
            : resolver.resolve(guideId);
        final start = channelIds.isEmpty
            ? null
            : parseXmltvTime(_attribute(event, 'start'));
        final stop = start == null
            ? null
            : parseXmltvTime(_attribute(event, 'stop'));
        if (stop == null) {
          // Not one of ours, or unusable: skip the subtree unread.
          if (!event.isSelfClosing) {
            _skipping = true;
            _depth = 1;
          }
          return;
        }
        _channelIds = channelIds;
        _start = start;
        _stop = stop;
        _title = null;
        _desc = null;
        if (event.isSelfClosing) {
          _emit(out);
          return;
        }
        _inProgramme = true;
        _depth = 1;
    }
  }

  void _inside(XmlEvent event, List<Programme> out) {
    if (event is XmlStartElementEvent) {
      if (_depth == 1 && _field == null && _wantsField(event.name)) {
        if (event.isSelfClosing) {
          _closeField(event.name, '');
          return;
        }
        _field = event.name;
        _text.clear();
      }
      if (!event.isSelfClosing) _depth++;
    } else if (event is XmlEndElementEvent) {
      _depth--;
      if (_depth == 1 && _field != null) {
        _closeField(_field!, _text.toString());
        _field = null;
      } else if (_depth == 0) {
        _finish(out);
      }
    } else if (_field != null) {
      if (event is XmlTextEvent) {
        _text.write(event.value);
      } else if (event is XmlCDATAEvent) {
        _text.write(event.value);
      }
    }
  }

  bool _wantsField(String name) => _inChannel
      ? name == 'display-name'
      : (name == 'title' && _title == null) ||
            (name == 'desc' && _desc == null);

  void _closeField(String name, String text) {
    final trimmed = text.trim();
    if (_inChannel) {
      if (trimmed.isNotEmpty) _names.add(trimmed);
    } else if (name == 'title') {
      _title = trimmed;
    } else {
      _desc = trimmed;
    }
  }

  void _finish(List<Programme> out) {
    if (_inChannel) {
      _inChannel = false;
      final id = _channelId;
      if (id != null) resolver.declareChannel(id, List.of(_names));
      return;
    }
    _inProgramme = false;
    _emit(out);
  }

  /// One [Programme] *per claimed channel* — a single guide entry can serve a
  /// playlist's HD and SD rows both.
  void _emit(List<Programme> out) {
    for (final channelId in _channelIds) {
      out.add(
        Programme(
          channelId: channelId,
          start: _start!,
          stop: _stop!,
          title: _title ?? '',
          description: _desc,
        ),
      );
    }
  }

  static String? _attribute(XmlStartElementEvent event, String name) {
    for (final attribute in event.attributes) {
      if (attribute.name == name) return attribute.value;
    }
    return null;
  }
}

/// Top-level worker so it can run under [compute]. Returns every mapped
/// [Programme] in one list.
Future<List<Programme>> _parseXmltvAll(
  (_GuideInput, Map<String, String>, Map<String, List<String>>) args,
) async {
  final (input, tvgIdToChannelId, nameToChannelIds) = args;
  final extractor = _GuideExtractor(
    XmltvChannelResolver(
      tvgIdToChannelId: tvgIdToChannelId,
      nameToChannelIds: nameToChannelIds,
    ),
  );
  final out = <Programme>[];
  await for (final events in await _guideEvents(input)) {
    for (final event in events) {
      extractor.add(event, out);
    }
  }
  return out;
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
  Map<String, List<String>> nameToChannelIds = const {},
  int batchSize = _defaultEpgBatchSize,
  LoadToken? token,
}) async* {
  if (token?.isCancelled ?? false) throw const LoadCancelledException();

  if (!isGzipBytes(bytes) && bytes.length < _isolateXmltvThreshold) {
    yield await _parseXmltvAll((
      (bytes: bytes, path: null),
      tvgIdToChannelId,
      nameToChannelIds,
    ));
    return;
  }
  yield* _parseInWorker(
    (bytes: bytes, path: null),
    tvgIdToChannelId,
    nameToChannelIds,
    batchSize,
    token,
  );
}

/// [parseXmltvBatched] over a guide already on disk — the path every
/// downloaded guide takes (see `xmltvGuideFeed`). Always parses on the worker
/// isolate, which reads [file] itself: only the path crosses the boundary, so
/// neither isolate ever holds the guide.
Stream<List<Programme>> parseXmltvFileBatched(
  File file,
  Map<String, String> tvgIdToChannelId, {
  Map<String, List<String>> nameToChannelIds = const {},
  int batchSize = _defaultEpgBatchSize,
  LoadToken? token,
}) async* {
  if (token?.isCancelled ?? false) throw const LoadCancelledException();
  yield* _parseInWorker(
    (bytes: null, path: file.path),
    tvgIdToChannelId,
    nameToChannelIds,
    batchSize,
    token,
  );
}

Stream<List<Programme>> _parseInWorker(
  _GuideInput input,
  Map<String, String> tvgIdToChannelId,
  Map<String, List<String>> nameToChannelIds,
  int batchSize,
  LoadToken? token,
) async* {
  final receivePort = ReceivePort();
  Isolate? isolate;
  // Set from the worker's handshake message (its first send) — the channel
  // this side acks each batch on, one at a time.
  SendPort? ackSendPort;
  try {
    isolate = await Isolate.spawn(_parseXmltvBatchedWorker, (
      receivePort.sendPort,
      input,
      tvgIdToChannelId,
      nameToChannelIds,
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
/// (gzip-aware, streamed — see [_decodedGuideBytes]) and event-parses the guide,
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
  (SendPort, _GuideInput, Map<String, String>, Map<String, List<String>>, int)
  args,
) async {
  final (sendPort, input, tvgIdToChannelId, nameToChannelIds, batchSize) = args;
  final extractor = _GuideExtractor(
    XmltvChannelResolver(
      tvgIdToChannelId: tvgIdToChannelId,
      nameToChannelIds: nameToChannelIds,
    ),
  );
  final ackPort = ReceivePort();
  sendPort.send(ackPort.sendPort); // handshake: ack channel first
  final acks = StreamIterator<dynamic>(ackPort);
  try {
    var batch = <Programme>[];
    await for (final events in await _guideEvents(input)) {
      for (final event in events) {
        extractor.add(event, batch);
        if (batch.length >= batchSize) {
          // A programme serving several of our rows adds one per row, so a
          // batch can overshoot; send exactly [batchSize] and carry the rest.
          final rest = batch.sublist(batchSize);
          sendPort.send(batch.sublist(0, batchSize));
          batch = rest;
          // Wait for the ack before parsing on. If the consumer went away
          // without acking (cancellation), it's a moot point in practice —
          // `parseXmltvBatched`'s `finally` kills this isolate outright — but
          // bail cleanly if the ack port ever closes instead.
          if (!await acks.moveNext()) return;
        }
      }
    }
    while (batch.isNotEmpty) {
      final take = batch.length < batchSize ? batch.length : batchSize;
      sendPort.send(batch.sublist(0, take));
      batch = batch.sublist(take);
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
