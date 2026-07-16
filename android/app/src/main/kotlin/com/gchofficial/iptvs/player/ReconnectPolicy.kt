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
