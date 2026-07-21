import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/diagnostics_log.dart';
import '../data/net.dart';
import '../sources/source.dart';
import 'mpv_options.dart';

/// Native Linux presentation backend selected from the desktop session.
enum LinuxNativeBackend { wayland, x11 }

/// Live-playback health signals surfaced from the native mpv process over IPC,
/// consumed by `player_screen.dart`'s live auto-reconnect watchdog (the
/// embedded/Windows watchdog watches media_kit streams; the native mpv process
/// is a separate OS process whose state only reaches Dart through these).
///
/// mpv runs with `--keep-open=yes --idle=yes`, so a dropped live stream would
/// otherwise freeze on the last frame indefinitely with no recovery — these
/// signals are what let the watchdog reload the source instead.
enum LinuxNativePlaybackSignal {
  /// An `end-file` with reason `error`/`eof` — a hard drop (network error) or
  /// an unexpected end of a live stream. A user quit (ESC/Back) and a
  /// Dart-initiated dispose both report reason `quit`/`stop` and are
  /// deliberately *not* surfaced, so they never trigger a reconnect.
  dropped,

  /// `paused-for-cache` went true — the stream is buffering (cache underrun).
  /// Note mpv only reports the cache-induced pause here, never a user pause,
  /// so this is a clean "the stream stalled" signal (unlike `core-idle`).
  stalled,

  /// `file-loaded`/`playback-restart` — a (re)loaded file is playing again, or
  /// a cache stall recovered. Clears the watchdog's stalled state and hides the
  /// "Reconnecting…" indicator. Deliberately *not* derived from
  /// `paused-for-cache` going false: mpv briefly reports that at `end-file`
  /// (when nothing is playing), which would race a drop and clear it falsely.
  resumed,
}

class LinuxNativePlaybackState {
  const LinuxNativePlaybackState(this.position, this.duration);

  final Duration position;
  final Duration duration;
}

/// The mpv version below which [LinuxNativeSession.start] refuses to launch
/// the native path (Wayland HDR pass-through was added in 0.40; below that
/// every native session would silently tone-map to SDR anyway, so it's
/// better to fall back to the embedded player, which is honest about it).
const (int, int) kMinNativeMpvVersion = (0, 40);

/// The mpv version at/after which `--target-colorspace-hint` defaults to and
/// only accepts `auto` — passing `auto` explicitly on 0.40 is rejected
/// (0.40 only understands `yes`/`no`), and mpv 0.41 exits nonzero on values
/// it doesn't recognise, so the flag must be version-gated rather than
/// passed unconditionally.
const (int, int) kAutoColorspaceHintMpvVersion = (0, 41);

/// Parses the leading `X.Y` out of an `mpv --version` first line. Tolerant of
/// upstream builds (`mpv v0.41.0-42-gabcdef1`), distro-patched versions
/// (`mpv 0.37.0-1ubuntu4+build2`), and git snapshots
/// (`mpv v0.42.0-dev-123-gabcdef1`) — all of which share a `v?<major>.<minor>`
/// prefix on the first digit run. Returns null when no such run is found.
@visibleForTesting
(int, int)? parseMpvVersion(String versionOutput) {
  final match = RegExp(r'\bv?(\d+)\.(\d+)').firstMatch(versionOutput);
  if (match == null) return null;
  final major = int.tryParse(match.group(1)!);
  final minor = int.tryParse(match.group(2)!);
  if (major == null || minor == null) return null;
  return (major, minor);
}

bool _versionAtLeast((int, int) version, (int, int) minimum) {
  final (major, minor) = version;
  final (minMajor, minMinor) = minimum;
  if (major != minMajor) return major > minMajor;
  return minor >= minMinor;
}

/// Whether [version] is new enough for the native Linux HDR path at all
/// (see [kMinNativeMpvVersion]).
@visibleForTesting
bool mpvSupportsNativeHdr((int, int) version) =>
    _versionAtLeast(version, kMinNativeMpvVersion);

/// The version-gated `--target-colorspace-hint` argument, if any. mpv 0.41+
/// defaults to `auto` so the flag can be omitted entirely; mpv 0.40 needs it
/// spelled out as `yes` (its only HDR-passthrough value — `auto` doesn't
/// exist yet on 0.40 and exits nonzero). Callers should not reach this for
/// versions below [kMinNativeMpvVersion] ([mpvSupportsNativeHdr] gates that).
@visibleForTesting
List<String> mpvColorspaceHintArgs((int, int) version) {
  if (_versionAtLeast(version, kAutoColorspaceHintMpvVersion)) return const [];
  return const ['--target-colorspace-hint=yes'];
}

