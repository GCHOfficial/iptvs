/// Staging a parsed EPG guide on disk so the database transaction that ingests
/// it never waits on the network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../sources/source.dart';
import 'diagnostics_log.dart';

/// A parsed guide, drained to a temporary file, ready to be replayed into
/// `AppDatabase.replaceEpgStream`.
///
/// **Why this exists.** `replaceEpgStream` holds one write transaction for the
/// whole ingest — that is its atomicity contract and it is correct. The problem
/// was what it was holding it *across*: the batches it consumed were produced
/// lazily by `mergeEpgGuides`, whose first act on each guide is an HTTP
/// download. So the transaction — on the single sqflite connection this whole
/// app shares — stayed open for the entire download and parse of every guide.
///
/// Two things follow from that, and both were observed:
///
///  * Every other database operation queues behind it. Not just writes: sqflite
///    serialises *all* work on its one connection, so a channel read, a now/next
///    query and a favorite toggle all wait too. With the refresh awaited the
///    user at least saw a spinner; the moment it was moved to the background it
///    became an unexplained multi-second freeze, and a source switch mid-ingest
///    deadlocked outright (`channel_list_focus_test` hung for ten minutes with
///    sqflite's own "database has been locked for 0:00:10" warning).
///  * The lock had **no upper bound**. A guide server that accepts the
///    connection and then stalls holds the entire application's database until
///    the read timeout fires.
///
/// Draining to a spool first splits those two phases apart: fetch, decompress
/// and parse happen here, with no transaction open and nothing else blocked;
/// the transaction is then opened over a local file and lasts only as long as
/// the inserts do. That is what makes the refresh safe to move off the load's
/// critical path.
///
/// Memory is bounded the same way the streaming parser already bounds it — one
/// batch at a time, written out and released — so this trades transient disk
/// for a lock window, not for RAM.
class ProgrammeSpool {
  ProgrammeSpool._(this._file, this.batches, this.programmes, this.bytes);

  final File _file;

  /// How many batches were spooled — the number of frames [read] will replay.
  final int batches;

  /// How many programmes the guide carried in total.
  final int programmes;

  /// The spool file's size on disk.
  final int bytes;

  /// Consumes [source] to a temporary file.
  ///
  /// Errors are **not** swallowed: an exception from [source] (a failed guide,
  /// a parse error, a `LoadCancelledException`) deletes the partial spool and
  /// propagates, so the caller behaves exactly as it did when the stream fed a
  /// transaction directly — nothing is written and the previously cached guide
  /// stands.
  ///
  /// That the failure now happens *outside* a transaction is a strict
  /// improvement rather than a change of contract: there is no partially
  /// written guide to roll back in the first place.
  static Future<ProgrammeSpool> drain(
    Stream<List<Programme>> source, {
    Directory? directory,
  }) async {
    final dir = directory ?? Directory.systemTemp;
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      'iptvs_epg_${DateTime.now().microsecondsSinceEpoch}_$_sequence.spool',
    );
    _sequence++;
    IOSink? sink;
    var batches = 0;
    var programmes = 0;
    try {
      await file.parent.create(recursive: true);
      sink = file.openWrite();
      await for (final batch in source) {
        if (batch.isEmpty) continue;
        sink.add(_encodeFrame(batch));
        batches++;
        programmes += batch.length;
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (_) {
      // `close()` on a sink whose write already failed rethrows that same
      // error, which would mask the real one — the file is being deleted
      // either way, so the close result is of no interest.
      try {
        await sink?.close();
      } catch (_) {}
      await _deleteQuietly(file);
      rethrow;
    }
    final bytes = await file.length();
    return ProgrammeSpool._(file, batches, programmes, bytes);
  }

  /// Replays the spooled guide, one batch per frame, in the order it arrived.
  ///
  /// Read frame-at-a-time rather than by decoding the whole file, so the peak
  /// memory of the ingest stays one batch — the same bound the parser works to.
  Stream<List<Programme>> read() async* {
    final handle = await _file.open();
    try {
      final header = Uint8List(4);
      while (true) {
        if (await handle.readInto(header) != header.length) break;
        final length = header.buffer.asByteData().getUint32(0, Endian.little);
        final frame = await handle.read(length);
        if (frame.length != length) {
          // Only reachable if something outside this class truncated the spool
          // between writing and reading. Louder than a short batch, which the
          // consumer would commit as a complete guide.
          throw StateError('EPG spool truncated: expected $length bytes');
        }
        yield _decodeFrame(frame);
      }
    } finally {
      await handle.close();
    }
  }

  /// Removes the spool file. Safe to call more than once.
  Future<void> dispose() => _deleteQuietly(_file);

  static int _sequence = 0;

  /// `[uint32 little-endian payload length][utf8 JSON payload]`.
  ///
  /// Length-prefixed so [read] can hand back one batch at a time without
  /// scanning, and so a truncated file is detected rather than silently read as
  /// a shorter guide.
  static Uint8List _encodeFrame(List<Programme> batch) {
    final payload = utf8.encode(
      jsonEncode([
        for (final p in batch)
          // A flat list, not a map: the keys would be repeated once per
          // programme, and a guide runs to six figures of them.
          [
            p.channelId,
            p.start.millisecondsSinceEpoch,
            p.stop.millisecondsSinceEpoch,
            p.title,
            p.description,
          ],
      ]),
    );
    final frame = Uint8List(4 + payload.length);
    frame.buffer.asByteData().setUint32(0, payload.length, Endian.little);
    frame.setRange(4, frame.length, payload);
    return frame;
  }

  static List<Programme> _decodeFrame(Uint8List frame) {
    final rows = jsonDecode(utf8.decode(frame)) as List<dynamic>;
    return [
      for (final row in rows.cast<List<dynamic>>())
        Programme(
          channelId: row[0] as String,
          start: DateTime.fromMillisecondsSinceEpoch(row[1] as int),
          stop: DateTime.fromMillisecondsSinceEpoch(row[2] as int),
          title: row[3] as String,
          description: row[4] as String?,
        ),
    ];
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      // A leftover spool costs temporary disk that the OS reclaims; failing the
      // refresh over it would cost the user their guide.
      DiagnosticsLog.instance.add(
        'epg',
        'could not remove EPG spool: ${error.runtimeType}',
      );
    }
  }
}
