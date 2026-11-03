package com.gchofficial.iptvs.player

import java.util.Locale

/**
 * How far behind the live edge a live stream has drifted, and the strings every
 * surface prints for it.
 *
 * ## Why this exists
 *
 * Live MPEG-TS arrives at 1x and nothing ever gives the time back. Every
 * rebuffer, every pause and every second the app spends in the background adds
 * its own duration to the gap between the broadcast and what is on screen —
 * permanently, because the player simply resumes where it stopped. Before this,
 * `liveSynced` went false on **one** condition: the user pressing pause. A
 * viewer who had drifted ninety seconds through rebuffering therefore saw a red
 * LIVE pill and no "Go to live" chip, which is the shipped bug behind "it's
 * delayed even on live".
 *
 * ## What is measured
 *
 * Drift is wall-clock time that media time did not account for. Each sample
 * compares how far the clock moved (`dWall`) with how far the playhead moved
 * (`dMedia`) and banks the difference. There is deliberately **no cap on
 * `dWall`**: a long gap with no media progress is not a measurement artefact,
 * it is exactly the lag this is trying to report.
 *
 * ## Why drift alone was not the delay
 *
 * Drift counts only what this session added **after its first frame**, and that
 * is not where most of the delay comes from. Providers commonly push a
 * **connect backlog** faster than real time — one measured provider sent ~76 s
 * of it — and playback starts at that backlog's *oldest* frame, on ExoPlayer
 * and on mpv alike, whatever our buffer preset says. A viewer can therefore be
 * a minute behind the broadcast with a perfectly healthy stream and zero drift,
 * which is exactly the session that read `LIVE` while being ≥30 s late.
 *
 * The cushion is the evidence. Media buffered ahead of the playhead has already
 * been received and not yet watched, so `ahead(t) <= delay(t)` at every instant,
 * and with `delay(t) = L0 + drift - credited` that gives
 * `L0 >= ahead + credited - drift`. Taking the running maximum of the
 * right-hand side over the session ([backlogMs]) is therefore a **lower bound**
 * on the delay that was already there at the first frame — it can only be too
 * small, never too large.
 *
 * Two things that would otherwise poison it are handled by the shape of that
 * expression rather than by special cases. A **pause on a 1x provider** queues
 * data while the playhead sits still, so `ahead` rises *together with* `drift`
 * and the bound does not move. A **skip forward inside the cache** (`credit`)
 * is subtracted from the delay but added back into the bound, so the refill
 * that follows it does not read as a second backlog.
 *
 * Two things are not drift and are filtered out rather than banked:
 *  * **A backwards jump** (`dMedia < [DISCONTINUITY_BACK_MS]`) — a reload, a
 *    seek, or a live window that slid under the playhead. The playhead is now
 *    describing a different timeline, so the previous sample is not a reference
 *    for it.
 *  * **Media running ahead of the clock** (`dMedia > dWall +
 *    [DISCONTINUITY_AHEAD_MS]`) — only a seek forward or a timeline change can
 *    do that at 1x, and subtracting it would let a discontinuity *erase*
 *    genuine accumulated lag.
 *
 * Both re-baseline and keep the drift banked so far, so a stream that is
 * reloaded under the tracker loses nothing and invents nothing. Stall counts
 * and buffering time are carried alongside purely as attribution — they explain
 * a drift figure, they never change it.
 *
 * Pure and clock-injected, like [ReconnectPolicy] / [PlaybackStatsSampler], so
 * the whole model is covered by plain JUnit rather than by a device.
 *
 * **Measurement only.** Nothing here touches the buffer presets, the
 * `LoadControl`, `cache-secs`, playback speed, the reconnect policy or the
 * handoff clocks. Its one effect on behaviour is making the existing
 * "Go to live" chip appear when the stream really is behind. The one thing
 * that *does* change playback is [CatchUpPolicy], which is a separate decision
 * on the same ticker; this tracker only reports what it did.
 */
