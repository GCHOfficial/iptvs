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
     * The same judgement again, once the handoff has demonstrably drawn at
     * least one frame on the **new** surface and then stopped.
     *
     * This is the shape real hardware actually produced: armed at the claim,
     * one frame rendered 251 ms later, and the counter never moved again — a
     * decoder that took the output switch, emitted a single frame and wedged.
     * At that point every ambiguity [HANDOFF_NO_FRAME_STALL_MS] is being
     * generous about is gone. The first-frame latency it was covering has
     * already been paid, so the only question left is whether a live stream
     * that drew a frame half a second ago and claims to be playing, unbuffered,
     * has drawn another. At any broadcast frame rate it has drawn twelve.
     *
     * Half a second rather than "immediately" because the recovery is still a
     * guess about a decoder, and [ReconnectPolicy.HANDOFF_POLL_MS] makes it
     * four consecutive identical samples rather than one unlucky gap.
     */
    const val HANDOFF_POST_FRAME_STALL_MS = 500L

    /** Base cadence of `HdrPlayerActivity`'s progress/liveness ticker. */
    const val PROGRESS_TICK_MS = 500L

    /**
     * Ticker cadence while [FrameLivenessWatch.inHandoffWindow] — the base
     * 500 ms cannot resolve [HANDOFF_POST_FRAME_STALL_MS] at all (one tick gap
     * would decide it), and the window is bounded to [HANDOFF_WINDOW_MS], so
     * the extra polling is five seconds long and nothing else in the session
     * pays for it.
     */
    const val HANDOFF_POLL_MS = 125L

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
 *
 * Inside that window the handoff then fails in **two** shapes, and they want
 * different patience. Until the claimed surface has drawn a frame of its own,
 * the clock is judging first-frame latency and stays at
 * [ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS]; once it has ([drewSinceArm]),
 * that latency has been paid and a freeze is decided on
 * [ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS].
 */
class FrameLivenessWatch(
    private val stallMs: Long = ReconnectPolicy.NO_FRAME_STALL_MS,
    private val handoffStallMs: Long = ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS,
    private val handoffPostFrameStallMs: Long = ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS,
    private val handoffWindowMs: Long = ReconnectPolicy.HANDOFF_WINDOW_MS,
) {
    private var lastFrames = NO_SAMPLE
    private var lastProgressAtMs = 0L
    private var sawProgress = false
    private var handoffUntilMs = NO_HANDOFF

    // Whether the counter has been seen to move since [armHandoff] — i.e.
    // whether the *new* surface has had a frame of its own, as opposed to the
    // preview's frames that armed the watch. It separates "the picture hasn't
    // arrived yet" from "the picture arrived and stopped", which deserve very
    // different patience.
    private var drewSinceHandoff = false

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
        drewSinceHandoff = false
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
     * Records that the **claimed** surface has drawn its first frame, moving
     * the watch onto [handoffPostFrameStallMs].
     *
     * Deliberately *not* inferred from the frame counter moving. The counter is
     * `renderedOutputBufferCount`, which is surface-agnostic, and
     * [armHandoff] runs at adoption while `claimViewSurface` is still
     * **deferred** waiting for `surfaceCreated` (measured at ~117 ms on real
     * hardware). Every frame drawn in that gap goes to the *preview texture*,
     * so treating counter movement as proof would drop a healthy handoff onto
     * the 500 ms clock before the new surface had drawn anything at all — and
     * a codec release/re-init plus the wait for the next IDR on a live MPEG-TS
     * stream routinely outlasts that while every health flag reads fine. The
     * result would be a spurious decoder rebuild on a working handoff, and
     * (since a frame stall skips the reload threshold entirely) a full reload
     * right behind it.
     *
     * The engine's own `onRenderedFirstFrame` after the claim is the honest
     * signal, and media3 only re-notifies it when the output surface actually
     * changed.
     */
    fun markHandoffFirstFrame() {
        if (handoffUntilMs != NO_HANDOFF) drewSinceHandoff = true
    }

    /**
     * Whether the surface the last [armHandoff] described has since drawn a
     * frame of its own. Reported alongside a recovery so an exported log says
     * which of the two handoff failures it was: a picture that never arrived,
     * or one that arrived and stopped.
     */
    fun drewSinceArm(): Boolean = drewSinceHandoff

    /**
     * Feeds one poll sample and reports whether the renderer has now been
     * frozen for [stallMs] — or, while [inHandoffWindow], for one of the two
     * shorter handoff clocks: [handoffStallMs] until the claimed surface has
     * drawn a frame of its own, [handoffPostFrameStallMs] after it has.
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
        val threshold = when {
            !inHandoffWindow(nowMs) -> stallMs
            // The new surface has had a frame of its own, so nothing is owed to
            // first-frame latency any more — see [HANDOFF_POST_FRAME_STALL_MS].
            drewSinceHandoff -> handoffPostFrameStallMs
            else -> handoffStallMs
        }
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
        // A buffering tick doesn't un-draw the frame the new surface already
        // got, so the shorter post-frame threshold survives it. A real reset
        // (reload / engine swap) forgets the whole handoff, and this with it.
        if (!keepHandoff) {
            handoffUntilMs = NO_HANDOFF
            drewSinceHandoff = false
        }
    }

    private companion object {
        const val NO_SAMPLE = -1
        const val NO_HANDOFF = 0L
    }
}
