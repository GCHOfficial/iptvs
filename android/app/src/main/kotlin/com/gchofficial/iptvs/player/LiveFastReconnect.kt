package com.gchofficial.iptvs.player

/**
 * Pure decisions for the **pre-resolved** live reconnect — the fast path that
 * turns a provider's mid-session disconnect from a ~4 s black screen into a
 * reload with no waiting in front of it.
 *
 * ### The shape it answers
 *
 * A user's 0.1.80 export (Stalker portal, Android TV, ExoPlayer, adopted
 * fullscreen) shows one `itv:create_link` connection carrying ~25.6 s of media
 * in ~6 s and then closing the HTTP body — `stream source eof sinceLoadMs=6032
 * ahead=21011 played=4580 bytes=8649536`. Playback runs on from the buffer at a
 * steady 50 fps for the next ~20 s, the renderer reaches `STATE_ENDED` when the
 * cushion finally runs dry, and only *then* does the watchdog start work:
 * [ReconnectPolicy.ENDED_RECONNECT_MS] (2 s), a `create_link` round trip
 * (~0.4 s), and 1.1–1.5 s to the first frame. Roughly four seconds of frozen
 * picture, every twenty-six, on a stream that was never in trouble.
 *
 * Three of those four seconds are spent on work that could have been done
 * while the picture was still running. The body closed twenty seconds before
 * anyone needed a new locator, and **[StreamEofPolicy]'s `onLoadCompleted` hook
 * already knows the exact instant it did**. So the Activity asks for the next
 * locator *then*, stores it, and when the buffer finally runs dry it loads it
 * immediately: no 2 s ended-threshold, no round trip.
 *
 * ### Why pre-resolving is safe where a speculative `create_link` would not be
 *
 * It is issued **after the server has already closed the body**. There is no
 * live connection left for a new link to disturb, which is what separates this
 * from "resolve ahead of time" — the practice CLAUDE.md forbids ("Resolve
 * streams at play time, never ahead", because Stalker `create_link` URLs are
 * short-lived). The locator is still resolved for an imminent *reload*, not
 * cached against a future tap, and [FRESH_MS] bounds how imminent that has to
 * be. Re-resolving while a stream plays is also already shipped behaviour:
 * "Go to live" does exactly that.
 *
 * ### What it deliberately does not touch
 *
 * None of [ReconnectPolicy]'s constants move. This is an **additional** path:
 * when there is no fresh pre-resolved locator — a stall rather than a drop, a
 * forced error reconnect, an mpv fallback, a cushion that took longer than
 * [FRESH_MS] to drain — the watchdog behaves exactly as it did before.
 *
 * Android-free so the plain-JUnit harness can pin it, like [ReconnectPolicy],
 * [StreamEofPolicy] and [ZapKeyPolicy] (`LiveFastReconnectTest`).
 */
object LiveFastReconnectPolicy {
    /**
     * How old a stored locator may be when the reload finally needs it.
     *
     * Bounded **below** by the drain it has to survive. In the evidence the
     * body closes at ~6 s with `ahead=21011`, so the locator is ~20 s old when
     * it is used; that drain is the size of the **backlog the connection
     * delivered**, which in turn is capped by the preset's `maxBufferMs`
     * ([ExoPlayerEngine.Durations]: 25 / 50 / 90 / 120 s). 30 s therefore
     * clears the observed case and the whole of `low`, with margin.
     *
     * Bounded **above** by what a portal-minted link plausibly outlives:
     * Stalker `play_token`s are single-use and short-lived. Stretching this to
     * cover `max`'s 120 s ceiling would mean loading a two-minute-old token —
     * precisely where a single-use link is most likely already dead — to save
     * a round trip, which is the wrong trade.
     *
     * The gap this used to leave — a backlog deeper than 30 s draining for
     * longer than the bound, so the stored locator went stale and was
     * re-resolved — is closed by [PRE_RESOLVE_AHEAD_MS]: the request is no
     * longer made at the EOF but when the cushion behind it is nearly spent,
     * so the locator's age at the reload is bounded by *that* and not by the
     * backlog's size. 30 s now has margin over a 10 s trigger on every preset.
     */
    const val FRESH_MS = 30_000L

