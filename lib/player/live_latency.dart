/// How far behind the live edge a live stream has drifted, and how that is
/// shown and logged — identical on every surface.
///
/// **Why this exists.** Live MPEG-TS arrives at ~1x. Every rebuffer, every
/// pause, every second the app spends in the background adds its own duration
/// to how far behind live the viewer is, permanently — nothing in the pipeline
/// ever subtracts it. Before this, `liveSynced` went false *only* on a user
/// pause, so a viewer who had drifted ninety seconds through rebuffering saw a
/// green LIVE pill and no "Go to live" chip. That is the shipped bug behind
/// "it's delayed even on live".
///
/// **This measures; it never steers.** Nothing here changes buffer presets,
/// `LoadControl`, `cache-secs`, playback speed, the reconnect policy, the
/// watchdog timings or the handoff windows. The only behavioural consequence
/// is that the (already existing) "Go to live" control appears when the stream
/// has drifted, which is what it was for.
///
/// The Kotlin (`HdrPlayerActivity`), Swift (`IptvsPlayerViewController`), C++
/// (Windows) and Lua (Linux) sides carry pure mirrors of [LiveLatencyTracker]
/// and of these formatters where they own their own engine; Dart owns every
/// media_kit surface plus the Linux native mpv process, and *pushes the
/// formatted strings* to the two renderers it drives (Windows GDI, the Lua
/// OSD), which print and never derive. See docs/player.md "Live latency".
library;

/// Drift at which a live stream stops counting as "at the live edge": the LIVE
/// badge starts naming the delay and "Go to live" appears.
///
/// Thirty seconds is deliberately well clear of ordinary buffering: a preset
/// as deep as `max` holds 120 s of media but plays it at 1x, so a healthy
/// stream's *drift* stays near zero however deep its cushion is. Anything this
/// far behind was bought by stalls or a pause, and is not coming back on its
/// own.
const int kLiveDriftWarnMs = 30000;

/// Media going *backwards* by more than this is a discontinuity, not drift.
const int _kDiscontinuityBackMs = -500;

/// Media running ahead of the wall clock by more than this between two samples
/// is a discontinuity too (a seek, a `loadfile` landing further along, an HLS
/// playlist jump) — a live stream cannot legitimately gain two seconds of
/// media in one second of wall time.
const int _kDiscontinuityAheadSlackMs = 2000;

/// How often a healthy, interesting session writes a line to the exportable
/// diagnostics log.
const int _kPeriodicLogMs = 60000;

/// Below these, a periodic line says nothing worth exporting.
const int _kPeriodicLogMinDriftMs = 5000;
const int _kPeriodicLogMinAheadMs = 30000;

/// Accumulates how far behind the live edge playback has fallen **since this
/// stream's first frame**, from samples taken on whatever tick the surface
/// already runs (0.5–1 s here; the natives mirror it on theirs).
///
/// One tracker per *live session*: [reset] is called at every point where
/// playback restarts at the live edge (a new open, a reconnect reload, a
/// settled zap, "Go to live", an engine swap, a preview→fullscreen claim).
///
/// Pure: no timers, no clock reads, no platform. The caller supplies `nowMs`,
/// which is also what makes the discontinuity and stall rules testable.
class LiveLatencyTracker {
  int _driftMs = 0;
  int _aheadMs = -1;
  int _stalls = 0;
  int _stalledMs = 0;
  int _discontinuities = 0;
  bool _baselined = false;
  bool _warned = false;

  int? _lastWallMs;
  int? _lastPositionMs;
  bool _wasBuffering = false;
  int? _lastPeriodicLogMs;

  /// Delay accumulated since the baseline, in milliseconds. Zero until
  /// [baselined].
  int get driftMs => _driftMs;

  /// Media buffered ahead of the playhead at the last sample, or `-1` when the
  /// surface could not answer (an engine Dart does not own, mpv before the
  /// first cache read).
  int get aheadMs => _aheadMs;

  /// Transitions **into** buffering since the reset. Attribution only.
  int get stalls => _stalls;

