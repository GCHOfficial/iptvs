import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Named limits for one HTTP workload. The wire/body ceiling is separate from
/// the decoded ceiling so compressed responses cannot become decompression
/// bombs. [totalTimeout] never resets; [idleTimeout] resets for each chunk.
class HttpWorkloadPolicy {
  const HttpWorkloadPolicy({
    required this.name,
    required this.maximumBodyBytes,
    required this.maximumDecodedBytes,
    required this.totalTimeout,
    this.idleTimeout = const Duration(seconds: 20),
  });

  final String name;
  final int maximumBodyBytes;
  final int maximumDecodedBytes;
  final Duration idleTimeout;
  final Duration totalTimeout;

  HttpWorkloadPolicy copyWith({
    String? name,
    int? maximumBodyBytes,
    int? maximumDecodedBytes,
    Duration? idleTimeout,
    Duration? totalTimeout,
  }) => HttpWorkloadPolicy(
    name: name ?? this.name,
    maximumBodyBytes: maximumBodyBytes ?? this.maximumBodyBytes,
    maximumDecodedBytes: maximumDecodedBytes ?? this.maximumDecodedBytes,
    idleTimeout: idleTimeout ?? this.idleTimeout,
    totalTimeout: totalTimeout ?? this.totalTimeout,
  );
}

class HttpReadMetrics {
  final int compressedBytes;
  final int decodedBytes;
  const HttpReadMetrics({
    required this.compressedBytes,
    required this.decodedBytes,
  });
}

const int _mib = 1024 * 1024;

/// Provider payload limits are deliberately generous relative to normal API
/// responses. They stop hostile/unconfigured endpoints without rejecting the
/// large catalogs represented by the PR 0 fixtures.
const kPlaylistWorkload = HttpWorkloadPolicy(
  name: 'playlist',
  maximumBodyBytes: 128 * _mib,
  maximumDecodedBytes: 256 * _mib,
  totalTimeout: Duration(minutes: 5),
);
const kEpgWorkload = HttpWorkloadPolicy(
  name: 'epg',
  maximumBodyBytes: 128 * _mib,
  maximumDecodedBytes: 512 * _mib,
  totalTimeout: Duration(minutes: 8),
);
const kProviderJsonWorkload = HttpWorkloadPolicy(
  name: 'provider JSON',
  maximumBodyBytes: 128 * _mib,
  maximumDecodedBytes: 256 * _mib,
  totalTimeout: Duration(minutes: 3),
);
const kStalkerJsonWorkload = HttpWorkloadPolicy(
  name: 'Stalker JSON',
  // Real portals can return the entire live catalog from get_all_channels in
  // one response. The PR 0 50k-row fixture is ~11 MiB and a user-validated
  // portal exceeds 16 MiB, so retain a meaningful ceiling without rejecting
  // legitimate large catalogs.
  maximumBodyBytes: 64 * _mib,
  maximumDecodedBytes: 128 * _mib,
  totalTimeout: Duration(minutes: 1),
);
const kMetadataJsonWorkload = HttpWorkloadPolicy(
  name: 'metadata JSON',
  maximumBodyBytes: 4 * _mib,
  maximumDecodedBytes: 8 * _mib,
  totalTimeout: Duration(seconds: 45),
);
const kUpdateDiscoveryWorkload = HttpWorkloadPolicy(
  name: 'update discovery',
  maximumBodyBytes: 1024 * 1024,
  maximumDecodedBytes: 2 * 1024 * 1024,
  totalTimeout: Duration(seconds: 45),
);
const kUpdateArtifactWorkload = HttpWorkloadPolicy(
  name: 'update artifact',
  maximumBodyBytes: 1024 * _mib,
  maximumDecodedBytes: 1024 * _mib,
  totalTimeout: Duration(minutes: 30),
);

/// Retained for native/update call sites that only need an idle timeout.
const Duration kHttpReadTimeout = Duration(seconds: 20);

class HttpWorkloadException implements Exception {
  const HttpWorkloadException(this.message);
  final String message;