    /**
     * How much cushion may remain when the pre-resolve is finally requested.
     *
     * **The trigger is the remaining buffer, not the EOF.** The EOF is still
     * the thing that *permits* a request — a `create_link` while the body is
     * open could kill it on a single-connection account, which is the whole
     * reason [shouldPreResolve] exists — but on this provider the body closes
     * ~27 s before anyone needs the next locator, and a token minted at the
     * EOF spends all of that age before it is used. On a deep preset it could
     * outlive [FRESH_MS] entirely and be thrown away, which is the
     * `path=resolve ageMs=32089` line in the 0.1.81 export: a wasted
     * `create_link` *and* a cold reconnect.
     *
     * 10 s is sized from the two things that have to fit inside it: the
     * re-resolve round trip (~0.4 s observed, backstopped at
     * [ResolveGate.TIMEOUT_MS]) and, when a stitched handover is armed, the
     * candidate evaluation that follows it — which must still reach a verdict
     * with [LiveStitchPolicy.STITCH_ABORT_AHEAD_MS] of cushion to spare.
     */
    const val PRE_RESOLVE_AHEAD_MS = 10_000L

    /**
     * A pre-resolved reconnect that ends again within this much playback was
     * not a working connection.
     *
     * The healthy cycle in the evidence is ~26 s of playback per connection, so
     * anything under 8 s cannot be confused with a short-but-working one. It is
     * also the existing policy's own notion of a connection that isn't working:
     * [ReconnectPolicy.STALL_RECONNECT_MS] is how long buffering has to last
     * before the watchdog gives up on a stream. Kept as its own constant rather
     * than a reference to it — they agree by reasoning, not by dependency, and
     * this one must stay free to move without retuning the stall watchdog.
     */
    const val FAILURE_WINDOW_MS = 8_000L

    /**
     * Consecutive short-lived pre-resolved reconnects before the fast path
     * stands down for the rest of the session.
     *
     * One is noise — a portal hiccup the ordinary path would also have hit.
     * Two can still be a flaky link. Three in a row, with no intervening
     * connection that survived [FAILURE_WINDOW_MS], is a portal that does not
     * honour a link minted before the previous one drained, and no further
     * evidence is going to arrive. The asymmetry favours patience: a wrong fast
     * path costs one wasted load and one wasted `create_link`, while disabling
     * too eagerly gives up the whole fix on a portal that merely blipped.
     */
    const val MAX_CONSECUTIVE_FAILURES = 3

    /**
     * Whether a source-EOF may be answered with a pre-resolve request.
     *
     * [holdsLocator] is the one-per-connection rule: a progressive load can
     * complete more than once (media3 retries a loadable), and each extra
     * request would spend another single-use `play_token` for a reload that
     * only needs one. [resolveInFlight] respects the single-connection
     * invariant the [ResolveGate] exists for; [zapSettling] stands down because
     * Dart is already replacing this stream with a different channel.
     */
    fun shouldPreResolve(
        isLive: Boolean,
        enabled: Boolean,
        holdsLocator: Boolean,
        resolveInFlight: Boolean,
        zapSettling: Boolean,
    ): Boolean = isLive && enabled && !holdsLocator && !resolveInFlight && !zapSettling

