import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';

void main() {
  group('transient source loading', () {
    test('retries one timeout and returns the successful result', () async {
      var calls = 0;
      final retriedAttempts = <int>[];

      final result = await retryTransientNetworkOperation(
        () async {
          calls++;
          if (calls == 1) throw TimeoutException('portal URL and details');
          return 'loaded';
        },
        retryDelay: Duration.zero,
        onRetry: (_, attempt) => retriedAttempts.add(attempt),
      );

      expect(result, 'loaded');
      expect(calls, 2);
      expect(retriedAttempts, [2]);
    });

    test('does not retry workload policy failures', () async {
      var calls = 0;

      await expectLater(
        retryTransientNetworkOperation(() async {
          calls++;
          throw const HttpWorkloadException('provider exceeds limit');
        }, retryDelay: Duration.zero),
        throwsA(isA<HttpWorkloadException>()),
      );
      expect(calls, 1);
    });
  });

  group('sourceLoadErrorMessage', () {
    test('hides nested URLs and exception details for timeouts', () {
      final message = sourceLoadErrorMessage(
        TimeoutException(
          'request to http://user:password@example.invalid/private timed out',
        ),
      );

      expect(message, contains('retried automatically'));
      expect(message, isNot(contains('example.invalid')));
      expect(message, isNot(contains('password')));
    });

    test('uses a bounded generic message for unknown provider errors', () {
      final message = sourceLoadErrorMessage(
        Exception('very long response body ${'secret ' * 500}'),
      );

      expect(message.length, lessThan(100));
      expect(message, isNot(contains('secret')));
    });
  });
}
