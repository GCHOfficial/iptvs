package com.gchofficial.iptvs.player

import java.util.Locale

/**
 * Pure decisions, constants and exported vocabulary for the **stitched
 * handover** — the path that turns a provider's per-connection live link
 * rotation from a visible freeze into nothing at all.
 *
 * ### The shape it answers
 *
 * A Stalker provider closes each live MPEG-TS body after a ~20–30 s backlog
 * burst plus 6–18 s of real time. 0.1.81's [LiveFastReconnectPolicy] already
 * removed the round trip and the ended threshold from the recovery, which left
 * ~2 s of frozen picture per cycle: a reload is a new `MediaSource`, a new
 * extractor, a new decoder and a new wait for an IDR, and none of that is
 * something a pre-resolved locator can shorten. The only way to reach zero is
 * for the player never to learn the link closed — which is what [TsSplicer]
 * and `StitchingDataSource` do, and what this object states the rules for.
 *
 * Android-free and media3-free so the plain-JUnit harness pins it
 * (`LiveStitchPolicyTest`), exactly like [ReconnectPolicy], [StreamEofPolicy]
 * and [LiveFastReconnectPolicy].
 */
object LiveStitchPolicy {
    /**
     * The session kill switch.
     *
     * A compile-time constant rather than a setting: it exists so one commit
     * can take the whole path out of a release if an export shows it misbehaves
     * on hardware nobody here can run, and a `const val false` makes every
     * branch below unreachable and strippable. It is **not** a user-facing
     * control — a user cannot tell a stitched handover from a healthy stream,
     * which is the point.
     */
    const val ENABLED = true

    /**
     * How much cushion may remain before a handover gives up and lets the
     * ordinary reconnect have the stream.
     *
     * Two things are bounded by this number and they pull the same way. It is
     * the *latest* a fallback may be decided, because everything after it is
     * frozen picture that 0.1.81 would not have had; and it is the margin that
     * keeps the "never two connections" promise, because the candidate's own
     * socket timeouts ([CANDIDATE_READ_TIMEOUT_MS], [CANDIDATE_CONNECT_TIMEOUT_MS])
     * are how long a wedged candidate can still be holding its connection open
     * after the abort is raised. Both of those are strictly smaller, so the
     * candidate is closed before the drained player's reload opens its own —
     * asserted in `LiveStitchPolicyTest`.
     *
     * There is a third thing riding on the same inequality, and it is the one
     * that would be expensive to get wrong. A held read means the loadable has
     * **not** completed, so a player that runs out of cushion while a handover
     * is still parked reaches `STATE_BUFFERING` rather than `STATE_ENDED` —
     * which the watchdog answers on [ReconnectPolicy.STALL_RECONNECT_MS] (8 s)
     * and without the pre-resolved fast path, because that is scoped to a clean
     * drop. The margin above is what keeps end of input reaching the extractor
     * with cushion to spare, so the stream still ends the way every other
     * version of it ends.
     */
    const val STITCH_ABORT_AHEAD_MS = 2_500L

    /**
     * Socket timeouts for a **candidate** link only. The link the player is
     * already reading keeps media3's defaults; nothing about the ordinary path
     * moves.
     *
     * Deliberately far below the defaults (8 s each). A candidate is opened
     * against a portal that answered a `create_link` moments ago and is about
     * to dump a backlog faster than real time — if its first bytes have not
     * arrived in 1.5 s, waiting longer only eats the cushion that the fallback
     * needs in order to still be invisible. And see [STITCH_ABORT_AHEAD_MS]:
     * a blocking read is the one thing an abort cannot interrupt, so its
     * ceiling is what bounds how long a wedged candidate can overlap the
     * reload that follows.
     */
    const val CANDIDATE_CONNECT_TIMEOUT_MS = 1_500

    /** See [CANDIDATE_CONNECT_TIMEOUT_MS]. */
    const val CANDIDATE_READ_TIMEOUT_MS = 1_500