    /**
     * Whether the request is **due yet**, given that the body has closed
     * ([eofSeen]) and [aheadMs] is still buffered ahead of the playhead.
     *
     * Separate from [shouldPreResolve] rather than folded into it because the
     * two answer different questions and are read at different moments:
     * `shouldPreResolve` is the standing eligibility of the *session* (checked
     * once, at the request), while this is the trigger the 500 ms ticker
     * re-asks every tick. Keeping them apart is also what lets the EOF itself
     * call both — a body that closes with the cushion already below the bound
     * must request immediately rather than wait a tick.
     *
     * A negative [aheadMs] is "the engine can't say" ([PlaybackEngine.bufferedAheadMs]),
     * and it is treated as **due**: the body has demonstrably closed, and an
     * engine that cannot report its cushion must not be able to postpone the
     * request forever.
     */
    fun isPreResolveDue(
        eofSeen: Boolean,
        aheadMs: Long,
        aheadLimitMs: Long = PRE_RESOLVE_AHEAD_MS,
    ): Boolean = eofSeen && (aheadMs < 0L || aheadMs <= aheadLimitMs)

    /** Whether a locator of [ageMs] is still worth loading without re-resolving. */
    fun isFresh(ageMs: Long, freshMs: Long = FRESH_MS): Boolean = ageMs in 0L..freshMs

    /**
     * Whether this reconnect should load the stored locator instead of taking
     * the ordinary wait-then-re-resolve path.
     *
     * Scoped to a **clean drop** (`kind=ended`), never to a stall and never to
     * a [forced] error reconnect. A buffering or frozen-renderer stall means
     * the connection is still open and the server never closed anything — a
     * locator minted at some earlier EOF is not what that failure needs, and
     * spending it there would throw away a single-use token on a guess.
     */
    fun shouldUsePreResolved(
        endedDrop: Boolean,
        forced: Boolean,
        enabled: Boolean,
        holdsLocator: Boolean,
        ageMs: Long,
        freshMs: Long = FRESH_MS,
    ): Boolean = endedDrop && !forced && enabled && holdsLocator && isFresh(ageMs, freshMs)

    /**
     * Whether a pre-resolved reconnect that has now ended again counts against
     * the fast path. [playedMs] is wall time from the fast load to the next
     * reconnect decision.
     *
     * Measuring at the next reconnect decision is deliberate and complete: a
     * pre-resolved locator the portal refuses produces a connection that ends
     * (or errors) within seconds, and *every* such ending arrives at
     * `reconnectLive`. There is no failure shape that skips it.
     */
    fun isFastPathFailure(playedMs: Long, failureWindowMs: Long = FAILURE_WINDOW_MS): Boolean =
        playedMs < failureWindowMs

    /** Whether [consecutiveFailures] is enough to stand the fast path down. */
    fun shouldBackOff(
        consecutiveFailures: Int,
        maxConsecutiveFailures: Int = MAX_CONSECUTIVE_FAILURES,
    ): Boolean = consecutiveFailures >= maxConsecutiveFailures

    // ── Diagnostics lines ────────────────────────────────────────────────────
    //
    // Credential-free by construction: every field is a number or a boolean,
    // and the locator itself never appears in any of them (see [LiveLocator]).
    // Formatted here, beside the decisions, so the exported vocabulary is
    // pinned by the same plain-JUnit test.

    /**
     * Written when the request is issued. [sinceLoadMs] describes the *EOF*
     * that permitted it (the field 0.1.81 printed); `ahead=` is the cushion
     * that triggered it, i.e. the direct read-out of [isPreResolveDue] — the
     * gap between the two is how long the request deliberately waited after
     * the body closed.
     */
    fun requestedLine(sinceLoadMs: Long, aheadMs: Long): String =
        "live pre-resolve requested sinceLoadMs=$sinceLoadMs ahead=$aheadMs"

    /**
     * Written when the request settles. [ageMs] is measured from the request,
     * i.e. the age the locator *already has* when it lands — the head start the
     * round trip cost. `ok=false` means nothing is held: a timeout, a reply
     * carrying no new URL, or a request the session has since moved past.
     */
    fun readyLine(ageMs: Long, ok: Boolean): String =
        "live pre-resolve ready ageMs=$ageMs ok=$ok"

    /** Written once, when the back-off stands the fast path down. */
    fun backOffLine(failures: Int, playedMs: Long): String =
        "live pre-resolve disabled failures=$failures playedMs=$playedMs"

