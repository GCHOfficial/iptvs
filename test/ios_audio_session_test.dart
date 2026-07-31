// The iOS audio-session claim wiring: `IosAudioSessionClaim` /
// `IosAudioSessionClient` in `lib/player/player_screen.dart`.
//
// Why this is worth a test file of its own. Since the `iosManageAudioSession:
// false` pin (docs/ios.md Constraint 1) mpv no longer activates
// `AVAudioSession`, and the plugin's `IosAudioSession` is the process's only
// owner — so two failures live here, and neither is diagnosable from the
// symptom:
//
//   * a *missing* acquire is silent playback with no error anywhere, and
//   * an *unbalanced* acquire leaves the process-wide session active forever,
//     which a user reports as "iptvs broke Spotify" and never connects to this
//     app at all.
//
// The device half of this can't be tested here, but the arithmetic can: the
// plugin keys claimants by id and only an empty→non-empty transition activates
// the real session (non-empty→empty deactivates it), so the whole correctness
// argument reduces to set membership. `_FakeAudioSession` below is a faithful
// Dart mirror of Swift's `AudioSessionClients`
// (`packages/iptvs_ios_player/ios/Core/Sources/IptvsPlayerCore/AudioSessionPolicy.swift`),
// which lets the sequences that actually matter — the `engineFailed`
// cross-engine handoff, the preview/fullscreen overlap, the app-pause
// asymmetry — be replayed exactly as they happen at runtime.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/player_screen.dart';

/// Faithful mirror of Swift's `AudioSessionClients` + `IosAudioSession`:
/// a set keyed by client id, where only empty→non-empty activates the real
/// `AVAudioSession` and only non-empty→empty deactivates it.
class _FakeAudioSession {
  final Set<String> clients = <String>{};
  final List<String> calls = <String>[];

  bool active = false;
  int activations = 0;
  int deactivations = 0;

  /// Client ids whose *acquire* should fail, simulating a platform error.
  final Set<String> failAcquireFor = <String>{};

  /// Error thrown for [failAcquireFor]. Deliberately carries a credential-shaped
  /// URL so the redaction of the failure log can be asserted.
  Object acquireError = PlatformException(
    code: 'audio',
    message:
        'could not activate for http://host:8080/live/joe/sup3rsecret/9.ts',
  );

