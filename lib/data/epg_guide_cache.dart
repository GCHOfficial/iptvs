/// The device-local body cache behind conditional XMLTV guide downloads.
///
/// A guide is the largest thing this app downloads — a real user-added
/// "all countries" file arrived as a **196,725,492-byte uncompressed body on
/// every refresh**, competing with a 4K live stream for bandwidth at app
/// start. Two things fix that, and both need somewhere to keep the last body:
/// `Accept-Encoding: gzip` (so a guide that *can* be compressed is), and a
/// conditional GET (so a guide that hasn't changed isn't sent at all).
///
/// Everything here is best-effort. A cache miss, an unreadable sidecar, a
/// directory that can't be created — each one degrades to the unconditional
/// download the app has always done, never to a failed refresh.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'diagnostics_log.dart';
import 'net.dart';

/// Total bytes of cached guide bodies kept on disk.
///
/// **Size-capped LRU is the whole eviction policy** — deliberately, over
/// "delete the entry when its guide URL is no longer configured" and over
/// clearing on `AppDatabase.invalidateEpg`:
///
/// * Nothing here can see the configured set. Sources are built per card and
///   per profile, a cloud pull rewrites `fields['epgUrls']` with no local
///   event, and the same URL can be shared by two sources — so a
///   "delete what nobody references" sweep would need a global enumeration of
///   every profile's sources just to reach the conclusion a cap reaches by
///   itself: an entry nobody revalidates stops being touched and ages out.
/// * `invalidateEpg` is the *wrong* hook. It is called when the guide **list**
///   is saved, and its job is to redo the merge (the claim order changed), not
///   to dispute the bytes — the body for a URL that is still configured is
///   still byte-for-byte what the server would send, so busting it there would
///   throw away the one download the user's edit did not invalidate.
/// * Only a cap bounds the disk a 200 MB guide can take, which is the number
///   that actually matters on a 2 GiB TV box.
///
/// Sized at roughly ten times the realistic working set (a provider guide plus
/// one or two gzipped top-ups). A set of guides whose bodies jointly exceed
/// this simply evicts across refreshes and re-downloads — exactly today's
/// behaviour, never worse.
const int kEpgGuideCacheMaxBytes = 256 * 1024 * 1024;

/// How long a `.part` file left by a killed process is kept before the next
/// eviction sweep reaps it.
const Duration kEpgGuidePartialTtl = Duration(days: 1);

/// One guide URL's place in [EpgGuideCache]: where a fresh body is downloaded,
/// where the last good body lives, and the validators to revalidate it with.
///
/// Obtained from [EpgGuideCache.slotFor] and released by the caller's
/// `finally` — `release()` deletes only the in-progress `.part` file, never a
/// published body.
class EpgGuideCacheSlot {
  EpgGuideCacheSlot._(this._cache, this.key);

  final EpgGuideCache _cache;

  /// SHA-256 of the guide URL, hex. **The file name is a hash and never the
  /// URL**: a guide URL routinely carries the provider's credentials
  /// (`xmltv.php?username=…&password=…`), and a cache directory is readable by
  /// anything that can read the app's storage, lands in device backups, and is
  /// the first thing a support request screenshots.
  final String key;

  String? _etag;
  String? _lastModified;
  int? _bytes;

  /// `ETag` of the cached body, or null when there is no usable one.
  String? get etag => _etag;

  /// `Last-Modified` of the cached body, or null when there is no usable one.
  String? get lastModified => _lastModified;

  /// The file a fresh download is written to. Published atomically by
  /// [publish]; deleted by [release] when it wasn't.
  ///
  /// **Unique per slot, not just per URL.** Guide refreshes are serialised by
  /// `AppDatabase.epgIngest`, but two sources can be configured with the same
  /// guide URL, and `HttpOperation.readToFile` deletes its destination before
  /// writing — so a shared `.part` name would let one download truncate the
  /// other's. A stale one left by a killed process is reaped by [makeRoom].
  late final File downloadFile = File(
    '${_cache.directory.path}/$key.${_attempt++}'
    '${DateTime.now().microsecondsSinceEpoch}.part',
  );