/// The `--gpu-context` argument for [backend], if any. On Wayland mpv 0.41+
/// prefers the Vulkan `waylandvk` context on its own (a more-tested HDR path
/// than forcing EGL), so the flag is omitted; X11 has no HDR output path at
/// all, so it stays pinned to the EGL context explicitly.
@visibleForTesting
List<String> mpvGpuContextArgs(LinuxNativeBackend backend) =>
    backend == LinuxNativeBackend.x11
    ? const ['--gpu-context=x11egl']
    : const [];

/// The output colorimetry read back from mpv over IPC — primaries/gamma/
/// sig-peak plus the ST2094-40 per-scene HDR10+ fields. Preferred source is
/// `video-target-params` (the actual values *after* mpv's render pipeline,
/// tone-mapping included — the honest signal for whether HDR reached the
/// display); [LinuxNativeSession.hdrColorimetry] falls back to source-side
/// `video-params` sub-properties when a target one is unavailable.
class LinuxHdrColorimetry {
  const LinuxHdrColorimetry({
    this.gamma,
    this.primaries,
    this.colormatrix,
    this.sigPeak,
    this.sceneMaxR,
    this.sceneMaxG,
    this.sceneMaxB,
    this.sceneAvg,
  });

  final String? gamma;
  final String? primaries;
  final String? colormatrix;
  final double? sigPeak;
  final double? sceneMaxR;
  final double? sceneMaxG;
  final double? sceneMaxB;
  final double? sceneAvg;

  /// True only when real ST2094-40 per-scene dynamic metadata is present —
  /// mirrors the Windows `_probeHdr10Plus` heuristic (see docs/player.md).
  bool get hasHdr10PlusMetadata =>
      (sceneMaxR ?? 0) > 0 ||
      (sceneMaxG ?? 0) > 0 ||
      (sceneMaxB ?? 0) > 0 ||
      (sceneAvg ?? 0) > 0;
}

/// A native mpv window used when the system provides a standalone mpv binary.
///
/// This deliberately uses mpv's JSON IPC rather than passing provider headers
/// on the process command line. The binary is the same libmpv/gpu-next stack
/// used by the Flutter backend, but owns its Wayland/X11 surface and built-in
/// OSC overlay, which is required for HDR metadata to reach the compositor.
class LinuxNativeSession {
  LinuxNativeSession._(this.backend, this._executable, this.mpvVersion);

  final LinuxNativeBackend backend;
  final String _executable;

  /// The host mpv's parsed `(major, minor)`, probed and version-gated by
  /// [start] before this session is ever constructed.
  final (int, int) mpvVersion;

  /// `"0.41"`-style label for diagnostics logging.
  String get mpvVersionLabel => '${mpvVersion.$1}.${mpvVersion.$2}';

  /// The `--gpu-context` mpv was launched with, for diagnostics logging —
  /// `"x11egl"` on X11; on Wayland mpv chooses its own (0.41+ prefers the
  /// Vulkan `waylandvk` context), so this reports that intent rather than a
  /// forced value.
  String get gpuContextLabel => backend == LinuxNativeBackend.x11
      ? 'x11egl'
      : 'auto(waylandvk-preferred)';
  Process? _process;
  Socket? _socket;
  String? _socketPath;
  String? _inputConfigPath;
  bool _disposed = false;
  bool _ipcErrorLogged = false;
  int _requestId = 0;

  /// Last-known `time-pos`/`duration`, kept fresh without a live read:
  /// `duration` by an IPC property observer (see [_start]), `time-pos` by the
  /// VOD-only 1 Hz [_startPositionPoll] (observing it would deliver a
  /// per-video-frame JSON firehose on the main isolate). [playbackState]
  /// falls back to these when a live `get_property` read fails — the mpv
  /// *process* commonly exits (window closed, ESC/MBTN_BACK `quit`) before
  /// `_finishLinuxNativePlayback` gets to persist the final position, so a
  /// live IPC read at that point would otherwise come back empty and lose up
  /// to the VOD position-persist interval of progress.
  double? _lastPositionSeconds;
  double? _lastDurationSeconds;
  final Map<int, Completer<Object?>> _requests = {};
  final StreamController<String> _controlEvents =
      StreamController<String>.broadcast();
  final StreamController<LinuxNativePlaybackSignal> _playbackEvents =
      StreamController<LinuxNativePlaybackSignal>.broadcast();

