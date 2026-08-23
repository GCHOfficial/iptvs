/// Merging the several XMLTV guides one source may carry into the single
/// programme stream `AppDatabase.replaceEpgStream` ingests.
///
/// A source has one guide by default — the provider's own. A user can add more
/// (a third-party XMLTV URL that covers what the provider's guide leaves blank),
/// and this is where they become one guide again.
library;

import 'dart:async';
import 'dart:typed_data';

import '../data/diagnostics_log.dart';
import '../data/load_token.dart';
import '../data/net.dart';
import 'source.dart';
import 'xmltv.dart';

/// The most guides one source may carry, primary included.
///
/// Every guide is a full download and a full parse on each EPG refresh, against
/// a workload where one guide already measures in the hundreds of MB and ~10^6
/// programmes (docs/validation-baseline.md). The cap is a guard against a
/// configuration that quietly turns a ~3-hourly background refresh into
/// something a TV box can't finish, not a statement about what's useful — in
/// practice the provider's guide plus one or two top-ups is the whole use case.
const int kMaxEpgGuides = 4;

/// One guide feeding a source's EPG.
class EpgGuideFeed {
  EpgGuideFeed({required this.open, this.url});

  /// Opens the guide's programme stream. Called at most once, and only when the
  /// merge actually reaches this feed — a lazy factory rather than a live
  /// `Stream` so a secondary guide's download never starts until the guides
  /// before it are done, keeping one HTTP body in flight at a time.
  final Stream<List<Programme>> Function() open;

  /// Where the guide came from, for diagnostics only. Logged through
  /// [redactUrl] — an EPG URL routinely carries the provider's credentials in
  /// its query string, and the diagnostics log is user-exportable.
  final String? url;
}

/// An [EpgGuideFeed] over an XMLTV URL.
///
/// [download] is the owning source's own fetch — each source already has one
/// carrying its timeouts, credentials, `User-Agent` and byte-budget metrics, so
/// injecting it keeps this helper usable by M3U, Xtream and Stalker alike
/// without opening a second [HttpClient] or duplicating any of that setup.
EpgGuideFeed xmltvGuideFeed({
  required String url,
  required Future<Uint8List> Function(Uri uri) download,
  required Map<String, String> tvgIdToChannelId,
  required Map<String, List<String>> nameToChannelIds,
  LoadToken? token,
}) => EpgGuideFeed(
  url: url,
  open: () async* {
    final bytes = await download(Uri.parse(url));
    yield* parseXmltvBatched(
      bytes,
      tvgIdToChannelId,
      nameToChannelIds: nameToChannelIds,
      token: token,
    );
  },
);

/// Feeds [guides] into one stream, in priority order, with **at most one guide
/// per channel**.
///
/// Not a plain concatenation, and that is the whole point. `programmes` rows
/// are keyed by `(source_id, channel_id)` with no notion of which guide wrote
/// them, and `AppDatabase.nowNext`'s "now" half is a bare
/// `start <= t AND stop > t` scan whose rows are folded into a map by
/// channel id — last row wins, arbitrarily. Two guides both covering a channel
/// would therefore make its now-playing programme *nondeterministic*, flipping
/// between them across refreshes, and would draw overlapping cells in the EPG
/// grid. So a channel is claimed by the first guide that carries it, and later
/// guides are filtered against those claims.
///
/// Claims are accumulated per guide and merged in only once that guide is
/// exhausted, so a guide is never filtered against itself.
///
/// Failure policy turns on **whether the failing guide had already yielded**.
///
/// A guide that fails before yielding anything — refused, 404, unreadable gzip
/// — has written nothing, so it is logged and skipped and the merge goes on.
/// That is the case the whole feature turns on: the *provider's* guide being
/// the broken one is the usual reason a user adds a top-up, and a policy that
/// failed the refresh there would block exactly the configuration being asked
/// for.
///
/// A guide that fails **mid-feed** is not survivable and rethrows. Its batches
/// are already inside the caller's transaction and cannot be taken back, so
/// completing normally would commit a *truncated* guide as a whole one:
/// `replaceEpgStream` would drop the previous guide and advance
/// `epg_synced_at`, so a network drop 80% through a large guide would cost the
/// user the complete one they had, with no retry for the whole refresh
/// interval. Throwing rolls the transaction back and keeps the last good guide.
///
/// If every guide fails without yielding, the last error is rethrown for the
/// same reason: a normally-completed empty stream reads as a successful *empty*
/// guide, which would clear the cache over a transient blip.
///
/// [LoadCancelledException] always propagates — cancellation is not a guide
/// failure, and swallowing it would commit a half-fed guide as if it were
/// complete.
Stream<List<Programme>> mergeEpgGuides(
  List<EpgGuideFeed> guides, {
  LoadToken? token,
}) async* {
  final claimed = <String>{};
  var failures = 0;
  Object? lastError;
  StackTrace? lastStack;
  for (var i = 0; i < guides.length; i++) {
    final guide = guides[i];
    final where = guide.url == null
        ? 'guide ${i + 1}'
        : 'guide ${i + 1} (${redactUrl(guide.url!)})';
    final fromThisGuide = <String>{};
    var kept = 0;
    var dropped = 0;
    var yielded = false;
    try {
      await for (final batch in guide.open()) {
        if (token?.isCancelled ?? false) throw const LoadCancelledException();
        // The first guide claims everything it carries, so skip the filter
        // entirely rather than testing an empty set per programme.
        if (i == 0) {
          for (final p in batch) {
            fromThisGuide.add(p.channelId);
          }
          kept += batch.length;
          yielded = true;
          yield batch;
          continue;
        }
        final out = <Programme>[];
        for (final p in batch) {
          if (claimed.contains(p.channelId)) {
            dropped++;
            continue;
          }
          fromThisGuide.add(p.channelId);
          out.add(p);
        }
        kept += out.length;
        // A batch filtered down to nothing is not yielded: every batch costs
        // the consumer a round trip through `replaceEpgStream`'s insert loop
        // and, upstream, one ack to the parser isolate.
        if (out.isNotEmpty) {
          yielded = true;
          yield out;
        }
      }
    } on LoadCancelledException {
      rethrow;
    } catch (error, stack) {
      // Already partly written — see the failure policy above. Nothing can undo
      // the batches this guide has fed into the caller's transaction, so the
      // only correct move is to fail the whole refresh and let it roll back.
      if (yielded) Error.throwWithStackTrace(error, stack);
      failures++;
      lastError = error;
      lastStack = stack;
      DiagnosticsLog.instance.add(
        'epg',
        '$where failed, continuing without it: ${redactText('$error')}',
      );
      continue;
    }
    claimed.addAll(fromThisGuide);
    if (i > 0 || guides.length > 1) {
      DiagnosticsLog.instance.add(
        'epg',
        '$where contributed $kept programmes across '
            '${fromThisGuide.length} channels'
            '${dropped > 0 ? ' ($dropped skipped, already covered)' : ''}',
      );
    }
  }
  if (guides.isNotEmpty && failures == guides.length) {
    // Nothing was yielded, so rethrowing here is what keeps the cached guide:
    // completing normally would look like a source that simply has no EPG.
    Error.throwWithStackTrace(lastError!, lastStack!);
  }
}
