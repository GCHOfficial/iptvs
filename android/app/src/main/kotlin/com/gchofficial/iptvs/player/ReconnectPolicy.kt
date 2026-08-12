package com.gchofficial.iptvs.player

/**
 * Pure timing policy for the live auto-reconnect watchdog (Android's
 * `HdrPlayerActivity`; Windows runs the same shape of watchdog independently —
 * see docs/player.md). Kept free of Android imports so it's covered by a
 * plain-JUnit test rather than an instrumented one.
 */
object ReconnectPolicy {
    /** Buffering/dropped this long before a non-forced reconnect fires. */
    const val STALL_RECONNECT_MS = 8_000L

    /** A live drop (ended) is faster to retry than a stall. */
    const val ENDED_RECONNECT_MS = 2_000L

    /** Cap on the attempt-scaled backoff between repeated reconnect attempts. */
    const val MAX_BACKOFF_MS = 30_000L

    /**
     * How long a live stream may claim to be playing normally while putting no
     * new frame on screen before [FrameLivenessWatch] calls it stalled.
     *
     * Shorter than [STALL_RECONNECT_MS] on purpose: this is not an underrun the
     * loader might still recover from — the engine is reporting healthy, the
     * clock is running, and nothing is being drawn. No live broadcast rate
     * leaves a gap remotely this long, so waiting the full stall interval only
     * lengthens a freeze the watchdog previously never ended at all.
     */
    const val NO_FRAME_STALL_MS = 6_000L

    /**
     * The same judgement, inside the fullscreen-handoff window
     * ([HANDOFF_WINDOW_MS] after an adopted engine's surface claim).
     *
     * Much shorter because the ambiguity [NO_FRAME_STALL_MS] is being generous
     * about doesn't exist here: the preview was demonstrably rendering a moment
     * ago, the only thing that changed is which surface the decoder outputs to,
     * and the recovery this arms ([PlaybackEngine.rebuildVideoDecoder]) is a
     * local decoder re-init — no provider round trip, no lost buffer, nothing
     * to be careful about spending. At the 500 ms poll that is three
     * consecutive identical samples.
     */
    const val HANDOFF_NO_FRAME_STALL_MS = 1_500L

    /**
     * How long after an adopted handoff a frozen renderer is still attributed
     * to the surface claim rather than to the network.
     *
     * Both observed shapes fall well inside it: the picture either never
     * arrives at all, or arrives and stops within a second (measured at ~250 ms
     * after the first frame). Past this the stream has visibly survived the
     * handoff and normal live rules apply again.
     */
    const val HANDOFF_WINDOW_MS = 5_000L

    /**
     * Minimum gap (ms) required since the last reconnect attempt before the
     * *next* one may fire. [priorAttempts] is the number of reconnect attempts
     * already made (0 before the first). A forced reconnect (hard player
     * error) always uses the base stall threshold instead of scaling with the
     * attempt count.
     */
    fun minGapMs(priorAttempts: Int, force: Boolean): Long = if (force) {
        STALL_RECONNECT_MS
    } else {
        minOf((priorAttempts + 1) * STALL_RECONNECT_MS, MAX_BACKOFF_MS)
    }
}

/**
 * Detects the one live failure the reconnect watchdog could not previously see:
 * **playing, but nothing on screen.**
 *
 * `HdrPlayerActivity.pollLiveReconnect` judges a stall from `isBuffering ||
 * ended`. An engine whose video output has gone nowhere — a decoder that was
 * released and re-instantiated across the preview→fullscreen surface handoff and
 * is still waiting for an IDR, or one holding a surface that no longer exists —
 * stays in `STATE_READY` and reports `isPlaying`. Both flags read healthy, the
 * position keeps advancing, and the picture never comes back: a permanent freeze
 * with no recovery and, until this existed, not one line in the exportable log.
 *
 * Frame counts are the only signal that distinguishes it, and the renderer
 * already publishes one. Deliberately kept free of Android imports (and of the
 * counter's source) so it is covered by the plain-JUnit harness.
 *
 * Fails **inert**, never false-positive, in three ways:
 *
 * 1. An engine that cannot report a frame count (`renderedFrames < 0` — an
 *    audio-only channel has no video renderer at all) is never judged.
 * 2. Any state that isn't "playing normally" resets the clock instead of
 *    accumulating toward a stall.
 * 3. **It only fires on a counter it has seen move** — or one [armHandoff] has
 *    been given proof about. A counter that has never advanced is
 *    indistinguishable from a renderer this class doesn't understand — some
 *    decode paths may simply not report — and reconnecting a perfectly healthy
 *    stream every few seconds would be a far worse bug than the one this fixes.
 *    What this catches is the other shape — a stream that *was* rendering (the
 *    preview) and stopped (the fullscreen handoff) while still claiming to
 *    play.
 *
 * The "wait to see it move" rule had one hole, and it was in the exact case the
 * class was written for. When the handoff freezes the renderer *before it draws
 * a single frame on the new surface* — the shape an exported log showed as a
 * surface claim followed by 11 s of nothing, no first frame, no stall, no
 * reconnect, until the user pressed Back — the counter never moves under this
 * watch's own observation, so it stays inert and the freeze is permanent. The
 * proof it was waiting for already existed: the preview had been rendering that
 * same counter seconds earlier. [armHandoff] hands it that proof at the moment
 * of the claim, which is also the moment a shorter window becomes justified
 * ([ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS]). Inert rule 3 is unchanged
 * everywhere else: a cold open, an mpv engine and an audio-only channel never
 * arm.
 */