object LiveLatency {
    /**
     * Delay at which the badge starts printing a figure.
     *
     * Half a minute is well past anything a healthy stream accrues (a cushion
     * refill costs a second or two) and is the point at which "live" stops
     * being a true description of what is on screen — a goal is cheered next
     * door before it is shown here.
     *
     * The same number is the drift threshold behind the `liveSynced` latch —
     * see [LiveLatencyTracker.driftBehind] for why the latch reads drift while
     * the badge reads delay.
     */
    const val WARN_MS = 30_000L

    /** A playhead that moves back further than this is a new timeline, not lag. */
    const val DISCONTINUITY_BACK_MS = -500L

    /**
     * Slack for media outrunning the wall clock. Sampling jitter and a position
     * that updates in chunks can legitimately put a tick a little ahead;
     * anything past this is a seek or a timeline change.
     */
    const val DISCONTINUITY_AHEAD_MS = 2_000L

    /** Cadence of the periodic diagnostics line. */
    const val LOG_INTERVAL_MS = 60_000L

    /**
     * Below both of these there is nothing worth a line in an exported log.
     *
     * The first is read against the **delay**, not the drift it started as. A
     * session whose entire delay is a provider's connect backlog has drift 0
     * for its whole length — which is precisely the session this work exists
     * to explain, and under a drift gate it wrote nothing at all unless the
     * cushion happened to be deep at the moment the minute elapsed.
     */
    const val LOG_MIN_DELAY_MS = 5_000L
    const val LOG_MIN_AHEAD_MS = 30_000L

    /**
     * A reset must have measured at least this much drift before [resetLine]
     * is worth printing. Below it a reset is noise — a healthy stream resets
     * with a few tens of milliseconds of ordinary jitter on nearly every
     * reconnect/zap, and an export full of `drift=29ms` lines buries the
     * resets that actually matter. Parity constant with Dart's
     * `kLiveLatencyResetLogMinDriftMs` and Swift's
     * `LiveLatencyLogging.resetLogMinDriftMs`.
     */
    const val RESET_LOG_MIN_DRIFT_MS = 1_000L

    /**
     * `m:ss`, or `h:mm:ss` past an hour. Floors to the second: a delay reported
     * as `0:07` that is really 7.9 s is right either way to the user, and
     * rounding up would make a stream that has drifted nothing at all read
     * `0:01`.
     */
    fun fmtDelay(ms: Long): String {
        val s = (if (ms < 0L) 0L else ms) / 1000L
        return if (s < 3600L) {
            String.format(Locale.ROOT, "%d:%02d", s / 60L, s % 60L)
        } else {
            String.format(Locale.ROOT, "%d:%02d:%02d", s / 3600L, (s % 3600L) / 60L, s % 60L)
        }
    }

    /**
     * The top-bar badge: `LIVE`, or `LIVE -1:23` once past [WARN_MS].
     *
     * The sign is an **ASCII hyphen-minus**, never U+2212: this same string is
     * drawn by the Windows GDI overlay and the Linux ASS renderer, whose fonts
     * are not guaranteed to carry the typographic minus.
     */
    fun badgeLabel(delayMs: Long): String =
        if (delayMs < WARN_MS) "LIVE" else "LIVE -" + fmtDelay(delayMs)

    /**
     * The "Live delay" value for the stream-information panel: the delay, and
     * the cushion that is absorbing network variance behind it.
     *
     * The two together are what make a report actionable — a large delay with a
     * deep buffer is a session that rebuffered once and never caught up, while a
     * large delay with no buffer is a link that is still struggling. An unknown
     * cushion (-1) prints the delay alone rather than a fabricated `0s`.
     */
    fun infoValue(delayMs: Long, aheadMs: Long): String {
        val delay = fmtDelay(delayMs)
        if (aheadMs < 0L) return delay
        // Half away from zero, matching the Dart/Swift/C++ mirrors. aheadMs is
        // non-negative here, so integer rounding is exact and locale-free.
        val seconds = (aheadMs + 500L) / 1000L
        return "$delay · buffer ${seconds}s"
    }

