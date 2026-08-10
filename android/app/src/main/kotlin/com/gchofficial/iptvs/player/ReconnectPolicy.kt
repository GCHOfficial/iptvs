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
 * 3. **It only fires on a counter it has seen move.** A counter that has never
 *    advanced is indistinguishable from a renderer this class doesn't
 *    understand — some decode paths may simply not report — and reconnecting a
 *    perfectly healthy stream every few seconds would be a far worse bug than
 *    the one this fixes. Nothing is lost by waiting for proof: a stream that
 *    never renders *at all* is a stream that never leaves `STATE_BUFFERING`,
 *    which the existing buffering watchdog already owns. What this catches is
 *    the other shape — a stream that *was* rendering (the preview) and stopped
 *    (the fullscreen handoff) while still claiming to play.
 */
class FrameLivenessWatch(
    private val stallMs: Long = ReconnectPolicy.NO_FRAME_STALL_MS,
) {
    private var lastFrames = NO_SAMPLE
    private var lastProgressAtMs = 0L
    private var sawProgress = false

    /**
     * Feeds one poll sample and reports whether the renderer has now been
     * frozen for [stallMs].
     *
     * [playingNormally] must be the engine's *own* claim of health (playing,
     * not buffering, not ended) — the whole point is to catch the case where
     * that claim and the screen disagree.
     */
    fun sample(nowMs: Long, playingNormally: Boolean, renderedFrames: Int): Boolean {
        if (!playingNormally || renderedFrames < 0) {
            reset()
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
        return sawProgress && nowMs - lastProgressAtMs >= stallMs
    }

    /** Forgets the current window — call around a reload or an engine swap. */
    fun reset() {
        lastFrames = NO_SAMPLE
        lastProgressAtMs = 0L
        sawProgress = false
    }

    private companion object {
        const val NO_SAMPLE = -1
    }
}