  Future<Object?> handle(MethodCall call) async {
    final client = (call.arguments as Map?)?['client'] as String?;
    calls.add('${call.method}:$client');
    if (client == null) return false;
    switch (call.method) {
      case 'acquireAudioSession':
        if (failAcquireFor.contains(client)) throw acquireError;
        final wasEmpty = clients.isEmpty;
        if (clients.add(client) && wasEmpty) {
          active = true;
          activations++;
        }
        return true;
      case 'releaseAudioSession':
        if (!clients.remove(client)) return true;
        if (clients.isEmpty) {
          active = false;
          deactivations++;
        }
        return true;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('iptvs/ios_audio_session_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _FakeAudioSession session;
  late List<String> logs;

  /// A claim forced on regardless of host platform — the production default is
  /// `Platform.isIOS`, which is what makes every call site inert elsewhere.
  IosAudioSessionClaim claim(String clientId) => IosAudioSessionClaim(
    clientId,
    channel: channel,
    enabled: true,
    onLogMessage: logs.add,
  );

  setUp(() {
    session = _FakeAudioSession();
    logs = <String>[];
    messenger.setMockMethodCallHandler(channel, session.handle);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('IosAudioSessionClaim', () {
    test('defaults to the shared native player channel', () {
      // The audio session is one more method on the existing process-static
      // channel, not a new one — a new channel would be a new
      // `ChannelHandlerOwner` surface for no gain.
      expect(
        IosAudioSessionClaim(IosAudioSessionClient.embeddedPlayer).channel.name,
        'iptvs/native_hdr_player',
      );
    });

    test('is inert when disabled (every non-iOS platform)', () async {
      final inert = IosAudioSessionClaim(
        IosAudioSessionClient.embeddedPlayer,
        channel: channel,
        enabled: false,
      );
      await inert.acquire();
      await inert.release();
      expect(session.calls, isEmpty);
      expect(inert.isHeld, isFalse);
      expect(session.active, isFalse);
    });

    test('the production default is enabled only on iOS', () async {
      // Guards the one line every call site's platform-inertness rests on.
      final production = IosAudioSessionClaim(
        IosAudioSessionClient.livePreview,
        channel: channel,
      );
      await production.acquire();
      expect(production.isHeld, Platform.isIOS);
      expect(session.calls, Platform.isIOS ? hasLength(1) : isEmpty);
      await production.release();
    });

    test(
      'acquire/release send client-keyed calls and move the session',
      () async {
        final embedded = claim(IosAudioSessionClient.embeddedPlayer);

        await embedded.acquire();
        expect(embedded.isHeld, isTrue);
        expect(session.calls, ['acquireAudioSession:embeddedPlayer']);
        expect(session.active, isTrue);

        await embedded.release();
        expect(embedded.isHeld, isFalse);
        expect(session.calls, [
          'acquireAudioSession:embeddedPlayer',
          'releaseAudioSession:embeddedPlayer',
        ]);
        expect(session.active, isFalse);
        expect(session.clients, isEmpty);
      },
    );

    test('acquire and release are both idempotent', () async {
      final preview = claim(IosAudioSessionClient.livePreview);

      await preview.acquire();
      await preview.acquire();
      await preview.acquire();
      expect(session.calls, hasLength(1));

      await preview.release();
      await preview.release();
      expect(session.calls, hasLength(2));
      expect(session.clients, isEmpty);
    });

    test('release on a claim that never acquired sends nothing', () async {
      // The AVPlayer-routed `PlayerScreen` path: `dispose()` releases
      // unconditionally, and must not chatter for a claim it never took.
      await claim(IosAudioSessionClient.embeddedPlayer).release();
      expect(session.calls, isEmpty);
    });

    test(
      'two claims in the same turn fire exactly one platform call',
      () async {
        // The flag flips before the await precisely so an un-awaited acquire
        // racing an awaited one can't double-send.
        final embedded = claim(IosAudioSessionClient.embeddedPlayer);
        await Future.wait([embedded.acquire(), embedded.acquire()]);
        expect(session.calls, ['acquireAudioSession:embeddedPlayer']);
      },
    );

    test('a failing acquire still owes a release, and logs redacted', () async {
      session.failAcquireFor.add(IosAudioSessionClient.embeddedPlayer);
      final embedded = claim(IosAudioSessionClient.embeddedPlayer);

      await embedded.acquire();
      // The failure bias: held stays true so teardown still sends the release.
      // Releasing an id the plugin never recorded is a documented no-op, while
      // skipping one would strand the session active forever.
      expect(embedded.isHeld, isTrue);
      expect(logs, hasLength(1));
      expect(logs.single, contains('acquireAudioSession'));
      // The platform error text embedded a provider locator. Assert both
      // halves: the credential path segments are gone, *and* the rest of the
      // message survived — an assertion that only checked for the absence of
      // the password would pass just as happily on an empty string.
      expect(logs.single, contains('could not activate for'));
      expect(logs.single, contains('host:8080'));
      expect(logs.single, isNot(contains('sup3rsecret')));
      expect(logs.single, isNot(contains('joe')));
      expect(logs.single, contains('<redacted>/<redacted>/9.ts'));

      await embedded.release();
      expect(session.calls.last, 'releaseAudioSession:embeddedPlayer');
      expect(session.clients, isEmpty);
    });

    test('a missing plugin is tolerated silently', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final embedded = claim(IosAudioSessionClient.embeddedPlayer);
      await embedded.acquire();
      await embedded.release();
      // Not an error worth a diagnostics line: no plugin means nothing owns a
      // session to claim, and nothing is playing through one either.
      expect(logs, isEmpty);
    });

    test('a null reply from a superseded owner is tolerated', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final embedded = claim(IosAudioSessionClient.embeddedPlayer);
      await embedded.acquire();
      expect(embedded.isHeld, isTrue);
      expect(logs, isEmpty);
      await embedded.release();
      expect(embedded.isHeld, isFalse);
    });
  });

  group('audio session balance', () {
    /// The Swift side of the contract — `IptvsPlayerViewController`'s
    /// per-instance claim, taken in `viewDidAppear` and released in
    /// `releasePlaybackServices` — replayed straight into the fake, because it
    /// is not Dart code and must not be modelled as if it were.
    Future<void> controllerAcquire(String id) =>
        session.handle(MethodCall('acquireAudioSession', {'client': id}));
    Future<void> controllerRelease(String id) =>
        session.handle(MethodCall('releaseAudioSession', {'client': id}));

    test('embedded fullscreen open/close settles unclaimed', () async {
      final embedded = claim(IosAudioSessionClient.embeddedPlayer);
      await embedded.acquire();
      expect(session.active, isTrue);
      await embedded.release();
      expect(session.clients, isEmpty);
      expect(session.active, isFalse);
      expect(session.activations, 1);
      expect(session.deactivations, 1);
    });

    test(
      'engineFailed handoff hands the session over and settles empty',
      () async {
        // 1. AVPlayer-routed open: `_tryOpenNativeHdrPlayer` succeeded, so the
        //    Dart route claims nothing at all — the presented controller does.
        const controllerId = 'fullscreenPlayer#4C0F-…';
        await controllerAcquire(controllerId);
        final embedded = claim(IosAudioSessionClient.embeddedPlayer);
        expect(embedded.isHeld, isFalse);
        expect(session.clients, {controllerId});

        // 2. AVPlayer can't play the container. `reportEngineFailed` tears the
        //    controller down and releases its own claim *before* emitting the
        //    event, so the session is genuinely unclaimed when Dart is told.
        await controllerRelease(controllerId);
        expect(session.clients, isEmpty);

        // 3. `_startIosMpvFallback` reopens on the embedded surface and claims.
        await embedded.acquire();
        expect(session.active, isTrue);
        expect(session.clients, {IosAudioSessionClient.embeddedPlayer});

        // 4. The route eventually pops: `dispose()` releases.
        await embedded.release();
        expect(session.clients, isEmpty);
        expect(session.active, isFalse);
        // Two hand-offs, two activations, and nothing left holding the session.
        expect(session.activations, 2);
        expect(session.deactivations, 2);
      },
    );

    test('a deferred engineFailed fallback still balances after Retry', () async {
      // `decideIosFallbackAction` can defer the reopen for a long time and then
      // surface Retry; `_runIosFallbackNow` is reachable twice (an automatic
      // wake racing a tap). The claim must not double-fire, and dispose must
      // still leave nothing held.
      const controllerId = 'fullscreenPlayer#9A1B-…';
      await controllerAcquire(controllerId);
      await controllerRelease(controllerId);

      final embedded = claim(IosAudioSessionClient.embeddedPlayer);
      await embedded.acquire(); // automatic wake
      await embedded.acquire(); // Retry tap landing on the same route
      expect(
        session.calls.where(
          (c) => c.startsWith('acquireAudioSession:embedded'),
        ),
        hasLength(1),
      );
      await embedded.release();
      expect(session.clients, isEmpty);
    });

    test(
      'preview and fullscreen claims overlap without silencing each other',
      () async {
        // The adopted-embedded handoff (`FullscreenHandoff.adoptEmbedded`): the
        // preview engine keeps playing and keeps its claim while `PlayerScreen`
        // takes its own. Distinct ids are the whole point — a shared id would let
        // the fullscreen route's dispose deactivate the session under the preview.
        final preview = claim(IosAudioSessionClient.livePreview);
        final embedded = claim(IosAudioSessionClient.embeddedPlayer);

        await preview.acquire();
        await embedded.acquire();
        expect(session.clients, hasLength(2));

        await embedded.release(); // fullscreen route pops
        expect(session.active, isTrue, reason: 'the preview is still playing');
        expect(session.deactivations, 0);

        await preview.release(); // user leaves the live tab
        expect(session.active, isFalse);
        expect(session.activations, 1);
        expect(session.deactivations, 1);
      },
    );

    test(
      'app pause releases the preview and leaves the player playing',
      () async {
        // The asymmetry `UIBackgroundModes = [audio]` makes load-bearing: the
        // fullscreen player *should* keep playing behind the launcher; a muted
        // preview must not keep decoding and holding a second provider connection
        // on a single-connection account.
        final preview = claim(IosAudioSessionClient.livePreview);
        final embedded = claim(IosAudioSessionClient.embeddedPlayer);
        await preview.acquire();
        await embedded.acquire();

        // `channel_list_screen`'s lifecycle observer stops the preview, and the
        // release rides that same `stop()`.
        await preview.release();

        expect(session.clients, {IosAudioSessionClient.embeddedPlayer});
        expect(session.active, isTrue);
        expect(session.deactivations, 0);
      },
    );

    test('a preview alone releases the session on app pause', () async {
      final preview = claim(IosAudioSessionClient.livePreview);
      await preview.acquire();
      await preview.release();
      expect(session.clients, isEmpty);
      expect(session.active, isFalse);
    });

    test('100 open/close cycles settle back to an unclaimed session', () async {
      // The Dart mirror of the soak assertion in
      // `integration_test/player_soak_test.dart`: a leak of one claim per cycle
      // is invisible in a single pass and fatal over a session.
      for (var i = 0; i < 100; i++) {
        final preview = claim(IosAudioSessionClient.livePreview);
        final embedded = claim(IosAudioSessionClient.embeddedPlayer);
        await preview.acquire();
        await embedded.acquire();
        await embedded.release();
        await preview.release();
      }
      expect(session.clients, isEmpty);
      expect(session.active, isFalse);
      expect(session.activations, 100);
      expect(session.deactivations, 100);
    });
  });

  group('client id parity with Swift', () {
    // The plugin keys its claimant set by these exact strings. A drift is not a
    // compile error on either side: it is silently a client nobody ever
    // releases, which strands the process-wide session active.
    final swift = File(
      'packages/iptvs_ios_player/ios/Core/Sources/IptvsPlayerCore/'
      'AudioSessionPolicy.swift',
    );

    String swiftConstant(String name) {
      final match = RegExp(
        'static\\s+let\\s+$name\\s*=\\s*"([^"]*)"',
      ).firstMatch(swift.readAsStringSync());
      expect(
        match,
        isNotNull,
        reason: 'AudioSessionClientId.$name not found in ${swift.path}',
      );
      return match!.group(1)!;
    }

    test('the Swift policy source is present', () {
      expect(swift.existsSync(), isTrue, reason: swift.path);
    });

    test('embeddedPlayer matches', () {
      expect(
        IosAudioSessionClient.embeddedPlayer,
        swiftConstant('embeddedPlayer'),
      );
    });

    test('livePreview matches', () {
      expect(IosAudioSessionClient.livePreview, swiftConstant('livePreview'));
    });
  });
}
