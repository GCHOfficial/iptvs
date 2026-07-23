import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/app_database.dart';
import '../data/diagnostics_log.dart';
import '../data/net.dart';
import '../sources/source.dart';
import 'channel_owner.dart';
import 'mpv_options.dart';
import 'player_overlay.dart';
import 'resource_counters.dart';
import 'linux_native_session.dart';

/// Buffering/dropped this long before a non-forced live reconnect fires.
/// Mirrors Android's `ReconnectPolicy.STALL_RECONNECT_MS`.
const int kReconnectStallMs = 8000;

/// Cap on the attempt-scaled backoff between repeated reconnect attempts.
/// Mirrors Android's `ReconnectPolicy.MAX_BACKOFF_MS`.
const int kReconnectMaxBackoffMs = 30000;

/// Minimum gap (ms) required since the last reconnect attempt before the next
/// may fire. [priorAttempts] is the number of reconnect attempts already made
/// (0 before the first). A forced reconnect (a hard player error / native
/// drop) always uses the base stall threshold instead of scaling with the
/// attempt count. This is the pure Dart mirror of Android's
/// `ReconnectPolicy.minGapMs`, shared by the embedded/Windows watchdog, the
/// Linux-native IPC watchdog, and the live preview's clean-EOF restart
/// (`LivePreviewController`) so every recovery path backs off identically.
int reconnectMinGapMs({
  required int priorAttempts,
  required bool force,
  int stallMs = kReconnectStallMs,
  int maxBackoffMs = kReconnectMaxBackoffMs,
}) => force ? stallMs : ((priorAttempts + 1) * stallMs).clamp(0, maxBackoffMs);

/// Whether a media_kit `completed` event should trigger a live reconnect.
/// A clean server-side EOF surfaces as mpv `eof-reached` → `completed=true`
/// with `buffering=false`, so the buffering-gated stall watchdog can never see
/// it (and `reconnect_at_eof` can't compensate — see `kLiveMpvOptions`). Live
/// treats it as a drop, mirroring the Linux-native `end-file` drop signal; VOD
/// completing is a legitimate end of playback, and an active native session
/// means the embedded player's events describe a stopped engine, not the
/// stream.
bool shouldReconnectOnCompleted({
  required bool completed,
  required bool isLive,
  required bool nativeSessionActive,
}) => completed && isLive && !nativeSessionActive;

/// Pure dynamic-range label from colorimetry (gamma/primaries/matrix). Shared
/// by the embedded/Windows path (media_kit [VideoParams]), the native Linux
/// path ([LinuxHdrColorimetry] read over mpv's IPC), and [isHdrColorimetry] —
/// same PQ/HLG/BT.2020/Dolby-Vision precedence either way. [hdr10Plus] only
/// distinguishes the two PQ labels; both are HDR.
@visibleForTesting
String dynamicRangeLabelFrom({
  String? gamma,
  String? primaries,
  String? matrix,
  bool hdr10Plus = false,
}) {
  final g = gamma?.toLowerCase() ?? '';
  final p = primaries?.toLowerCase() ?? '';
  final m = matrix?.toLowerCase() ?? '';
  if (m.contains('dolby') || g.contains('dolby')) return 'Dolby Vision';
  if (g.contains('pq')) return hdr10Plus ? 'HDR10+ · PQ' : 'HDR10 · PQ';
  if (g.contains('hlg')) return 'HLG';
  if (p.contains('2020')) return 'HDR · BT.2020';
  if (g.isEmpty && p.isEmpty) return '';
  return 'SDR';
}

/// Whether these colorimetry params describe an HDR source (PQ/HLG/Dolby
/// Vision, or a BT.2020 primaries signal). Drives the Linux Wayland
/// native-mpv escalation (`_PlayerScreenState._maybeEscalateLinuxNative`) and
/// feeds `decideFullscreenHandoff`'s `streamLikelyHdr` in
/// `channel_list_screen.dart`. Derived from [dynamicRangeLabelFrom] so the
/// HDR/SDR precedence stays single-sourced.
bool isHdrColorimetry({String? gamma, String? primaries, String? matrix}) {
  final label = dynamicRangeLabelFrom(
    gamma: gamma,
    primaries: primaries,
    matrix: matrix,
  );
  return label.isNotEmpty && label != 'SDR';
}

/// Identifies what's playing for the VOD resume store: where to save
/// positions and where to resume from. Absent for live streams and anything
/// the caller doesn't want remembered.
class PlaybackContext {
  final AppDatabase db;
  final String sourceId;
  final ContentKind kind;
  final String itemId;

  /// Saved position to resume at (read by the caller before pushing the
  /// player); null/zero plays from the top.
  final Duration? resumeFrom;

  const PlaybackContext({
    required this.db,
    required this.sourceId,
    required this.kind,
    required this.itemId,
    this.resumeFrom,
  });
}

/// Plays a resolved [StreamInfo] using media_kit (libmpv under the hood, so it
/// handles HEVC / AC-3 / MPEG-TS that an HTML video element can't). Controls
/// are media_kit's adaptive set, themed to match the app.
class PlayerScreen extends StatefulWidget {
  final String title;
  final StreamInfo stream;

  /// Active source's display name, shown as a badge in the player overlay.
  final String? sourceName;

  /// EPG now/next for a live channel (a one-shot snapshot taken at play time),
  /// surfaced in the overlay instead of the VOD scrubber. Null for VOD.
  final Programme? epgNow;
  final Programme? epgNext;

  /// An already-open [Player]/[VideoController] to adopt instead of opening
  /// [stream] fresh — passed when coming from a live preview that's already
  /// playing this exact stream, so going fullscreen doesn't restart playback.
  /// [PlayerScreen] does not own an adopted player: it never disposes it, that
  /// stays the caller's responsibility. Ignored on Android when the native HDR
  /// player launches (a separate Activity/hardware surface — no live decode
  /// session can be handed to it) and, on Windows, only skips reopening the
  /// media if the native HDR surface can still be created for the adopted
  /// player; otherwise it falls back to a fresh open.
  final Player? existingPlayer;
  final VideoController? existingController;

  /// Android: the live preview is already playing this exact stream on the
  /// *shared native engine*, and the native fullscreen Activity should adopt
  /// it — moving only the video output to its own surface — instead of
  /// reloading the stream. This is the seamless preview → fullscreen handoff:
  /// audio, decoder and buffer are never interrupted. Mutually exclusive with
  /// [existingPlayer] (that's the media_kit adoption used off Android).
  final bool adoptNativePreview;

  /// VOD resume context — where to persist playback positions and where to
  /// start. Null for live streams (never persisted) and untracked playback.
  final PlaybackContext? playback;

  /// Live-channel favorite integration. [favoriteInitial] seeds the overlay's
  /// star; [onSetFavorite] persists an absolute new state (the host reuses its
  /// existing favorites store, so a toggle here shows up in the channel list on
  /// return). Both are only wired for live channels; when [onSetFavorite] is
  /// null the star isn't shown.
  final bool favoriteInitial;
  final Future<void> Function(bool favorite)? onSetFavorite;

  /// Re-resolves this live channel's stream fresh from the source. Used by the
  /// live reconnect watchdog and "Go to live": Stalker `create_link` URLs
  /// carry single-use/short-lived `play_token`s, so after a portal-side kill
  /// the originally resolved URL is permanently dead — a reload must get a
  /// fresh link ("resolve at play time, never ahead"). When null, reloads fall
  /// back to the original [stream] URL.
  final Future<StreamInfo?> Function()? resolveAgain;

  /// Linux only: go straight to the native mpv path on open instead of the
  /// embedded media_kit surface. Set true by the channel list for the
  /// Wayland+HDR same-channel handoff ([FullscreenHandoff.stopResolveFresh]),
  /// where the preview was already stopped and [stream] re-resolved fresh — the
  /// native mpv process can't adopt an engine, so there's nothing to keep
  /// embedded. When false (zap / EPG grid / VOD / SDR), the screen opens
  /// embedded and escalates *once* to native only if the source reports PQ/HLG
  /// on Wayland (see `_maybeEscalateLinuxNative`). Ignored off Linux and when a
  /// native launch fails (falls back to embedded either way).
  final bool preferLinuxNative;

  /// Windows only: render the adopted preview engine on the **embedded**
  /// media_kit surface (its shared texture) instead of hot-swapping mpv's `vo`
  /// to the native HDR HWND. Set true by the channel list for a same-channel
  /// **SDR** preview handoff, so preview→fullscreen (and back) is seamless — the
  /// same `Player`/`VideoController` keeps rendering, no `vo` reinit, and the
  /// preview is never disposed. HDR streams leave this false and keep the native
  /// HWND path (real D3D11 HDR, at the cost of the reinit beat) — the same
  /// "embedded by default, dedicated surface only when the stream needs it"
  /// policy Linux uses (SDR embedded, HDR native mpv). Ignored off Windows.
  final bool preferWindowsEmbedded;

  /// Debug-only: when non-null (and only honored under [kDebugMode]), passed
  /// through as `soakAutoCloseMs` on the Android native `open` call so the
  /// native Activity self-closes after this many milliseconds — lets
  /// `integration_test/player_soak_test.dart` cycle the player without a real
  /// Back press. Ignored on other platforms and in release builds.
  @visibleForTesting
  static int? debugSoakAutoCloseMs;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.stream,
    this.sourceName,
    this.epgNow,
    this.epgNext,
    this.existingPlayer,
    this.existingController,
    this.adoptNativePreview = false,
    this.playback,
    this.favoriteInitial = false,
    this.onSetFavorite,
    this.resolveAgain,
    this.preferLinuxNative = false,
    this.preferWindowsEmbedded = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const MethodChannel _nativeHdrPlayer = MethodChannel(
    'iptvs/native_hdr_player',
  );
  // Arbitrates the static channel's handler across successive States — e.g.
  // navigation replacing an old route's State before it disposes — so a
  // superseded owner's dispose can never clear a newer owner's handler. See
  // [ChannelHandlerOwner].
  static final ChannelHandlerOwner _hdrOwner = ChannelHandlerOwner(
    _nativeHdrPlayer,
  );
  int? _hdrToken;

  // Ceilings for the lifecycle-critical native calls. Without these, a native
  // side that connects but never replies (surface creation wedged, engine
  // init hung) would leave the awaiting Dart future pending forever — the
  // player route couldn't fall back to the embedded surface or be popped, so
  // the app looks frozen. On timeout we take the same fallback path as an
  // unavailable/failed native player.
  static const Duration _nativeOpenTimeout = Duration(seconds: 10);
  static const Duration _nativeExitTimeout = Duration(seconds: 3);

  late final Player _player = _createPlayer();