  /// Wall time spent buffering since the reset. Attribution only.
  int get stalledMs => _stalledMs;

  /// Media-time discontinuities seen (a seek, a reload landing elsewhere, an
  /// HLS playlist jump). Attribution only — a discontinuity re-baselines
  /// rather than contributing drift.
  int get discontinuities => _discontinuities;

  /// Whether the first frame / first media progress has been seen. Before it,
  /// drift is zero by definition — startup latency is not drift.
  bool get baselined => _baselined;

  /// Whether [kLiveDriftWarnMs] has been crossed **in this session**.
  ///
  /// Latched: it stays true once set, until [reset]. That hysteresis is
  /// mandatory, not cosmetic — the "Go to live" chip removes itself while
  /// focused and hands focus on, so a gate that oscillated around the
  /// threshold would take the D-pad with it (docs/tv-navigation.md).
  bool get warned => _warned;

  /// Folds one sample in. Returns true on the **first** sample that crosses
  /// [kLiveDriftWarnMs] in this session, which is the caller's cue to write the
  /// `live latency behind …` line and drop `liveSynced`.
  bool sample({
    required int nowMs,
    required int positionMs,
    required int aheadMs,
    required bool playing,
    required bool buffering,
  }) {
    _aheadMs = aheadMs;

    final lastWall = _lastWallMs;
    final lastPosition = _lastPositionMs;
    final dWall = lastWall == null ? 0 : nowMs - lastWall;

    // Stall attribution runs whether or not a baseline exists: buffering
    // before the first frame is still time the viewer spent waiting, and the
    // counters are never an input to the drift arithmetic.
    if (buffering && !_wasBuffering) _stalls++;
    if (_wasBuffering && lastWall != null && dWall > 0) _stalledMs += dWall;
    _wasBuffering = buffering;

    if (!_baselined) {
      // **Baseline:** the first sample where playback is playing *and* media
      // time has advanced since the previous sample. Anything before that is
      // the open itself — a connection, a demuxer and a first IDR — which is
      // startup latency, not accumulated delay.
      if (playing &&
          lastPosition != null &&
          positionMs > lastPosition &&
          lastWall != null) {
        _baselined = true;
      }
      _lastWallMs = nowMs;
      _lastPositionMs = positionMs;
      return false;
    }

    final dMedia = positionMs - (lastPosition ?? positionMs);
    if (dMedia < _kDiscontinuityBackMs ||
        dMedia > dWall + _kDiscontinuityAheadSlackMs) {
      // A discontinuity is not drift and not a correction of it: the media
      // timeline moved for a reason outside this arithmetic, so re-anchor and
      // keep what was already accumulated. Adding (or subtracting) this tick
      // would charge the viewer for a seek or credit them for a reload.
      _discontinuities++;
    } else {
      // Deliberately **no cap on dWall**: a long gap with no media progress —
      // a pause, a stall, the app in the background — is real lag, and the
      // whole point of the measurement is that nothing ever gives it back.
      final delta = dWall - dMedia;
      if (delta > 0) _driftMs += delta;
    }

    _lastWallMs = nowMs;
    _lastPositionMs = positionMs;

    if (!_warned && _driftMs >= kLiveDriftWarnMs) {
      _warned = true;
      return true;
    }
    return false;
  }

  /// Starts a new live session: drift zero, unbaselined, counters cleared, the
  /// warn latch released.
  void reset() {
    _driftMs = 0;
    _aheadMs = -1;
    _stalls = 0;
    _stalledMs = 0;
    _discontinuities = 0;
    _baselined = false;
    _warned = false;
    _lastWallMs = null;
    _lastPositionMs = null;
    _wasBuffering = false;
    _lastPeriodicLogMs = null;
  }

