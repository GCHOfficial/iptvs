/// Merging the several XMLTV guides one source may carry into the single
/// programme stream `AppDatabase.replaceEpgStream` ingests.
///
/// A source has one guide by default — the provider's own. A user can add more
/// (a third-party XMLTV URL that covers what the provider's guide leaves blank),
/// and this is where they become one guide again.
library;

import 'dart:async';
import 'dart:io';

import '../data/diagnostics_log.dart';
import '../data/epg_guide_cache.dart';
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

/// What a conditional guide request got back. The byte count is deliberately
/// absent: the caller stats the file it asked for, which is the one number a
/// 304 and a 200 can both be measured by.
typedef GuideDownloadResult = ({
  /// 200 or 304. Anything else has already been thrown by the downloader.
  int statusCode,
  String? etag,
  String? lastModified,
});

/// The owning source's fetch of one guide URL into one file.
///
/// Conditional when [ifNoneMatch]/[ifModifiedSince] are given: a `304 Not
/// Modified` writes nothing to [destination] and reports itself through
/// [GuideDownloadResult.statusCode], while any other non-200 throws as before.
typedef GuideDownload =
    Future<GuideDownloadResult> Function(
      Uri uri,
      File destination, {
      String? ifNoneMatch,
      String? ifModifiedSince,
    });

/// Fetches an XMLTV guide into [destination] over [client].
///
/// Shared by M3U, Xtream and Stalker because the three had byte-identical
/// copies of it and the conditional-request handling must not drift between
/// them. Each source still owns its own [HttpClient] (timeouts, proxy) and its
/// own [userAgent] — Stalker's deliberately bypasses the portal transport here,
/// so no MAC cookie or Bearer token can reach a user-supplied guide host.
///
/// **`Accept-Encoding: gzip` is sent explicitly**, because every one of those
/// clients sets `autoUncompress = false` — which, besides keeping `dart:io`'s
/// unbounded decoder out of the app, also suppresses the default
/// `Accept-Encoding` `dart:io` would otherwise have sent. So until this line
/// existed, a guide arrived uncompressed however the server was configured: a
/// real export showed a 196,725,492-byte body on **every** refresh. The body
/// is written to disk exactly as received and inflated later by the parser
/// worker from its magic bytes (`parseXmltvFileBatched`), so this app's
/// bounded decode stays the only decoder and a `.xml.gz` served as-is still
/// works. [kEpgWorkload]'s body ceiling now bounds *compressed* bytes; its
/// decoded ceiling is still enforced during inflation.
///
/// Logs `status=`, `content_encoding=` and `body_bytes=` for every guide, so an
/// export can tell a full download from a revalidated one.
Future<GuideDownloadResult> downloadXmltvGuide({
  required HttpClient client,
  required Uri uri,
  required File destination,
  String? userAgent,
  String? ifNoneMatch,
  String? ifModifiedSince,
  HttpWorkloadPolicy policy = kEpgWorkload,
}) async {
  final operation = HttpOperation(policy);
  final request = await operation.wait(client.getUrl(uri));
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
  if (userAgent != null) {
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
  }
  if (ifNoneMatch != null) {
    request.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
  }
  if (ifModifiedSince != null) {
    // `dart:io` parses this header itself and throws on anything it does not
    // recognise, so a server whose `Last-Modified` we stored verbatim but
    // cannot re-emit degrades to an ETag-only (or unconditional) request
    // rather than to a failed refresh.
    try {
      request.headers.set(
        HttpHeaders.ifModifiedSinceHeader,
        HttpDate.parse(ifModifiedSince),
      );
    } catch (_) {
      // Unparseable; send nothing for it.
    }
  }
  final response = await operation.wait(request.close());
  final encoding = contentEncodingLabel(response);
  if (response.statusCode == HttpStatus.notModified) {
    // A 304 has no body, but an unread response still holds its socket out of
    // the pool — the same reason the error path below drains.
    await response.drain<void>();
    DiagnosticsLog.instance.add(
      'http:${policy.name}',
      'status=304 content_encoding=$encoding body_bytes=0',
    );
    return (
      statusCode: HttpStatus.notModified,
      // RFC 9110 says a 304 carries the validators; when it doesn't, the
      // caller keeps the ones it already had rather than losing them.
      etag: response.headers.value(HttpHeaders.etagHeader) ?? ifNoneMatch,
      lastModified:
          response.headers.value(HttpHeaders.lastModifiedHeader) ??
          ifModifiedSince,
    );
  }
  if (response.statusCode != HttpStatus.ok) {
    // Drain before throwing: an unread body never returns its socket to the
    // pool, so a guide URL that 404s leaks one per EPG refresh.
    await response.drain<void>();
    // redactUrl strips credentials providers embed in the guide URL.
    throw StateError('HTTP ${response.statusCode} fetching ${redactUrl(uri)}');
  }
  final bytes = await operation.readToFile(response, destination);
  DiagnosticsLog.instance.add(
    'http:${policy.name}',
    'status=200 content_encoding=$encoding body_bytes=$bytes',
  );
  return (
    statusCode: HttpStatus.ok,
    etag: response.headers.value(HttpHeaders.etagHeader),
    lastModified: response.headers.value(HttpHeaders.lastModifiedHeader),
  );
}