  Future<int> get exitCode => _process?.exitCode ?? Future<int>.value(-1);
  Stream<String> get controlEvents => _controlEvents.stream;

  /// Live-playback health signals (drop/stall/resume) for the reconnect
  /// watchdog in `player_screen.dart`. See [LinuxNativePlaybackSignal].
  Stream<LinuxNativePlaybackSignal> get playbackEvents =>
      _playbackEvents.stream;

  static LinuxNativeBackend? detectBackend() {
    if ((Platform.environment['WAYLAND_DISPLAY'] ?? '').trim().isNotEmpty) {
      return LinuxNativeBackend.wayland;
    }
    if ((Platform.environment['DISPLAY'] ?? '').trim().isNotEmpty) {
      return LinuxNativeBackend.x11;
    }
    return null;
  }

  /// Finds a bundled mpv next to the running executable first (the AppImage
  /// no longer ships one by default, but `package_linux_appimage.sh`'s
  /// `MPV_BINARY` knob still can), then falls back to the host's system mpv
  /// — the version probe in [start] gates whichever one is found on
  /// [kMinNativeMpvVersion].
  static String? findExecutable() {
    final sibling = File(
      p.join(File(Platform.resolvedExecutable).parent.path, 'mpv'),
    );
    if (sibling.existsSync() && (sibling.statSync().mode & 0x49) != 0) {
      return sibling.path;
    }
    for (final candidate in const ['/usr/bin/mpv', '/usr/local/bin/mpv']) {
      final file = File(candidate);
      if (file.existsSync() && (file.statSync().mode & 0x49) != 0) {
        return candidate;
      }
    }
    return null;
  }

  static String? findOverlayScript() {
    final executable = File(Platform.resolvedExecutable);
    final bundled = File(
      p.normalize(
        p.join(executable.parent.path, '..', 'share', 'iptvs', 'overlay.lua'),
      ),
    );
    if (bundled.existsSync()) return bundled.path;
    final development = File(p.join('linux', 'mpv', 'iptvs_overlay.lua'));
    return development.existsSync() ? development.absolute.path : null;
  }

  /// The vendored Inter/Material Icons fonts the overlay script renders
  /// with. Mirrors [findOverlayScript]'s bundled-then-dev-tree lookup;
  /// returns null (rather than a nonexistent path) when neither location has
  /// the directory, since passing a missing `--osd-fonts-dir` would abort
  /// mpv's startup entirely (unlike a missing font *inside* an existing dir,
  /// which libass just falls back from).
  static String? findFontsDir() {
    final executable = File(Platform.resolvedExecutable);
    final bundled = Directory(
      p.normalize(
        p.join(executable.parent.path, '..', 'share', 'iptvs', 'fonts'),
      ),
    );
    if (bundled.existsSync()) return bundled.path;
    final development = Directory(p.join('linux', 'mpv', 'fonts'));
    return development.existsSync() ? development.absolute.path : null;
  }

  /// Runs `<executable> --version` and returns its stdout, or null if the
  /// probe fails/times out (a broken/missing binary should fall back to the
  /// embedded player the same as any other native-launch failure).
  static Future<String?> _probeVersionOutput(String executable) async {
    try {
      final result = await Process.run(executable, const [
        '--version',
      ]).timeout(const Duration(seconds: 5));
      return result.stdout.toString();
    } catch (_) {
      return null;
    }
  }

  /// Cached result of [nativeLikelyAvailable] — the executable/version can't
  /// change mid-process, so the (spawning) probe only ever needs to run once.
  static bool? _availabilityCache;