    /**
     * Consecutive **structural** fallbacks before stitching stands down for
     * the session.
     *
     * Two, because a structural rejection is a statement about the *shape of
     * the stream*, and that does not change between one of a provider's links
     * and the next: a PMT that disagrees, a renumbered PTS window, a GOP with
     * no IDR inside the skip budget. One can be a genuinely odd link (an
     * advert insertion, a brief encoder restart); two in a row is the
     * provider's normal output, and every further attempt costs a candidate
     * connection and — on the deadline path — burns the cushion down to
     * [STITCH_ABORT_AHEAD_MS] before giving up, which is *worse* than 0.1.81's
     * timing rather than merely no better.
     */
    const val MAX_CONSECUTIVE_STRUCTURAL_FAILURES = 2

    /**
     * Consecutive **transient** fallbacks before the same stand-down.
     *
     * Deliberately more tolerant than [MAX_CONSECUTIVE_STRUCTURAL_FAILURES],
     * because these say nothing about whether the stream can be spliced: a
     * candidate that refused to open, or that ended before it had delivered a
     * splice point, is the same network or portal condition the *reconnect*
     * would have hit anyway. Disabling the whole path on two bad minutes of
     * Wi-Fi would give up a working feature for the rest of a session on
     * evidence that is not about the feature. Four in a row with no commit
     * between them is a portal that will not serve a second link at all, and
     * at that point the attempts are pure waste.
     */
    const val MAX_CONSECUTIVE_TRANSIENT_FAILURES = 4

    // ── Fallback reasons ─────────────────────────────────────────────────────
    //
    // A fixed vocabulary, because an export is grepped. Anything coming out of
    // the splicer arrives as a [SpliceRejectReason.token]; everything below is
    // a failure of the handover *machinery* rather than of the splice.

    /** A splice committed; nothing to explain. */
    const val REASON_NONE = "none"

    /** The cushion reached [STITCH_ABORT_AHEAD_MS] with no commit. */
    const val REASON_DEADLINE = "deadline"

    /** The candidate link could not be opened. */
    const val REASON_OPEN_FAILED = "open-failed"

    /** The candidate's body ended (or stalled out) before a splice point. */
    const val REASON_CANDIDATE_EOF = "candidate-eof"

    /** The pre-resolve answered with the locator we already had. */
    const val REASON_SAME_URL = "same-url"

    /** The pre-resolve timed out, or produced nothing usable. */
    const val REASON_RESOLVE_FAILED = "resolve-failed"

    /** No locator supply: the pre-resolved reconnect has backed off. */
    const val REASON_DISABLED = "disabled"

    /** The session moved on under the handover (zap, reload, finish, handback). */
    const val REASON_CANCELLED = "cancelled"

    /** `mechanism=` on the handover line. */
    const val MECHANISM_SPLICE = "splice"

    /** `mechanism=` on the handover line. */
    const val MECHANISM_FALLBACK = "fallback"

    /**
     * Whether [reason] is a statement about the stream's shape (as opposed to
     * about the network, the portal, or this session's own bookkeeping).
     *
     * Everything [TsSplicer] can reject with is structural by construction —
     * it only ever rejects on what it read — so the rule is "came from the
     * splicer". Stated as a membership test over [SpliceRejectReason] rather
     * than a list of strings so a *new* reject reason cannot be added without
     * landing on one side of this judgement; `LiveStitchPolicyTest` asserts
     * every token is classified.
     */
    fun isStructuralFailure(reason: String): Boolean =
        SpliceRejectReason.entries.any { it.token == reason }

    /**
     * Whether [reason] is a network/portal condition — worth retrying, but
     * only so many times (see [MAX_CONSECUTIVE_TRANSIENT_FAILURES]).
     */
    fun isTransientFailure(reason: String): Boolean =
        reason == REASON_OPEN_FAILED || reason == REASON_CANDIDATE_EOF