  File get _bodyFile => File('${_cache.directory.path}/$key.body');
  File get _metaFile => File('${_cache.directory.path}/$key.meta');

  Future<void> _load() async {
    final meta = await _readMeta();
    if (meta == null) return;
    final (:etag, :lastModified, :bytes) = meta;
    if (etag == null && lastModified == null) return;
    // The length check is the corruption test. A body that does not match the
    // byte count its sidecar recorded is a truncated or half-published file —
    // including the crash window between writing the sidecar and renaming the
    // new body over the old one — and must never be served behind a 304.
    if (await _lengthOf(_bodyFile) != bytes) return;
    _etag = etag;
    _lastModified = lastModified;
    _bytes = bytes;
  }

  Future<({String? etag, String? lastModified, int bytes})?> _readMeta() async {
    try {
      if (!await _metaFile.exists()) return null;
      final decoded = jsonDecode(await _metaFile.readAsString());
      if (decoded is! Map) return null;
      final bytes = decoded['bytes'];
      if (bytes is! int || bytes <= 0) return null;
      final etag = decoded['etag'];
      final lastModified = decoded['last_modified'];
      return (
        etag: etag is String && etag.isNotEmpty ? etag : null,
        lastModified: lastModified is String && lastModified.isNotEmpty
            ? lastModified
            : null,
        bytes: bytes,
      );
    } catch (_) {
      // A disposable cache's answer to anything unreadable is "no entry".
      return null;
    }
  }

  /// The cached body to parse behind a 304, or null when it can no longer be
  /// trusted — in which case the caller downloads unconditionally rather than
  /// failing the refresh.
  Future<File?> usableBody() async {
    final bytes = _bytes;
    if (bytes == null) return null;
    final file = _bodyFile;
    if (await _lengthOf(file) != bytes) return null;
    // Touch for LRU: a guide held by 304s is in active use and must not be
    // evicted ahead of one nobody reads.
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // Best effort; a read-only timestamp is not worth failing over.
    }
    return file;
  }

  /// Publishes the freshly downloaded [downloadFile] as this slot's cached
  /// body and returns the file the parser should read.
  ///
  /// Returns [downloadFile] itself — uncached, cleaned up by [release] — when
  /// caching would buy nothing or could not be done:
  ///
  /// * neither validator was sent, so the next request could never be
  ///   conditional and the body would only ever occupy disk;
  /// * the body alone exceeds [EpgGuideCache.maximumBytes], where storing it
  ///   would evict every other guide to hold something the cap evicts next;
  /// * any filesystem error, including a rename Windows refuses over an open
  ///   file.
  ///
  /// The sidecar is written **before** the rename, so a crash in between
  /// leaves a sidecar whose `bytes` disagree with the old body — which
  /// [_load] rejects — rather than a sidecar that vouches for the wrong body.
  Future<File> publish({String? etag, String? lastModified}) async {
    if (etag == null && lastModified == null) return downloadFile;
    final length = await _lengthOf(downloadFile);
    if (length <= 0 || length > _cache.maximumBytes) return downloadFile;
    try {
      await _cache.makeRoom(length, keep: key);
      await _metaFile.writeAsString(
        jsonEncode({
          'etag': etag,
          'last_modified': lastModified,
          'bytes': length,
        }),
      );
      final published = await downloadFile.rename(_bodyFile.path);
      _etag = etag;
      _lastModified = lastModified;
      _bytes = length;
      return published;
    } catch (error) {
      try {
        if (await _metaFile.exists()) await _metaFile.delete();
      } catch (_) {
        // Nothing left to do; a stale sidecar without a matching body reads
        // as "no entry" anyway.
      }
      DiagnosticsLog.instance.add(
        'epg',
        'guide cache write failed, continuing uncached: '
            '${redactText('$error')}',
      );
      return downloadFile;
    }
  }

  /// Deletes the in-progress download if it was never published. Safe to call
  /// however the feed ended, and never touches a published body.
  Future<void> release() async {
    try {
      final file = downloadFile;
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stray `.part` is reaped by the next eviction sweep.
    }
  }
}