    /**
     * The fields appended to the reconnect line so an export says which path a
     * reconnect took and, for a stale one, how stale it was (`ageMs=-1` when
     * nothing was held at all).
     */
    fun reconnectPath(usedPreResolved: Boolean, ageMs: Long): String =
        "path=${if (usedPreResolved) "preresolved" else "resolve"} ageMs=$ageMs"
}

/** What [LiveFastReconnect.noteReconnect] made of the previous fast load. */
enum class FastReconnectOutcome {
    /** Nothing was being judged (the last reload took the ordinary path). */
    NONE,

    /** The pre-resolved connection outlived [LiveFastReconnectPolicy.FAILURE_WINDOW_MS]. */
    SURVIVED,

    /** It did not, and the fast path is still enabled. */
    FAILED,

    /** It did not, and that was the last one — the fast path is now off. */
    BACKED_OFF,
}

/**
 * Session state for the fast reconnect path: the one pre-resolved locator, its
 * age, and the consecutive-failure streak that can switch the whole thing off.
 *
 * One instance per `HdrPlayerActivity`. The store holds **at most one**
 * locator and every reload consumes or discards it ([takeForReload]), because a
 * Stalker `play_token` is single-use and a locator that outlives the reload it
 * was minted for is only an opportunity to play a dead URL.
 *
 * Deliberately Android-free and free of timers: the Activity's existing 500 ms
 * progress ticker supplies every `nowMs`.
 */