    /**
     * [REASON_DEADLINE] and the three locator-supply reasons count against
     * neither streak.
     *
     * A deadline means the *locator* did not arrive in time, which is the
     * pre-resolve path's business and already has its own back-off
     * ([LiveFastReconnect]); a cancellation is this session deliberately
     * replacing the stream. None of them is evidence about splicing, and
     * counting them would disable the path on exactly the sessions where the
     * portal is slow rather than where the stream is unspliceable.
     */
    fun countsAgainstSession(reason: String): Boolean =
        isStructuralFailure(reason) || isTransientFailure(reason)

    /** Whether a handover still without a commit must be abandoned now. */
    fun shouldAbortHandover(aheadMs: Long): Boolean = aheadMs <= STITCH_ABORT_AHEAD_MS

    // ── Diagnostics lines ────────────────────────────────────────────────────
    //
    // Credential-free by construction: every field is a number, a boolean or a
    // token from the fixed vocabulary above. The locator never appears in any
    // of them, and neither do the headers. Formatted here, beside the
    // decisions, so the exported vocabulary is pinned by the same plain-JUnit
    // test (the discipline [LiveFastReconnectPolicy] already follows).

    /**
     * One line per link close where a stitch was considered. The field set is
     * **fixed** — unused fields read `-1` or `0` rather than being omitted —
     * because an export is grepped by column, not parsed.
     */
    fun handoverLine(
        link: Int,
        mechanism: String,
        reason: String,
        durationMs: Long,
        aheadAtCommitMs: Long,
        trimmedMs: Long,
        skippedMs: Long,
        repeatedMs: Long,
        droppedBytes: Long,
    ): String = String.format(
        Locale.US,
        "live handover link=%d mechanism=%s reason=%s durationMs=%d aheadAtCommitMs=%d " +
            "trimmedMs=%d skippedMs=%d repeatedMs=%d droppedBytes=%d",
        link,
        mechanism,
        reason,
        durationMs,
        aheadAtCommitMs,
        trimmedMs,
        skippedMs,
        repeatedMs,
        droppedBytes,
    )

    /** The fallback shape of [handoverLine], where no splice figures exist. */
    fun fallbackLine(link: Int, reason: String, durationMs: Long): String = handoverLine(
        link = link,
        mechanism = MECHANISM_FALLBACK,
        reason = reason,
        durationMs = durationMs,
        aheadAtCommitMs = -1L,
        trimmedMs = 0L,
        skippedMs = 0L,
        repeatedMs = 0L,
        droppedBytes = 0L,
    )

    /**
     * Written once per link at the moment the wrapping `DataSource` arms on it.
     * `spliceable=pending` for a link that has yet to be parsed; `true` for one
     * that arrived *through* a commit, whose shape is already known.
     */
    fun armedLine(link: Int, spliceable: String): String =
        "live stitch armed link=$link spliceable=$spliceable"

    /**
     * Written once per link when the splicer reaches a verdict on it — the
     * line that lets an export prove why a session never stitched, as opposed
     * to leaving it indistinguishable from one where nothing was ever tried.
     */
    fun spliceableLine(link: Int, spliceable: Boolean, reason: String): String =
        "live stitch link=$link spliceable=$spliceable reason=$reason"

    /** Written once, when the session rule stands stitching down. */
    fun disabledLine(failures: Int, reason: String): String =
        "live stitch disabled failures=$failures reason=$reason"

    /**
     * The fields appended to the existing `live reconnect …` line.
     *
     * `mechanism=reconnect` is there so the two ways a live link can be
     * replaced read as one vocabulary — a committed splice writes
     * `mechanism=splice` on its own line and deliberately writes no reconnect
     * line at all, and an export that counts `mechanism=` therefore counts
     * every link rotation in the session. `after=fallback:<reason>` attributes
     * a reconnect that a handover tried and failed to avoid, which is the
     * difference between "stitching is off" and "stitching ran and lost".
     */
    fun reconnectMechanism(afterFallbackReason: String?): String =
        if (afterFallbackReason == null) {
            "mechanism=reconnect"
        } else {
            "mechanism=reconnect after=fallback:$afterFallbackReason"
        }
}