  /// Best-effort, cached probe for whether the native path is *worth* using —
  /// the policy predicate for both the preview→fullscreen handoff decision
  /// (`decideFullscreenHandoff`/`_openLivePlayer` in `channel_list_screen.dart`)
  /// and the embedded→native HDR escalation (`_maybeEscalateLinuxNative` in
  /// `player_screen.dart`). It runs the same executable/overlay-script
  /// detection and mpv version gate as [start] without spawning the long-lived
  /// process, **and restricts to Wayland**: X11 has no HDR output path at all,
  /// so the native window buys nothing there (it would only tone-map to SDR,
  /// which the embedded path already does while staying seamless and holding a
  /// single provider connection). The native mpv process can't adopt a running
  /// preview engine either, unlike Android's shared engine or the
  /// Windows/embedded media_kit hot-swap — so on X11 this returns false and
  /// callers keep everything embedded.
  ///
  /// This is deliberately narrower than [start], which is left backend-agnostic
  /// (it still launches on X11 if called explicitly): the Wayland restriction
  /// is a *policy* choice made here, not a capability of the session itself.
  /// Never throws.
  static Future<bool> nativeLikelyAvailable() async {
    final cached = _availabilityCache;
    if (cached != null) return cached;
    var result = false;
    try {
      final backend = detectBackend();
      final executable = findExecutable();
      final overlayScript = findOverlayScript();
      if (backend == LinuxNativeBackend.wayland &&
          executable != null &&
          overlayScript != null) {
        final version = await _probeVersion(executable);
        result = version != null && mpvSupportsNativeHdr(version);
      }
    } catch (_) {
      result = false;
    }
    _availabilityCache = result;
    return result;
  }

  /// Runs `<executable> --version` and parses it with [parseMpvVersion] —
  /// the process-spawn + parse step shared by [start] (which applies
  /// [mpvSupportsNativeHdr] itself so it can log *why* a miss happened —
  /// unparseable vs. too old) and [nativeLikelyAvailable] (which only needs
  /// the pass/fail).
  static Future<(int, int)?> _probeVersion(String executable) async {
    final versionOutput = await _probeVersionOutput(executable);
    return versionOutput == null ? null : parseMpvVersion(versionOutput);
  }

  static Future<LinuxNativeSession?> start({
    required StreamInfo stream,
    required String title,
    String? sourceName,
    Programme? epgNow,
    Programme? epgNext,
    required bool canFavorite,
    required bool favorite,
    required bool liveSynced,
    required String aspectLabel,
    Duration? resumeFrom,
  }) async {
    final backend = detectBackend();
    final executable = findExecutable();
    final overlayScript = findOverlayScript();
    if (backend == null || executable == null || overlayScript == null) {
      return null;
    }
    // Re-probes (rather than reusing nativeLikelyAvailable's cache) so a
    // version that regresses/upgrades between calls is caught, but shares
    // the actual spawn+parse step via _probeVersion.
    final version = await _probeVersion(executable);
    if (version == null || !mpvSupportsNativeHdr(version)) {
      DiagnosticsLog.instance.add(
        'player',
        'linux native mpv unavailable: '
            '${version == null ? 'version unparseable' : 'version ${version.$1}.${version.$2}'} '
            '(need >= ${kMinNativeMpvVersion.$1}.${kMinNativeMpvVersion.$2} for the '
            'native HDR path); using embedded fallback',
      );
      return null;
    }
    final session = LinuxNativeSession._(backend, executable, version);
    try {
      await session._start(
        stream: stream,
        title: title,
        sourceName: sourceName,
        epgNow: epgNow,
        epgNext: epgNext,
        canFavorite: canFavorite,
        favorite: favorite,
        liveSynced: liveSynced,
        aspectLabel: aspectLabel,
        overlayScript: overlayScript,
        resumeFrom: resumeFrom,
      );
      return session;
    } catch (error) {
      DiagnosticsLog.instance.add(
        'player',
        'linux native ${backend.name} unavailable: ${redactText('$error')}',
      );
      await session.dispose();
      return null;
    }
  }

