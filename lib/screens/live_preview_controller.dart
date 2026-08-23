import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/net.dart';
import '../player/channel_owner.dart';
import '../player/buffer_preset.dart';
import '../player/mpv_options.dart';
import '../player/player_screen.dart'
    show
        IosAudioSessionClaim,
        IosAudioSessionClient,
        kReconnectStallMs,
        reconnectMinGapMs;
import '../player/resource_counters.dart';
import '../sources/source.dart';

/// Whether a `completed: true` from the embedded preview engine is *this*
/// controller's to recover from.
///
/// Pulled out of [LivePreviewController] and made pure so the case that matters
/// can be pinned without a libmpv engine (which is unavailable on a Windows dev
/// box, and skips 22 of 23 tests in `channel_list_focus_test.dart` when it is —
/// see CLAUDE.md "Testing notes").
///
/// [adoptedByFullscreen] is the one that was missing. On the embedded seamless
/// handoff the fullscreen route is built with `existingPlayer: _preview.player`
/// — one engine, two watchdogs — so a single clean live EOF ran both
/// recoveries: `PlayerScreen._reconnectLive` re-resolved and reopened the
/// player, and this one re-resolved and reopened it again, finishing with
/// `setVolume(muted ? 0 : 100)` against the *preview's* remembered mute. Any
/// hover-started (muted) preview therefore came back from a reconnect silent,
/// with the mute button reading muted — and a single-connection provider saw
/// two overlapping `create_link` calls where one reconnect was intended.
bool previewOwnsEofRecovery({
  required bool completed,
  required bool disposed,
  required bool nativeActive,
  required bool pausedByApp,
  required bool adoptedByFullscreen,
  required bool loading,
  required String? previewChannelId,
  required String? activeChannelId,
}) {
  // media_kit reports `completed: false` too (a stop, a fresh open); only the
  // rising edge is an EOF.
  if (!completed) return false;
  // Not ours to answer: no controller left, the native shared engine is
  // playing (Android reconnects in Kotlin), or the app paused us around a
  // handoff and this EOF is a consequence of that.
  if (disposed || nativeActive || pausedByApp) return false;
  // Fullscreen is driving this very player and carries its own live watchdog.
  if (adoptedByFullscreen) return false;
  // Not (or no longer) previewing this channel — including mid-`start()`
  // resolves, where `loading` is true — so there is nothing to recover.
  if (activeChannelId == null || previewChannelId != activeChannelId) {
    return false;
  }
  return !loading;
}

/// Owns the live split-pane/phone **preview** player and its state — which
/// channel is previewing, its resolved [StreamInfo], and loading/error — as a
/// [ChangeNotifier] so the screen rebuilds via a listener.
///
/// Two playback paths, chosen per channel:
///
/// - **Android (default)**: the *shared native ExoPlayer engine* (Kotlin
///   `SharedEngine`), rendering into a platform view. This is what makes the
///   preview → fullscreen handoff seamless: the fullscreen Activity *adopts*
///   the running engine (only the video surface moves — audio, decoder and
///   buffer carry over) instead of reloading the stream, and it's also the
///   cheapest decode path for weak TV boxes (MediaCodec straight into a
///   `SurfaceView` the system compositor consumes directly — no mpv, and no GL
///   texture copy; see [_NativePreviewView] for why that surface type is
///   load-bearing rather than incidental).
/// - **Fallback / other platforms**: the embedded media_kit [Player] +
///   [VideoController] texture. On Android this covers streams the native
///   engine can't decode (chiefly Dolby Vision P5 on non-DV hardware — mpv
///   software-reshapes those), remembered per channel in
///   [_nativeUnsupportedIds].
///
/// Fullscreen playback, the phone preview sheet, and focus handling stay in
/// the screen (they need navigation/context/focus); they drive the preview
/// through [start]/[stop]/[pause]/[play] and read these fields.
class LivePreviewController extends ChangeNotifier {
  final LibraryRepository repo;

  /// Surfaces a preview-resolution failure (the screen shows a snackbar).
  final void Function(String message)? onError;