/** What [StitchCoordinator.awaitLocator] came back with. */
sealed interface StitchHandover {
    /** The host handed over the next link's locator; evaluate it. */
    data class Offered(val locator: LiveLocator) : StitchHandover

    /** Give up on this handover and let the ordinary reconnect have it. */
    data class Aborted(val reason: String) : StitchHandover
}

/** What [StitchCoordinator.arm] grants a `DataSource` that may stitch. */
data class StitchArming(val session: Long, val link: Int)

/**
 * The rendezvous between the media3 loader thread (which owns the byte stream
 * and blocks at a link's end of input) and `HdrPlayerActivity`'s main thread
 * (which owns the re-resolve and every reason a handover must be abandoned).
 *
 * It is the only thing the two threads share, and it holds three kinds of
 * state:
 *
 *  1. **Whether a load may stitch at all** ([arm]) — the conservative gate
 *     described in docs/player.md. A `DataSource` that is not armed is a
 *     byte-for-byte delegate and nothing about the shipped path changes.
 *  2. **The hand-off itself** ([awaitLocator] / [offer] / [abort]) — one
 *     waiter at a time, identified by a monotonic session token so a locator
 *     meant for a load the session has moved past can never be applied to the
 *     one that replaced it (the discipline `ResolveGate`, `LiveFastReconnect`
 *     and `ChannelHandlerOwner` all use).
 *  3. **The session's own patience** ([noteFallback]) — two consecutive
 *     structural failures, or four transient ones, and the path stands down
 *     for the rest of the session.
 *
 * Deliberately Android-free and media3-free: the threading rules are the part
 * most worth pinning and the plain-JUnit harness can drive them with ordinary
 * threads (`StitchCoordinatorTest`). It starts no thread of its own — the
 * loader thread blocks on this monitor, which is why there is no executor here
 * and nothing for `DebugCounters` to count.
 */