  @override
  String toString() => 'HttpWorkloadException: $message';
}

/// Whether a provider operation is worth retrying automatically.
///
/// Some provider implementations preserve the original dart:io exception,
/// while older Stalker endpoint discovery wraps it in a provider exception.
/// Keep the textual fallback deliberately narrow: size/policy failures and
/// authentication failures must fail immediately rather than repeating an
/// expensive catalog request.
bool isTransientNetworkError(Object error) {
  if (error is HttpWorkloadException) return false;
  if (error is TimeoutException ||
      error is SocketException ||
      error is HttpException) {
    return true;
  }
  final message = error.toString().toLowerCase();
  return message.contains('timed out') ||
      message.contains('timeoutexception') ||
      message.contains('connection reset') ||
      message.contains('connection closed') ||
      message.contains('connection refused') ||
      message.contains('network is unreachable') ||
      message.contains('temporary failure in name resolution');
}

/// Retries one transient provider failure, while leaving policy, parsing, and
/// authentication failures untouched.
Future<T> retryTransientNetworkOperation<T>(
  Future<T> Function() operation, {
  int maximumAttempts = 2,
  Duration retryDelay = const Duration(milliseconds: 600),
  void Function(Object error, int nextAttempt)? onRetry,
}) async {
  if (maximumAttempts < 1) {
    throw ArgumentError.value(maximumAttempts, 'maximumAttempts');
  }
  for (var attempt = 1; ; attempt++) {
    try {
      return await operation();
    } catch (error) {
      if (attempt >= maximumAttempts || !isTransientNetworkError(error)) {
        rethrow;
      }
      onRetry?.call(error, attempt + 1);
      if (retryDelay > Duration.zero) await Future<void>.delayed(retryDelay);
    }
  }
}

/// Short text suitable for a source-loading page. Provider exceptions can
/// contain request URLs, response bodies, or nested stack-like messages, so
/// those details stay in redacted diagnostics rather than the widget tree.
String sourceLoadErrorMessage(Object error) {
  if (isTransientNetworkError(error)) {
    return 'The source did not respond in time. We retried automatically; '
        'check the connection and try again.';
  }
  if (error is HttpWorkloadException) {
    return 'The source returned more data than the app can safely load.';
  }
  final message = error.toString().toLowerCase();
  if (message.contains('unauthorized') ||
      message.contains('forbidden') ||
      message.contains('invalid credential') ||
      message.contains('authentication')) {
    return 'The source rejected the saved credentials. Check the source details.';
  }
  return 'The source could not be loaded. Check its details and try again.';
}

/// One non-resetting deadline spanning request creation, headers, redirects,
/// body transfer, and optional decoding.
class HttpOperation {
  HttpOperation(this.policy, {this.onReadMetrics})
    : _stopwatch = Stopwatch()..start();

  final HttpWorkloadPolicy policy;
  final Stopwatch _stopwatch;
  HttpReadMetrics? lastReadMetrics;
  final void Function(HttpReadMetrics metrics)? onReadMetrics;

