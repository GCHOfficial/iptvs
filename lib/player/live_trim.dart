/// "Go to live" without a reload: skipping forward inside mpv's own demuxer
/// cache.
///
/// **Why this is worth having.** A live IPTV stream is commonly handed to us
/// with a *connect backlog* — the provider sends the last minute or two faster
/// than real time and playback starts at its oldest frame. Nothing the app
/// asks for changes that: a smaller readahead doesn't make the provider hold
/// less, it only costs stall protection. So the delay is sitting in the
/// demuxer cache, already downloaded, ahead of the playhead.
///
/// mpv can simply step over it. `seek <t> absolute+keyframes` on a live TS
/// lands inside the cache with no new HTTP request, A/V sync intact, and the
/// cache refills from the backlog the provider is still holding (verified on
/// mpv 0.41 / FFmpeg 9 with this app's exact live options). The alternative —
/// the reload this control used to do — spends a provider round trip, a fresh
/// token and a whole new buffer to reach the same place, and on a
/// single-connection account it also has to give the old connection up first.
///
/// **ExoPlayer and AVPlayer cannot do this**, which is why the decision lives
/// here rather than in the shared tracker: media3's `ProgressiveMediaPeriod`
/// treats every seek on non-seekable live media as t=0 and restarts the load,
/// so the Android native path keeps its reload. Only the mpv surfaces Dart
/// drives — the embedded player, the Windows native HWND (the same `_player`
/// presenting through a `vo` swap) and the Linux native mpv process — use
/// this. See docs/player.md "Live latency".
///
/// Pure: the decision and its verification are arithmetic, so the awkward
/// cases (an unknown cache, a cache too shallow to be worth a jump, a seek
/// that silently didn't take) are testable without an engine.
library;

/// How much cushion to leave ahead of the playhead after a skip.
///
/// Not zero, and deliberately not the preset's own cache depth either. Landing
/// *on* the live edge would leave the demuxer with nothing to absorb the next
/// hiccup, so the very next stall would undo the skip; two seconds is enough
/// to keep playing while the cache refills behind it, and is well inside the
/// margin [kTrimMinJumpMs] already insists on.
const int kTrimTargetMs = 2000;

/// The smallest jump worth making.
///
/// Below this the skip costs a keyframe-accurate reposition (a visible hitch,
/// and on some streams an audio gap) to buy a delay reduction the viewer would
/// not notice. A cache this shallow is also the case where a jump is most
/// likely to land past the end of what has really been demuxed.
const int kTrimMinJumpMs = 5000;

/// How long to wait before reading `time-pos` back to see whether the seek
/// took.
///
/// mpv acknowledges a command long before the demuxer has repositioned and
/// the renderer has drawn from the new point, so an immediate read would
/// report the old position and condemn every healthy skip as unverified. 300 ms
/// is comfortably more than an in-cache keyframe seek needs and short enough
/// that a user who pressed a button does not perceive it as a second action.
const Duration kTrimVerifyDelay = Duration(milliseconds: 300);

/// Why a skip is not on offer — the `reason=` field of the diagnostics line.
enum LiveTrimUnavailable {
  /// The surface could not say how much it holds ahead of the playhead.
  unknown,

  /// There is a cache, but stepping over it would not be worth the hitch.
  small,

  /// The seek was issued and the playhead did not move far enough to believe
  /// it. Decided by [LiveTrimDecision.verifiedBy], after the fact.
  unverified,
}

/// Either a jump to make, or the reason there isn't one.
class LiveTrimDecision {
  const LiveTrimDecision._(this.targetPositionMs, this.jumpMs, this.unavailable);

  /// Where to seek to, in milliseconds on the engine's own media timeline.
  /// Meaningless unless [canSkip].
  final int targetPositionMs;

  /// How far the playhead is being asked to move. Meaningless unless
  /// [canSkip].
  final int jumpMs;

  /// Null exactly when [canSkip].
  final LiveTrimUnavailable? unavailable;

  bool get canSkip => unavailable == null;

  /// Whether an observed jump of [observedJumpMs] counts as the seek having
  /// taken: at least **half** of what was asked for.
  ///
  /// Half rather than all, because the two numbers are read ~300 ms apart from
  /// a playhead that is also advancing, and because mpv seeks to the keyframe
  /// at or before the target — on a 2 s GOP that is up to two seconds short on
  /// its own. Half is far enough past "the seek did nothing" (the failure this
  /// guards: a surface that answers the command and stays put) to be decisive,
  /// while never rejecting a skip that really happened.
  ///
  /// Integer arithmetic on purpose — `observed >= jump / 2` with a fractional
  /// half is the kind of off-by-one that only shows up on an odd-sized cache.
  bool verifiedBy(int observedJumpMs) => observedJumpMs * 2 >= jumpMs;
}

/// Decides whether the playhead can be stepped forward inside the cache, from
/// a *fresh* read of `time-pos` ([positionMs]) and `demuxer-cache-duration`
/// ([aheadMs], `-1` when unknown).
///
/// **[aheadMs] must be a duration, never mpv's `demuxer-cache-time`.** That
/// property is an absolute timestamp on the demuxer's timeline (it is what
/// media_kit surfaces as `PlayerState.buffer`), so treating it as a depth
/// would ask for a seek somewhere near twice the live edge on any stream whose
/// timeline does not start at zero.
LiveTrimDecision decideLiveTrim({
  required int positionMs,
  required int aheadMs,
}) {
  if (aheadMs < 0) {
    return const LiveTrimDecision._(0, 0, LiveTrimUnavailable.unknown);
  }
  final jumpMs = aheadMs - kTrimTargetMs;
  if (jumpMs < kTrimMinJumpMs) {
    return const LiveTrimDecision._(0, 0, LiveTrimUnavailable.small);
  }
  // Clamped at zero: mpv reports a negative `time-pos` on a stream whose
  // timeline starts behind its first played frame, and asking for a negative
  // absolute seek on a live TS is how a "go to live" press becomes a reload
  // from the start of the cache.
  final target = positionMs + jumpMs;
  return LiveTrimDecision._(target < 0 ? 0 : target, jumpMs, null);
}

/// The diagnostics line for a skip that happened and verified. Credential-free
/// by construction: two durations.
String liveTrimSkipLogLine({
  required int jumpedMs,
  required int aheadBeforeMs,
}) => 'live latency skip jumped=${jumpedMs}ms ahead_before=${aheadBeforeMs}ms';

/// The diagnostics line for a press that fell through to the reload instead.
String liveTrimUnavailableLogLine(LiveTrimUnavailable reason) =>
    'live latency skip unavailable reason=${reason.name}';