  LivePreviewController({required this.repo, this.onError}) {
    if (Platform.isAndroid) {
      // Last-created controller wins the channel — there's one live preview at
      // a time, and a new source's screen replaces the old controller.
      _previewToken = _previewOwner.claim(_handleNativeCall);
    }
  }

  static const MethodChannel _nativeChannel = MethodChannel(
    'iptvs/native_preview',
  );
  // Arbitrates the static channel's handler across successive controllers
  // (a new source's screen replacing the old one) so a superseded
  // controller's dispose can never clear a newer controller's handler. See
  // [ChannelHandlerOwner].
  static final ChannelHandlerOwner _previewOwner = ChannelHandlerOwner(
    _nativeChannel,
  );
  int? _previewToken;

  /// The preview's claim on the process-wide iOS audio session.
  ///
  /// The preview is always the embedded media_kit/libmpv engine on iOS (the
  /// shared-engine native path is Android-only), and since
  /// `iosManageAudioSession: false` mpv no longer activates `AVAudioSession`
  /// itself — so without this claim the preview is simply **silent**.
  ///
  /// Its release discipline is deliberately *stricter* than the fullscreen
  /// player's: [stop] and [dispose] release it, and because the app-pause
  /// lifecycle observer in `channel_list_screen.dart` stops the preview, the
  /// pause release rides that existing path rather than a second observer. That
  /// asymmetry — preview releases on `AppLifecycleState.paused`, `PlayerScreen`
  /// does not — is the load-bearing half of `UIBackgroundModes = [audio]`: the
  /// fullscreen player *should* keep playing behind the launcher, a muted
  /// preview must not keep decoding and holding a (single-connection) provider
  /// connection. See docs/ios.md "Other work required".
  ///
  /// Uses its own client id, so it can coexist with the fullscreen player's
  /// claim through an adopted handoff without either one deactivating the
  /// session under the other. No-op off iOS.
  final IosAudioSessionClaim _audioSession = IosAudioSessionClaim(
    IosAudioSessionClient.livePreview,
  );

  /// Channels whose video the native engine can't decode (e.g. Dolby Vision
  /// P5 on non-DV hardware) — they preview via media_kit for this session.
  ///
  /// Keyed by `(sourceId, channelId)` rather than the channel id alone. The
  /// cross-source Favorites view can preview two providers' channels that
  /// happen to share an id — the very case `GlobalFavoriteChannel.globalId`
  /// exists for — and an id-keyed memo would push a perfectly decodable channel
  /// onto the fallback path because an unrelated one elsewhere failed.
  final Set<(String, String)> _nativeUnsupportedIds = <(String, String)>{};

  /// True while the native shared engine (not media_kit) owns the preview.
  bool nativeActive = false;

  /// Current mute state (native volume isn't readable back, so track it here).
  bool muted = true;

  bool get isMuted => muted;

  Player? _player;
  Player get player => _player ??= _createPlayer();

  /// True once the embedded media_kit player exists (it's created lazily, and
  /// never at all while the native path serves every preview).
  bool get hasEmbeddedPlayer => _player != null;

  VideoController? _controller;
  // Force hardware decode for the preview via the controller config — the only
  // place `hwdec` sticks (media_kit sets it at controller creation, overriding
  // setProperty). On a weak TV box the default `auto-safe` silently drops to
  // software decode, playing 4K HEVC in slow-motion at ~100% CPU. Android-only;
  // other platforms keep media_kit's default.
  VideoController get controller => _controller ??= VideoController(
    player,
    configuration: Platform.isAndroid
        ? const VideoControllerConfiguration(hwdec: kAndroidPreviewHwdec)
        : const VideoControllerConfiguration(),
  );

  StreamSubscription<VideoParams>? _hwdecProbe;
  bool _loggedHwdec = false;