  Duration get remaining {
    final value = policy.totalTimeout - _stopwatch.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('${policy.name} exceeded total deadline');
    }
    return value;
  }

  Future<T> wait<T>(Future<T> future) => future.timeout(
    remaining,
    onTimeout: () => throw TimeoutException(
      '${policy.name} exceeded total deadline',
      policy.totalTimeout,
    ),
  );

  Future<Uint8List> readBytes(HttpClientResponse response) async {
    final encoded = await readBoundedBytes(
      response,
      contentLength: response.contentLength,
      maximumBytes: policy.maximumBodyBytes,
      idleTimeout: policy.idleTimeout,
      totalTimeout: remaining,
      workloadName: policy.name,
    );
    if (!_isGzip(response, encoded)) {
      _checkLimit(encoded.length, policy.maximumDecodedBytes, policy.name);
      lastReadMetrics = HttpReadMetrics(
        compressedBytes: encoded.length,
        decodedBytes: encoded.length,
      );
      onReadMetrics?.call(lastReadMetrics!);
      return encoded;
    }
    final decoded = await wait(
      Isolate.run(() => decodeGzipBounded(encoded, policy.maximumDecodedBytes)),
    );
    lastReadMetrics = HttpReadMetrics(
      compressedBytes: encoded.length,
      decodedBytes: decoded.length,
    );
    onReadMetrics?.call(lastReadMetrics!);
    return decoded;
  }

  /// Streams a response directly to [destination], bounding both a declared
  /// Content-Length and actual chunks. The partial file is deleted on every
  /// failure, including idle/total timeout and a consumer callback exception.
  Future<int> readToFile(
    HttpClientResponse response,
    File destination, {
    int? maximumBytes,
    void Function(List<int> chunk, int received)? onChunk,
  }) async {
    final ceiling = maximumBytes ?? policy.maximumBodyBytes;
    return writeBoundedStreamToFile(
      response,
      destination,
      contentLength: response.contentLength,
      maximumBytes: ceiling,
      idleTimeout: policy.idleTimeout,
      totalTimeout: remaining,
      workloadName: policy.name,
      onChunk: onChunk,
    );
  }
}

Future<Uint8List> readBoundedBytes(
  Stream<List<int>> stream, {
  required int contentLength,
  required int maximumBytes,
  required Duration idleTimeout,
  Duration? totalTimeout,
  required String workloadName,
}) async {
  _checkContentLength(contentLength, maximumBytes, workloadName);
  final builder = BytesBuilder(copy: false);
  var received = 0;
  await _consumeWithTimeouts(
    stream,
    idleTimeout: idleTimeout,
    totalTimeout: totalTimeout,
    workloadName: workloadName,
    onChunk: (chunk) {
      received += chunk.length;
      _checkLimit(received, maximumBytes, workloadName);
      builder.add(chunk);
    },
  );
  return builder.takeBytes();
}

Future<int> writeBoundedStreamToFile(
  Stream<List<int>> stream,
  File destination, {
  required int contentLength,
  required int maximumBytes,
  required Duration idleTimeout,
  Duration? totalTimeout,
  required String workloadName,
  void Function(List<int> chunk, int received)? onChunk,
}) async {
  _checkContentLength(contentLength, maximumBytes, workloadName);
  if (await destination.exists()) await destination.delete();
  final sink = destination.openWrite();
  var received = 0;
  try {
    await _consumeWithTimeouts(
      stream,
      idleTimeout: idleTimeout,
      totalTimeout: totalTimeout,
      workloadName: workloadName,
      onChunk: (chunk) {
        received += chunk.length;
        _checkLimit(received, maximumBytes, workloadName);
        sink.add(chunk);
        onChunk?.call(chunk, received);
      },
    );
    await sink.flush();
    await sink.close();
    return received;
  } catch (_) {
    await sink.close();
    if (await destination.exists()) await destination.delete();
    rethrow;
  }
}

