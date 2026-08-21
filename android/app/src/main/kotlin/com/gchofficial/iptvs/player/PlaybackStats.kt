package com.gchofficial.iptvs.player

/**
 * Periodic playback health, sampled from the decoder's own tallies.
 *
 * Exists because the exportable log had **no frame data at all unless something
 * failed**: `videoFrameCounters` is written only on a reconnect attempt or a
 * handoff decoder rebuild. A stream that plays — but plays badly — produced a
 * log indistinguishable from a healthy one, which is exactly the report this
 * was added for ("4K50 runs in slow motion, the preview looks fine").
 *
 * What the emitted line separates, none of which the old log could:
 *  * `fps` far below the stream's rate with `dropped` climbing — the decoder
 *    cannot keep up (a software fallback, or thermal throttling).
 *  * `fps` at the stream's rate with the picture still juddering — the decoder
 *    is fine and the *display cadence* is not (50fps content on a 60Hz output).
 *  * `fps` low with **no** drops — frames are arriving late rather than being
 *    discarded: a clock or scheduling problem, the true "slow motion".
 *  * `inits` climbing — the decoder is being rebuilt repeatedly.
 *
 * Pure and clock-injected so it is unit-testable without a player or a device.
 */
class PlaybackStatsSampler(
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
) {
    // An explicit flag rather than `lastMs == 0L` as the sentinel: 0 is a
    // perfectly good timestamp, and conflating "no baseline yet" with a real
    // value makes the sampler silently re-baseline forever at that instant.
    private var hasBaseline = false
    private var lastMs = 0L
    private var lastRendered = -1
    private var lastDropped = -1

    /**
     * Returns a log line at most once per [intervalMs], or null.
     *
     * The first call only establishes a baseline: a rate needs two samples, and
     * reporting a total as if it were a rate is worse than reporting nothing.
     * A counter that goes backwards (a new decoder resets the tallies) also
     * re-baselines rather than emitting a negative rate.
     */
    fun sample(nowMs: Long, rendered: Int, dropped: Int): String? {
        // -1 is "this engine does not count frames" (mpv, audio-only): never a
        // measurement, so never a baseline either.
        if (rendered < 0) return null
        if (!hasBaseline || rendered < lastRendered || dropped < lastDropped) {
            hasBaseline = true
            lastMs = nowMs
            lastRendered = rendered
            lastDropped = dropped
            return null
        }
        val elapsed = nowMs - lastMs
        if (elapsed < intervalMs) return null

        val renderedDelta = rendered - lastRendered
        val droppedDelta = dropped - lastDropped
        // One decimal: 49.8 vs 50.0 is the difference between "fine" and "a
        // frame lost every five seconds", and rounding to an integer hides it.
        val fps = renderedDelta * 1000.0 / elapsed
        lastMs = nowMs
        lastRendered = rendered
        lastDropped = dropped
        // Locale.ROOT: this is a log line read by whoever receives the export,
        // not UI. A device in a comma-decimal locale would otherwise write
        // `fps=50,0`.
        val rate = String.format(java.util.Locale.ROOT, "%.1f", fps)
        return "fps=$rate rendered=+$renderedDelta " +
            "dropped=+$droppedDelta over ${elapsed}ms"
    }

    /** Forget the baseline — after a decoder rebuild or a reload. */
    fun reset() {
        hasBaseline = false
        lastMs = 0L
        lastRendered = -1
        lastDropped = -1
    }

    companion object {
        /**
         * Long enough that the line is rare in an exported log, short enough to
         * localise a complaint to a part of a session. The ticker it rides on
         * runs at 500ms, so this is one line per ten ticks.
         */
        const val DEFAULT_INTERVAL_MS = 5_000L
    }
}

/**
 * Whether a `MediaCodec` name is one of Android's **software** decoders.
 *
 * `c2.android.*` (Codec2) and `OMX.google.*` are the platform's own software
 * implementations; everything else is a vendor codec, which on a TV means
 * hardware. This matters because `setEnableDecoderFallback(true)` lets media3
 * quietly fall back to the next decoder in the list when the hardware one fails
 * to configure — and a software HEVC decoder cannot sustain 4K50, so the stream
 * plays but crawls. That failure is invisible in every health flag the engine
 * exposes; the decoder's *name* is the only place it shows.
 */
fun isSoftwareDecoder(name: String): Boolean {
    val lower = name.lowercase()
    return lower.startsWith("c2.android.") ||
        lower.startsWith("omx.google.") ||
        lower.startsWith("c2.google.")
}