  // An adopted player was already counted by whoever constructed it (e.g.
  // LivePreviewController._createPlayer) — only count one built fresh here.
  Player _createPlayer() {
    final existing = widget.existingPlayer;
    if (existing != null) return existing;
    ResourceCounters.incMediaKitPlayers();
    return Player(
      configuration: PlayerConfiguration(
        vo: _usesWindowsNativeSurface ? 'null' : null,
        osc: _usesWindowsNativeSurface,
        // 64 MB forward demuxer cache (default is 32) — smoother VOD seeking.
        bufferSize: 64 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
  }

  /// The embedded (texture) video output. **Deliberately `late`**: reading it
  /// is what constructs it, and constructing a [VideoController] is not free —
  /// on Android it means an `Utils.IsEmulator` channel round-trip, a decoder
  /// query, a SurfaceTexture/ANativeWindow allocation and ~10 mpv property
  /// sets, all on the main isolate during the exact frames that decide
  /// time-to-first-frame. Android's happy path never renders this surface (the
  /// native HDR Activity owns playback), so nothing must read this field until
  /// the embedded fallback is actually taking over — see
  /// [_ensureEmbeddedController] and the ordering in [_playbackSurface].
  late final VideoController? _controller = _usesWindowsNativeSurface
      ? null
      : (widget.existingController ??
            VideoController(
              _player,
              configuration: VideoControllerConfiguration(
                // GNU/Linux defaults to `auto`, which can select fragile
                // zero-copy paths. Match the proven Windows policy: use the
                // safest available VA-API/VDPAU path and fall back cleanly.
                hwdec: Platform.isLinux ? 'auto-safe' : null,
              ),
            ));

  /// Forces the lazily-built [_controller] into existence. Called on the
  /// embedded-fallback path *before* [_configureNativePlayer] applies the
  /// embedded mpv options, because [VideoController] creation sets `vo`/`hwdec`
  /// itself (see `kEmbeddedAndroidVideoOptions`) — keeping it ahead of the
  /// option sweep preserves the ordering the embedded path has always had.
  VideoController? _ensureEmbeddedController() => _controller;
  final GlobalKey<PlayerVideoSurfaceState> _embeddedSurfaceKey = GlobalKey();

  /// False when [_player] was adopted from an existing preview — it's owned by
  /// the caller (e.g. [LivePreviewController]), so this screen must never
  /// dispose it.
  bool get _ownsPlayer => widget.existingPlayer == null;

  /// True once this screen has re-pointed an adopted player's video output at
  /// the Windows native HDR surface. That leaves the player's mpv `vo`/`wid`
  /// pointed at a surface this route is about to tear down, so it's no longer
  /// safe for the caller to keep using for embedded (texture) rendering —
  /// reported back via the pop result so the caller discards it.
  bool _didWindowsHotSwap = false;
  final List<StreamSubscription<dynamic>> _subs = [];
  String? _error;
  late final bool _isLive = widget.stream.isLive;
  // Live-channel favorite state for the overlay star (embedded path); the
  // Android native overlay tracks its own copy and reports back on close.
  late bool _favorite = widget.favoriteInitial;
  bool get _canFavorite => _isLive && widget.onSetFavorite != null;
  // Live-edge sync for the Windows overlay: false once the user pauses live (and
  // falls behind), true again after go-to-live. Greys the LIVE badge + shows the
  // go-to-live button.
  bool _liveSynced = true;
  // Live reconnect watchdog (Windows / embedded media_kit; Android reconnects in
  // its native Activity). Reload the source when a live stream stalls or errors.
  bool _buffering = false;
  bool _reconnecting = false;
  int _stalledSinceMs = 0;
  int _lastReconnectMs = 0;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// True while a *native* surface owns playback, so [_playbackSurface] renders
  /// a bare black fill instead of the embedded media_kit surface.
  ///
  /// Starts true on Windows (which always opens on its native HWND) **and on
  /// Android**: `MainActivity` answers the `open` call `true` unconditionally —
  /// engine selection, including the mpv fallback, happens inside
  /// `HdrPlayerActivity` — so the Dart embedded path is only ever reached when
  /// the *channel* itself fails (`MissingPluginException`, the 10s timeout, a
  /// `PlatformException`). Starting true means the happy path never builds a
  /// [VideoController] or a `Video` widget tree at all. The fallback branch in
  /// [_open] sets it back to false (and calls [_ensureEmbeddedController]) so
  /// the embedded path still works when the native launch really did fail.
  late bool _nativePlaybackLaunched =
      _usesWindowsNativeSurface || Platform.isAndroid;
  // Android adopted-handoff: set once the native launch failed and the
  // embedded fallback is taking over (ends the transparent handoff window).
  bool _nativeLaunchFailed = false;
  bool _isNativeFullscreen = false;
  bool _nativeControlsVisible = true;
  bool _nativeTeardownScheduled = false;
  bool _loggedActiveVo = false;
  bool _loggedHwdec = false;
  String? _lastVideoParamsLog;
  // HDR10+ detection (Windows/mpv). mpv has no clean "has HDR10+" flag, so we
  // infer it from the ST2094-40 scene dynamic-metadata sub-properties — which are
  // zero for plain HDR10 and, unlike max-pq-y, aren't synthesised by
  // `hdr-compute-peak`. Conservative: stays false (→ "HDR10 · PQ") on any
  // absence/error, only flips true once a PQ stream clearly carries scene metadata.
  bool _hdr10Plus = false;
  bool _probingHdr10Plus = false;
  DateTime? _ignoreNativeInputUntil;
  int? _windowsNativeSurface;
  // VOD resume plumbing (null when untracked / live).
  Timer? _positionPersistTimer;
  Duration? _pendingEmbeddedResume;
  // Index into [_aspectModes]. Starts at "Fill" to match the panscan=1.0 the
  // native surface is configured with in [_configureNativePlayer].
  int _aspectModeIndex = 1;

  static const List<double> _speedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  static const List<_AspectMode> _aspectModes = <_AspectMode>[
    _AspectMode('Fit', '0.0', 'no'),
    _AspectMode('Fill', '1.0', 'no'),
    _AspectMode('16:9', '0.0', '16:9'),
    _AspectMode('4:3', '0.0', '4:3'),
  ];

  // Whether playback is *currently* on the native HWND surface. Starts from the
  // initial SDR/HDR decision (`preferWindowsEmbedded`) but flips true when an
  // SDR-adopted embedded stream turns out HDR and escalates
  // (`_maybeEscalateWindowsNative`), so the runtime gates below track the actual
  // surface rather than the initial choice. `late` so it can read `widget`.
  late bool _windowsNativeActive =
      Platform.isWindows && !widget.preferWindowsEmbedded;
  // Windows embedded→native escalation guards (one-shot, re-entry-blocked),
  // mirroring the Linux `_linuxEscalated`/`_linuxEscalating` pair.
  bool _windowsEscalated = false;
  bool _windowsEscalating = false;
  bool get _usesWindowsNativeSurface => _windowsNativeActive;
  bool get _usesLinuxNativeSurface => Platform.isLinux;
  LinuxNativeSession? _linuxNativeSession;
  StreamSubscription<String>? _linuxNativeControlSub;
  StreamSubscription<LinuxNativePlaybackSignal>? _linuxNativePlaybackSub;
  bool _linuxNativeClosing = false;

  /// True once the native mpv reported its first file-loaded/playback-restart
  /// for the current session — gates the preview→native handoff blackout and
  /// keeps initial buffering out of the stall watchdog.
  bool _linuxNativeStarted = false;

  /// One-shot guard for the Linux embedded→native escalation: once the
  /// embedded player reports a PQ/HLG source on Wayland we escalate to native
  /// mpv exactly once and never re-escalate or de-escalate (see
  /// `_maybeEscalateLinuxNative`). `_linuxEscalating` blocks re-entry while the
  /// (async) escalation is mid-flight.
  bool _linuxEscalated = false;
  bool _linuxEscalating = false;

  /// Android adopted-handoff window: this route (pushed non-opaque by the
  /// caller) stays fully transparent so the channel list — including the
  /// preview's frozen last frame — remains visible until the native Activity's
  /// first frame covers it. No black flash in between. Ends if the native
  /// launch fails and the embedded fallback needs a real surface.
  bool get _transparentHandoff =>
      Platform.isAndroid && widget.adoptNativePreview && !_nativeLaunchFailed;

  @override
  void initState() {
    super.initState();
    // Both native-player platforms call back over this channel: Windows sends
    // input/control/closed events for its GDI overlay; Android sends `nativeClosed`
    // when its native Activity finishes. Without the Android handler, backing out
    // of the native player leaves this route stranded on the black overlay until a
    // second Back press — register it so `nativeClosed` pops us straight to the list.
    if (Platform.isWindows || Platform.isAndroid) {
      _hdrToken = _hdrOwner.claim(_handleNativeHdrMethodCall);
    }

    // Show errors once as an overlay rather than a stream of snackbars. On a live
    // stream, auto-reconnect instead of surfacing a terminal error.
    _subs.add(
      _player.stream.error.listen((message) {
        _logPlayback('error ${_redactPlayback(message)}');
        if (!mounted) return;
        if (_isLive) {
          _reconnectLive(force: true);
        } else {
          setState(() => _error = message);
        }
      }),
    );
    // Track buffering for the live reconnect watchdog.
    _subs.add(_player.stream.buffering.listen((value) => _buffering = value));
    // Clean server-side EOF (mpv eof-reached → completed=true, buffering=false)
    // is invisible to the buffering-gated watchdog above — treat it as a live
    // drop, like the Linux-native end-file signal. App-initiated stop() emits
    // completed=false, so teardown and the native handoff never trip this.
    _subs.add(
      _player.stream.completed.listen((completed) {
        if (!mounted) return;
        if (!shouldReconnectOnCompleted(
          completed: completed,
          isLive: _isLive,
          nativeSessionActive:
              _linuxNativeSession != null || _nativePlaybackLaunched,
        )) {
          return;
        }
        _logPlayback('live stream completed (clean EOF) — reconnecting');
        _reconnectLive(force: true);
      }),
    );
    if (_isLive) {
      _reconnectTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _pollLiveReconnect(),
      );
      ResourceCounters.incReconnectTimers();
    }
    // VOD resume: persist the position periodically (plus on dispose and via
    // the native player's nativeClosed payload), so a crash mid-film loses at
    // most half a minute.
    if (widget.playback != null && !_isLive) {
      _positionPersistTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _persistPlaybackPosition(),
      );
      final resume = widget.playback!.resumeFrom;
      if (resume != null && resume > Duration.zero) {
        _pendingEmbeddedResume = resume;
      }
    }
    // Embedded resume: seek once the duration is known (a cold seek right
    // after open can land before the demuxer is ready).
    _subs.add(
      _player.stream.duration.listen((duration) {
        final resume = _pendingEmbeddedResume;
        if (resume == null || _nativePlaybackLaunched) return;
        if (duration <= Duration.zero) return;
        _pendingEmbeddedResume = null;
        if (resume < duration) {
          _logPlayback('resume seek to ${resume.inSeconds}s');
          unawaited(_player.seek(resume));
        }
      }),
    );
    _subs.add(
      _player.stream.log.listen((entry) {
        if (entry.level != 'warn' && entry.level != 'error') return;
        // ffmpeg-prefixed lines (UDTA/timescale demux noise, alternating
        // `hevc: Could not find ref with POC …` / `Error constructing the frame
        // RPS` decode complaints) are non-fatal diagnostics, amplified by the
        // shared libav av_log callback relaying the native engine's software
        // decode out through media_kit's log stream. Drop them at both warn and
        // error level — genuine fatal playback failures arrive on stream.error,
        // not here. Keep non-ffmpeg warnings/errors.
        if (entry.prefix.contains('ffmpeg')) return;
        _logPlaybackDeduped('${entry.level} ${entry.prefix}: ${entry.text}');
      }),
    );
    _subs.add(
      _player.stream.audioParams.listen((params) {
        _logPlayback(
          'audio format=${params.format} channels=${params.channels} '
          'rate=${params.sampleRate}',
        );
      }),
    );
    _subs.add(
      _player.stream.track.listen((track) {
        _logPlayback(
          'selected tracks video=${_trackSummary(track.video)} '
          'audio=${_trackSummary(track.audio)}',
        );
        _syncWindowsNativeControlState();
      }),
    );
    _subs.add(
      _player.stream.tracks.listen((tracks) {
        final audio = tracks.audio
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(_trackSummary)
            .join('; ');
        final video = tracks.video
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(_trackSummary)
            .join('; ');
        final subtitles = tracks.subtitle
            .where((track) => track.id != 'auto' && track.id != 'no')
            .map(_trackSummary)
            .join('; ');
        _logPlayback(
          'available tracks video=[${video.isEmpty ? 'none' : video}] '
          'audio=[${audio.isEmpty ? 'none' : audio}] '
          'subtitles=[${subtitles.isEmpty ? 'none' : subtitles}] '
          'externalSubtitles=${widget.stream.subtitles.length}',
        );
        _syncWindowsNativeControlState();
      }),
    );
    _subs.add(
      _player.stream.videoParams.listen((params) {
        // mpv re-emits identical video-params repeatedly; only log on change so
        // the exportable diagnostics log stays readable.
        final line =
            'video format=${params.hwPixelformat ?? params.pixelformat} '
            'w=${params.w} h=${params.h} display=${params.dw}x${params.dh} '
            'primaries=${params.primaries} gamma=${params.gamma} '
            'sigPeak=${params.sigPeak} matrix=${params.colormatrix} '
            'levels=${params.colorlevels}';
        if (line != _lastVideoParamsLog) {
          _lastVideoParamsLog = line;
          _logPlayback(line);
        }
        unawaited(_logActiveVideoOutput());
        unawaited(_probeHdr10Plus(params));
        unawaited(_maybeEscalateLinuxNative(params));
        unawaited(_maybeEscalateWindowsNative(params));
      }),
    );
    // Clear the error overlay once playback actually starts.
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (playing && _error != null && mounted) setState(() => _error = null);
        _syncWindowsNativeControlState();
      }),
    );
    // Continuous streams (position ticks several times a second, duration/
    // volume piggyback on them) go through the throttle — shipping the full
    // control-state map over the MethodChannel per tick is pure churn while
    // the overlay is hidden, and 2 Hz is plenty for a visible scrubber.
    // Discrete events (track change, play/pause, user commands) keep calling
    // _syncWindowsNativeControlState directly so the overlay never lags input.
    _subs.add(_player.stream.position.listen((_) => _requestControlSync()));
    _subs.add(_player.stream.duration.listen((_) => _requestControlSync()));
    _subs.add(_player.stream.volume.listen((_) => _requestControlSync()));

    _open();
  }

  Future<void> _open() async {
    if (mounted) setState(() => _error = null);
    _showNativeControls(scheduleHide: false);
    _logPlayback(
      'open live=$_isLive url=${_redactPlayback(widget.stream.url)} '
      'surface=${_usesWindowsNativeSurface
          ? 'native-windows'
          : _usesLinuxNativeSurface
          ? (widget.preferLinuxNative ? 'linux-native-attempt' : 'linux-embedded')
          : 'embedded'} '
      'headers=${widget.stream.headers.keys.join(',')} '
      'instance=${identityHashCode(this)} adopted=${widget.existingPlayer != null}',
    );

    if (await _tryOpenNativeHdrPlayer()) {
      if (mounted) setState(() => _nativePlaybackLaunched = true);
      // The native Activity now owns playback of this stream from scratch —
      // an adopted (preview) player isn't rendered anywhere and would just
      // waste decode/bandwidth (and, if unmuted, double up audio) left
      // running behind it.
      if (widget.existingPlayer != null) unawaited(_player.pause());
      return;
    }

    if (_usesLinuxNativeSurface && widget.preferLinuxNative) {
      // Wayland+HDR same-channel handoff ([FullscreenHandoff.stopResolveFresh]):
      // the channel list already stopped the preview and re-resolved [stream]
      // fresh (the native mpv process can't adopt a running engine, so no
      // existingPlayer was handed over). Go straight to native — this is the
      // honest fresh-open cost of real Wayland HDR output. SDR and X11 never
      // set this flag (native buys nothing there); they open embedded below,
      // and only escalate to native if the source turns out to be PQ/HLG on
      // Wayland (see `_maybeEscalateLinuxNative`).
      if (await _startLinuxNativeSession(widget.stream)) return;
      _logPlayback('native linux player unavailable; using embedded fallback');
    }

    // Adopted-handoff path that failed to launch natively: the preview's shared
    // engine was deliberately left playing (seamless handoff), but this route is
    // now about to open the stream itself — silence the engine or the audio
    // doubles up behind the embedded fallback.
    if (widget.adoptNativePreview) {
      try {
        await const MethodChannel(
          'iptvs/native_preview',
        ).invokeMethod<void>('pause');
      } catch (_) {}
    }

    int? nativeWindowHandle;
    if (_usesWindowsNativeSurface) {
      nativeWindowHandle = await _createWindowsNativeHdrSurface();
      if (nativeWindowHandle == null) {
        // No native HWND to hand mpv's `wid`/`vo` to: proceeding would leave
        // audio-only playback behind a black overlay with no visible failure
        // (embeddedVideoOptionsForPlatform() is empty on Windows and
        // _controller is null, so nothing ever renders). Surface the same
        // error/Retry overlay VOD errors use instead — Retry re-runs _open,
        // including this surface-creation attempt.
        if (mounted) {
          setState(() {
            _nativePlaybackLaunched = false;
            _error = "Couldn't create the video surface.";
          });
        }
        return;
      }
    } else if (mounted) {
      // The embedded surface is taking over (on Android: the native channel
      // itself failed). Build the VideoController now, before the mpv options
      // below land — its creation sets `vo`/`hwdec` itself, and on Android it
      // was deliberately skipped until this point.
      _ensureEmbeddedController();
      setState(() {
        _nativePlaybackLaunched = false;
        _nativeLaunchFailed = true;
      });
    }

    // Keep a backward cache so scrubbing back through a VOD doesn't refetch
    // already-downloaded data. (Forward cache comes from bufferSize above.)
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await _configureNativePlayer(platform, nativeWindowHandle);
    }

    // headers carry things like a MAG User-Agent for Stalker; empty for plain HLS.
    if (widget.stream.headers.isNotEmpty && platform is NativePlayer) {
      await _setNativeHeaderOptions(platform, widget.stream.headers);
    }

    // An adopted player is already open and playing this exact stream — the
    // preview it came from resolved and opened it moments ago. On Windows that
    // only holds once the native HDR surface above was actually created (the
    // properties just applied re-pointed its video output at that surface); if
    // surface creation failed, fall through to a fresh open like any other
    // Windows playback. Off Windows there's no separate surface to switch —
    // the embedded VideoController already adopted the same player/controller.
    final adopting = widget.existingPlayer != null;
    final canSkipOpen =
        adopting && (!_usesWindowsNativeSurface || nativeWindowHandle != null);
    if (canSkipOpen && _usesWindowsNativeSurface) _didWindowsHotSwap = true;
    if (!canSkipOpen) {
      await _player.open(
        Media(
          widget.stream.url,
          httpHeaders: widget.stream.headers.isEmpty
              ? null
              : widget.stream.headers,
        ),
      );
    }
    // Insurance against a muted/zero-volume default.
    await _player.setVolume(100);
    if (canSkipOpen) await _player.play();
    _showNativeControls();
  }

  Future<bool> _tryOpenNativeHdrPlayer() async {
    if (!Platform.isAndroid) return false;
    try {
      final opened = await _nativeHdrPlayer
          .invokeMethod<bool>('open', {
            'url': widget.stream.url,
            'title': widget.title,
            if (widget.sourceName != null) 'sourceName': widget.sourceName,
            'headers': widget.stream.headers,
            'isLive': widget.stream.isLive,
            'adoptShared': widget.adoptNativePreview,
            'resumeMs': widget.playback?.resumeFrom?.inMilliseconds ?? 0,
            'canFavorite': _canFavorite,
            'isFavorite': _favorite,
            if (kDebugMode && PlayerScreen.debugSoakAutoCloseMs != null)
              'soakAutoCloseMs': PlayerScreen.debugSoakAutoCloseMs,
            ..._epgPayload(),
            'subtitles': widget.stream.subtitles
                .map(
                  (subtitle) => {
                    'url': subtitle.url,
                    'label': subtitle.label,
                    if (subtitle.language != null)
                      'language': subtitle.language,
                  },
                )
                .toList(growable: false),
          })
          .timeout(_nativeOpenTimeout);
      _logPlayback(
        opened == true
            ? 'native hdr player launched platform=android'
            : 'native hdr player unavailable platform=android',
      );
      return opened == true;
    } on TimeoutException {
      _logPlayback('native hdr player timed out platform=android');
      return false;
    } on MissingPluginException catch (error) {
      _logPlayback('native hdr player missing: $error');
      return false;
    } on PlatformException catch (error) {
      _logPlayback('native hdr player failed: ${error.code} ${error.message}');
      return false;
    }
  }

  Future<int?> _createWindowsNativeHdrSurface() async {
    if (!Platform.isWindows) return null;
    try {
      final handle = await _nativeHdrPlayer
          .invokeMethod<int>('createSurface', {'topInset': 0, 'bottomInset': 0})
          .timeout(_nativeOpenTimeout);
      if (handle == null || handle == 0) {
        _logPlayback('native hdr surface unavailable platform=windows');
        return null;
      }
      _windowsNativeSurface = handle;
      if (mounted) setState(() => _nativePlaybackLaunched = true);
      await _syncWindowsNativeControlState();
      _logPlayback('native hdr surface created platform=windows hwnd=$handle');
      return handle;
    } on TimeoutException {
      _logPlayback('native hdr surface timed out platform=windows');
      return null;
    } on MissingPluginException catch (error) {
      _logPlayback('native hdr surface missing: $error');
      return null;
    } on PlatformException catch (error) {
      _logPlayback('native hdr surface failed: ${error.code} ${error.message}');
      return null;
    }
  }

  void _scheduleWindowsNativeTeardown({bool prepared = false}) {
    if (!Platform.isWindows || _nativeTeardownScheduled) return;
    _nativeTeardownScheduled = true;
    if (!prepared) unawaited(_prepareWindowsNativeExit());
  }

  Future<void> _prepareWindowsNativeExit() async {
    if (!Platform.isWindows) return;
    unawaited(_player.setVolume(0));
    unawaited(_player.pause());
    try {
      await _nativeHdrPlayer
          .invokeMethod<bool>('prepareExit')
          .timeout(_nativeExitTimeout);
    } on TimeoutException {
      _logPlayback('native hdr prepare exit timed out platform=windows');
    } catch (error) {
      _logPlayback('native hdr prepare exit failed: $error');
    }
    // Tear down our own tracking regardless of the native reply — we're
    // leaving the native surface, so a hung/failed prepareExit must not strand
    // the Dart state (and block the route pop) with a stale surface handle.
    _windowsNativeSurface = null;
    _isNativeFullscreen = false;
    _nativeControlsVisible = true;
  }

  Future<void> _setNativeFullscreen(bool fullscreen) async {
    if (!Platform.isWindows) return;
    try {
      final changed = await _nativeHdrPlayer.invokeMethod<bool>(
        'setFullscreen',
        {'fullscreen': fullscreen, 'pinControls': !_player.state.playing},
      );
      if (mounted) {
        setState(() => _isNativeFullscreen = changed ?? fullscreen);
      }
      await _syncWindowsNativeControlState();
      _showNativeControls(scheduleHide: _player.state.playing);
    } catch (error) {
      _logPlayback('native fullscreen failed: $error');
    }
  }

  Future<void> _toggleNativeFullscreen() async {
    if (!_usesWindowsNativeSurface) return;
    _showNativeControls(scheduleHide: _player.state.playing);
    await _setNativeFullscreen(!_isNativeFullscreen);
  }

  // Windows always-on-top mini-player: a compact frameless topmost window,
  // draggable by its video area. Toggled with the M key; the native side owns
  // the geometry and restores the previous placement on exit.
  bool _isNativeMiniPlayer = false;

  Future<void> _toggleNativeMiniPlayer() async {
    if (!_usesWindowsNativeSurface) return;
    try {
      final mini = await _nativeHdrPlayer.invokeMethod<bool>('setMiniPlayer', {
        'mini': !_isNativeMiniPlayer,
      });
      _isNativeMiniPlayer = mini ?? !_isNativeMiniPlayer;
      _logPlayback('native mini-player=$_isNativeMiniPlayer');
      await _syncWindowsNativeControlState();
    } catch (error) {
      _logPlayback('native mini-player failed: $error');
    }
  }

  Future<dynamic> _handleNativeHdrMethodCall(MethodCall call) async {
    if (!mounted) return null;
    if (call.method == 'nativeInput') {
      final ignoreUntil = _ignoreNativeInputUntil;
      if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
        return;
      }
      _showNativeControls();
    } else if (call.method == 'nativeControl') {
      final command = call.arguments?.toString();
      if (command != null) await _handleNativeControlCommand(command);
    } else if (call.method == 'nativeClosed') {
      // The native Activity reports its final VOD position on exit; persist it
      // as the resume point (live playback sends no args).
      final args = call.arguments;
      final playback = widget.playback;
      if (args is Map) {
        if (playback != null) {
          final positionMs = (args['positionMs'] as num?)?.toInt();
          final durationMs = (args['durationMs'] as num?)?.toInt();
          if (positionMs != null && durationMs != null && durationMs > 0) {
            // Awaited — the caller (_playMedia) reloads "Continue watching"
            // right after this route pops, so the write must land first.
            await playback.db.savePlaybackPosition(
              playback.sourceId,
              playback.kind,
              playback.itemId,
              position: Duration(milliseconds: positionMs),
              duration: Duration(milliseconds: durationMs),
            );
          }
        }
        // The native overlay's final favorite state — persist it (awaited, like
        // the position, so the channel list re-read after the pop sees it).
        final favorite = args['favorite'];
        if (favorite is bool && favorite != _favorite) {
          _favorite = favorite;
          await widget.onSetFavorite?.call(favorite);
        }
      }
      await _finishAndroidNativePlayback();
    }
  }

  Future<void> _finishAndroidNativePlayback() async {
    if (!Platform.isAndroid || !mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      setState(() => _nativePlaybackLaunched = false);
    }
  }

  Future<void> _finishLinuxNativePlayback(LinuxNativeSession session) async {
    if (_linuxNativeClosing || _linuxNativeSession != session || !mounted) {
      return;
    }
    // The standalone window can be closed directly. Capture its final IPC
    // position before dropping the session reference or the embedded player
    // fallback will have no useful state to persist.
    try {
      await _persistPlaybackPosition();
    } catch (error) {
      _logPlayback('warn native Linux position save failed: $error');
    }
    if (!mounted || _linuxNativeSession != session) return;
    await _linuxNativeControlSub?.cancel();
    await _linuxNativePlaybackSub?.cancel();
    if (!mounted || _linuxNativeSession != session) return;
    _linuxNativeControlSub = null;
    _linuxNativePlaybackSub = null;
    _linuxNativeSession = null;
    ResourceCounters.decLinuxNativeSessions();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(_didWindowsHotSwap);
    } else {
      setState(() => _nativePlaybackLaunched = false);
    }
  }

  /// Drives the live reconnect watchdog from the native mpv process's
  /// drop/stall/resume signals. Feeds the same `_buffering` flag the
  /// embedded/Windows watchdog uses, so `_pollLiveReconnect`'s 8s stall
  /// threshold, attempt-scaled backoff, counter reset and "Reconnecting…"
  /// clearing all apply unchanged; a hard drop additionally forces an
  /// immediate first retry (mirroring the embedded error path).
  void _handleLinuxNativePlaybackSignal(LinuxNativePlaybackSignal signal) {
    if (!mounted || _linuxNativeSession == null || _linuxNativeClosing) return;
    switch (signal) {
      case LinuxNativePlaybackSignal.dropped:
        // VOD keeps the terminal-frame contract (no auto-reconnect): mpv's
        // --keep-open holds the last frame; Back exits cleanly.
        if (!_isLive) return;
        _buffering = true;
        unawaited(_reconnectLive(force: true));
      case LinuxNativePlaybackSignal.stalled:
        // Initial buffering before the first file-loaded is startup latency,
        // not a mid-play stall — feeding it to the watchdog made slow HLS
        // warmups eat a pointless reload at the 8s threshold.
        if (!_isLive || !_linuxNativeStarted) return;
        _buffering = true;
      case LinuxNativePlaybackSignal.resumed:
        _buffering = false;
        _markLinuxNativeStarted();
    }
  }

  /// First load/playback signal from the native mpv: only now swap this route
  /// to the native-playback build. Until then the route keeps rendering the
  /// adopted (already paused — see _open) preview engine's frozen last frame,
  /// so the handoff shows freeze-frame → native video with no black gap.
  void _markLinuxNativeStarted() {
    if (_linuxNativeStarted || _linuxNativeSession == null) return;
    _linuxNativeStarted = true;
    if (mounted) setState(() => _nativePlaybackLaunched = true);
  }

  /// Launches the standalone native mpv session for [stream] and wires all its
  /// signals (control events, drop/stall/resume reconnect signals, the exit
  /// handler, the blackout deferral, colorimetry probe) plus its resource
  /// counter. Returns true when the session started (this screen now drives it),
  /// false when the native path was unavailable and the caller should fall back
  /// to the embedded surface. Reused by both the direct open ([preferLinuxNative])
  /// and the embedded→native escalation ([_maybeEscalateLinuxNative]).
  /// [resumeOverride] replaces the widget's static resume point when the
  /// caller knows a fresher position (the escalation passes the embedded
  /// player's live position so VOD doesn't rewind by the embedded phase).
  Future<bool> _startLinuxNativeSession(
    StreamInfo stream, {
    Duration? resumeOverride,
  }) async {
    final native = await LinuxNativeSession.start(
      stream: stream,
      title: widget.title,
      sourceName: widget.sourceName,
      epgNow: widget.epgNow,
      epgNext: widget.epgNext,
      canFavorite: _canFavorite,
      favorite: _favorite,
      liveSynced: _liveSynced,
      aspectLabel: _aspectModes[_aspectModeIndex].label,
      resumeFrom: resumeOverride ?? widget.playback?.resumeFrom,
    );
    if (native == null) return false;
    if (!mounted || _linuxNativeClosing) {
      // The route was popped (or teardown began) while mpv was spawning and
      // connecting its IPC socket — a window of several seconds. Adopting the
      // session into a dead State would orphan a fullscreen mpv process:
      // dispose() has already run and saw a null session, and the exit-code
      // handler bails on !mounted without cleaning up. Kill it here instead;
      // the counter was never incremented, so balance holds.
      unawaited(native.dispose());
      return false;
    }
    _linuxNativeSession = native;
    ResourceCounters.incLinuxNativeSessions();
    _linuxNativeClosing = false;
    _linuxNativeControlSub = native.controlEvents.listen(
      _handleLinuxNativeControl,
    );
    // Live auto-reconnect: the embedded/Windows watchdog watches media_kit
    // streams, but here the native mpv process plays and the embedded _player
    // is idle — so drive _buffering (and a fast first retry) off mpv's
    // drop/stall/resume IPC signals instead.
    _linuxNativePlaybackSub = native.playbackEvents.listen(
      _handleLinuxNativePlaybackSignal,
    );
    // Handoff blackout deferral: this route keeps rendering the embedded
    // surface's frozen last frame until the native mpv reports its file
    // loaded/playing — _markLinuxNativeStarted then swaps to the
    // native-playback build, right as mpv's window (created at file load,
    // --force-window=yes) appears already bearing video. A fallback timer
    // covers a native process that never signals.
    _linuxNativeStarted = false;
    unawaited(
      native.exitCode.then((code) {
        _logPlayback(
          'linux native process exited code=$code '
          'instance=${identityHashCode(this)}',
        );
        return _finishLinuxNativePlayback(native);
      }),
    );
    unawaited(
      Future<void>.delayed(const Duration(seconds: 10), () {
        if (mounted && _linuxNativeSession == native) {
          _markLinuxNativeStarted();
        }
      }),
    );
    _logPlayback(
      'native hdr player launched platform=linux backend=${native.backend.name} '
      'mpv=${native.mpvVersionLabel} context=${native.gpuContextLabel} '
      'vo=gpu-next hwdec=auto-safe',
    );
    // Give mpv a moment to open the stream and start decoding before reading
    // back the output colorimetry — video-target-params is only populated once
    // the render pipeline has produced a frame.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (!mounted || _linuxNativeSession != native) return;
        unawaited(_probeLinuxNativeHdr(native));
      }),
    );
    return true;
  }

  /// Linux embedded→native escalation, driven off the embedded player's
  /// [VideoParams] stream. The default Linux fullscreen path is embedded
  /// media_kit (seamless, one provider connection); the native mpv window buys
  /// nothing for SDR and nothing at all on X11 (no HDR output there). But a
  /// real PQ/HLG source on Wayland *does* want native mpv's HDR passthrough, so
  /// the first time the embedded player reports HDR colorimetry — and only if
  /// the native path is actually usable ([LinuxNativeSession.nativeLikelyAvailable]
  /// is Wayland-gated) — escalate exactly once: re-resolve fresh (Stalker tokens
  /// are single-use and the embedded engine holds the connection), stop the
  /// embedded playback to free that connection, and launch native. One-shot:
  /// never re-escalates, never de-escalates. Mirrors Android's "default engine,
  /// escalate only when the stream needs it".
  Future<void> _maybeEscalateLinuxNative(VideoParams params) async {
    if (!_usesLinuxNativeSurface) return;
    // Already native (direct open or a prior escalation), or one already
    // resolved/in-flight — nothing to do.
    if (widget.preferLinuxNative) return;
    if (_linuxNativeSession != null || _linuxEscalated || _linuxEscalating) {
      return;
    }
    if (!isHdrColorimetry(
      gamma: params.gamma,
      primaries: params.primaries,
      matrix: params.colormatrix,
    )) {
      return;
    }
    _linuxEscalating = true;
    // Only escalate when the native path can actually run (Wayland + a host mpv
    // >= 0.40). On X11 / below the floor this is false, so we stay embedded.
    if (!await LinuxNativeSession.nativeLikelyAvailable()) {
      _linuxEscalating = false;
      return;
    }
    // Re-check the one-shot guards after the await — a teardown or a competing
    // videoParams event may have raced in.
    if (!mounted || _linuxNativeSession != null || _linuxEscalated) {
      _linuxEscalating = false;
      return;
    }
    _linuxEscalated = true; // one-shot: never re-escalate
    _logPlayback(
      'linux native escalation: PQ/HLG source on Wayland — switching '
      'embedded → native mpv',
    );
    // Fresh resolve: the embedded engine holds the (possibly single-use)
    // connection/token, so native must open a freshly resolved URL.
    final fresh = await _freshLiveStream();
    if (!mounted) {
      _linuxEscalating = false;
      return;
    }
    // Free the provider connection before native opens (single-connection
    // portals refuse a second), then launch native with the fresh stream.
    // For VOD/catch-up, carry the embedded player's actual position across
    // the switch — the widget's resumeFrom predates the embedded phase, and
    // stop() discards the live position.
    final embeddedPosition = _isLive ? null : _player.state.position;
    await _player.stop();
    final started = await _startLinuxNativeSession(
      fresh,
      resumeOverride:
          (embeddedPosition != null && embeddedPosition > Duration.zero)
          ? embeddedPosition
          : null,
    );
    if (!started && mounted) {
      // Native was predicted available but failed to launch — resume embedded
      // playback (honest SDR tone-mapped fallback) rather than leaving a
      // stopped player behind a black surface.
      _logPlayback('linux native escalation failed; staying embedded');
      await _player.open(
        Media(
          fresh.url,
          httpHeaders: fresh.headers.isEmpty ? null : fresh.headers,
        ),
      );
    }
    _linuxEscalating = false;
  }

  /// Windows counterpart of [_maybeEscalateLinuxNative]: an SDR-adopted embedded
  /// open ([preferWindowsEmbedded]) whose stream turns out HDR (PQ/HLG) switches
  /// to the native HWND surface so real D3D11 HDR engages. The ahead-of-time
  /// colorimetry read in `_openLivePlayer` can miss HDR when the preview hadn't
  /// decoded it yet (a cold/fast preview→fullscreen), which otherwise left an
  /// HDR channel stuck on the tone-mapped SDR embedded surface until reopened.
  /// One-shot; unlike Linux this reuses the *same* media_kit player (a `vo`
  /// hot-swap, no fresh resolve) — the cost is a brief mid-playback switch.
  Future<void> _maybeEscalateWindowsNative(VideoParams params) async {
    // Only from the SDR-adopted embedded path. VOD and HDR-native opens never
    // set preferWindowsEmbedded, so they never reach here (already native).
    if (!Platform.isWindows || !widget.preferWindowsEmbedded) return;
    if (_windowsNativeActive || _windowsEscalated || _windowsEscalating) return;
    if (!isHdrColorimetry(
      gamma: params.gamma,
      primaries: params.primaries,
      matrix: params.colormatrix,
    )) {
      return;
    }
    _windowsEscalating = true;
    _windowsEscalated = true; // one-shot: never retry, even if the surface fails
    _logPlayback(
      'windows native escalation: PQ/HLG source — switching embedded → '
      'native HWND',
    );
    // Creates the HWND surface *and* the GDI overlay, sets _windowsNativeSurface
    // / _nativePlaybackLaunched, and syncs control state (see
    // _createWindowsNativeHdrSurface / CreateNativeVideoSurface).
    final handle = await _createWindowsNativeHdrSurface();
    if (!mounted) {
      // Route popped mid-escalation: tear the just-created surface down so it
      // isn't orphaned.
      if (handle != null) await _prepareWindowsNativeExit();
      _windowsEscalating = false;
      return;
    }
    if (handle == null) {
      // Surface creation failed — stay on the embedded (tone-mapped SDR) surface
      // rather than leaving a black native overlay.
      _logPlayback('windows native escalation: surface unavailable, staying embedded');
      _windowsEscalating = false;
      return;
    }
    _windowsNativeActive = true;
    // The adopted preview player's video output now lives on the HWND (about to
    // be torn down on exit), so the channel list must discard + restart the
    // preview on return rather than resuming it — the same as a normal native
    // hot-swap.
    _didWindowsHotSwap = true;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // wid-before-vo hot-swap of the already-playing player (see
      // _configureNativePlayer's ordering note).
      await _configureNativePlayer(platform, handle);
      if (widget.stream.headers.isNotEmpty) {
        await _setNativeHeaderOptions(platform, widget.stream.headers);
      }
    }
    if (!mounted) {
      _windowsEscalating = false;
      return;
    }
    _showNativeControls();
    _windowsEscalating = false;
  }

  Future<void> _handleLinuxNativeControl(String command) async {
    final session = _linuxNativeSession;
    if (session == null) return;
    switch (command) {
      case 'back':
        await _exitAndPop();
      case 'playPause':
        // Route through _togglePlayback (not a direct 'cycle pause' send) so
        // the live _liveSynced=false transition and overlay-state push run
        // the same as every other play/pause trigger.
        await _togglePlayback();
      case 'seekBack':
        _seekBy(-10);
      case 'seekForward':
        _seekBy(10);
      case 'mute':
        await session.command(const ['cycle', 'mute']);
      case 'goLive':
        await _goToLive();
      case 'favorite':
        _toggleFavorite();
        await _pushLinuxOverlayState();
      case 'audio':
        await session.command(const ['cycle', 'audio']);
      case 'subtitle':
        await session.command(const ['cycle', 'sub']);
      case 'aspect':
        // Dart owns the label sequence (shared with the Windows overlay via
        // _aspectModes/_aspectModeIndex) so the overlay always shows the mode
        // mpv actually ended up in, rather than mpv cycling its own
        // 'video-aspect-override' values out of step with a hardcoded label.
        _aspectModeIndex = (_aspectModeIndex + 1) % _aspectModes.length;
        final mode = _aspectModes[_aspectModeIndex];
        await session.command(['set_property', 'panscan', mode.panscan]);
        await session.command([
          'set_property',
          'video-aspect-override',
          mode.aspect,
        ]);
        _logPlayback('native linux aspect mode=${mode.label}');
        await _pushLinuxOverlayState();
      case 'fullscreen':
        await session.command(const ['cycle', 'fullscreen']);
    }
  }

  void _showNativeControls({bool scheduleHide = true}) {
    if (!_usesWindowsNativeSurface) return;
    if (mounted && !_nativeControlsVisible) {
      setState(() => _nativeControlsVisible = true);
    } else {
      _nativeControlsVisible = true;
    }
    unawaited(
      _nativeHdrPlayer.invokeMethod<bool>('showControls', {
        'visible': true,
        'scheduleHide': scheduleHide,
      }),
    );
  }

  void _handlePlaybackInput() {
    if (_usesWindowsNativeSurface) _showNativeControls();
  }

  Future<void> _handleNativeControlCommand(String command) async {
    if (command.startsWith('seekPercent:')) {
      final ratio = double.tryParse(command.substring('seekPercent:'.length));
      final duration = _player.state.duration;
      if (ratio != null && duration > Duration.zero) {
        await _player.seek(
          Duration(
            milliseconds: (duration.inMilliseconds * ratio.clamp(0.0, 1.0))
                .round(),
          ),
        );
      }
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('volumePercent:')) {
      final ratio = double.tryParse(command.substring('volumePercent:'.length));
      if (ratio != null) {
        await _player.setVolume((ratio.clamp(0.0, 1.0) * 100).roundToDouble());
      }
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('subtitleTrack:')) {
      final id = command.substring('subtitleTrack:'.length);
      await _selectNativeSubtitleTrack(id);
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('audioTrack:')) {
      final id = command.substring('audioTrack:'.length);
      await _selectNativeAudioTrack(id);
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('speed:')) {
      final rate = double.tryParse(command.substring('speed:'.length));
      if (rate != null) await _player.setRate(rate);
      await _syncWindowsNativeControlState();
      return;
    }
    if (command.startsWith('menu:')) {
      // The native overlay owns menu open/close state; refresh so the menu it
      // just opened renders the latest track/option list.
      await _syncWindowsNativeControlState();
      return;
    }
    switch (command) {
      case 'back':
        _back();
        break;
      case 'playPause':
        final wasPlaying = _player.state.playing;
        await _togglePlayback();
        if (wasPlaying) _showNativeControls(scheduleHide: false);
        break;
      case 'seekBack':
        _seekBy(-10);
        break;
      case 'seekForward':
        _seekBy(10);
        break;
      case 'muteToggle':
        final volume = _player.state.volume;
        await _player.setVolume(volume > 0 ? 0 : 100);
        break;
      case 'fullscreen':
        await _toggleNativeFullscreen();
        break;
      case 'aspect':
        await _cycleNativeAspect();
        break;
      case 'goLive':
        // Live IPTV streams are usually non-seekable ("Cannot seek in this
        // stream"), so reopen the source instead of seeking — reconnecting drops
        // the buffer and resumes at the live edge.
        await _goToLive();
        break;
      case 'info':
        // The native overlay owns the info-panel open state; refresh so it
        // renders with the latest metadata.
        await _syncWindowsNativeControlState();
        break;
      case 'favorite':
        // Dart owns the favorites store; toggle it and the trailing sync below
        // pushes the new state back to the overlay star.
        _toggleFavorite();
        break;
      case 'show':
        break;
    }
    await _syncWindowsNativeControlState();
  }

  // Watchdog: a live stream stuck buffering past the threshold gets reloaded.
  void _pollLiveReconnect() {
    if (!_isLive || !mounted) return;
    if (!_buffering) {
      _stalledSinceMs = 0;
      _reconnectAttempt = 0;
      if (_reconnecting) {
        _reconnecting = false;
        _onReconnectingChanged();
      }
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_stalledSinceMs == 0) _stalledSinceMs = now;
    if (now - _stalledSinceMs >= kReconnectStallMs) {
      unawaited(_reconnectLive(force: false));
    }
  }

  /// Reload the live source to reconnect, with capped backoff between attempts.
  /// [force] (a hard error) skips the stall threshold but still rate-limits.
  Future<void> _reconnectLive({required bool force}) async {
    if (!_isLive || !mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final minGap = reconnectMinGapMs(
      priorAttempts: _reconnectAttempt,
      force: force,
    );
    if (_lastReconnectMs != 0 && now - _lastReconnectMs < minGap) return;
    _reconnectAttempt++;
    _lastReconnectMs = now;
    _stalledSinceMs = now;
    _liveSynced = true; // a reconnect reopens at the live edge
    if (!_reconnecting) {
      _reconnecting = true;
      _onReconnectingChanged();
    }
    _logPlayback('live reconnect attempt=$_reconnectAttempt force=$force');
    try {
      final stream = await _freshLiveStream();
      if (!mounted) return;
      final linuxSession = _linuxNativeSession;
      if (linuxSession != null) {
        // The native mpv process owns playback (the embedded _player is idle),
        // so reload the source in mpv — same live-edge `loadfile replace` as
        // "Go to live", with headers refreshed alongside the (possibly
        // re-resolved) URL.
        await linuxSession.command(
          LinuxNativeSession.buildHeaderFieldsCommand(stream.headers),
        );
        await linuxSession.command(['loadfile', stream.url, 'replace']);
      } else {
        await _player.open(
          Media(
            stream.url,
            httpHeaders: stream.headers.isEmpty ? null : stream.headers,
          ),
        );
      }
    } catch (error) {
      _logPlayback('live reconnect failed: ${_redactPlayback('$error')}');
    }
  }

  /// The stream to use for a live reload: freshly re-resolved when the caller
  /// provided [PlayerScreen.resolveAgain] (Stalker tokens are single-use — see
  /// its doc), the original resolved stream otherwise or on resolve failure.
  Future<StreamInfo> _freshLiveStream() async {
    final resolve = widget.resolveAgain;
    if (resolve == null) return widget.stream;
    try {
      final fresh = await resolve();
      if (fresh != null) return fresh;
    } catch (error) {
      _logPlayback('re-resolve failed: ${_redactPlayback('$error')}');
    }
    return widget.stream;
  }

  void _onReconnectingChanged() {
    if (_usesWindowsNativeSurface) {
      if (_reconnecting) _showNativeControls(scheduleHide: false);
      unawaited(_syncWindowsNativeControlState());
    } else if (_linuxNativeSession != null) {
      // The native mpv overlay draws its own "Reconnecting…" chip from the
      // pushed state; the embedded Flutter chip (below) is hidden behind the
      // mpv window on this path.
      unawaited(_pushLinuxOverlayState());
    } else if (mounted) {
      setState(() {});
    }
  }

  /// Pushes the current overlay state to the native mpv Lua overlay, including
  /// the live-reconnect indicator. Centralises the (otherwise repeated) full
  /// `updateOverlayState` argument list for the state the reconnect watchdog
  /// mutates.
  Future<void> _pushLinuxOverlayState() async {
    final session = _linuxNativeSession;
    if (session == null) return;
    await session.updateOverlayState(
      title: widget.title,
      sourceName: widget.sourceName,
      epgNow: widget.epgNow,
      epgNext: widget.epgNext,
      canFavorite: _canFavorite,
      favorite: _favorite,
      isLive: _isLive,
      liveSynced: _liveSynced,
      aspectLabel: _aspectModes[_aspectModeIndex].label,
      reconnecting: _reconnecting,
      hdr10Plus: _hdr10Plus,
    );
  }

  // Coalesces continuous-stream control-state syncs (see initState) to 2 Hz.
  // Note the native overlay auto-hides on its own timer without telling Dart,
  // so visibility can't gate this — the throttle alone does the work. Any
  // user action syncs directly, so the overlay never reappears stale.
  Timer? _controlSyncThrottle;

  void _requestControlSync() {
    if (!Platform.isWindows || _windowsNativeSurface == null) return;
    if (_controlSyncThrottle?.isActive ?? false) return;
    _controlSyncThrottle = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      unawaited(_syncWindowsNativeControlState());
    });
  }

  Future<void> _syncWindowsNativeControlState() async {
    if (!Platform.isWindows || _windowsNativeSurface == null) return;
    try {
      await _nativeHdrPlayer.invokeMethod<bool>('setControlState', {
        'title': widget.title,
        if (widget.sourceName != null) 'sourceName': widget.sourceName,
        ..._epgPayload(),
        'isLive': _isLive,
        'liveSynced': _liveSynced,
        'canFavorite': _canFavorite,
        'isFavorite': _favorite,
        'reconnecting': _reconnecting,
        'playing': _player.state.playing,
        'fullscreen': _isNativeFullscreen,
        'positionMs': _player.state.position.inMilliseconds.toDouble(),
        'durationMs': _player.state.duration.inMilliseconds.toDouble(),
        'volume': _player.state.volume,
        'selectedSubtitleId': _player.state.track.subtitle.id,
        'subtitleTracks': _nativeSubtitleTrackPayload(),
        'selectedAudioId': _player.state.track.audio.id,
        'audioTracks': _nativeAudioTrackPayload(),
        'selectedSpeedId': _speedId(_player.state.rate),
        'speedOptions': _speedOptionPayload(),
        'aspectLabel': _aspectModes[_aspectModeIndex].label,
        ..._streamInfoPayload(),
      });
    } catch (error) {
      _logPlayback('native hdr control state failed: $error');
    }
  }

  Future<void> _selectNativeSubtitleTrack(String id) async {
    final tracks = _nativeSubtitleTracks();
    SubtitleTrack? selected;
    for (final track in tracks) {
      if (track.id == id) {
        selected = track;
        break;
      }
    }
    if (selected == null) return;
    _logPlayback(
      'native subtitle select id=${selected.id} '
      'label=${_subtitleTrackLabel(selected)}',
    );
    await _player.setSubtitleTrack(selected);
    final platform = _player.platform;
    if (platform is NativePlayer) {
      final properties = selected.id == 'no'
          ? const <String, String>{
              'sid': 'no',
              'secondary-sid': 'no',
              'sub-visibility': 'no',
            }
          : <String, String>{
              if (selected.id == 'auto') 'sid': 'auto',
              if (int.tryParse(selected.id) != null) 'sid': selected.id,
              'sub-visibility': 'yes',
              'sub-ass': 'yes',
              'sub-use-margins': 'no',
            };
      for (final entry in properties.entries) {
        try {
          await platform.setProperty(entry.key, entry.value);
        } catch (error) {
          _logPlayback(
            'warn mpv subtitle option ${entry.key}=${entry.value} failed: '
            '$error',
          );
        }
      }
    }
  }

  List<Map<String, String>> _nativeSubtitleTrackPayload() {
    final tracks = _nativeSubtitleTracks();
    // Only surface the subtitles button when there is something to pick beyond
    // the Auto/Off defaults (e.g. most live IPTV has none).
    final hasReal = tracks.any(
      (track) => track.id != 'auto' && track.id != 'no',
    );
    if (!hasReal) return const [];
    return tracks
        .map((track) => {'id': track.id, 'label': _subtitleTrackLabel(track)})
        .toList(growable: false);
  }

  List<AudioTrack> _nativeAudioTracks() {
    return _player.state.tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .toList();
  }

  List<Map<String, String>> _nativeAudioTrackPayload() {
    final tracks = _nativeAudioTracks();
    // Switching is only meaningful with at least two real tracks.
    if (tracks.length < 2) return const [];
    return tracks
        .map((track) => {'id': track.id, 'label': _audioTrackLabel(track)})
        .toList(growable: false);
  }

  String _audioTrackLabel(AudioTrack track) {
    final parts = <String>[];
    final language = track.language?.trim();
    if (language != null && language.isNotEmpty) {
      parts.add(language.toUpperCase());
    }
    final title = track.title?.trim();
    if (title != null && title.isNotEmpty) parts.add(title);
    final codec = _codecLabel(track.codec);
    if (codec.isNotEmpty) parts.add(codec);
    final channels = _channelsLabel(track);
    if (channels.isNotEmpty) parts.add(channels);
    if (parts.isEmpty) return 'Audio ${track.id}';
    return parts.join(' · ');
  }

  Future<void> _selectNativeAudioTrack(String id) async {
    AudioTrack? selected;
    for (final track in _nativeAudioTracks()) {
      if (track.id == id) {
        selected = track;
        break;
      }
    }
    if (selected == null) return;
    _logPlayback(
      'native audio select id=${selected.id} '
      'label=${_audioTrackLabel(selected)}',
    );
    await _player.setAudioTrack(selected);
  }

  String _speedId(double rate) => rate.toStringAsFixed(2);

  String _speedLabel(double rate) {
    if (rate == 1.0) return 'Normal (1.0×)';
    final text = rate == rate.roundToDouble()
        ? rate.toStringAsFixed(1)
        : rate.toString();
    return '$text×';
  }

  List<Map<String, String>> _speedOptionPayload() {
    if (_isLive) return const [];
    return _speedOptions
        .map((rate) => {'id': _speedId(rate), 'label': _speedLabel(rate)})
        .toList(growable: false);
  }

  Future<void> _cycleNativeAspect() async {
    _aspectModeIndex = (_aspectModeIndex + 1) % _aspectModes.length;
    final mode = _aspectModes[_aspectModeIndex];
    final platform = _player.platform;
    if (platform is NativePlayer) {
      final properties = <String, String>{
        'panscan': mode.panscan,
        'video-aspect-override': mode.aspect,
      };
      for (final entry in properties.entries) {
        try {
          await platform.setProperty(entry.key, entry.value);
        } catch (error) {
          _logPlayback('warn mpv aspect ${entry.key} failed: $error');
        }
      }
    }
    _logPlayback('native aspect mode=${mode.label}');
    await _syncWindowsNativeControlState();
  }

  // The selected track often reads as the `auto` placeholder (null codec/fps)
  // even while a concrete track is playing, so fall back to the first real
  // track for the info panel's codec/fps/channels.
  VideoTrack _infoVideoTrack() {
    final selected = _player.state.track.video;
    if (selected.codec != null || selected.fps != null) return selected;
    for (final track in _player.state.tracks.video) {
      if (track.id != 'auto' && track.id != 'no') return track;
    }
    return selected;
  }

  AudioTrack _infoAudioTrack() {
    final selected = _player.state.track.audio;
    if (selected.codec != null || selected.channels != null) return selected;
    for (final track in _player.state.tracks.audio) {
      if (track.id != 'auto' && track.id != 'no') return track;
    }
    return selected;
  }

  // Live EPG now/next snapshot for the native overlays. Epoch values are passed
  // as doubles (ms) so they survive the MethodChannel without int32 truncation.
  Map<String, Object?> _epgPayload() {
    final now = widget.epgNow;
    final next = widget.epgNext;
    return {
      if (now != null) ...{
        'epgNowTitle': now.title,
        'epgNowStartMs': now.start.millisecondsSinceEpoch.toDouble(),
        'epgNowStopMs': now.stop.millisecondsSinceEpoch.toDouble(),
        if (now.description != null && now.description!.isNotEmpty)
          'epgNowDesc': now.description,
      },
      if (next != null) ...{
        'epgNextTitle': next.title,
        'epgNextStartMs': next.start.millisecondsSinceEpoch.toDouble(),
        'epgNextStopMs': next.stop.millisecondsSinceEpoch.toDouble(),
      },
    };
  }

  Map<String, Object?> _streamInfoPayload() {
    final params = _player.state.videoParams;
    final video = _infoVideoTrack();
    final audio = _infoAudioTrack();
    return {
      'videoWidth': params.w ?? video.w ?? 0,
      'videoHeight': params.h ?? video.h ?? 0,
      'fps': video.fps ?? 0.0,
      'dynamicRange': _dynamicRangeLabel(params),
      'videoCodec': _codecLabel(video.codec),
      'audioCodec': _codecLabel(audio.codec),
      'audioChannels': _channelsLabel(audio),
    };
  }

  String _dynamicRangeLabel(VideoParams params) => _dynamicRangeLabelFrom(
    gamma: params.gamma,
    primaries: params.primaries,
    matrix: params.colormatrix,
  );

  /// Shared by [_dynamicRangeLabel] (embedded/Windows, from media_kit's
  /// [VideoParams]) and [_probeLinuxNativeHdr] (native Linux, from
  /// [LinuxHdrColorimetry] read over mpv's own IPC socket) — same label
  /// vocabulary, same PQ/HLG/BT.2020/Dolby Vision precedence either way.
  /// Delegates to the pure top-level [dynamicRangeLabelFrom], threading this
  /// screen's live [_hdr10Plus] state so both PQ variants render correctly.
  String _dynamicRangeLabelFrom({
    String? gamma,
    String? primaries,
    String? matrix,
  }) => dynamicRangeLabelFrom(
    gamma: gamma,
    primaries: primaries,
    matrix: matrix,
    hdr10Plus: _hdr10Plus,
  );

  /// Best-effort HDR10+ detection for the Windows/embedded mpv path (see
  /// [_hdr10Plus]). The native Linux path is probed separately by
  /// [_probeLinuxNativeHdr] — the native mpv process is a different OS
  /// process from the embedded [_player], so its video params never reach
  /// `_player.stream.videoParams` in the first place.
  ///
  /// mpv exposes no "has HDR10+" flag, so we read the ST2094-40 per-scene
  /// dynamic-metadata sub-properties. These are non-zero only when the stream
  /// actually carries dynamic metadata and — unlike `max-pq-y`/`sig-peak` — are
  /// not synthesised by `hdr-compute-peak`, so they don't false-positive on plain
  /// HDR10. Any missing property / error leaves us at "HDR10 · PQ".
  Future<void> _probeHdr10Plus(VideoParams params) async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    if (_linuxNativeSession != null) return;
    final gamma = params.gamma?.toLowerCase() ?? '';
    if (!gamma.contains('pq')) {
      // Not PQ -> can't be HDR10+. Clear any stale detection from a prior stream.
      _hdr10Plus = false;
      return;
    }
    if (_hdr10Plus || _probingHdr10Plus) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _probingHdr10Plus = true;
    try {
      for (final prop in const [
        'video-params/scene-max-r',
        'video-params/scene-max-g',
        'video-params/scene-max-b',
        'video-params/scene-avg',
      ]) {
        final raw = (await platform.getProperty(prop)).trim();
        final value = double.tryParse(raw);
        if (value != null && value > 0) {
          _hdr10Plus = true;
          _logPlayback('hdr10+ detected via $prop=$value');
          unawaited(_syncWindowsNativeControlState());
          // The embedded Linux overlay reads the label through
          // _dynamicRangeLabel — rebuild so the badge upgrades immediately
          // instead of on its next scheduled refresh.
          if (mounted) setState(() {});
          break;
        }
      }
    } catch (_) {
      // Property unavailable on this mpv build -> stay at HDR10 (conservative).
    } finally {
      _probingHdr10Plus = false;
    }
  }

  /// Native-Linux counterpart to [_probeHdr10Plus]. Called once, shortly
  /// after [LinuxNativeSession.start] launches, since there's no equivalent
  /// of media_kit's `videoParams` stream to trigger on: the native mpv
  /// process is a separate OS process, so its output never reaches the
  /// embedded [_player]. Reads the output colorimetry over the session's own
  /// IPC socket (preferring the post-render `video-target-params`, so a
  /// tone-mapped-to-SDR stream is reported honestly) and logs it to
  /// diagnostics either way, so exported logs show whether HDR actually
  /// engaged — then upgrades PQ to HDR10+ if real ST2094-40 scene metadata is
  /// present, mirroring the Windows heuristic in [_probeHdr10Plus].
  Future<void> _probeLinuxNativeHdr(LinuxNativeSession session) async {
    if (_linuxNativeSession != session) return;
    final colorimetry = await session.hdrColorimetry();
    if (_linuxNativeSession != session) return;
    final dynamicRange = _dynamicRangeLabelFrom(
      gamma: colorimetry.gamma,
      primaries: colorimetry.primaries,
      matrix: colorimetry.colormatrix,
    );
    _logPlayback(
      'linux native colorimetry gamma=${colorimetry.gamma} '
      'primaries=${colorimetry.primaries} sigPeak=${colorimetry.sigPeak} '
      'dynamicRange=$dynamicRange',
    );
    final gamma = colorimetry.gamma?.toLowerCase() ?? '';
    if (gamma.contains('pq') && colorimetry.hasHdr10PlusMetadata) {
      _hdr10Plus = true;
      _logPlayback('hdr10+ detected via video-target-params scene metadata');
      // The Lua badge can't read scene metadata itself — ship the upgrade to
      // the overlay now that it's known.
      await _pushLinuxOverlayState();
    }
  }

  String _codecLabel(String? codec) {
    if (codec == null || codec.trim().isEmpty) return '';
    switch (codec.toLowerCase()) {
      case 'hevc':
        return 'HEVC';
      case 'h264':
        return 'H.264';
      case 'mpeg2video':
        return 'MPEG-2';
      case 'av1':
        return 'AV1';
      case 'vp9':
        return 'VP9';
      case 'eac3':
        return 'E-AC3';
      case 'ac3':
        return 'AC3';
      case 'aac':
        return 'AAC';
      case 'mp3':
        return 'MP3';
      default:
        return codec.toUpperCase();
    }
  }

  String _channelsLabel(AudioTrack track) {
    final channels = track.channels?.trim();
    if (channels != null && channels.isNotEmpty) return channels;
    final count = track.audiochannels ?? track.channelscount;
    if (count != null && count > 0) {
      if (count == 1) return 'Mono';
      if (count == 2) return 'Stereo';
      return '$count ch';
    }
    return '';
  }

  List<SubtitleTrack> _nativeSubtitleTracks() {
    final external = widget.stream.subtitles.map(
      (subtitle) => SubtitleTrack.uri(
        subtitle.url,
        title: subtitle.label,
        language: subtitle.language,
      ),
    );
    final real = _player.state.tracks.subtitle
        .where((track) => track.id != 'auto' && track.id != 'no')
        .toList();
    final seen = <String>{'auto', 'no'};
    final merged = <SubtitleTrack>[SubtitleTrack.auto(), SubtitleTrack.no()];
    for (final track in [...external, ...real]) {
      if (seen.add(track.id)) merged.add(track);
    }
    return merged;
  }

  String _subtitleTrackLabel(SubtitleTrack track) {
    if (track.id == 'auto') return 'Auto';
    if (track.id == 'no') return 'Off';
    final title = track.title?.trim();
    if (title != null && title.isNotEmpty) return title;
    final language = track.language?.trim();
    if (language != null && language.isNotEmpty) return language.toUpperCase();
    return 'Subtitle ${track.id}';
  }

  Widget _playbackSurface() {
    // Transparent while the adopted-handoff Activity launches/plays — the
    // route below (channel list + frozen preview frame) shows through instead
    // of a black flash.
    if (_transparentHandoff) return const SizedBox.expand();
    // Order matters: the native check comes first so the happy path never
    // *reads* `_controller` — reading it is what constructs it (see the field's
    // doc comment). Only once the embedded surface is genuinely going to render
    // do we pay for a VideoController.
    if (_nativePlaybackLaunched) return _nativePlaybackOverlay();
    if (_controller == null) return _nativePlaybackOverlay();
    return PlayerVideoSurface(
      key: _embeddedSurfaceKey,
      player: _player,
      controller: _controller,
      title: widget.title,
      sourceName: widget.sourceName,
      epgNow: widget.epgNow,
      epgNext: widget.epgNext,
      isLive: _isLive,
      canFavorite: _canFavorite,
      favorite: _favorite,
      liveSynced: _liveSynced,
      dynamicRangeLabel: _dynamicRangeLabel,
      onBack: _back,
      onToggleFavorite: _toggleFavorite,
      onPlayPause: _togglePlayback,
      onGoLive: _goToLive,
      onCycleAspect: _cycleNativeAspect,
    );
  }

  Future<void> _goToLive() async {
    if (!_isLive) return;
    final stream = await _freshLiveStream();
    if (!mounted) return;
    if (_linuxNativeSession != null) {
      final session = _linuxNativeSession!;
      await session.command(
        LinuxNativeSession.buildHeaderFieldsCommand(stream.headers),
      );
      await session.command(['loadfile', stream.url, 'replace']);
      if (mounted) setState(() => _liveSynced = true);
      await _pushLinuxOverlayState();
      return;
    }
    await _player.open(
      Media(
        stream.url,
        httpHeaders: stream.headers.isEmpty ? null : stream.headers,
      ),
    );
    if (mounted) setState(() => _liveSynced = true);
  }

  Future<void> _togglePlayback() async {
    if (_linuxNativeSession != null) {
      final session = _linuxNativeSession!;
      // Mirror the embedded branch below: pausing a synced live stream drops
      // sync, so the overlay's "Go to live" affordance and LIVE pill greying
      // must follow. The native session has no local mirror of mpv's
      // playing/paused state, so ask mpv directly (before toggling) rather
      // than guessing.
      if (_isLive && _liveSynced) {
        final paused = await session.getPropertyBool('pause');
        if (paused == false && mounted) {
          setState(() => _liveSynced = false);
        }
      }
      await session.command(const ['cycle', 'pause']);
      if (_isLive) await _pushLinuxOverlayState();
      return;
    }
    if (_isLive && _player.state.playing && mounted) {
      setState(() => _liveSynced = false);
    }
    await _player.playOrPause();
  }

  Future<void> _configureNativePlayer(
    NativePlayer platform,
    int? nativeWindowHandle,
  ) async {
    final options = _isLive
        ? kLiveMpvOptions
        : const <String, String>{
            // File-cache creation can fail for provider HTTP URLs on Windows,
            // and mpv still has the in-memory buffer configured above.
            'cache-on-disk': 'no',
            'demuxer-max-back-bytes': '48MiB',
            'network-timeout': '15',
          };

    final videoOptions = nativeWindowHandle != null
        ? const <String, String>{
            // On Windows, prefer mpv's D3D11 path and advertise HDR metadata
            // to the display stack. With a native HWND, mpv presents directly
            // instead of round-tripping frames through Flutter's SDR texture.
            'vid': 'auto',
            // gpu-next is libplacebo's renderer; it has the modern HDR and
            // Dolby Vision (P5/P8) handling the legacy 'gpu' VO lacks. Requires
            // a libplacebo-enabled libmpv (see windows/libmpv/README.md);
            // falls back to 'gpu' when that build isn't present.
            'vo': 'gpu-next,gpu',
            'gpu-api': 'd3d11',
            'gpu-context': 'd3d11',
            // Hardware-decode on the GPU. `auto-safe` lets mpv negotiate the
            // best working method (d3d11va zero-copy with this d3d11 path) and
            // fall back cleanly to software when a codec/driver combo isn't
            // supported — forcing `d3d11va` could half-init and stall/desync.
            // 4K HEVC/10-bit is too heavy for software decode, so we want HW.
            'hwdec': 'auto-safe',
            // 10-bit swapchain so HDR/10-bit output isn't truncated to 8-bit,
            // without forcing the desktop into HDR globally.
            'd3d11-output-format': 'rgb10_a2',
            'osd-level': '1',
            'target-colorspace-hint': 'yes',
            'tone-mapping': 'auto',
            'hdr-compute-peak': 'yes',
            'panscan': '1.0',
            'sub-ass': 'yes',
            'sub-visibility': 'yes',
            'secondary-sub-visibility': 'yes',
            'sub-use-margins': 'no',
          }
        : embeddedVideoOptionsForPlatform();

    final nativeWindowOptions = nativeWindowHandle == null
        ? const <String, String>{}
        : <String, String>{
            'wid': nativeWindowHandle.toString(),
            'force-window': 'yes',
            'keepaspect-window': 'yes',
          };

    // Order matters: options apply sequentially, and `wid` must land before
    // `vo`/`force-window`. Setting `vo=gpu-next` on an already-playing player
    // (the preview hot-swap) with no `wid` yet makes mpv create the VO in its
    // *own* top-level window, then recreate it into the child surface when
    // `wid` arrives — visible as a stray window popping up during the
    // preview → fullscreen handoff.
    await applyMpvOptions(platform, {
      ...options,
      ...nativeWindowOptions,
      ...videoOptions,
    }, onWarn: (message) => _logPlayback('warn $message'));
  }

  // Logs which video output / decoder mpv actually initialized — tells us
  // whether `gpu-next` loaded or fell back to `gpu`, and the active colorspace.
  Future<void> _logActiveVideoOutput() async {
    if (_loggedActiveVo && _loggedHwdec) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      if (!_loggedActiveVo) {
        final vo = await platform.getProperty('current-vo');
        if (vo.isNotEmpty) {
          _loggedActiveVo = true;
          _logPlayback('active vo=$vo');
        }
      }
      // The decoder initializes a beat after the VO, so hwdec-current is often
      // still empty on the first videoParams event — only log it (once) once it's
      // actually engaged, so an empty reading isn't mistaken for software decode.
      if (!_loggedHwdec) {
        final hwdec = await platform.getProperty('hwdec-current');
        if (hwdec.isNotEmpty && hwdec != 'no') {
          _loggedHwdec = true;
          _logPlayback('active hwdec=$hwdec');
        }
      }
    } catch (error) {
      _loggedActiveVo = true;
      _loggedHwdec = true;
      _logPlayback('warn query active vo failed: $error');
    }
  }

  Future<void> _setNativeHeaderOptions(
    NativePlayer platform,
    Map<String, String> headers,
  ) async {
    final userAgent = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .map((entry) => entry.value)
        .firstOrNull;
    if (userAgent != null && userAgent.isNotEmpty) {
      try {
        await platform.setProperty('user-agent', userAgent);
      } catch (error) {
        _logPlayback('warn mpv user-agent failed: $error');
      }
    }
    final referrer = headers.entries
        .where((entry) {
          final key = entry.key.toLowerCase();
          return key == 'referer' || key == 'referrer';
        })
        .map((entry) => entry.value)
        .firstOrNull;
    if (referrer != null && referrer.isNotEmpty) {
      try {
        await platform.setProperty('referrer', referrer);
      } catch (error) {
        _logPlayback('warn mpv referrer failed: $error');
      }
    }
  }

  /// Persist the embedded or Linux-native player's current VOD position. The
  /// Android native Activity reports its position via `nativeClosed` instead.
  ///
  /// Returns the write's Future so exit paths can await it — the "Continue
  /// watching" rail is reloaded right after this route pops, and `pop()`'s
  /// Future resolves as soon as `pop()` is *called*, well before this route's
  /// `dispose()` (previously the only place a generic Back saved the final
  /// position) actually runs on the next frame. A fire-and-forget save there
  /// raced the reload and reliably lost, which is why the rail looked stale
  /// until a manual refresh re-read the by-then-completed write.
  Future<void> _persistPlaybackPosition() async {
    final playback = widget.playback;
    if (playback == null || _isLive) return;
    if (Platform.isAndroid && _nativePlaybackLaunched) return;
    final linuxSession = _linuxNativeSession;
    if (linuxSession != null) {
      final linuxState = await linuxSession.playbackState();
      if (linuxState == null) return;
      await playback.db.savePlaybackPosition(
        playback.sourceId,
        playback.kind,
        playback.itemId,
        position: linuxState.position,
        duration: linuxState.duration,
      );
      return;
    }
    final position = _player.state.position;
    final duration = _player.state.duration;
    if (duration <= Duration.zero) return;
    await playback.db.savePlaybackPosition(
      playback.sourceId,
      playback.kind,
      playback.itemId,
      position: position,
      duration: duration,
    );
  }

  @override
  void dispose() {
    _logPlayback('player dispose instance=${identityHashCode(this)}');
    final token = _hdrToken;
    if (token != null) {
      _hdrOwner.release(token);
    }
    _positionPersistTimer?.cancel();
    // Last-resort safety net (e.g. dispose without an explicit exit path) —
    // the real save-before-pop is in _exitAndPop/nativeClosed, both of which
    // run and complete well before this.
    unawaited(_persistPlaybackPosition());
    final reconnectTimer = _reconnectTimer;
    if (reconnectTimer != null) {
      final wasActive = reconnectTimer.isActive;
      reconnectTimer.cancel();
      if (wasActive) ResourceCounters.decReconnectTimers();
    }
    _controlSyncThrottle?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _flushDedup();
    if (Platform.isWindows && _windowsNativeSurface != null) {
      _scheduleWindowsNativeTeardown();
    }
    unawaited(_teardownLinuxNative());
    _disposePlayerNonBlocking();
    super.dispose();
  }

  /// Tears down the Linux-native session state: marks closing, cancels the
  /// IPC subscriptions, and — only if this call is the one that still owns a
  /// live session (_exitAndPop, _finishLinuxNativePlayback, or dispose may
  /// each get here first) — disposes it and decrements its counter, so no
  /// path can double-decrement. Sole teardown implementation; `dispose()`
  /// fire-and-forgets it, `_exitAndPop` awaits it.
  Future<void> _teardownLinuxNative() async {
    _linuxNativeClosing = true;
    final controlSub = _linuxNativeControlSub;
    final playbackSub = _linuxNativePlaybackSub;
    _linuxNativeControlSub = null;
    _linuxNativePlaybackSub = null;
    final linuxSession = _linuxNativeSession;
    _linuxNativeSession = null;
    await controlSub?.cancel();
    await playbackSub?.cancel();
    if (linuxSession != null) {
      await linuxSession.dispose();
      ResourceCounters.decLinuxNativeSessions();
    }
  }

  void _disposePlayerNonBlocking() {
    if (!_ownsPlayer) return;
    final platform = _player.platform;
    if (Platform.isWindows && platform is NativePlayer) {
      unawaited(
        platform
            .dispose(synchronized: false)
            .then((_) => ResourceCounters.decMediaKitPlayers()),
      );
    } else {
      unawaited(
        _player.dispose().then((_) => ResourceCounters.decMediaKitPlayers()),
      );
    }
  }

  void _back() {
    unawaited(_exitAndPop());
  }

  Future<void> _exitAndPop() async {
    // Await the final position write before popping — see the doc comment on
    // _persistPlaybackPosition for why this can't be fire-and-forget here.
    await _persistPlaybackPosition();
    await _teardownLinuxNative();
    if (Platform.isWindows && _nativePlaybackLaunched) {
      await _prepareWindowsNativeExit();
      _scheduleWindowsNativeTeardown(prepared: true);
    }
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(_didWindowsHotSwap);
    }
  }

  void _toggleFavorite() {
    if (!_canFavorite) return;
    final next = !_favorite;
    setState(() => _favorite = next);
    unawaited(widget.onSetFavorite?.call(next));
  }

  void _seekBy(int seconds) {
    if (_isLive) return; // live has no meaningful timeline to seek
    if (_linuxNativeSession != null) {
      unawaited(_linuxNativeSession!.command(['seek', seconds, 'relative']));
      return;
    }
    final pos = _player.state.position + Duration(seconds: seconds);
    _player.seek(pos < Duration.zero ? Duration.zero : pos);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _transparentHandoff ? Colors.transparent : Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _handlePlaybackInput();
            _back();
          },
          const SingleActivator(LogicalKeyboardKey.space): () {
            _handlePlaybackInput();
            unawaited(_togglePlayback());
          },
          const SingleActivator(LogicalKeyboardKey.select): () {
            _handlePlaybackInput();
            unawaited(_togglePlayback());
          },
          const SingleActivator(LogicalKeyboardKey.enter): () {
            _handlePlaybackInput();
            unawaited(_togglePlayback());
          },
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () {
            _handlePlaybackInput();
            unawaited(_togglePlayback());
          },
          const SingleActivator(LogicalKeyboardKey.mediaPlay): () {
            _handlePlaybackInput();
            _player.play();
          },
          const SingleActivator(LogicalKeyboardKey.mediaPause): () {
            _handlePlaybackInput();
            _player.pause();
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            _handlePlaybackInput();
            _seekBy(-10);
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            _handlePlaybackInput();
            _seekBy(10);
          },
          const SingleActivator(LogicalKeyboardKey.keyF): () {
            _handlePlaybackInput();
            if (Platform.isLinux) {
              _embeddedSurfaceKey.currentState?.togglePlayerFullscreen();
            } else {
              _toggleNativeFullscreen();
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyM): () {
            _handlePlaybackInput();
            _toggleNativeMiniPlayer();
          },
        },
        child: Listener(
          onPointerHover: (_) => _handlePlaybackInput(),
          onPointerDown: (_) => _handlePlaybackInput(),
          onPointerMove: (_) => _handlePlaybackInput(),
          child: Focus(
            autofocus: true,
            child: Stack(
              children: [
                Positioned.fill(child: _playbackSurface()),
                if (_error case final error?)
                  Positioned.fill(
                    child: PlayerErrorOverlay(
                      message: error,
                      onBack: _back,
                      onRetry: _open,
                    ),
                  ),
                // Windows draws its own "Reconnecting…" in the native overlay;
                // this covers the embedded media_kit path.
                if (_reconnecting && !_usesWindowsNativeSurface)
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: const Center(child: PlayerReconnectChip()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The native player (Android Activity / Windows HWND) renders over this route
  // and owns its own controls; this surface is only ever visible for the launch
  // flicker and is auto-popped on `nativeClosed`. Keep it a bare black fill — no
  // labels or buttons that would read as a stray extra screen.
  Widget _nativePlaybackOverlay() => const ColoredBox(color: Colors.black);

  // Redaction lives in net.dart (redactText) so the preview controller and
  // any other user-visible error path share the same scrubbing.
  String _redactPlayback(String value) => redactText(value);

  void _logPlayback(String message) {
    DiagnosticsLog.instance.add('player', message);
    developer.log(message, name: 'iptvs.player');
    debugPrint('[iptvs.player] $message');
  }

  // Collapses runs of identical messages (e.g. the hundreds of repeated
  // `hevc: Could not find ref with POC …` errors from bad DV P5 muxing) into a
  // single line plus a `(×N)` summary, so the exportable diagnostics stay
  // readable. Non-repeating lines pass straight through.
  String? _lastDedupMessage;
  int _dedupCount = 0;

  void _logPlaybackDeduped(String message) {
    if (message == _lastDedupMessage) {
      _dedupCount++;
      return;
    }
    _flushDedup();
    _lastDedupMessage = message;
    _logPlayback(message);
  }

  void _flushDedup() {
    if (_dedupCount > 0 && _lastDedupMessage != null) {
      _logPlayback('$_lastDedupMessage (×${_dedupCount + 1})');
    }
    _lastDedupMessage = null;
    _dedupCount = 0;
  }

  String _trackSummary(dynamic track) {
    final codec = track.codec == null ? '' : ' codec=${track.codec}';
    final decoder = track.decoder == null ? '' : ' decoder=${track.decoder}';
    final channels = track.channels == null
        ? ''
        : ' channels=${track.channels}';
    final rate = track.samplerate == null ? '' : ' rate=${track.samplerate}';
    final size = track.w == null || track.h == null
        ? ''
        : ' ${track.w}x${track.h}';
    return '${track.id}$codec$decoder$channels$rate$size';
  }
}

/// A video framing mode for the Windows native surface. [panscan] maps to mpv's
/// `panscan` (0 = letterbox/fit, 1 = crop to fill) and [aspect] to
/// `video-aspect-override` (`no` clears any forced display aspect).
class _AspectMode {
  final String label;
  final String panscan;
  final String aspect;
  const _AspectMode(this.label, this.panscan, this.aspect);
}