Future<void> _consumeWithTimeouts(
  Stream<List<int>> stream, {
  required Duration idleTimeout,
  required Duration? totalTimeout,
  required String workloadName,
  required void Function(List<int>) onChunk,
}) {
  final completer = Completer<void>();
  StreamSubscription<List<int>>? subscription;
  Timer? idleTimer;
  Timer? totalTimer;
  var finished = false;

  Future<void> fail(Object error, [StackTrace? stackTrace]) async {
    if (finished) return;
    finished = true;
    idleTimer?.cancel();
    totalTimer?.cancel();
    await subscription?.cancel();
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void armIdleTimer() {
    idleTimer?.cancel();
    idleTimer = Timer(
      idleTimeout,
      () => fail(
        TimeoutException('$workloadName stalled while reading response'),
      ),
    );
  }

  if (totalTimeout != null) {
    totalTimer = Timer(
      totalTimeout,
      () => fail(TimeoutException('$workloadName exceeded total deadline')),
    );
  }
  armIdleTimer();
  subscription = stream.listen(
    (chunk) {
      if (finished) return;
      try {
        onChunk(chunk);
        armIdleTimer();
      } catch (error, stackTrace) {
        fail(error, stackTrace);
      }
    },
    onError: (Object error, StackTrace stackTrace) => fail(error, stackTrace),
    onDone: () {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      totalTimer?.cancel();
      completer.complete();
    },
    cancelOnError: true,
  );
  return completer.future;
}

void _checkContentLength(int contentLength, int maximum, String name) {
  if (contentLength >= 0 && contentLength > maximum) {
    throw HttpWorkloadException('$name Content-Length exceeds $maximum bytes');
  }
}

void _checkLimit(int actual, int maximum, String name) {
  if (actual > maximum) {
    throw HttpWorkloadException('$name exceeds $maximum bytes');
  }
}

bool _isGzip(HttpClientResponse response, Uint8List bytes) {
  final encoding = response.headers
      .value(HttpHeaders.contentEncodingHeader)
      ?.toLowerCase();
  return encoding?.split(',').any((value) => value.trim() == 'gzip') == true ||
      isGzipBytes(bytes);
}

bool isGzipBytes(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

/// Synchronous bounded gzip decoding. Call this inside an isolate for large or
/// attacker-controlled input; [HttpOperation.readBytes] already does so.
Uint8List decodeGzipBounded(Uint8List encoded, int maximumDecodedBytes) {
  final sink = _BoundedByteSink(maximumDecodedBytes, 'decoded gzip');
  final decoder = gzip.decoder.startChunkedConversion(sink);
  decoder.add(encoded);
  decoder.close();
  return sink.takeBytes();
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.maximumBytes, this.workloadName);

  final int maximumBytes;
  final String workloadName;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  var _length = 0;

  @override
  void add(List<int> data) {
    _length += data.length;
    _checkLimit(_length, maximumBytes, workloadName);
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Redacts secret-looking material from free-form [text] (an exception
/// message, an mpv log line) so it is safe to log or show on screen. Finds an
/// embedded http(s) URL and redacts its path segments that look like
/// credentials (long or token-shaped) — IPTV providers put username/password
/// in the *path* (`/live/user/pass/123.ts`), which [redactUrl]'s query-focused
/// redaction wouldn't touch.
String redactText(String text) {
  final urlMatch = RegExp(
    r'https?://\S+',
    caseSensitive: false,
  ).firstMatch(text);
  if (urlMatch != null) {
    final redactedUrl = _redactUrlPath(urlMatch.group(0)!);
    return text.replaceRange(urlMatch.start, urlMatch.end, redactedUrl);
  }
  return _redactUrlPath(text);
}

String _redactUrlPath(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return value;
  if (!uri.hasAuthority && !value.contains('/')) return value;
  final cleanSegments = uri.pathSegments.map((segment) {
    final looksSecret =
        segment.length > 18 ||
        RegExp(r'^[A-Za-z0-9_-]{12,}$').hasMatch(segment);
    return looksSecret ? '<redacted>' : segment;
  }).toList();
  final path = cleanSegments.join('/');
  final authority = uri.hasAuthority ? '${uri.scheme}://${uri.authority}' : '';
  final prefix = authority.isNotEmpty
      ? authority
      : (uri.scheme.isNotEmpty ? '${uri.scheme}:' : '');
  return '$prefix/${path.replaceAll(RegExp(r'/+'), '/')}';
}

/// Removes credentials from [url] so it is safe to surface in error messages,
/// logs, and exported diagnostics.
String redactUrl(Object url) {
  final text = url.toString();
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.isEmpty) {
    return text.split('?').first;
  }
  final out = StringBuffer()
    ..write(uri.scheme)
    ..write('://')
    ..write(uri.host);
  if (uri.hasPort) out.write(':${uri.port}');
  out.write(uri.path);
  if (uri.hasQuery) out.write('?<redacted>');
  return out.toString();
}
