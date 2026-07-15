import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/channel_owner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iptvs/channel_owner_test');
  final messenger = TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger;

  /// Dispatches a platform call to [channel] as the native side would, and
  /// returns the decoded reply (or null if no one handled it).
  Future<dynamic> dispatch(String method) async {
    final call = MethodCall(method);
    final result = <dynamic>[];
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(call),
      (data) {
        if (data != null) {
          result.add(channel.codec.decodeEnvelope(data));
        }
      },
    );
    return result.isEmpty ? null : result.first;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'a successor claim then predecessor release: dispatch reaches successor only',
    () async {
      final owner = ChannelHandlerOwner(channel);
      var aCalls = 0;
      var bCalls = 0;

      final tokenA = owner.claim((call) async {
        aCalls++;
        return null;
      });
      final tokenB = owner.claim((call) async {
        bCalls++;
        return null;
      });
      owner.release(tokenA);

      await dispatch('ping');

      expect(aCalls, 0);
      expect(bCalls, 1);
      // The handler is still installed for B — releasing the stale A token
      // must not have cleared it.
      expect(owner.currentToken, tokenB);
    },
  );

  test(
    'sole owner released with no successor: dispatched call reaches no one',
    () async {
      final owner = ChannelHandlerOwner(channel);
      var calls = 0;

      final token = owner.claim((call) async {
        calls++;
        return null;
      });
      owner.release(token);

      final result = await dispatch('ping');

      expect(calls, 0);
      expect(result, isNull);
    },
  );

  test(
    'claiming a successor without releasing the predecessor: predecessor never fires',
    () async {
      final owner = ChannelHandlerOwner(channel);
      var aCalls = 0;
      var bCalls = 0;

      owner.claim((call) async {
        aCalls++;
        return null;
      });
      owner.claim((call) async {
        bCalls++;
        return null;
      });

      await dispatch('ping');

      expect(aCalls, 0);
      expect(bCalls, 1);
    },
  );

  test(
    'N claim/release cycles keep tokens monotonic and only the latest claimant receives calls',
    () async {
      final owner = ChannelHandlerOwner(channel);
      const cycles = 5;
      final callCounts = List<int>.filled(cycles, 0);
      final tokens = <int>[];

      for (var i = 0; i < cycles; i++) {
        final index = i;
        final token = owner.claim((call) async {
          callCounts[index]++;
          return null;
        });
        tokens.add(token);
        expect(owner.currentToken, token);
        if (i > 0) {
          expect(token, greaterThan(tokens[i - 1]));
        }

        await dispatch('ping');

        owner.release(token);
      }

      // Only each cycle's own claimant ever received a call.
      expect(callCounts, everyElement(1));

      // A stale release from an earlier, already-superseded cycle is a no-op:
      // re-claim, then release an old token from a prior cycle.
      var freshCalls = 0;
      final freshToken = owner.claim((call) async {
        freshCalls++;
        return null;
      });
      owner.release(tokens.first);
      expect(owner.currentToken, freshToken);
      // The handler must still be installed (stale release didn't clear it) —
      // a dispatched call still reaches the current claimant.
      await dispatch('ping');
      expect(freshCalls, 1);

      // Final release clears the handler entirely.
      owner.release(freshToken);
      final result = await dispatch('ping');
      expect(result, isNull);
    },
  );
}
