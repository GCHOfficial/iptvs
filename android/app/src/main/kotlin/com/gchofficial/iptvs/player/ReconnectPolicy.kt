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
     * Shorter than [NO_FRAME_STALL_MS] because part of the ambiguity that one
     * is being generous about doesn't exist here: the preview was demonstrably
     * rendering a moment ago, the only thing that changed is which surface the
     * decoder outputs to, and the recovery this arms
     * ([PlaybackEngine.rebuildVideoDecoder]) is a local decoder re-init — no
     * provider round trip, no lost buffer.
     *
     * **It was 1.5 s, and that was measured wrong.** The number came from one
     * healthy first frame landing 251 ms after the claim; an exported log from
     * an Amlogic set-top box then showed the *same channel*, on consecutive
     * opens, taking 346 ms and **1830 ms** — the second one perfectly healthy,
     * with its first frame arriving 148 ms after the rebuild this threshold had
     * just fired (i.e. from the decoder that rebuild was throwing away).
     * First-frame latency after an output-surface switch is a wait for the next
     * IDR, and on broadcast MPEG-TS that is a whole GOP; 1.5 s does not clear
     * one, so the watchdog was rebuilding a working decoder on essentially
     * every handoff.
     *
     * The cost of being wrong is deeply asymmetric, which is why this is now
     * generous rather than tight. A false positive is *guaranteed* damage on
     * every handoff — another codec release, another IDR wait, and a
     * dropped-frame catch-up against an audio clock that never stopped, which
     * is exactly the "black screen going fullscreen, then the picture runs
     * behind the sound" report. A false negative costs only latency:
     * [FrameLivenessWatch.armHandoff] leaves `sawProgress` set, so once
     * [HANDOFF_WINDOW_MS] closes the ordinary [NO_FRAME_STALL_MS] clock still
     * catches the freeze and escalates to a reload. Nothing goes undetected —
     * it is only decided later.
     */
    const val HANDOFF_NO_FRAME_STALL_MS = 3_000L

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
     * that drew a frame a second ago and claims to be playing, unbuffered, has
     * drawn another. At any broadcast frame rate it has drawn twenty-five.
     *
     * **Was 500 ms, and a handoff in an exported log fired on it against a
     * decoder reporting `dropped=0 skipped=0 toKeyframe=0 inits=1` — no
     * distress of any kind.** The likeliest reading is the one since fixed at
     * source: the counter was being read across threads without
     * `DecoderCounters.ensureUpdated()`, so "unchanged for half a second" could
     * mean a stale field rather than a stalled decoder (`ExoPlayerEngine`
     * `videoCounters`). Doubling this is the belt to that fix's braces, and it
     * is cheap for the same reason [HANDOFF_NO_FRAME_STALL_MS] is: a missed
     * freeze is still caught by [NO_FRAME_STALL_MS] once the window closes,
     * while a false rebuild is a visible glitch every single time.
     *
     * Not "immediately", because the recovery is still a guess about a decoder,
     * and [ReconnectPolicy.HANDOFF_POLL_MS] makes this eight consecutive
     * identical samples rather than one unlucky scheduling gap.
     */
    const val HANDOFF_POST_FRAME_STALL_MS = 1_000L

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
     *
     * Must stay comfortably clear of [HANDOFF_NO_FRAME_STALL_MS] plus
     * [HANDOFF_POST_FRAME_STALL_MS]: a window that closed before its own clocks
     * could run would silently disable the cheap rung and hand every handoff
     * failure straight to the reload watchdog. Asserted in `ReconnectPolicyTest`.
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
 * 4. **Inside the handoff window, a decoder that is dropping frames is
 *    decoding.** `droppedBufferCount` moving is proof of life that
 *    `renderedOutputBufferCount` alone doesn't carry — the pipeline is alive
 *    and merely behind — and the rebuild that window arms cannot make a decoder
 *    faster. Deliberately scoped to that window; see [sample].
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
    private var lastDropped = NO_SAMPLE
    private var lastProgressAtMs = 0L
    private var sawProgress = false
    private var handoffUntilMs = NO_HANDOFF
    private var handoffArmedAtMs = 0L

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
        lastDropped = NO_SAMPLE
        handoffArmedAtMs = nowMs
        handoffUntilMs = nowMs + handoffWindowMs
        return true
    }

    /**
     * Milliseconds since the [armHandoff] this watch is currently running on,
     * or -1 if it isn't running on one. Reported alongside a recovery so an
     * exported log says how much of the handoff budget had actually elapsed —
     * the number that showed the previous thresholds were firing inside normal
     * first-frame latency rather than after a freeze.
     */
    fun sinceArmMs(nowMs: Long): Long =
        if (handoffUntilMs == NO_HANDOFF) -1L else nowMs - handoffArmedAtMs

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
     *
     * Restarts the progress clock at [nowMs], because the clock this switches
     * onto is documented as "drew, then stopped" and must therefore be measured
     * *from the frame*. It previously kept measuring from whenever the counter
     * last happened to move, which during a deferred claim is preview frames on
     * the old texture — so a handoff could inherit a clock that was already
     * part-spent and be judged frozen having barely drawn.
     */
    fun markHandoffFirstFrame(nowMs: Long) {
        if (handoffUntilMs == NO_HANDOFF) return
        drewSinceHandoff = true
        // NO_SAMPLE rather than a value: the next poll re-seeds both the count
        // and the timestamp together, which is the only pairing that can't
        // disagree with itself.
        lastFrames = NO_SAMPLE
        lastProgressAtMs = nowMs
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
     *
     * [droppedFrames] is `droppedBufferCount`, and **inside the handoff window**
     * it is what separates a renderer that is **wedged** from one that is
     * merely **behind**. A dropped frame was still decoded: the pipeline is
     * alive, it just can't keep up. An Amlogic box on a 4K50 HDR HEVC channel
     * produced exactly that — rendered static across the poll while dropped
     * climbed by 127 — and judging it on `renderedFrames` alone called it
     * frozen and rebuilt the codec. That made it strictly worse: the one open
     * in that log which did *not* rebuild held 49.3 fps with 3 dropped frames,
     * while the session after a rebuild fell to 28.8 fps with 50, and the
     * shared engine carried the damage back into the preview at 11.7 fps.
     *
     * **Scoped to the handoff window on purpose.** The question that window
     * asks is "did the surface swap wedge the decoder?", and frames being
     * dropped answers *no* — so the local rebuild, which cannot make a decoder
     * faster, must not fire. Outside it the question is the older and broader
     * one, "is anything reaching the screen?", and there dropping every frame
     * answers *no* just as a freeze does. A renderer discarding every output
     * buffer as late while the audio clock runs on is a picture frozen
     * indefinitely, and a reload — which restarts at the live edge — genuinely
     * fixes it. Letting the dropped counter hold that clock open would have
     * made this watchdog inert for the exact "sound fine, picture stuck" shape
     * it exists to catch.
     *
     * -1 (an engine that can't report it) simply leaves the old
     * rendered-only judgement in place. The failure this class was written for
     * is untouched: a decoder wedged by a surface swap decodes *nothing*, so
     * neither counter moves.
     */
    fun sample(
        nowMs: Long,
        playingNormally: Boolean,
        renderedFrames: Int,
        droppedFrames: Int = NO_SAMPLE,
    ): Boolean {
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
            lastDropped = droppedFrames
            lastProgressAtMs = nowMs
            return false
        }
        // Seeded on first observation, so the seeding sample can't be mistaken
        // for movement. A caller passing -1 throughout re-seeds to NO_SAMPLE
        // every time and the dropped term stays inert.
        if (lastDropped == NO_SAMPLE) lastDropped = droppedFrames
        val decoderMoved =
            renderedFrames != lastFrames ||
                (inHandoffWindow(nowMs) &&
                    droppedFrames >= 0 &&
                    droppedFrames != lastDropped)
        if (decoderMoved) {
            sawProgress = true
            lastFrames = renderedFrames
            lastDropped = droppedFrames
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
        lastDropped = NO_SAMPLE
        lastProgressAtMs = 0L
        sawProgress = keepHandoff
        // A buffering tick doesn't un-draw the frame the new surface already
        // got, so the shorter post-frame threshold survives it. A real reset
        // (reload / engine swap) forgets the whole handoff, and this with it.
        if (!keepHandoff) {
            handoffUntilMs = NO_HANDOFF
            handoffArmedAtMs = 0L
            drewSinceHandoff = false
        }
    }

    private companion object {
        const val NO_SAMPLE = -1
        const val NO_HANDOFF = 0L
    }
}