class LiveFastReconnect(
    private val freshMs: Long = LiveFastReconnectPolicy.FRESH_MS,
    private val failureWindowMs: Long = LiveFastReconnectPolicy.FAILURE_WINDOW_MS,
    private val maxConsecutiveFailures: Int = LiveFastReconnectPolicy.MAX_CONSECUTIVE_FAILURES,
) {
    private var stored: LiveLocator? = null

    // When the request that produced [stored] was *issued*, not when its reply
    // landed. The portal mints the token somewhere inside that window, so the
    // earlier end is the conservative one — and it keeps the age on the
    // `ready` line and the age on the reconnect line on a single clock.
    //
    // **[noteRequested] is the only writer of a meaningful value, and
    // `stored == null` is the only test for "nothing held".** This field has no
    // sentinel: zero is a legitimate clock reading, so any code reading `== 0L`
    // as "no request recorded" cannot tell that apart from a request issued at
    // time zero — which is exactly how [store] used to move the age clock
    // forward to the reply and let a 30-second-stale locator read as fresh.
    private var requestedAtMs = 0L

    private var disabled = false
    private var consecutiveFailures = 0

    // Identifies the pre-resolve request currently outstanding. Bumped by
    // every [noteRequested] *and* by [discard], so a reply that settles after
    // the session has moved on (a zap, an engine fallback, a finish) is dropped
    // by token comparison rather than quietly re-stocking the store — the same
    // discipline `ResolveGate` and `ChannelHandlerOwner` use.
    private var requestToken = 0L

    // The fast load currently awaiting judgement, or [NO_LOAD].
    private var fastLoadAtMs = NO_LOAD

    /** False once the back-off has stood the fast path down for this session. */
    val enabled: Boolean get() = !disabled

    /** Whether a pre-resolved locator is being held. */
    val holdsLocator: Boolean get() = stored != null

    /** Age of the held locator, or -1 when none is held. */
    fun ageMs(nowMs: Long): Long = if (stored == null) -1L else nowMs - requestedAtMs

    /**
     * Whether a reconnect decided at [nowMs] *would* take the fast path — the
     * non-consuming form of [takeForReload], read by the watchdog when it sizes
     * the ended threshold (a fast path with nothing to wait for waits zero).
     */
    fun readyFor(nowMs: Long, endedDrop: Boolean, forced: Boolean): Boolean =
        LiveFastReconnectPolicy.shouldUsePreResolved(
            endedDrop = endedDrop,
            forced = forced,
            enabled = !disabled,
            holdsLocator = stored != null,
            ageMs = ageMs(nowMs),
            freshMs = freshMs,
        )

    /**
     * Records that a pre-resolve request has been issued at [nowMs] and returns
     * the token its [store] must quote. The age clock starts here rather than
     * at the reply (see [requestedAtMs]).
     */
    fun noteRequested(nowMs: Long): Long {
        requestedAtMs = nowMs
        return ++requestToken
    }

    /**
     * Stores the outcome of the pre-resolve identified by [token], and reports
     * whether anything usable is now held.
     *
     * [locator] is null when the round trip produced no *new* URL — a timeout,
     * an unreadable reply, or a Flutter host that answered with the locator we
     * already hold. Storing that would be worse than storing nothing: the fast
     * path would then skip both the wait and the re-resolve in order to reload
     * a URL already known to be spent. A stale [token] (a discard or a newer
     * request has intervened) reports false for the same reason — nothing is
     * held — which is all the `ok=` field on the diagnostics line claims.
     *
     * **Takes no clock.** The age clock belongs to [noteRequested] and this must
     * not touch it: the age the reconnect judges has to *include* the round
     * trip, because that is time the portal's token has already spent. A
     * settle-time reading here would under-report the age by exactly the round
     * trip, and (through the token check below) can only ever follow a
     * [noteRequested] that has already stamped it.
     */
    fun store(token: Long, locator: LiveLocator?): Boolean {
        if (token != requestToken) return false
        if (disabled || locator == null) {
            stored = null
            return false
        }
        stored = locator
        return true
    }

    /**
     * Hands the stored locator to a reload when it is the right answer for
     * this reconnect, and **always clears the store either way**.
     *
     * Consume-or-discard, not consume-or-keep: any reload supersedes the
     * locator, so one left behind by a stall or a forced reconnect would only
     * age toward being loaded dead later.
     */
    fun takeForReload(nowMs: Long, endedDrop: Boolean, forced: Boolean): LiveLocator? {
        val usable = readyFor(nowMs, endedDrop, forced)
        val held = stored
        stored = null
        requestedAtMs = 0L
        requestToken++
        if (!usable) {
            fastLoadAtMs = NO_LOAD
            return null
        }
        fastLoadAtMs = nowMs
        return held
    }

    /**
     * Judges the previous fast load, if one is awaiting judgement, against the
     * reconnect now being decided at [nowMs]. Call once per reconnect, before
     * [takeForReload].
     */
    fun noteReconnect(nowMs: Long): FastReconnectOutcome {
        val loadedAt = fastLoadAtMs
        fastLoadAtMs = NO_LOAD
        if (loadedAt == NO_LOAD) return FastReconnectOutcome.NONE
        lastJudgedPlayedMs = nowMs - loadedAt
        if (!LiveFastReconnectPolicy.isFastPathFailure(lastJudgedPlayedMs, failureWindowMs)) {
            consecutiveFailures = 0
            return FastReconnectOutcome.SURVIVED
        }
        consecutiveFailures++
        if (!LiveFastReconnectPolicy.shouldBackOff(consecutiveFailures, maxConsecutiveFailures)) {
            return FastReconnectOutcome.FAILED
        }
        disabled = true
        discard()
        return FastReconnectOutcome.BACKED_OFF
    }

    /** Consecutive short-lived pre-resolved reconnects, for the back-off line. */
    fun failures(): Int = consecutiveFailures

    /**
     * How long the most recently judged fast load survived, in ms — the number
     * the back-off line prints to say *how* short "short" was.
     */
    var lastJudgedPlayedMs: Long = -1L
        private set

    /**
     * Drops the stored locator without using it — a zap, "Go to live", an
     * engine fallback, a stop or a finish. Each of those either replaces the
     * stream deliberately or ends it, and in both cases the held token belongs
     * to a reload that is never going to happen.
     */
    fun discard() {
        stored = null
        requestedAtMs = 0L
        fastLoadAtMs = NO_LOAD
        requestToken++
    }

    private companion object {
        const val NO_LOAD = -1L
    }
}