  Future<void> _start({
    required StreamInfo stream,
    required String title,
    required String? sourceName,
    required Programme? epgNow,
    required Programme? epgNext,
    required bool canFavorite,
    required bool favorite,
    required bool liveSynced,
    required String aspectLabel,
    required String overlayScript,
    Duration? resumeFrom,
  }) async {
    final temp = Directory.systemTemp;
    _socketPath = p.join(
      temp.path,
      'iptvs-mpv-$pid-${DateTime.now().microsecondsSinceEpoch}.sock',
    );
    _inputConfigPath = '$_socketPath.input.conf';
    await File(_inputConfigPath!).writeAsString('ESC quit\nMBTN_BACK quit\n');
    final fontsDir = findFontsDir();
    final args = <String>[
      '--no-terminal',
      // The app always feeds direct, already-resolved media URLs — mpv's
      // youtube-dl fallback would only ever fire after a dead-URL open
      // failure, spamming "Subprocess failed" errors instead of surfacing
      // the real end-file error promptly.
      '--ytdl=no',
      '--idle=yes',
      // `yes`, not `immediate`: the window is created at file load rather
      // than at process spawn, so the app's route (still rendering the
      // adopted preview) stays visible until mpv can actually show video —
      // no premature black fullscreen window during the handoff. `yes` still
      // guarantees a window for audio-only streams.
      '--force-window=yes',
      '--keep-open=yes',
      '--osc=no',
      '--osd-level=1',
      '--fullscreen=yes',
      '--title=$title',
      if (resumeFrom != null && resumeFrom > Duration.zero)
        '--start=${resumeFrom.inMilliseconds / 1000}',
      '--vo=gpu-next',
      '--hwdec=auto-safe',
      ...mpvColorspaceHintArgs(mpvVersion),
      if (backend == LinuxNativeBackend.wayland) '--wayland-content-type=video',
      '--input-ipc-server=$_socketPath',
      '--input-conf=$_inputConfigPath',
      '--script=$overlayScript',
      // The overlay renders as an OSD ass-events surface (not burned-in
      // subtitles), so --osd-fonts-dir — not --sub-fonts-dir — is the option
      // libass actually consults for its bundled Inter/Material Icons faces.
      if (fontsDir != null) '--osd-fonts-dir=$fontsDir',
      // Wayland: let mpv pick its own context (0.41+ prefers the Vulkan
      // waylandvk context over EGL, a more-tested HDR path than forcing it).
      // X11 has no HDR output path at all, so it stays pinned to EGL.
      ...mpvGpuContextArgs(backend),
    ];
    _process = await Process.start(_executable, args);
    _process!.stderr.transform(utf8.decoder).listen((line) {
      if (line.trim().isNotEmpty) {
        DiagnosticsLog.instance.add(
          'player',
          'linux native mpv: ${redactText(line.trim())}',
        );
      }
    });
    await _connectSocket();
    await command(const ['observe_property', 9001, 'user-data/iptvs-control']);
    // Buffering (cache underrun) for the live reconnect watchdog. mpv delivers
    // `end-file`/`file-loaded`/`playback-restart` events to IPC clients without
    // any subscription, but property-changes require an explicit observe.
    await command(const ['observe_property', 9002, 'paused-for-cache']);
    // Keep a last-known position/duration cache (see _lastPositionSeconds) so a
    // post-exit playbackState() read has something to fall back to. `duration`
    // is observed (it changes once per file); `time-pos` is deliberately **not**
    // — mpv fires it at video frame rate, i.e. 25-60 socket lines + jsonDecode
    // per second on the main isolate, for a value only the VOD resume point
    // reads. Same rule the Lua overlay already follows (docs/player.md). VOD
    // instead polls it at [_positionPollInterval]; live never persists a
    // position at all, so it polls nothing.
    await command(const ['observe_property', 9004, 'duration']);
    await command(buildHeaderFieldsCommand(stream.headers));
    await command(['set_property', 'force-media-title', title]);
    // Same network/demuxer resilience tuning the embedded/Windows path applies
    // via _configureNativePlayer for live streams (see kLiveMpvOptions) — set
    // before loadfile so it's in effect for the upcoming open, same ordering
    // as the embedded path's setProperty-before-Media.open.
    if (stream.isLive) {
      for (final entry in kLiveMpvOptions.entries) {
        await command(['set_property', entry.key, entry.value]);
      }
    }
    DiagnosticsLog.instance.add('player', 'linux native loadfile (initial)');
    await command(['loadfile', stream.url, 'replace']);
    for (final subtitle in stream.subtitles) {
      await command([
        'sub-add',
        subtitle.url,
        'auto',
        subtitle.label,
        subtitle.language ?? '',
      ]);
    }
    await updateOverlayState(
      title: title,
      sourceName: sourceName,
      epgNow: epgNow,
      epgNext: epgNext,
      canFavorite: canFavorite,
      favorite: favorite,
      isLive: stream.isLive,
      liveSynced: liveSynced,
      aspectLabel: aspectLabel,
    );
    if (!stream.isLive) _startPositionPoll();
  }

  /// Low-frequency refresh of [_lastPositionSeconds], replacing the per-frame
  /// `time-pos` property observation. 1 Hz is as fresh as the cache ever needs
  /// to be: it only matters when the mpv *process* has already exited and
  /// `playbackState()`'s live read comes back empty, and it feeds a resume
  /// point, not a scrubber.
  static const Duration _positionPollInterval = Duration(seconds: 1);
  Timer? _positionPollTimer;
  bool _pollingPosition = false;