/// An [EpgGuideFeed] over an XMLTV URL.
///
/// [download] is the owning source's own fetch — each source already has one
/// carrying its timeouts, credentials, `User-Agent` and byte-budget metrics, so
/// injecting it keeps this helper usable by M3U, Xtream and Stalker alike
/// without opening a second [HttpClient] or duplicating any of that setup.
///
/// The guide goes **to disk, not to memory**: [download] streams the body into
/// a file and the parser worker reads it back from there, inflating gzip as it
/// goes. Holding the whole compressed and then the whole decompressed body is
/// what used to cap guides at 128 MB — an "all countries" guide (~192 MB
/// compressed, ~1.7 GB decompressed) was ~1.9 GB of heap on a 2 GiB TV box.
/// Now its size costs disk while it is parsed, and parse time.
///
/// **Where that file lives decides whether the next refresh has to download at
/// all.** With an [EpgGuideCache] (the normal case) the body is downloaded
/// into, and parsed from, that URL's own slot in the app-private cache
/// directory — no copy — and the next refresh revalidates it with
/// `If-None-Match`/`If-Modified-Since`. A **304 is fed to the parser exactly
/// as a fresh download would have been**: the same `parseXmltvFileBatched`
/// over the same kind of file, so `mergeEpgGuides` and `replaceEpgStream` see
/// precisely the programmes a 200 would have produced and none of the EPG
/// contract moves. This is per guide on purpose — the merge is rebuilt whole on
/// every refresh, so one guide being unchanged says nothing about the others.
///
/// Without a cache (no app-private directory, or none injected in a test) the
/// body goes to a temp directory deleted however the feed ends, which is what
/// this always did.
EpgGuideFeed xmltvGuideFeed({
  required String url,
  required GuideDownload download,
  required Map<String, String> tvgIdToChannelId,
  required Map<String, List<String>> nameToChannelIds,
  LoadToken? token,
  Directory? tempDirectory,

  /// Resolves the body cache. Defaults to the process-wide one; a test injects
  /// its own directory, and returning null keeps every download unconditional.
  Future<EpgGuideCache?> Function()? openCache,

  /// Reports the guide's on-disk byte count — as transmitted, i.e. still
  /// gzipped when the server sent it that way — once the body is in hand,
  /// whether it was just downloaded or **reused from cache behind a 304**. A
  /// cheap `file.length()` stat, not a second copy of the body. Fed to
  /// [EpgByteReporting] so `LibraryRepository._ensureEpg` can sum every
  /// guide's cost into the exportable `ingestion compressed_bytes=…` line
  /// instead of leaving it `unknown`. Never called when the guide could not be
  /// obtained at all.
  void Function(int bytes)? onDownloaded,
}) => EpgGuideFeed(
  url: url,
  open: () async* {
    final uri = Uri.parse(url);
    final cache = await (openCache ?? resolveEpgGuideCache)();
    EpgGuideCacheSlot? slot;
    Directory? scratch;
    try {
      if (cache != null) slot = await cache.slotFor(url);
      final File target;
      if (slot != null) {
        target = slot.downloadFile;
      } else {
        scratch = await (tempDirectory ?? Directory.systemTemp).createTemp(
          'iptvs_guide_',
        );
        target = File('${scratch.path}/guide');
      }

      var result = await _fetchGuide(
        download,
        uri,
        target,
        ifNoneMatch: slot?.etag,
        ifModifiedSince: slot?.lastModified,
      );
      File body;
      if (result.statusCode == HttpStatus.notModified) {
        final cached = await slot?.usableBody();
        if (cached != null) {
          body = cached;
          DiagnosticsLog.instance.add(
            'epg',
            'guide ${redactUrl(url)} unchanged (304), reusing the cached body',
          );
        } else {
          // A 304 we cannot honour — the cached body went missing, no longer
          // matches its sidecar, or the server answered one we never asked
          // for. Never a failed refresh: ask again without validators.
          DiagnosticsLog.instance.add(
            'epg',
            'guide ${redactUrl(url)} answered 304 with no usable cached body; '
                'downloading it in full',
          );
          result = await _fetchGuide(download, uri, target);
          if (result.statusCode != HttpStatus.ok) {
            throw StateError(
              'HTTP ${result.statusCode} fetching ${redactUrl(uri)}',
            );
          }
          body = await _publish(slot, result) ?? target;
        }
      } else {
        body = await _publish(slot, result) ?? target;
      }
      if (onDownloaded != null) {
        try {
          onDownloaded(await body.length());
        } catch (_) {
          // A diagnostics stat is never worth failing a guide over.
        }
      }
      yield* parseXmltvFileBatched(
        body,
        tvgIdToChannelId,
        nameToChannelIds: nameToChannelIds,
        token: token,
      );
    } finally {
      // Deletes only an unpublished download; a cached body stays for the next
      // refresh to revalidate.
      await slot?.release();
      if (scratch != null) {
        try {
          await scratch.delete(recursive: true);
        } catch (_) {
          // A temp file the OS will reap is not worth failing a guide over.
        }
      }
    }
  },
);

Future<GuideDownloadResult> _fetchGuide(
  GuideDownload download,
  Uri uri,
  File destination, {
  String? ifNoneMatch,
  String? ifModifiedSince,
}) async {
  try {
    return await download(
      uri,
      destination,
      ifNoneMatch: ifNoneMatch,
      ifModifiedSince: ifModifiedSince,
    );
  } on HttpWorkloadException catch (error) {
    // What the user needs is the way out, not the number. Most publishers of a
    // combined guide also publish per-country files two orders of magnitude
    // smaller, and one of those is what a player wants.
    throw HttpWorkloadException(
      '${error.message}. Use a per-country or per-provider guide instead.',
    );
  }
}

Future<File?> _publish(EpgGuideCacheSlot? slot, GuideDownloadResult result) =>
    slot == null
    ? Future.value()
    : slot.publish(etag: result.etag, lastModified: result.lastModified);

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