  Player _createPlayer() {
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        // iOS: mpv's `ao_audiounit` driver unconditionally calls
        // `AVAudioSession.setActive:` on init/dispose, and the session is
        // process-wide — a preview engine starting or stopping would clobber
        // the fullscreen AVPlayer engine's background audio and lock-screen
        // controls. The upstream opt-out **defaults to true**, so it has to be
        // set at both PlayerConfiguration sites (here and
        // `_PlayerScreenState._createPlayer`); missing either reintroduces the
        // bug the media_kit git pin exists to fix. Inert off iOS.
        iosManageAudioSession: false,
      ),
    );
    ResourceCounters.incMediaKitPlayers();
    // Unlike the fullscreen player, previews never get a native HDR/HWND surface —
    // they're always the embedded (texture) path. Apply the same live-stream
    // network/demuxer tuning + tone-map-to-SDR options the fullscreen embedded
    // fallback uses. (Hardware decode is set separately on the VideoController
    // config above — that's the one place `hwdec` isn't overridden.)
    final platform = player.platform;
    if (platform is NativePlayer) {
      unawaited(
        applyMpvOptions(platform, {
          ...kLiveMpvOptions,
          ...mpvBufferOptions(_bufferPreset),
          ...embeddedVideoOptionsForPlatform(),
        }),
      );
      // Log the decoder mpv actually engaged once frames start flowing, so the
      // exportable diagnostics confirm hardware decode (not a silent software
      // fallback) on the low-power TV boxes where this matters.
      _hwdecProbe = player.stream.videoParams.listen((_) {
        if (_loggedHwdec) return;
        unawaited(_logPreviewHwdec(platform));
      });
    }
    // media_kit maps mpv's `eof-reached` to `completed: true` — a clean
    // server-side EOF, distinct from a player error. Nothing else here
    // recovers from it (the fullscreen watchdogs are per-PlayerScreen, not
    // preview-owned), so the preview would otherwise sit dead until an
    // unrelated selection change. See [_handleCompleted].
    _completedSub = player.stream.completed.listen(_handleCompleted);
    return player;
  }

  /// Recovers from a clean EOF on the embedded preview player by re-starting
  /// the same channel (never a different one — the preview only ever plays
  /// what the user explicitly chose). Re-resolves rather than reopening the
  /// stale URL: provider tokens (Stalker `create_link`) are single-use.
  /// Rate-limited and capped by the shared reconnect min-gap policy so a
  /// stream stuck bouncing at EOF doesn't loop forever.
  void _handleCompleted(bool completed) {
    final channel = _activeChannel;
    if (!previewOwnsEofRecovery(
      completed: completed,
      disposed: _disposed,
      nativeActive: nativeActive,
      pausedByApp: _pausedByApp,
      adoptedByFullscreen: adoptedByFullscreen,
      loading: loading,
      previewChannelId: channelId,
      activeChannelId: channel?.id,
    )) {
      return;
    }
    // Non-null by the guard: it refuses a null `activeChannelId`.
    final active = channel!;
    final now = DateTime.now().millisecondsSinceEpoch;
    // A completed landing well after the last restart is a fresh incident
    // (the restart held for a full stall window), not a continuation of a
    // stuck loop — forget the earlier attempts.
    if (_lastEofRestartMs != 0 &&
        now - _lastEofRestartMs >= kReconnectStallMs) {
      _eofRestartAttempts = 0;
    }
    if (_eofRestartAttempts >= _maxConsecutiveEofRestarts) {
      DiagnosticsLog.instance.add(
        'library',
        'preview eof giving up channel=${active.name} '
            'attempts=$_eofRestartAttempts',
      );
      _set(() {
        loading = false;
        error = 'Stream ended';
      });
      return;
    }
    final minGap = reconnectMinGapMs(
      priorAttempts: _eofRestartAttempts,
      force: false,
    );
    if (_lastEofRestartMs != 0 && now - _lastEofRestartMs < minGap) return;
    _eofRestartAttempts++;
    _lastEofRestartMs = now;
    DiagnosticsLog.instance.add(
      'library',
      'preview eof restart channel=${active.name} '
          'attempt=$_eofRestartAttempts',
    );
    // Through the same repository the preview was started with — an EOF on a
    // cross-source favorite must re-resolve against its own provider.
    // …and on the same buffering. A restart that fell back to the default
    // would quietly undo the user's choice on exactly the unstable stream they
    // chose it for.
    unawaited(
      start(
        active,
        muted: muted,
        from: _activeRepo,
        bufferPreset: _bufferPreset,
      ),
    );
  }

  /// Pushes the current preset's mpv properties onto an already-built player.
  ///
  /// A no-op before the player exists — [_createPlayer] applies them itself for
  /// the first one — and non-fatal, since a rejected property is a degraded
  /// buffer rather than a reason to lose the preview.
  Future<void> _applyBufferOptions() async {
    final existing = _player;
    if (existing == null) return;
    final platform = existing.platform;
    if (platform is! NativePlayer) return;
    await applyMpvOptions(
      platform,
      mpvBufferOptions(_bufferPreset),
      onWarn: (message) => DiagnosticsLog.instance.add('player', message),
    );
  }

  Future<void> _logPreviewHwdec(NativePlayer platform) async {
    if (_loggedHwdec) return;
    try {
      final hwdec = (await platform.getProperty('hwdec-current')).trim();
      // Decoder not up yet, or a software fallback — nothing to log.
      if (hwdec.isEmpty || hwdec == 'no') return;
      _loggedHwdec = true;
      unawaited(_hwdecProbe?.cancel());
      _hwdecProbe = null;
      DiagnosticsLog.instance.add('library', 'preview active hwdec=$hwdec');
    } catch (_) {
      // Property unavailable on this build — leave the probe running.
    }
  }

  /// Channel currently selected for preview (may still be loading), or null.
  String? channelId;
  StreamInfo? stream;
  bool loading = false;
  String? error;

  int _requestId = 0;
  bool _disposed = false;

  /// The channel [start] most recently targeted — kept so a clean server-side
  /// EOF can restart the *same* channel (never any other; "preview is
  /// deliberate and locked"). Cleared by [stop]/[discardPlayer] so an
  /// app-initiated stop never triggers a restart.
  Channel? _activeChannel;

  /// The repository [start] most recently resolved through — the active
  /// source's, or the owning source's for a cross-source favorite.
  ///
  /// Kept so an EOF restart re-resolves against the *same* provider, and so
  /// [isPreviewing] can answer for a channel id that exists in more than one
  /// list.
  LibraryRepository? _activeRepo;

  /// The source id the preview currently belongs to.
  String get previewSourceId => (_activeRepo ?? repo).source.id;

  /// Whether the preview is showing (or loading) this channel **of this
  /// source**.
  ///
  /// Channel ids are unique only *within* a provider, so every "is this the
  /// previewing channel?" question has to carry the source id. Asking by id
  /// alone was sound while the preview was guaranteed to be the active
  /// source's; the cross-source Favorites view breaks that guarantee, and the
  /// failure it produces is the worst kind — going fullscreen on provider B's
  /// channel using the stream resolved from provider A.
  bool isPreviewing(String sourceId, String channelId) =>
      this.channelId == channelId && previewSourceId == sourceId;

  /// True while the app (not a genuine EOF) has paused the preview around a
  /// fullscreen handoff — an EOF landing in this window is ignored.
  bool _pausedByApp = false;

  /// True while a fullscreen `PlayerScreen` is driving **this controller's own
  /// media_kit [player]** (the embedded seamless handoff — Windows SDR, Linux
  /// SDR/X11, iOS mpv — where the route is built with
  /// `existingPlayer: _preview.player`).
  ///
  /// The engine is shared, so every stream this controller listens to is also
  /// the fullscreen player's, and both sides carry a live-EOF watchdog. Left
  /// ungated, one clean server-side EOF fired *two* recoveries on one player:
  /// `PlayerScreen._reconnectLive` re-resolved and reopened it, and
  /// [_handleCompleted] re-resolved and reopened it again — then finished with
  /// `setVolume(muted ? 0 : 100)` against the *preview's* remembered mute, which
  /// is true for any desktop hover-started preview. The stream came back
  /// silent, the mute button read muted, and a single-connection provider saw
  /// two overlapping `create_link` calls for one reconnect.
  ///
  /// Set by `channel_list_screen._openLivePlayer` around the push, and cleared
  /// the moment the route pops (including the failure path), because the
  /// preview owns its own recovery again as soon as fullscreen lets go.
  bool adoptedByFullscreen = false;

  /// Consecutive automatic EOF-restart attempts for the current incident, and
  /// when the last one fired — caps a stuck stream from looping forever and
  /// resets once a restart holds for a full stall window (a fresh incident).
  int _eofRestartAttempts = 0;
  int _lastEofRestartMs = 0;
  static const int _maxConsecutiveEofRestarts = 3;

  StreamSubscription<bool>? _completedSub;

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  bool _useNative(String sourceId, Channel channel) =>
      Platform.isAndroid &&
      !_nativeUnsupportedIds.contains((sourceId, channel.id));

  /// The most recent [start], so a caller that arrives mid-resolve can wait for
  /// it instead of starting a competing one. Already-completed (or never
  /// started) resolves make this a no-op future.
  ///
  /// This exists for the second OK press on a channel whose preview is still
  /// resolving: the channel list waits here and then goes fullscreen, rather
  /// than restarting the preview (which superseded the in-flight `create_link`
  /// with a second one and reloaded the shared engine — see
  /// [ChannelPlayAction.awaitPreviewThenOpen] in `channel_list_screen.dart`).
  /// It deliberately reports *completion*, not success: the caller re-reads
  /// [channelId]/[stream] afterwards, because the resolve it waited on may have
  /// failed or been superseded.
  Future<void> get pendingStart => _pendingStart ?? Future<void>.value();
  Future<void>? _pendingStart;


  /// Buffering preset of the source that owns the previewing channel.
  ///
  /// Set per [start] rather than at construction because a cross-source
  /// favorite previews through its *owning* source's repository, and must
  /// preview with that source's buffering too. Read by both preview paths: the
  /// media_kit player's mpv options, and the Android native engine's
  /// `LoadControl`.
  BufferPreset _bufferPreset = BufferPreset.normal;

  /// Resolve [channel] and open it in the preview player. [muted] is true for
  /// desktop auto-previews (mouse-hover style) and false for deliberate ones
  /// (OK / long-press). Superseded by a newer call via a request id.
  ///
  /// [from] is the repository to resolve through, for a channel this controller
  /// doesn't own: a cross-source favorite belongs to another provider, and
  /// resolving it against [repo] would spend the *active* source's single-use
  /// `create_link` on a channel id that means something else there. Null means
  /// the active source, which is every ordinary preview.
  Future<void> start(
    Channel channel, {
    bool muted = true,
    LibraryRepository? from,
    // **Required on purpose.** A default would silently reset the source's
    // choice to normal at any call site that forgot it — and the ones that
    // matter most are the restarts (returning from fullscreen, an EOF
    // re-arm), where a preview that came back on the wrong buffering would be
    // invisible until someone read a diagnostics export. Making it required
    // moves that from a runtime surprise to a compile error.
    required BufferPreset bufferPreset,
  }) {
    // Re-applied on every start, not just at player creation. `_createPlayer`
    // runs once behind `_player ??=`, and an ordinary `stop()` keeps that
    // player alive — so without this the preview kept whichever preset it was
    // first built with: changing the setting and coming back did nothing until
    // an app restart, and previewing a cross-source favorite owned by a
    // different source ran on the previous source's buffering. These are plain
    // mpv properties, settable at runtime, so unlike ExoPlayer's `LoadControl`
    // this needs no engine rebuild.
    final changed = bufferPreset != _bufferPreset;
    _bufferPreset = bufferPreset;
    if (changed) unawaited(_applyBufferOptions());
    final pending = _start(channel, muted: muted, from: from);
    _pendingStart = pending;
    return pending;
  }

  Future<void> _start(
    Channel channel, {
    bool muted = true,
    LibraryRepository? from,
  }) async {
    final activeRepo = from ?? repo;
    // No guard on `loading`: a newer call must supersede an in-flight resolve
    // (a slow Stalker create_link would otherwise swallow the user's channel
    // change). The request id makes the stale attempt's completions no-ops.
    final requestId = ++_requestId;
    this.muted = muted;
    if (_activeChannel?.id != channel.id ||
        !identical(_activeRepo, activeRepo)) {
      // A genuinely new selection, not an EOF-triggered restart of the same
      // channel — forget any earlier incident's restart bookkeeping. The source
      // is part of "same channel": the identical id in another provider's list
      // is a different channel, and inherits none of this one's incident.
      _eofRestartAttempts = 0;
      _lastEofRestartMs = 0;
    }
    _activeChannel = channel;
    _activeRepo = activeRepo;
    _pausedByApp = false;
    _set(() {
      channelId = channel.id;
      loading = true;
      error = null;
      stream = null;
    });
    try {
      DiagnosticsLog.instance.add(
        'library',
        'preview live source=${activeRepo.source.name} channel=${channel.name} id=${channel.id}',
      );
      final resolved = await activeRepo.resolve(channel);
      if (_disposed || requestId != _requestId) return;
      if (_useNative(activeRepo.source.id, channel)) {
        final opened = await _openNative(resolved, muted: muted);
        if (_disposed || requestId != _requestId) return;
        if (opened) {
          // A previous fallback (media_kit) preview may still be running.
          if (_player != null) unawaited(_player!.stop());
          _set(() {
            nativeActive = true;
            stream = resolved;
            loading = false;
            error = null;
          });
          return;
        }
        // Native engine unavailable for this channel — embedded path instead.
        _nativeUnsupportedIds.add((activeRepo.source.id, channel.id));
      }
      if (nativeActive) {
        nativeActive = false;
        unawaited(_stopNative());
      }
      // iOS: claim the audio session before libmpv brings its output up, or the
      // preview plays silently (`iosManageAudioSession: false` — mpv no longer
      // activates the session itself). Only the embedded path needs it; the
      // Android shared-engine path above returns before here. Inert off iOS.
      await _audioSession.acquire();
      await player.open(Media(resolved.url, httpHeaders: resolved.headers));
      await player.setVolume(muted ? 0 : 100);
      if (_disposed || requestId != _requestId) return;
      _set(() {
        stream = resolved;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (_disposed || requestId != _requestId) return;
      // Exception text can embed the stream URL (credentials in the path) —
      // scrub before anything user-visible.
      final message = redactText('$e');
      _set(() {
        loading = false;
        error = message;
      });
      onError?.call('Could not preview: $message');
    }
  }

  Future<bool> _openNative(StreamInfo resolved, {required bool muted}) async {
    try {
      final opened = await _nativeChannel.invokeMethod<bool>('open', {
        'url': resolved.url,
        'headers': resolved.headers,
        'muted': muted,
        // A changed preset makes SharedEngine build a fresh engine, the same
        // way changed headers do — ExoPlayer's LoadControl is fixed at
        // construction.
        'bufferPreset': _bufferPreset.storageName,
      });
      if (opened == true) {
        DiagnosticsLog.instance.add('library', 'preview native engine open');
        return true;
      }
      return false;
    } catch (e) {
      // No URL in the log — provider URLs carry credentials.
      DiagnosticsLog.instance.add(
        'library',
        'preview native engine unavailable: ${e.runtimeType}',
      );
      return false;
    }
  }

  Future<void> _stopNative() async {
    try {
      await _nativeChannel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Events pushed by the Kotlin side (`SharedEngine` via MainActivity).
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed || call.method != 'previewEvent') return null;
    final args = call.arguments as Map?;
    if (!nativeActive) return null;
    switch (args?['event']) {
      case 'unsupported':
        // The native engine can't decode this channel's video — remember that
        // and fall back to the embedded media_kit preview mid-flight.
        final id = channelId;
        final s = stream;
        if (id != null) _nativeUnsupportedIds.add((previewSourceId, id));
        nativeActive = false;
        if (s == null) return null;
        DiagnosticsLog.instance.add(
          'library',
          'preview video unsupported by native engine — media_kit fallback',
        );
        try {
          await player.open(Media(s.url, httpHeaders: s.headers));
          await player.setVolume(muted ? 0 : 100);
          _set(() {});
        } catch (e) {
          _set(() => error = redactText('$e'));
        }
      case 'lost':
        // Fullscreen swapped the adopted shared engine for mpv (unsupported
        // video), so the native preview is gone. Clear the preview; the next
        // (re)focus starts a fresh one on the fallback path.
        final id = channelId;
        if (id != null) _nativeUnsupportedIds.add((previewSourceId, id));
        _set(() {
          nativeActive = false;
          stream = null;
          loading = false;
        });
      case 'error':
        // Native engine error text can carry the stream URL — scrub it.
        final message = redactText(
          (args?['message'] as String?) ?? 'stream error',
        );
        _set(() {
          loading = false;
          error = message;
        });
    }
    return null;
  }

  /// Stop the preview player. [clearSelection] also drops the previewing
  /// channel (used when leaving the live view / closing the phone sheet).
  Future<void> stop({bool clearSelection = false}) async {
    // App-initiated stop — never auto-restart on the EOF this may itself
    // trigger (media_kit's `stop()` reports `completed: false`, but clear the
    // target anyway so a straggling event can't act on it).
    _activeChannel = null;
    if (nativeActive) {
      nativeActive = false;
      await _stopNative();
    }
    try {
      if (_player != null) await _player!.stop();
    } catch (_) {}
    // Nothing is decoding any more, so the preview must stop holding the
    // process-wide session open. This is also the app-pause release path: the
    // lifecycle observer in `channel_list_screen.dart` calls `stop()`, so the
    // pause behaviour rides here rather than in a second observer.
    await _audioSession.release();
    if (_disposed) return;
    _set(() {
      loading = false;
      error = null;
      stream = null;
      if (clearSelection) channelId = null;
    });
  }

  /// Pause/resume the preview player around fullscreen playback (no-ops if the
  /// player was never created).
  Future<void> pause() async {
    _pausedByApp = true;
    if (nativeActive) {
      try {
        await _nativeChannel.invokeMethod('pause');
      } catch (_) {}
      return;
    }
    if (_player != null) await _player!.pause();
  }

  Future<void> play() async {
    _pausedByApp = false;
    if (nativeActive) {
      try {
        await _nativeChannel.invokeMethod('play');
      } catch (_) {}
      return;
    }
    if (_player != null) await _player!.play();
  }

  /// Mute/unmute whichever engine is previewing (and remember the state).
  Future<void> setMuted(bool value) async {
    muted = value;
    if (nativeActive) {
      try {
        await _nativeChannel.invokeMethod('setVolume', {
          'volume': value ? 0.0 : 1.0,
        });
      } catch (_) {}
      return;
    }
    if (_player != null) await _player!.setVolume(value ? 0 : 100);
  }

  /// Disposes the current player entirely and clears preview state. Used when
  /// the fullscreen player adopted this player and hot-swapped its video
  /// output to the Windows native HDR surface (see [PlayerScreen]) — once that
  /// surface tears down, the player's mpv `vo`/`wid` are no longer valid for
  /// this controller's embedded texture, so it's discarded rather than reused.
  /// The next [start] call builds a fresh one.
  Future<void> discardPlayer() async {
    final player = _player;
    if (nativeActive) {
      nativeActive = false;
      unawaited(_stopNative());
    }
    unawaited(_hwdecProbe?.cancel());
    _hwdecProbe = null;
    _loggedHwdec = false;
    unawaited(_completedSub?.cancel());
    _completedSub = null;
    _activeChannel = null;
    _player = null;
    _controller = null;
    channelId = null;
    loading = false;
    error = null;
    stream = null;
    if (!_disposed) notifyListeners();
    // The engine this claim was taken for is being destroyed outright.
    await _audioSession.release();
    if (player != null) {
      await player.dispose();
      ResourceCounters.decMediaKitPlayers();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final token = _previewToken;
    if (token != null) {
      _previewOwner.release(token);
    }
    if (nativeActive) {
      nativeActive = false;
      unawaited(_stopNative());
    }
    unawaited(_hwdecProbe?.cancel());
    unawaited(_completedSub?.cancel());
    // Last-resort balance: the controller can be disposed without a preceding
    // `stop()` (the whole screen going away with a preview still running). An
    // acquire this never released would leave the process-wide session active
    // for the rest of the app's life, so other apps could not resume audio.
    // Idempotent — a no-op when `stop()`/`discardPlayer()` already released.
    unawaited(_audioSession.release());
    _activeChannel = null;
    final player = _player;
    if (player != null) {
      unawaited(
        player.dispose().then((_) => ResourceCounters.decMediaKitPlayers()),
      );
    }
    super.dispose();
  }
}

/// Renders the live preview's video: the native shared-engine platform view
/// when that path is active, else the embedded media_kit texture. Build this
/// only once the preview has loaded ([LivePreviewController.stream] != null) so
/// the media_kit player isn't spun up while the native path is still deciding.
class PreviewVideo extends StatelessWidget {
  final LivePreviewController preview;

  const PreviewVideo({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    if (preview.nativeActive) {
      return const _NativePreviewView();
    }
    return Video(controller: preview.controller, controls: NoVideoControls);
  }
}

/// The native shared-engine preview, embedded with **hybrid composition**.
///
/// Deliberately not `AndroidView`. That path hands Flutter a *texture*, and the
/// platform view behind this is a `SurfaceView` (`PreviewPlatformView`)
/// precisely because a texture is what made a 4K50 HDR10 channel unwatchable:
/// every frame leaves the decoder as an external GL texture the app's GPU has
/// to draw, which Flutter then composites again — two extra full-frame passes
/// at 3840x2160x10-bit, fifty times a second, on a set-top box. An exported log
/// measured the same codec instance on the same stream holding 49.3 fps into
/// the fullscreen Activity's SurfaceView while a mostly-preview window managed
/// about 11.7 fps. `initExpensiveAndroidView` puts the real SurfaceView into
/// the Activity's view hierarchy instead, so the decoder's buffers reach the
/// system compositor untouched — usually on a hardware overlay plane, with the
/// HDR metadata intact.
///
/// **"Expensive" is Flutter's own name for it, and it is not free:** any widget
/// drawn *over* a hybrid-composition view is promoted onto its own overlay
/// surface, composited separately every frame. Exactly one thing overlaps the
/// live video today — the small static "Preview" chip in the panel's bottom-left
/// corner — and that is a fine price. What must not appear is a *full-bleed*
/// overlay: the panel's loading scrim and error scrim are alternatives to the
/// video inside the same `Stack`, never layers on top of it, so a spinner over
/// live 4K is unrepresentable rather than merely avoided. Pinned by
/// `test/preview_overlay_test.dart`, because "we chose not to" is not a
/// guarantee and a later "show a spinner while it rebuffers" would hand back a
/// large share of what this surface switch just bought.
///
/// The Android view is non-focusable and blocks descendant focus on the Kotlin
/// side: under hybrid composition it is a real view in the Activity's
/// hierarchy, so an focusable SurfaceView would be a D-pad trap the Flutter
/// focus model cannot see (docs/tv-navigation.md).
class _NativePreviewView extends StatelessWidget {
  const _NativePreviewView();

  static const String _viewType = 'iptvs/preview_view';

  @override
  Widget build(BuildContext context) => PlatformViewLink(
    viewType: _viewType,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      // The video is never an input target: the selection model owns the D-pad
      // and the panel's controls are ordinary Flutter widgets beside it.
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );
}