  /// Starts the VOD-only position poll. Not resource-counted: its lifetime is
  /// strictly bounded by this session (cancelled in [dispose]), which is itself
  /// counted as `ResourceCounters.linuxNativeSessions` — the same reasoning as
  /// `player_screen.dart`'s VOD position-persist timer.
  void _startPositionPoll() {
    _positionPollTimer?.cancel();
    _positionPollTimer = Timer.periodic(_positionPollInterval, (_) async {
      // _getProperty times out after 1s, so a wedged socket could otherwise
      // stack overlapping reads at the poll interval.
      if (_disposed || _socket == null || _pollingPosition) return;
      _pollingPosition = true;
      try {
        final data = await _getProperty('time-pos');
        final (position, duration) = applyPlaybackPropertyChange(
          (_lastPositionSeconds, _lastDurationSeconds),
          'time-pos',
          data,
        );
        _lastPositionSeconds = position;
        _lastDurationSeconds = duration;
      } finally {
        _pollingPosition = false;
      }
    });
  }

  Future<void> updateOverlayState({
    required String title,
    required String? sourceName,
    required Programme? epgNow,
    required Programme? epgNext,
    required bool canFavorite,
    required bool favorite,
    required bool isLive,
    required bool liveSynced,
    required String aspectLabel,
    bool reconnecting = false,
    bool hdr10Plus = false,
  }) => command(
    buildOverlayStateCommand(
      title: title,
      sourceName: sourceName,
      epgNow: epgNow,
      epgNext: epgNext,
      canFavorite: canFavorite,
      favorite: favorite,
      isLive: isLive,
      liveSynced: liveSynced,
      aspectLabel: aspectLabel,
      reconnecting: reconnecting,
      hdr10Plus: hdr10Plus,
    ),
  );

  /// Builds the `script-message-to iptvs_overlay iptvs-state` mpv IPC command
  /// [updateOverlayState] sends, without touching the socket — a pure seam
  /// so tests can assert on the JSON contract the Lua overlay parses without
  /// standing up a real mpv IPC connection.
  @visibleForTesting
  static List<Object?> buildOverlayStateCommand({
    required String title,
    required String? sourceName,
    required Programme? epgNow,
    required Programme? epgNext,
    required bool canFavorite,
    required bool favorite,
    required bool isLive,
    required bool liveSynced,
    required String aspectLabel,
    bool reconnecting = false,
    bool hdr10Plus = false,
  }) => [
    'script-message-to',
    'iptvs_overlay',
    'iptvs-state',
    jsonEncode({
      'title': title,
      'sourceName': ?sourceName,
      'canFavorite': canFavorite,
      'favorite': favorite,
      'isLive': isLive,
      'liveSynced': liveSynced,
      'aspectLabel': aspectLabel,
      'reconnecting': reconnecting,
      // The Lua badge derives PQ/HLG from mpv properties itself but cannot
      // see ST2094-40 scene metadata semantics — Dart's probe is the single
      // authority for the HDR10+ upgrade (docs/player.md).
      'hdr10Plus': hdr10Plus,
      if (epgNow != null) ...{
        'epgNowTitle': epgNow.title,
        'epgNowStartMs': epgNow.start.millisecondsSinceEpoch,
        'epgNowStopMs': epgNow.stop.millisecondsSinceEpoch,
      },
      if (epgNext != null) ...{
        'epgNextTitle': epgNext.title,
        'epgNextStartMs': epgNext.start.millisecondsSinceEpoch,
        'epgNextStopMs': epgNext.stop.millisecondsSinceEpoch,
      },
    }),
  ];

  /// Builds the `set_property http-header-fields` IPC command as a native
  /// JSON array — mpv JSON IPC accepts native lists for list-type options.
  /// `http-header-fields` is otherwise a comma-separated *string* list
  /// option, which would corrupt any header value containing a literal comma
  /// (e.g. the default Stalker/MAG user-agent's `(KHTML, like Gecko)`). A
  /// pure seam so tests can assert on the JSON contract without a real mpv
  /// IPC connection — mirrors [buildOverlayStateCommand]. Also used by the
  /// live reload paths in `player_screen.dart` to refresh headers alongside a
  /// re-resolved URL (so no @visibleForTesting despite doubling as the test
  /// seam).
  static List<Object?> buildHeaderFieldsCommand(Map<String, String> headers) =>
      [
        'set_property',
        'http-header-fields',
        headers.entries
            .map((entry) => '${entry.key}: ${entry.value}')
            .toList(growable: false),
      ];

