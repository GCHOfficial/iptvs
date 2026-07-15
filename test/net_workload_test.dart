import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';

void main() {
  group('bounded response reading', () {
    test('rejects an excessive declared Content-Length before listening', () {
      var listened = false;
      final stream = Stream<List<int>>.multi((controller) {
        listened = true;
        controller.close();
      });

      expect(
        readBoundedBytes(
          stream,
          contentLength: 11,
          maximumBytes: 10,
          idleTimeout: const Duration(seconds: 1),
          workloadName: 'test',
        ),
        throwsA(isA<HttpWorkloadException>()),
      );
      expect(listened, isFalse);
    });

    test('missing Content-Length cannot bypass the streamed-byte limit', () {
      expect(
        readBoundedBytes(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5, 6],
          ]),
          contentLength: -1,
          maximumBytes: 5,
          idleTimeout: const Duration(seconds: 1),
          workloadName: 'test',
        ),
        throwsA(isA<HttpWorkloadException>()),
      );
    });

    test('false Content-Length cannot bypass the streamed-byte limit', () {
      expect(
        readBoundedBytes(
          Stream.value(List<int>.filled(8, 1)),
          contentLength: 2,
          maximumBytes: 5,
          idleTimeout: const Duration(seconds: 1),
          workloadName: 'test',
        ),
        throwsA(isA<HttpWorkloadException>()),
      );
    });

    test('slow drip reaches the non-resetting total deadline', () async {
      final stream = Stream<List<int>>.periodic(
        const Duration(milliseconds: 20),
        (_) => const [1],
      ).take(20);
      final stopwatch = Stopwatch()..start();

      await expectLater(
        readBoundedBytes(
          stream,
          contentLength: -1,
          maximumBytes: 100,
          idleTimeout: const Duration(milliseconds: 50),
          totalTimeout: const Duration(milliseconds: 75),
          workloadName: 'slow test',
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(stopwatch.elapsedMilliseconds, lessThan(250));
    });

    test('an idle response times out', () async {
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      await expectLater(
        readBoundedBytes(
          controller.stream,
          contentLength: -1,
          maximumBytes: 10,
          idleTimeout: const Duration(milliseconds: 20),
          workloadName: 'idle test',
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('bounded gzip decoding', () {
    test('accepts a legitimate gzip payload', () {
      final original = Uint8List.fromList(utf8.encode('programme data'));
      final encoded = Uint8List.fromList(gzip.encode(original));
      expect(decodeGzipBounded(encoded, 1024), original);
    });

    test('aborts a high-ratio payload at the decoded ceiling', () {
      final encoded = Uint8List.fromList(gzip.encode(Uint8List(256 * 1024)));
      expect(
        () => decodeGzipBounded(encoded, 32 * 1024),
        throwsA(isA<HttpWorkloadException>()),
      );
    });
  });

  test('file streaming deletes a partial file after failure', () async {
    final directory = await Directory.systemTemp.createTemp('iptvs-net-test-');
    addTearDown(() => directory.delete(recursive: true));
    final partial = File('${directory.path}/payload.partial');

    await expectLater(
      writeBoundedStreamToFile(
        Stream.fromIterable([
          [1, 2, 3],
          [4, 5, 6],
        ]),
        partial,
        contentLength: -1,
        maximumBytes: 5,
        idleTimeout: const Duration(seconds: 1),
        workloadName: 'file test',
      ),
      throwsA(isA<HttpWorkloadException>()),
    );
    expect(await partial.exists(), isFalse);
  });
}