    /**
     * Shared tail of the two periodic log lines. Credential-free by
     * construction — every field is a duration or a count.
     *
     * `drift` is kept beside `delay` rather than replaced by it because the two
     * answer different support questions: `delay` is what the viewer is
     * experiencing, while `drift` is how much of it *this session* caused. A
     * `delay=76000ms drift=0ms` export is a provider that sends a backlog and
     * nothing to fix on the device; `delay=76000ms drift=74000ms` is a link
     * that stalled its way there. `backlog` and `credited` are the two halves
     * that make the arithmetic reproducible from the line alone.
     */
    fun statsLine(
        driftMs: Long,
        delayMs: Long,
        backlogMs: Long,
        creditedMs: Long,
        aheadMs: Long,
        stalls: Int,
        stalledMs: Long,
        discontinuities: Int,
    ): String =
        "live latency drift=${driftMs}ms delay=${delayMs}ms backlog=${backlogMs}ms " +
            "credited=${creditedMs}ms ahead=${aheadMs}ms " +
            "stalls=$stalls stalled=${stalledMs}ms disc=$discontinuities"

    /** The line emitted when a reset throws away a non-zero measurement. */
    fun resetLine(reason: String, driftMs: Long, stalls: Int): String =
        "live latency reset reason=$reason drift=${driftMs}ms stalls=$stalls"
}

/** Why a [LiveLatencyTracker] was reset — the vocabulary of the reset log line. */
object LiveLatencyReset {
    const val LOAD = "load"
    const val RECONNECT = "reconnect"
    const val ZAP = "zap"
    const val GO_LIVE = "golive"
    const val ENGINE = "engine"
    const val CLAIM = "claim"
}

/**
 * The delay tracker itself: fed one sample per host tick, it accumulates
 * [driftMs] / [backlogMs] / [creditedMs], publishes [delayMs], and hands back a
 * log line when one is due.
 *
 * Sampled on the host's existing ticker (500 ms on Android) rather than on a
 * timer of its own — a measurement that needs its own wakeup on a TV box is
 * already too expensive for what it reports.
 */