class StitchCoordinator(
    /**
     * Where the exported lines go. Called **without** the monitor held, and
     * from either thread, so the host's own sink owns the thread hop.
     */
    private val diagnostics: (String) -> Unit,
) {
    private val lock = Object()

    // ── Session state (guarded by `lock`) ────────────────────────────────────

    /**
     * Monotonic, and the whole of "does this still belong to the load that
     * started it". Bumped by [noteLoad] and [cancel]; never 0, so a non-null
     * [StitchArming] always carries a usable token.
     */
    private var session = 1L

    private var expectedUrl: String? = null
    private var live = false

    /**
     * The arming rule's one piece of *evidence*: a pre-resolve for this
     * session has answered with a different URL.
     *
     * This is how the native side scopes stitching to providers that rotate
     * their locators without knowing what a provider *is*. An Xtream or M3U
     * source re-resolves to the same URL, reports `refreshed=false` forever,
     * and is therefore never armed — so its links keep today's path with no
     * kind-specific branch anywhere in Kotlin. The cost is that a rotating
     * provider's **first** link does not stitch either, which is the right way
     * round: the first link is also the one with no stored locator to splice
     * from.
     */
    private var rotationProven = false

    private var disabled = false
    private var structuralFailures = 0
    private var transientFailures = 0
    private var links = 0

    // ── The rendezvous (guarded by `lock`) ───────────────────────────────────

    /** The session currently waiting for, or evaluating, a locator. 0 = none. */
    private var waiterSession = 0L
    private var evaluating = false
    private var offered: LiveLocator? = null
    private var abortReason: String? = null

    // ── Host side ────────────────────────────────────────────────────────────

    /**
     * A live load began. Records what a `DataSource` must match to arm, and
     * invalidates any handover still outstanding from the load being replaced.
     */
    fun noteLoad(url: String, isLive: Boolean) {
        synchronized(lock) {
            session++
            expectedUrl = url
            live = isLive
            // Cleared rather than set to "cancelled": the token bump is what
            // ends an outstanding handover, and a reason left standing here
            // would be consumed by the *next* waiter before it had waited for
            // anything.
            offered = null
            abortReason = null
            lock.notifyAll()
        }
    }

    /** A pre-resolve answered with a *different* URL — see [rotationProven]. */
    fun noteRotationProven() {
        synchronized(lock) { rotationProven = true }
    }

    /**
     * A zap can cross sources, so whatever this session proved about the
     * previous channel's provider says nothing about the next one's.
     */
    fun resetRotationProof() {
        synchronized(lock) { rotationProven = false }
    }

    /**
     * The session moved on under any outstanding handover: a reload, a zap,
     * "Go to live", an mpv fallback, a handback to the preview, finish or
     * destroy. Bumps the token, so a locator offered after this can never be
     * applied, and wakes the loader thread so it stops waiting on a reply that
     * is not coming.
     */
    fun cancel() {
        synchronized(lock) {
            session++
            offered = null
            abortReason = null
            lock.notifyAll()
        }
    }

    /** True while a `DataSource` is waiting for a locator or evaluating one. */
    val pendingHandover: Boolean get() = synchronized(lock) { waiterSession != 0L }

    /**
     * Hands the next link's locator to a waiting `DataSource`.
     *
     * Returns false when nobody is waiting (an unarmed link, one already
     * evaluating a candidate, or a handover the session has moved past) — the
     * caller then stores the locator for the ordinary pre-resolved reconnect,
     * exactly as 0.1.81 does. **A true return means the locator is consumed**:
     * it is spent on the splice and must not also be stored, or a single-use
     * `play_token` would be loaded twice.
     */
    fun offer(locator: LiveLocator): Boolean = synchronized(lock) {
        if (waiterSession == 0L || waiterSession != session || evaluating) return false
        offered = locator
        lock.notifyAll()
        true
    }

    /** Abandon an outstanding handover with [reason]; a no-op when none is. */
    fun abort(reason: String) {
        synchronized(lock) {
            if (waiterSession == 0L) return
            abortReason = reason
            lock.notifyAll()
        }
    }

    // ── Loader side ──────────────────────────────────────────────────────────

    /**
     * Whether this `DataSource` may stitch, and under which session/link.
     *
     * Every condition is a reason *not* to: the kill switch, the session
     * stand-down, a stream the provider did not call live, a provider that has
     * never been seen to rotate a locator, a URI that is not the item the
     * engine loaded (a subtitle sidecar, an HLS segment), a resumed range
     * rather than a fresh body, and a container media3 would not read as one
     * unbounded progressive stream. Null means "behave exactly as the shipped
     * build does".
     */
    fun arm(uri: String, position: Long, contentTypeOther: Boolean): StitchArming? =
        synchronized(lock) {
            if (!LiveStitchPolicy.ENABLED) return null
            if (disabled || !live || !rotationProven) return null
            if (position != 0L) return null
            if (!contentTypeOther) return null
            val expected = expectedUrl ?: return null
            if (uri != expected) return null
            links++
            StitchArming(session, links)
        }

    /** The link index a committed splice promotes into. */
    fun nextLink(): Int = synchronized(lock) {
        links++
        links
    }

    /**
     * Blocks the loader thread until the host offers the next locator or
     * abandons the handover.
     *
     * Interruptible by design: media3's `Loader` interrupts its thread when a
     * load is cancelled, and that is the one wake-up this monitor cannot
     * produce for itself. The caller turns the [InterruptedException] into an
     * `InterruptedIOException`, which is what the extractor loop expects.
     */
    @Throws(InterruptedException::class)
    fun awaitLocator(session: Long): StitchHandover = synchronized(lock) {
        if (session != this.session) {
            return@synchronized StitchHandover.Aborted(LiveStitchPolicy.REASON_CANCELLED)
        }
        waiterSession = session
        evaluating = false
        var settled: StitchHandover? = null
        while (settled == null) {
            val reason = abortReason
            val locator = offered
            settled = when {
                session != this.session ->
                    StitchHandover.Aborted(LiveStitchPolicy.REASON_CANCELLED)
                reason != null -> {
                    abortReason = null
                    StitchHandover.Aborted(reason)
                }
                locator != null -> {
                    offered = null
                    evaluating = true
                    StitchHandover.Offered(locator)
                }
                else -> {
                    lock.wait()
                    null
                }
            }
        }
        // An abandoned handover is over the instant it is abandoned: the caller
        // closes any candidate and returns end of input, so leaving the slot
        // occupied would only have the deadline poller keep aborting something
        // that has already given up. Guarded on still owning the slot, because
        // a cancelled loader can unwind *after* the load that replaced it has
        // armed and begun waiting — see [finishHandover].
        if (settled is StitchHandover.Aborted && waiterSession == session) {
            waiterSession = 0L
            evaluating = false
        }
        settled
    }

    /**
     * Non-blocking check for an abort raised while a candidate is being
     * evaluated — the deadline, a zap, a reload. Polled between candidate
     * reads rather than delivered, because the loader thread is inside a
     * socket read for most of that window and nothing can preempt it there
     * (which is what [LiveStitchPolicy.CANDIDATE_READ_TIMEOUT_MS] bounds).
     */
    fun pollAbort(session: Long): String? = synchronized(lock) {
        if (session != this.session) return LiveStitchPolicy.REASON_CANCELLED
        val reason = abortReason
        if (reason != null) abortReason = null
        reason
    }

    /**
     * The handover is over, whichever way it went. Clears the rendezvous only
     * when it still belongs to [session]: a cancelled loader can finish *after*
     * a newer load has already armed and begun waiting, and clearing that one's
     * slot would strand it until the deadline.
     */
    fun finishHandover(session: Long) {
        synchronized(lock) {
            if (waiterSession != session) return
            waiterSession = 0L
            evaluating = false
            offered = null
            abortReason = null
        }
    }

    /** A splice committed: the session's patience is restored in full. */
    fun noteCommit() {
        synchronized(lock) {
            structuralFailures = 0
            transientFailures = 0
        }
    }

    /**
     * A handover fell back. Returns true when this one stood the path down for
     * the session (the caller has already logged the handover line; the
     * stand-down writes its own).
     */
    fun noteFallback(reason: String): Boolean {
        val line = synchronized(lock) {
            if (disabled) return false
            // Deadlines and locator-supply failures say nothing about splicing.
            if (!LiveStitchPolicy.countsAgainstSession(reason)) return false
            if (LiveStitchPolicy.isStructuralFailure(reason)) {
                structuralFailures++
            } else {
                transientFailures++
            }
            val structuralTripped =
                structuralFailures >= LiveStitchPolicy.MAX_CONSECUTIVE_STRUCTURAL_FAILURES
            val transientTripped =
                transientFailures >= LiveStitchPolicy.MAX_CONSECUTIVE_TRANSIENT_FAILURES
            if (!structuralTripped && !transientTripped) return false
            disabled = true
            val failures = if (structuralTripped) structuralFailures else transientFailures
            LiveStitchPolicy.disabledLine(failures, reason)
        }
        diagnostics(line)
        return true
    }

    /** False once the session rule has stood stitching down. */
    val enabled: Boolean get() = synchronized(lock) { !disabled }

    /** Test seam: the structural/transient streaks, for assertions. */
    fun failureStreaks(): Pair<Int, Int> =
        synchronized(lock) { structuralFailures to transientFailures }
}