class FrameLivenessWatch(
    private val stallMs: Long = ReconnectPolicy.NO_FRAME_STALL_MS,
    private val handoffStallMs: Long = ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS,
    private val handoffWindowMs: Long = ReconnectPolicy.HANDOFF_WINDOW_MS,
) {
    private var lastFrames = NO_SAMPLE
    private var lastProgressAtMs = 0L
    private var sawProgress = false
    private var handoffUntilMs = NO_HANDOFF

    /**
     * Arms the watch for a fullscreen surface claim on an *adopted* engine,
     * against [renderedFrames] — the count the preview has already run up on
     * this very renderer.
     *
     * A non-zero count is the proof inert rule 3 asks for: those frames were
     * drawn, by this counter, moments ago. Zero (or -1) is not proof and is
     * refused — returning false so the caller can say so in a report rather
     * than assume it armed.
     */
    fun armHandoff(nowMs: Long, renderedFrames: Int): Boolean {
        if (renderedFrames <= 0) return false
        lastFrames = renderedFrames
        lastProgressAtMs = nowMs
        sawProgress = true
        handoffUntilMs = nowMs + handoffWindowMs
        return true
    }

    /**
     * True while a frozen renderer is still attributable to the surface claim
     * [armHandoff] recorded — i.e. while the cheap, local recovery is the right
     * answer and a full reload is not yet.
     */
    fun inHandoffWindow(nowMs: Long): Boolean =
        handoffUntilMs != NO_HANDOFF && nowMs < handoffUntilMs

    /**
     * Feeds one poll sample and reports whether the renderer has now been
     * frozen for [stallMs] — or for the shorter [handoffStallMs] while
     * [inHandoffWindow].
     *
     * [playingNormally] must be the engine's *own* claim of health (playing,
     * not buffering, not ended) — the whole point is to catch the case where
     * that claim and the screen disagree.
     */
    fun sample(nowMs: Long, playingNormally: Boolean, renderedFrames: Int): Boolean {
        // An engine that can't count at all is not one this watch can be armed
        // against either (it is also how an mpv fallback arrives here).
        if (renderedFrames < 0) {
            reset()
            return false
        }
        if (!playingNormally) {
            // Inside the handoff window the proof is the *preview's* frames,
            // not an observation of this watch's own that a moment of
            // buffering could revoke. Without this a single buffering tick
            // during the claim silently disarms the handoff — and the handoff
            // is exactly when a buffering tick is most likely.
            clearFrameWindow(keepHandoff = inHandoffWindow(nowMs))
            return false
        }
        if (lastFrames == NO_SAMPLE) {
            lastFrames = renderedFrames
            lastProgressAtMs = nowMs
            return false
        }
        if (renderedFrames != lastFrames) {
            sawProgress = true
            lastFrames = renderedFrames
            lastProgressAtMs = nowMs
            return false
        }
        val threshold = if (inHandoffWindow(nowMs)) handoffStallMs else stallMs
        return sawProgress && nowMs - lastProgressAtMs >= threshold
    }

    /**
     * Forgets the current window *and* any armed handoff — call around a
     * reload or an engine swap. A reload builds its own decoder against the
     * surface it will keep, so whatever the claim was owed, this is no longer
     * it.
     */
    fun reset() = clearFrameWindow(keepHandoff = false)

    private fun clearFrameWindow(keepHandoff: Boolean) {
        lastFrames = NO_SAMPLE
        lastProgressAtMs = 0L
        sawProgress = keepHandoff
        if (!keepHandoff) handoffUntilMs = NO_HANDOFF
    }

    private companion object {
        const val NO_SAMPLE = -1
        const val NO_HANDOFF = 0L
    }
}