  Future<void> _connectSocket() async {
    final path = _socketPath!;
    for (var attempt = 0; attempt < 100; attempt++) {
      if (_disposed) throw StateError('Native session disposed');
      try {
        _socket = await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        _socket!
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              _handleMessage,
              onDone: _completePendingRequests,
              onError: (Object error) {
                // A dead/reset IPC socket (e.g. mpv crashed instead of
                // exiting cleanly) — log once and fail any pending
                // get_property/command requests fast instead of letting them
                // hang for their full timeout. Never rethrow: the process
                // exit/dispose path is what actually tears this session down.
                if (!_ipcErrorLogged) {
                  _ipcErrorLogged = true;
                  DiagnosticsLog.instance.add(
                    'player',
                    'linux native mpv IPC error: ${redactText('$error')}',
                  );
                }
                _completePendingRequests();
              },
            );
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    throw TimeoutException('mpv IPC socket did not open');
  }

  /// Serialises every IPC socket write: Dart's `IOSink.flush()` *binds* the
  /// sink until the buffered data drains, so a concurrent `write` from another
  /// caller throws `Bad state: StreamSink is bound to a stream`. All writes —
  /// [command], [_getProperty], [dispose]'s quit — must go through here.
  Future<void> _writeQueue = Future<void>.value();

  Future<void> _send(String line) {
    final next = _writeQueue.then((_) async {
      final socket = _socket;
      if (socket == null) return;
      socket.write(line);
      await socket.flush();
    });
    // Keep the chain alive after a failed write (socket closed mid-session);
    // the failure still propagates to this call's awaiter via `next`.
    _writeQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> command(List<Object?> command) async {
    if (_socket == null || _disposed) return;
    await _send('${jsonEncode({'command': command})}\n');
  }

  /// Prefers a live IPC read (the freshest value); falls back to the
  /// observed-property cache ([_lastPositionSeconds]/[_lastDurationSeconds])
  /// when the read comes back empty — notably once the mpv process has
  /// already exited (window closed, ESC/MBTN_BACK `quit`), which is exactly
  /// when `_finishLinuxNativePlayback` calls this to persist the final VOD
  /// position.
  Future<LinuxNativePlaybackState?> playbackState() async {
    final position =
        await _getPropertyNumber('time-pos') ?? _lastPositionSeconds;
    final duration =
        await _getPropertyNumber('duration') ?? _lastDurationSeconds;
    if (position == null || duration == null || duration <= 0) return null;
    return LinuxNativePlaybackState(
      Duration(milliseconds: (position * 1000).round()),
      Duration(milliseconds: (duration * 1000).round()),
    );
  }

  Future<double?> _getPropertyNumber(String property) async {
    final value = await _getProperty(property);
    return value is num ? value.toDouble() : null;
  }

  /// Reads an mpv boolean property (e.g. `pause`) over IPC. Used to decide
  /// whether an upcoming `cycle pause` is about to pause (vs. resume) live
  /// playback, mirroring the embedded player's `_togglePlayback` check.
  Future<bool?> getPropertyBool(String property) async {
    final value = await _getProperty(property);
    return value is bool ? value : null;
  }

  /// Reads the output colorimetry mpv actually rendered, preferring
  /// `video-target-params/<suffix>` (post-render, honest about tone-mapping)
  /// and falling back to source-side `video-params/<suffix>` when the target
  /// sub-property comes back null (older mpv, or queried before the render
  /// pipeline has produced a frame). See [LinuxHdrColorimetry].
  Future<LinuxHdrColorimetry> hdrColorimetry() async {
    Future<Object?> read(String suffix) async {
      final target = await _getProperty('video-target-params/$suffix');
      if (target != null) return target;
      return _getProperty('video-params/$suffix');
    }

    double? asDouble(Object? value) => value is num ? value.toDouble() : null;

    // Each read() claims its request id + completer synchronously before its
    // first await, so firing all eight concurrently is safe — avoids up to
    // ~16s of compounded 1s timeouts (two reads each) on a dead socket.
    final results = await Future.wait([
      read('gamma'),
      read('primaries'),
      read('colormatrix'),
      read('sig-peak'),
      read('scene-max-r'),
      read('scene-max-g'),
      read('scene-max-b'),
      read('scene-avg'),
    ]);
    final [
      gamma,
      primaries,
      colormatrix,
      sigPeak,
      sceneMaxR,
      sceneMaxG,
      sceneMaxB,
      sceneAvg,
    ] = results;
    return LinuxHdrColorimetry(
      gamma: gamma?.toString(),
      primaries: primaries?.toString(),
      colormatrix: colormatrix?.toString(),
      sigPeak: asDouble(sigPeak),
      sceneMaxR: asDouble(sceneMaxR),
      sceneMaxG: asDouble(sceneMaxG),
      sceneMaxB: asDouble(sceneMaxB),
      sceneAvg: asDouble(sceneAvg),
    );
  }

  Future<Object?> _getProperty(String property) async {
    if (_socket == null || _disposed) return null;
    final requestId = ++_requestId;
    final completer = Completer<Object?>();
    _requests[requestId] = completer;
    try {
      await _send(
        '${jsonEncode({
          'command': ['get_property', property],
          'request_id': requestId,
        })}\n',
      );
    } catch (_) {
      _requests.remove(requestId);
      return null;
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      _requests.remove(requestId);
      return null;
    }
  }

  void _handleMessage(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      final requestId = decoded['request_id'];
      if (requestId is int) {
        _requests.remove(requestId)?.complete(decoded['data']);
        return;
      }
      final event = decoded['event'];
      if (event == 'property-change') {
        final name = decoded['name'];
        if (name == 'user-data/iptvs-control') {
          final data = decoded['data'];
          if (data is String && !_controlEvents.isClosed) {
            _controlEvents.add(data.split('|').first);
          }
        } else if (name == 'paused-for-cache' && decoded['data'] == true) {
          // Only the underrun (true) is a signal; the recovering (false) edge
          // is deliberately ignored — see [LinuxNativePlaybackSignal.resumed].
          _emitPlayback(LinuxNativePlaybackSignal.stalled);
        } else if (name == 'time-pos' || name == 'duration') {
          // `time-pos` isn't observed any more (see [_start]) — only `duration`
          // arrives here — but the shared update seam stays name-driven so the
          // poll and the observer keep one code path.
          final (position, duration) = applyPlaybackPropertyChange(
            (_lastPositionSeconds, _lastDurationSeconds),
            name,
            decoded['data'],
          );
          _lastPositionSeconds = position;
          _lastDurationSeconds = duration;
        }
        return;
      }
      if (event == 'end-file') {
        final reason = decoded['reason'];
        DiagnosticsLog.instance.add(
          'player',
          'linux native end-file reason=$reason',
        );
        if (reason == 'error' || reason == 'eof') {
          _emitPlayback(LinuxNativePlaybackSignal.dropped);
        }
        return;
      }
      if (event == 'file-loaded' || event == 'playback-restart') {
        _emitPlayback(LinuxNativePlaybackSignal.resumed);
        return;
      }
    } on FormatException {
      // Ignore non-JSON diagnostic output on the IPC stream.
    }
  }

  /// Pure update for the [_lastPositionSeconds]/[_lastDurationSeconds] cache
  /// given a `time-pos`/`duration` `property-change` event — a testable seam
  /// so the caching logic can be pinned without a real mpv IPC connection.
  /// Non-numeric/unrelated data leaves the corresponding slot unchanged
  /// (mpv reports `null` for `time-pos`/`duration` when nothing is loaded).
  @visibleForTesting
  static (double?, double?) applyPlaybackPropertyChange(
    (double?, double?) cached,
    String name,
    Object? data,
  ) {
    final (position, duration) = cached;
    final value = data is num ? data.toDouble() : null;
    if (name == 'time-pos') return (value ?? position, duration);
    if (name == 'duration') return (position, value ?? duration);
    return cached;
  }

  void _emitPlayback(LinuxNativePlaybackSignal signal) {
    if (!_playbackEvents.isClosed) _playbackEvents.add(signal);
  }

  void _completePendingRequests() {
    for (final request in _requests.values) {
      if (!request.isCompleted) request.complete(null);
    }
    _requests.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
    try {
      if (_socket != null) {
        await _send(
          '${jsonEncode({
            'command': const ['quit'],
          })}\n',
        );
      }
    } catch (_) {}
    _disposed = true;
    _completePendingRequests();
    await _controlEvents.close();
    await _playbackEvents.close();
    await _socket?.close();
    _socket = null;
    final process = _process;
    if (process != null) {
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          return -1;
        },
      );
    }
    final path = _socketPath;
    if (path != null) {
      await File(path).delete().catchError((_) => File(path));
    }
    final inputConfigPath = _inputConfigPath;
    if (inputConfigPath != null) {
      await File(
        inputConfigPath,
      ).delete().catchError((_) => File(inputConfigPath));
    }
  }
}