  /// Whether a periodic diagnostics line is due at [nowMs], **consuming** the
  /// slot when it is (so the caller can simply `if (…) log(…)`).
  ///
  /// Every 60 s while playing, and only when the session is saying something:
  /// ≥5 s of drift, or ≥30 s of cushion. A stream that is neither behind nor
  /// deeply buffered would otherwise write a line a minute into an exportable
  /// log for no reason.
  bool takePeriodicLog({required int nowMs, required bool playing}) {
    final last = _lastPeriodicLogMs;
    if (last == null) {
      // Anchor on the first call rather than on the epoch, or the very first
      // sample of every session would be "due".
      _lastPeriodicLogMs = nowMs;
      return false;
    }
    if (!playing) return false;
    if (nowMs - last < _kPeriodicLogMs) return false;
    if (_driftMs < _kPeriodicLogMinDriftMs &&
        _aheadMs < _kPeriodicLogMinAheadMs) {
      return false;
    }
    _lastPeriodicLogMs = nowMs;
    return true;
  }

  /// The periodic/threshold line for this tracker's current state.
  String get logLine => liveLatencyLogLine(
    driftMs: _driftMs,
    aheadMs: _aheadMs,
    stalls: _stalls,
    stalledMs: _stalledMs,
    discontinuities: _discontinuities,
  );

  /// The first-crossing line: the same facts, flagged.
  String get behindLogLine => 'live latency behind $logLine';

  /// The line written when a session with measured drift is reset.
  String resetLogLine(String reason) => liveLatencyResetLogLine(
    reason: reason,
    driftMs: _driftMs,
    stalls: _stalls,
  );
}

/// `m:ss` below an hour, `h:mm:ss` at or above it — total seconds, floored.
///
/// Floored, not rounded, because this is "how far behind", and rounding 7.9 s
/// up to `0:08` would claim a precision the 1 Hz sampling does not have.
String fmtDelay(int ms) {
  final total = ms < 0 ? 0 : ms ~/ 1000;
  final seconds = (total % 60).toString().padLeft(2, '0');
  if (total < 3600) return '${total ~/ 60}:$seconds';
  final minutes = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  return '${total ~/ 3600}:$minutes:$seconds';
}

/// The top-bar LIVE badge's text: bare `LIVE` while at the edge, `LIVE -1:23`
/// once drifted.
///
/// The sign is an **ASCII hyphen-minus**, never U+2212: this same string is
/// drawn by the Windows GDI overlay and by libass in the Lua OSD, whose
/// bundled faces are not guaranteed to carry the typographic minus.
///
/// The greyed-when-unsynced styling each surface already applies is unchanged
/// and orthogonal — the badge can read `LIVE` while greyed (a user pause), and
/// a latched drift greys it too.
String liveDelayBadgeLabel(int driftMs) =>
    driftMs < kLiveDriftWarnMs ? 'LIVE' : 'LIVE -${fmtDelay(driftMs)}';

/// The "Live delay" row's value in the Stream information panel:
/// `1:23 · buffer 24s`, or just `1:23` when the surface cannot report a
/// buffer depth.
///
/// The cushion sits beside the delay on purpose: the two answer the question a
/// buffer setting is asked to answer — whether a stream fell behind because it
/// never built a cushion, or because it built one and drained it.
String liveDelayInfoValue(int driftMs, int aheadMs) {
  final delay = fmtDelay(driftMs);
  if (aheadMs < 0) return delay;
  return '$delay · buffer ${(aheadMs / 1000).round()}s';
}

/// The periodic / first-crossing diagnostics line. Credential-free by
/// construction: durations and counts only, no URL and no channel name.
String liveLatencyLogLine({
  required int driftMs,
  required int aheadMs,
  required int stalls,
  required int stalledMs,
  required int discontinuities,
}) =>
    'live latency drift=${driftMs}ms ahead=${aheadMs}ms stalls=$stalls '
    'stalled=${stalledMs}ms disc=$discontinuities';

/// The reset line, written only when the session being ended had measured
/// drift — the reason is one of `load|reconnect|zap|golive|engine|claim`.
String liveLatencyResetLogLine({
  required String reason,
  required int driftMs,
  required int stalls,
}) => 'live latency reset reason=$reason drift=${driftMs}ms stalls=$stalls';
