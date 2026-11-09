package com.gchofficial.iptvs.player

/**
 * Periodic *inbound* throughput, measured from bytes the media loader has
 * actually taken off the wire.
 *
 * Exists for the same report [PlaybackStatsSampler] couldn't answer on its
 * own: a 1080p25 Xtream `.ts` channel logged `stalls=10 stalled=22941ms` with
 * delay reaching 30s, and the one line that samples every 5s — `native
 * playback fps=…` — simply stops printing while the player buffers, because
 * fps/rendered/dropped are meaningless then. That left an exported log unable
 * to say whether the stall was **starvation** (the provider link genuinely
 * wasn't delivering data) or something else entirely. This class answers
 * that: how many bytes arrived, expressed as a rate, over a window that
 * keeps running **through** a buffering stall rather than resetting at its
 * edges — the fps sampler resets there on purpose (see its own doc), but a
 * byte counter that did the same would go silent for exactly the interval
 * the report needs it most.
 *
 * Pure and clock-injected (no Android import) so it is unit-testable without
 * a player, a device, or even a real media3 dependency.
 */
class ThroughputMeter(
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
) {
    // -1 is "no window open yet" — distinct from a real window whose first
    // instant happens to be millisecond 0, the same reasoning
    // PlaybackStatsSampler's own `hasBaseline` flag documents.
    private var windowStartMs = -1L
    private var bytes = 0L

    /**
     * Records bytes as the media loader delivers them.
     *
     * Called from whichever thread the HTTP loader runs on — media3's
     * `TransferListener` fires there, not on the main thread [sampleKbps] is
     * read from — so this and [sampleKbps] share a lock. No timestamp is
     * taken here: the window's clock is owned entirely by [sampleKbps], on
     * the caller's own ticker, exactly like [PlaybackStatsSampler].
     */
    @Synchronized
    fun onBytesTransferred(byteCount: Long) {
        if (byteCount > 0L) bytes += byteCount
    }

    /**
     * Returns the window's throughput in kbps once [intervalMs] has elapsed
     * since it opened, and starts the next window — or null while still
     * inside it, or on the very first call, which only opens the window.
     *
     * A window with zero bytes still reports **`0`**, deliberately — that is
     * the one signal this class exists to surface: a stall with nothing
     * arriving at all reads `in=0kbps` instead of the line simply not being
     * there. The window is opened and closed purely by [sampleKbps]'s own
     * calls, so a caller that keeps calling it on every tick — playing,
     * buffering, paused, reconnecting — gets a continuous, uninterrupted
     * measurement regardless of what the player is doing; nothing in this
     * class ever resets the window on its own.
     */
    @Synchronized
    fun sampleKbps(nowMs: Long): Long? {
        val start = windowStartMs
        if (start < 0L) {
            windowStartMs = nowMs
            return null
        }
        val elapsed = nowMs - start
        if (elapsed < intervalMs) return null
        // bytes*8 bits, over `elapsed` ms, is already bits/ms == kbit/s: no
        // separate /1000 x1000 round trip needed.
        val kbps = if (elapsed <= 0L) 0L else bytes * 8L / elapsed
        windowStartMs = nowMs
        bytes = 0L
        return kbps
    }

    companion object {
        /** Mirrors [PlaybackStatsSampler.DEFAULT_INTERVAL_MS] — one shared cadence. */
        const val DEFAULT_INTERVAL_MS = 5_000L
    }
}