/// App-private, device-local store of the last body fetched for each guide URL.
///
/// **Never `SourceConfig.settings`.** That blob rides the source row into the
/// cloud panel, and an ETag is device state, not configuration.
class EpgGuideCache {
  EpgGuideCache(this.directory, {this.maximumBytes = kEpgGuideCacheMaxBytes});

  final Directory directory;
  final int maximumBytes;

  /// The slot for [url], with its validators loaded when a usable body is
  /// already on disk — or **null** when the directory itself cannot be made
  /// usable, on which the caller downloads to its own scratch file instead.
  /// Handing back a slot pointing into a directory that does not exist would
  /// turn a missing cache into a failed guide, which is the one thing this is
  /// not allowed to do.
  Future<EpgGuideCacheSlot?> slotFor(String url) async {
    try {
      await directory.create(recursive: true);
    } catch (_) {
      return null;
    }
    final slot = EpgGuideCacheSlot._(
      this,
      sha256.convert(utf8.encode(url)).toString(),
    );
    try {
      await slot._load();
    } catch (_) {
      // An unreadable sidecar means "no entry", not a failed refresh.
    }
    return slot;
  }

  /// Frees space for an incoming body of [incoming] bytes, oldest entry first,
  /// and reaps `.part` files older than [kEpgGuidePartialTtl] left by a killed
  /// process.
  ///
  /// [keep]'s own body is neither counted nor deleted: the publish that
  /// follows renames over it, so its bytes are reclaimed rather than spent.
  Future<void> makeRoom(int incoming, {required String keep}) async {
    final entries = <({String key, int bytes, DateTime at})>[];
    var total = 0;
    final cutoff = DateTime.now().subtract(kEpgGuidePartialTtl);
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.part')) {
        try {
          if ((await entity.lastModified()).isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {
          // Reaped next time.
        }
        continue;
      }
      if (!name.endsWith('.body')) continue;
      final key = name.substring(0, name.length - '.body'.length);
      if (key == keep) continue;
      try {
        final stat = await entity.stat();
        entries.add((key: key, bytes: stat.size, at: stat.modified));
        total += stat.size;
      } catch (_) {
        // Vanished under us; nothing to account for.
      }
    }
    entries.sort((a, b) => a.at.compareTo(b.at));
    for (final entry in entries) {
      if (total + incoming <= maximumBytes) return;
      total -= entry.bytes;
      await _deleteEntry(entry.key);
    }
  }

  Future<void> _deleteEntry(String key) async {
    for (final suffix in const ['.body', '.meta']) {
      try {
        final file = File('${directory.path}/$key$suffix');
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Next sweep.
      }
    }
  }
}

/// Distinguishes two slots created in the same microsecond.
int _attempt = 0;

Future<int> _lengthOf(File file) async {
  try {
    return await file.length();
  } catch (_) {
    return -1;
  }
}

/// Resolved once per process, including the failure: [getApplicationCacheDirectory]
/// is a plugin call, so it throws outright in a unit test with no platform
/// channels, and retrying it per guide would cost an exception per refresh for
/// an answer that cannot change.
Future<EpgGuideCache?>? _shared;

/// The process-wide guide cache, or null when no app-private cache directory
/// can be had — on which the caller downloads unconditionally, exactly as the
/// app did before this existed.
///
/// `getApplicationCacheDirectory` and **not** `getTemporaryDirectory`: the OS
/// temp directory is reaped behind the app's back on every platform this ships
/// to, which would turn every conditional GET into a full download at random.
Future<EpgGuideCache?> resolveEpgGuideCache() => _shared ??= () async {
  try {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/epg_guides');
    await dir.create(recursive: true);
    return EpgGuideCache(dir);
  } catch (error) {
    DiagnosticsLog.instance.add(
      'epg',
      'guide cache unavailable, downloads stay unconditional: '
          '${redactText('$error')}',
    );
    return null;
  }
}();

/// Pins (or clears, with null) the process-wide cache, so a test can exercise
/// the path a real `Source` takes — which resolves the cache itself rather
/// than being handed one — without a platform channel.
@visibleForTesting
void debugSetEpgGuideCache(EpgGuideCache? cache) =>
    _shared = cache == null ? null : Future.value(cache);