class LiveLatencyTracker(
    private val warnMs: Long = LiveLatency.WARN_MS,
    private val logIntervalMs: Long = LiveLatency.LOG_INTERVAL_MS,
) {
    /** Delay accumulated since this stream's first progress. */
    var driftMs = 0L
        private set

    /**
     * Delay deliberately given back, and the only thing that ever subtracts.
     *
     * Two sources, both of which had to *happen* before they count: a verified
     * in-cache skip ([credit], the measured jump — not the one that was asked
     * for), and playing faster than real time while the host reports
     * `catchingUp`. Nothing is credited on a tick the host does not claim, so
     * wave 1's "no credit-back" rule still holds everywhere else: media simply
     * running a little ahead of the clock is sampling jitter, not recovery.
     */
    var creditedMs = 0L
        private set

    /**
     * The running lower bound on how far behind live this stream *started* —
     * the provider's connect backlog, in practice.
     *
     * `max` over the session rather than the latest sample, because the bound
     * is only ever evidence: a shallow cushion right now does not disprove a
     * deep one a minute ago, and the delay it implies has not gone anywhere.
     * Monotonic by construction, which is what keeps [delayMs] from
     * oscillating around the badge threshold.
     */
    var backlogMs = 0L
        private set

    /**
     * What the viewer is actually behind the broadcast: the backlog they
     * started with, plus everything this session added, minus what was given
     * back. Floored at 0 — the parts are independent estimates and a
     * generous credit must not print a negative delay.
     *
     * This, not [driftMs], is what the badge and the info row read.
     */
    val delayMs: Long get() = (backlogMs + driftMs - creditedMs).coerceAtLeast(0L)

    /** Transitions into buffering since the last reset (attribution only). */
    var stalls = 0
        private set

    /** Wall time spent buffering since the last reset (attribution only). */
    var stalledMs = 0L
        private set

    /** Samples discarded as a timeline change rather than banked as drift. */
    var discontinuities = 0
        private set

    /**
     * Whether playback has been seen to progress at all.
     *
     * Before it has, drift is 0 by definition: a stream that has not started
     * cannot be behind its own live edge, and the wait for the first frame is
     * the open, not the lag.
     */
    var baselined = false
        private set

    /**
     * "The viewer is behind the live edge" — what the badge prints a figure for
     * and what the `behind` diagnostics line fires on.
     */
    val behind: Boolean get() = delayMs >= warnMs

    /**
     * The narrower, **drift-only** answer the `liveSynced` latch reads on this
     * surface — and the reason the two are separate.
     *
     * "Go to live" on Android reloads the source. That recovers drift (the
     * reload starts at the live edge of what the provider is sending now) but
     * it cannot recover a backlog: the reconnect re-receives the same head
     * start, so the stream comes back exactly as late as it was. ExoPlayer has
     * no trim to offer instead — `ProgressiveMediaPeriod` treats every seek on
     * a non-seekable live source as t=0 — so offering the chip for a backlog
     * delay would be promising a fix that does not exist. Backlog is therefore
     * **shown, not offered**: the badge says how late the picture is, while the
     * chip appears only for the delay a reload can actually remove. What
     * recovers the backlog here is catch-up ([CatchUpPolicy]), which needs no
     * chip and no round trip.
     *
     * The surfaces that *can* trim (every mpv surface Dart drives, and Linux
     * native) latch on the full delay instead — see docs/player.md.
     */
    val driftBehind: Boolean get() = driftMs >= warnMs

    private var hasSample = false
    private var lastWallMs = 0L
    private var lastPosMs = 0L
    private var wasBuffering = false
    private var lastLogMs = 0L
    private var warned = false

    /**
     * One tick. Returns a diagnostics line to emit, or null.
     *
     * [positionMs] is the engine's media position and [aheadMs] its buffered
     * cushion (-1 when the engine cannot report one — it is reported, never
     * guessed, and never used in the *drift* arithmetic; an unknown cushion is
     * skipped by the backlog bound rather than treated as zero).
     *
     * [catchingUp] says the engine ran **faster than real time over the
     * interval that just ended** — the previous tick's decision, not the one
     * about to be taken, because the media/wall difference this sample measures
     * was produced by the speed that was in force while it elapsed.
     */
    fun sample(
        nowMs: Long,
        positionMs: Long,
        isPlaying: Boolean,
        isBuffering: Boolean,
        aheadMs: Long,
        catchingUp: Boolean = false,
    ): String? {
        // Stall attribution first, while lastWallMs still names the previous
        // tick: the time being attributed is the gap *between* samples.
        if (hasSample && wasBuffering) {
            stalledMs += (nowMs - lastWallMs).coerceAtLeast(0L)
        }
        if (isBuffering && !wasBuffering) stalls++
        wasBuffering = isBuffering

        if (!hasSample) {
            // The first sample is a reference point, not a measurement: a delta
            // needs two. Same rule as PlaybackStatsSampler's baseline.
            hasSample = true
            lastWallMs = nowMs
            lastPosMs = positionMs
            lastLogMs = nowMs
            return null
        }

        val dWall = nowMs - lastWallMs
        val dMedia = positionMs - lastPosMs
        if (!baselined) {
            // Baseline on the first tick that is both playing and actually
            // advancing. Everything before it — the open, the first IDR wait,
            // a stream that never starts — is not drift.
            if (isPlaying && dMedia > 0L) baselined = true
        } else if (dMedia < LiveLatency.DISCONTINUITY_BACK_MS ||
            dMedia > dWall + LiveLatency.DISCONTINUITY_AHEAD_MS
        ) {
            // A timeline change. Re-baseline on the new position and keep what
            // has been banked: this tick describes two different timelines, so
            // it measures nothing at all.
            discontinuities++
        } else {
            driftMs += (dWall - dMedia).coerceAtLeast(0L)
            // Media outrunning the clock is only recovery when the host says it
            // asked for it. Unclaimed, the same arithmetic is sampling jitter —
            // and crediting jitter would let a stream that never caught up
            // anything slowly talk its own delay down to zero.
            if (catchingUp) creditedMs += (dMedia - dWall).coerceAtLeast(0L)
        }
        lastWallMs = nowMs
        lastPosMs = positionMs
        // After the drift/credit update, never before: during a pause the
        // cushion grows at the provider's rate while drift grows at the clock's,
        // and measuring the bound against the *old* drift would read that as a
        // deepening backlog instead of the pause it is.
        if (baselined && aheadMs >= 0L) {
            val bound = aheadMs + creditedMs - driftMs
            if (bound > backlogMs) backlogMs = bound
        }

        return logFor(nowMs, isPlaying, isBuffering, aheadMs)
    }

    /**
     * The at-most-one line this tick produces.
     *
     * The first crossing of [warnMs] is reported whatever the stream is doing —
     * it is the moment the session stopped being live, and an export that
     * reaches support needs it even if playback paused in the same second. The
     * periodic line is gated on playing, and on there being something worth
     * saying: a session sitting a few hundred milliseconds behind with a
     * normal cushion would otherwise write a line a minute into every export
     * for no reason. That gate reads the **delay**, so a session whose whole
     * delay is a connect backlog — drift 0 for its entire length — still
     * reports, which under the old drift gate it did not.
     */
    private fun logFor(
        nowMs: Long,
        isPlaying: Boolean,
        isBuffering: Boolean,
        aheadMs: Long,
    ): String? {
        val stats = {
            LiveLatency.statsLine(
                driftMs = driftMs,
                delayMs = delayMs,
                backlogMs = backlogMs,
                creditedMs = creditedMs,
                aheadMs = aheadMs,
                stalls = stalls,
                stalledMs = stalledMs,
                discontinuities = discontinuities,
            )
        }
        if (!warned && delayMs >= warnMs) {
            warned = true
            lastLogMs = nowMs
            return "live latency behind " + stats()
        }
        if (!isPlaying || isBuffering) return null
        if (delayMs < LiveLatency.LOG_MIN_DELAY_MS && aheadMs < LiveLatency.LOG_MIN_AHEAD_MS) {
            return null
        }
        if (nowMs - lastLogMs < logIntervalMs) return null
        lastLogMs = nowMs
        return stats()
    }

    /**
     * Record delay that was deliberately removed, in the amount **measured**
     * after the fact.
     *
     * Unused on Android — ExoPlayer cannot seek forward inside a live
     * progressive source, so this surface's only lever is catch-up — but the
     * tracker is a cross-surface contract and the arithmetic has to be the same
     * everywhere, or an exported log would mean different things on different
     * platforms. The mpv surfaces call it after verifying the jump actually
     * landed.
     */
    fun credit(ms: Long) {
        creditedMs += ms.coerceAtLeast(0L)
    }

    /**
     * Forget everything: a new stream is about to start on this surface.
     *
     * Returns a line to emit when at least [RESET_LOG_MIN_DRIFT_MS] of drift is
     * being discarded — an export that shows a reload at 90 s of drift says far
     * more than one that shows a reload. Returns null below that threshold,
     * which includes the ordinary jitter of a few tens of milliseconds a
     * healthy stream resets with on nearly every open or zap.
     */
    fun reset(reason: String): String? {
        val line = if (driftMs >= LiveLatency.RESET_LOG_MIN_DRIFT_MS) {
            LiveLatency.resetLine(reason, driftMs, stalls)
        } else {
            null
        }
        driftMs = 0L
        // The backlog belonged to the connection that is being replaced: the
        // next one gets its own head start, measured from its own cushion.
        backlogMs = 0L
        creditedMs = 0L
        stalls = 0
        stalledMs = 0L
        discontinuities = 0
        baselined = false
        hasSample = false
        lastWallMs = 0L
        lastPosMs = 0L
        wasBuffering = false
        lastLogMs = 0L
        warned = false
        return line
    }
}
