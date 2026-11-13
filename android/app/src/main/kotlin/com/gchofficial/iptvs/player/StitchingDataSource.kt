package com.gchofficial.iptvs.player

import android.net.Uri
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException

/**
 * What a stitching `DataSource` tells the engine about the link it is reading.
 *
 * Every method is called on the **media3 loader thread**, so the implementation
 * owns the hop to wherever it reads player state or writes the exportable log.
 *
 * Every method also carries the coordinator [session] it belongs to, and the
 * implementation **must drop anything stale**. The loader thread can be
 * seconds behind the main one — parked in a socket read, or inside a handover
 * the session has already cancelled — so a report can arrive describing a link
 * that a zap, a reload or an mpv fallback replaced long ago.
 */
@UnstableApi
interface StitchHost {
    /** A link armed for stitching. [spliceable] is `pending` or `true`. */
    fun onStitchArmed(session: Long, link: Int, spliceable: String)

    /** The splicer reached a verdict on [link]'s shape. */
    fun onStitchSpliceable(session: Long, link: Int, spliceable: Boolean, reason: String)

    /**
     * An armed link's HTTP body ended, and this source — not media3's
     * `onLoadCompleted` — owns reporting it from here on. The host writes the
     * `stream source eof` line and starts the pre-resolve.
     */
    fun onStitchLinkEof(session: Long, link: Int, bytes: Long, sinceLinkOpenMs: Long)

    /**
     * A splice committed: [link] closed and [newLink] is now feeding the same
     * decoder, from [locator] — which is the stream the session is **playing**
     * from here on, and so is the locator every later re-resolve, mpv fallback
     * and `refreshed` comparison has to be measured against.
     */
    fun onStitchCommitted(
        session: Long,
        link: Int,
        newLink: Int,
        locator: LiveLocator,
        info: SpliceInfo,
        durationMs: Long,
    )

    /**
     * The handover gave up on [link]; end of input follows immediately.
     * [consumedLocator] says whether a locator was actually handed over and
     * spent — the host's fail-safe re-ask turns on it
     * ([LiveStitchPolicy.shouldRequestFailsafePreResolve]).
     */
    fun onStitchFallback(
        session: Long,
        link: Int,
        reason: String,
        durationMs: Long,
        consumedLocator: Boolean,
    )
}

/**
 * The byte-stream half of the **stitched handover**: a `DataSource` that sits
 * between `DefaultHttpDataSource` and ExoPlayer's extractor and, when a live
 * link ends, opens the next one and splices it into the *same* byte stream
 * instead of letting the load complete.
 *
 * ExoPlayer never learns the link closed. One `MediaItem`, one `MediaSource`,
 * one extractor, one decoder, one audio sink, one continuous timeline — so
 * there is no reload, no new wait for an IDR, and no frozen picture. The seam
 * itself is [TsSplicer]'s business; this class is the I/O, the thread
 * discipline and the point at which a handover is abandoned.
 *
 * ### It does nothing at all unless it is armed
 *
 * [StitchCoordinator.arm] is deliberately hard to satisfy — a fullscreen
 * session's coordinator, a live stream, the item's own URI at position 0, a
 * container media3 reads as one unbounded progressive body, and a provider
 * this session has *seen* rotate a locator. Miss any of them and every call
 * below is a direct delegate: same bytes, same timings, same `onLoadCompleted`,
 * same `stream source eof` line, and **not one byte of buffer allocated** —
 * [ArmedLink] is the only thing that holds any, and it is built in `open()`
 * only once arming has been granted. That matters because most of the data
 * sources this factory makes are never the live progressive body at all:
 * preview opens, VOD, HLS segments, subtitle sidecars and load retries.
 *
 * ### Never two connections
 *
 * A single-connection account is the constraint the whole player is built
 * around. The candidate link is opened **after** the current body has returned
 * end of input *and* been closed, and it is closed again before end of input is
 * ever returned to the extractor. The one window this cannot police from here
 * is a candidate wedged inside a blocking call, which is why the pre-commit
 * phase carries short socket timeouts ([LiveStitchPolicy.MAX_BLOCKING_CALL_MS])
 * bounded by the deadline's cushion ([LiveStitchPolicy.STITCH_ABORT_AHEAD_MS]),
 * and why it also has a wall clock of its own
 * ([LiveStitchPolicy.PRE_COMMIT_BUDGET_MS]) checked across every blocking call
 * including the open.
 *
 * ### A committed link is an ordinary link
 *
 * Those short timeouts are a property of being a *candidate*, not of the
 * connection. Once a candidate is promoted it must ride out exactly what any
 * other live link rides out, so a stalled read is retried until
 * [LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS] has passed with nothing
 * arriving — rebuilding media3's own 8 s read timeout out of 1 s ones, because
 * a `SocketTimeoutException` leaves the socket valid by contract and an open
 * socket's timeout cannot be changed.
 *
 * ### Threading
 *
 * Every method here runs on the media3 loader thread, which is also the thread
 * that blocks in [StitchCoordinator.awaitLocator]. Blocking it is safe and is
 * the point: a live progressive load *is* that thread's whole job, and media3
 * interrupts it on cancel — which is why the wait is interruptible and arrives
 * at the extractor as an `InterruptedIOException`.
 */
@UnstableApi
class StitchingDataSource(
    /** The link the engine's own factory opened, with the item's headers. */
    private val upstream: DataSource,
    /** Builds a candidate link with the re-resolved locator's headers. */
    private val candidateFactory: (Map<String, String>) -> DataSource,
    /** Read at [open] time, because an Activity installs it after the engine is built. */
    private val coordinatorOf: () -> StitchCoordinator?,
    private val host: StitchHost,
) : DataSource {

    /**
     * Everything a stitching link needs and an unarmed one must not pay for:
     * the splicer, the 32 KiB read scratch, the output queue between them, and
     * the per-link bookkeeping. One allocation, made only once
     * [StitchCoordinator.arm] has said yes.
     */
    private class ArmedLink(val session: Long, var link: Int) {
        val splicer = TsSplicer()
        val out = OutputBuffer()
        val scratch = ByteArray(SCRATCH_BYTES)
        val sink: (ByteArray, Int, Int) -> Unit = { array, offset, length ->
            out.write(array, offset, length)
        }

        var verdictReported = false

        /**
         * Latched the first time this source reports a link EOF itself. From
         * then on the engine's `onLoadCompleted` path is suppressed for this
         * load and **every** later link's EOF is reported here — including one
         * that turns out not to be spliceable, which would otherwise lose its
         * line entirely.
         */
        var reportsEof = false

        var openedAtMs = 0L
        var bytes = 0L

        /**
         * When an unbroken run of read timeouts on a **committed** link began,
         * or 0. See [LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS].
         */
        var stalledSinceMs = 0L
    }

    private val listeners = ArrayList<TransferListener>(2)

    private var coordinator: StitchCoordinator? = null
    private var armed: ArmedLink? = null

    /** The body currently being read. [upstream] until a splice promotes a candidate. */
    private var current: DataSource = upstream
    private var currentOpen = false
    private var candidate: DataSource? = null

    private var atLinkEnd = false
    private var finished = false

    override fun addTransferListener(transferListener: TransferListener) {
        listeners.add(transferListener)
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        // `ProgressiveMediaPeriod` holds **one** `DataSource` per period and
        // re-opens it on every load retry, so none of this may carry over from
        // the body that just ended.
        resetForOpen()
        val co = coordinatorOf()
        coordinator = co
        val arming = co?.arm(
            uri = dataSpec.uri.toString(),
            position = dataSpec.position,
            // A playlist or manifest is read in chunks, so there is no single
            // unbounded body to splice; a sidecar subtitle is not the stream
            // at all. media3's own content-type inference is the right judge
            // because it is what chose the `MediaSource` we are feeding.
            contentTypeOther = Util.inferContentType(dataSpec.uri) == C.CONTENT_TYPE_OTHER,
        )
        val length = upstream.open(dataSpec)
        currentOpen = true
        if (arming == null) return length
        val state = ArmedLink(arming.session, arming.link)
        state.openedAtMs = SystemClock.elapsedRealtime()
        armed = state
        host.onStitchArmed(state.session, state.link, SPLICEABLE_PENDING)
        return length
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        // The unarmed path, and the only thing that runs on a stream this
        // feature has no business touching.
        val state = armed ?: return current.read(buffer, offset, length)
        if (length == 0) return 0
        while (true) {
            if (state.out.available > 0) return state.out.drainTo(buffer, offset, length)
            if (finished) return C.RESULT_END_OF_INPUT
            if (!atLinkEnd) {
                val read = readCurrent(state)
                if (read == C.RESULT_END_OF_INPUT) {
                    atLinkEnd = true
                } else if (read > 0) {
                    state.bytes += read
                    state.splicer.forwardCurrent(state.scratch, 0, read, state.sink)
                    reportVerdict(state)
                }
                continue
            }
            handleLinkEnd(state)
        }
    }

    override fun getUri(): Uri? = current.uri ?: upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = current.responseHeaders

    override fun close() {
        armed?.let { coordinator?.finishHandover(it.session) }
        closeCandidate()
        if (current !== upstream) {
            runCatching { if (currentOpen) current.close() }
        }
        // Always, even when never opened: media3 calls close() after a failed
        // open, and `DefaultHttpDataSource` is a no-op when it holds nothing.
        currentOpen = false
        upstream.close()
    }

    private fun resetForOpen() {
        armed = null
        coordinator = null
        candidate = null
        current = upstream
        currentOpen = false
        atLinkEnd = false
        finished = false
    }

    // ── Reading the current link ─────────────────────────────────────────────

    /**
     * One read of the link being played, with the **committed link's** stall
     * budget layered over its short candidate timeout.
     *
     * A promoted candidate still holds the socket it was opened with, and a
     * socket's read timeout cannot be changed once its stream exists. So the
     * long timeout is rebuilt here: a `SocketTimeoutException` leaves the
     * socket valid by contract, so the read is simply issued again until
     * [LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS] has elapsed with nothing
     * arriving. Without it an ordinary two-second network hiccup — which an
     * unstitched link absorbs in silence — would surface as a load error, and
     * media3 would retry the *item's* URI, i.e. a spent single-use token.
     *
     * [upstream] is excluded because it already carries media3's own default.
     */
    private fun readCurrent(state: ArmedLink): Int {
        while (true) {
            try {
                val read = current.read(state.scratch, 0, state.scratch.size)
                state.stalledSinceMs = 0L
                return read
            } catch (e: IOException) {
                if (current === upstream || !isReadTimeout(e)) throw e
                val now = SystemClock.elapsedRealtime()
                if (state.stalledSinceMs == 0L) state.stalledSinceMs = now
                if (!LiveStitchPolicy.shouldRetryStalledRead(now - state.stalledSinceMs)) throw e
            }
        }
    }

    // ── The handover ─────────────────────────────────────────────────────────

    /**
     * The current link's body ended. Either splice the next one in behind it,
     * or give up and let the ordinary reconnect have the stream.
     *
     * Leaves the source in exactly one of two states: [finished] (end of input
     * follows), or reading a freshly promoted link.
     */
    private fun handleLinkEnd(state: ArmedLink) {
        // Before anything else can open a connection.
        closeCurrent()
        state.splicer.endCurrent()
        val blocked = blockedReason(state)
        if (blocked != null) {
            // Nothing to splice here. When this source already owns the EOF
            // reporting for the load, the line is still ours to write —
            // otherwise media3's own `onLoadCompleted` writes it, exactly as it
            // does on every unarmed stream today.
            if (state.reportsEof) reportLinkEof(state)
            giveUp(state, blocked, SystemClock.elapsedRealtime(), consumedLocator = false)
            return
        }
        reportLinkEof(state)
        val startedAtMs = SystemClock.elapsedRealtime()
        val handover = try {
            coordinator!!.awaitLocator(state.session)
        } catch (e: InterruptedException) {
            // media3's Loader interrupts this thread on cancel. Restore the
            // flag and hand the extractor loop the exception it expects.
            Thread.currentThread().interrupt()
            throw InterruptedIOException("stitch handover interrupted")
        }
        when (handover) {
            is StitchHandover.Aborted ->
                giveUp(state, handover.reason, startedAtMs, consumedLocator = false)
            // The pre-commit budget (and the logged duration) start at the
            // **offer**, not at the park. Parking is the normal state of a
            // handover: the link closes with ~25 s of cushion and the host
            // only resolves once ~10 s remain, so timing the budget from the
            // park spent it before the locator ever arrived — every handover
            // fell back with `reason=deadline durationMs≈15000` (the first
            // live-cut emulator run that reached its channel).
            is StitchHandover.Offered ->
                evaluate(state, handover.locator, SystemClock.elapsedRealtime())
        }
    }

    /**
     * Why this link cannot be spliced from, or null when it can.
     *
     * The second half is a **zero-length probe** of the splicer, and it earns
     * its keep: `offerCandidate` refuses a link that never carried a video PTS
     * before it looks at a single byte, so asking it now means a link that
     * could never be spliced costs no candidate connection and no waiting —
     * the ordinary path runs with its ordinary timing.
     */
    private fun blockedReason(state: ArmedLink): String? {
        val splicer = state.splicer
        if (!splicer.spliceable) {
            return splicer.unsupportedReason?.token ?: SpliceRejectReason.UNSUPPORTED.token
        }
        val probe = splicer.offerCandidate(EMPTY, 0, 0, state.sink)
        if (probe is SpliceDecision.Rejected) {
            splicer.abandonCandidate()
            return probe.reason.token
        }
        return null
    }

    private fun evaluate(state: ArmedLink, locator: LiveLocator, startedAtMs: Long) {
        val source = try {
            val built = candidateFactory(locator.headers)
            for (listener in listeners) built.addTransferListener(listener)
            built.open(DataSpec.Builder().setUri(Uri.parse(locator.url)).build())
            built
        } catch (e: IOException) {
            giveUp(state, LiveStitchPolicy.REASON_OPEN_FAILED, startedAtMs, consumedLocator = true)
            return
        }
        candidate = source
        var candidateBytes = 0L
        while (true) {
            // Both halves of the pre-commit bound, re-asked around every
            // blocking call: the host's cushion deadline, and the loader's own
            // wall clock — which is what covers the open above, since nothing
            // could be polled while it was running.
            coordinator!!.pollAbort(state.session)?.let { reason ->
                giveUp(state, reason, startedAtMs, consumedLocator = true)
                return
            }
            val elapsed = SystemClock.elapsedRealtime() - startedAtMs
            if (LiveStitchPolicy.preCommitBudgetSpent(elapsed)) {
                giveUp(state, LiveStitchPolicy.REASON_DEADLINE, startedAtMs, consumedLocator = true)
                return
            }
            val read = try {
                source.read(state.scratch, 0, state.scratch.size)
            } catch (e: IOException) {
                // A candidate that stalled past its own read timeout is a
                // candidate that never delivered; the same answer as an early
                // end of body, and the same (transient) weight against the
                // session. **Not** retried the way a committed link's read is:
                // a candidate is on a budget, and one that has gone quiet has
                // already failed the only thing it was asked to do.
                giveUp(
                    state,
                    LiveStitchPolicy.REASON_CANDIDATE_EOF,
                    startedAtMs,
                    consumedLocator = true,
                )
                return
            }
            if (read == C.RESULT_END_OF_INPUT) {
                giveUp(
                    state,
                    LiveStitchPolicy.REASON_CANDIDATE_EOF,
                    startedAtMs,
                    consumedLocator = true,
                )
                return
            }
            if (read <= 0) continue
            candidateBytes += read
            when (
                val decision =
                    state.splicer.offerCandidate(state.scratch, 0, read, state.sink)
            ) {
                is SpliceDecision.NeedMore -> Unit
                is SpliceDecision.Rejected -> {
                    giveUp(state, decision.reason.token, startedAtMs, consumedLocator = true)
                    return
                }
                is SpliceDecision.Committed -> {
                    commit(state, decision.info, source, locator, candidateBytes, startedAtMs)
                    return
                }
            }
        }
    }

    /** The candidate becomes the link being read; the stream never noticed. */
    private fun commit(
        state: ArmedLink,
        info: SpliceInfo,
        source: DataSource,
        locator: LiveLocator,
        candidateBytes: Long,
        startedAtMs: Long,
    ) {
        val closed = state.link
        candidate = null
        current = source
        currentOpen = true
        atLinkEnd = false
        // Everything the splicer emitted before the splice point was dropped,
        // but the bytes were still delivered by *this* body — so the next
        // `stream source eof` line counts them, as an honest "what this HTTP
        // connection carried".
        state.bytes = candidateBytes
        state.openedAtMs = SystemClock.elapsedRealtime()
        state.stalledSinceMs = 0L
        val promoted = coordinator!!.nextLink()
        state.link = promoted
        // Established by the commit itself: the candidate's layout had to match
        // the link it replaced, which was spliceable by definition.
        state.verdictReported = true
        coordinator!!.finishHandover(state.session)
        coordinator!!.noteCommit()
        host.onStitchCommitted(
            session = state.session,
            link = closed,
            newLink = promoted,
            // The session is now **playing** this locator, not the one it was
            // launched with. Everything downstream measures against it: the mpv
            // fallback loads it, `ResolveAgainReply` preserves it, and the
            // `refreshed` comparison that arms the next handover is made
            // against it.
            locator = locator,
            info = info,
            durationMs = SystemClock.elapsedRealtime() - startedAtMs,
        )
    }

    /** Abandon the handover and let the ordinary reconnect take the stream. */
    private fun giveUp(
        state: ArmedLink,
        reason: String,
        startedAtMs: Long,
        consumedLocator: Boolean,
    ) {
        state.splicer.abandonCandidate()
        closeCandidate()
        coordinator?.finishHandover(state.session)
        finished = true
        host.onStitchFallback(
            session = state.session,
            link = state.link,
            reason = reason,
            durationMs = SystemClock.elapsedRealtime() - startedAtMs,
            consumedLocator = consumedLocator,
        )
        coordinator?.noteFallback(reason)
    }

    // ── Bookkeeping ──────────────────────────────────────────────────────────

    private fun reportVerdict(state: ArmedLink) {
        if (state.verdictReported) return
        val unsupported = state.splicer.unsupportedReason
        if (unsupported != null) {
            state.verdictReported = true
            host.onStitchSpliceable(state.session, state.link, false, unsupported.token)
        } else if (state.splicer.spliceable) {
            state.verdictReported = true
            host.onStitchSpliceable(
                state.session,
                state.link,
                true,
                LiveStitchPolicy.REASON_NONE,
            )
        }
    }

    private fun reportLinkEof(state: ArmedLink) {
        state.reportsEof = true
        host.onStitchLinkEof(
            session = state.session,
            link = state.link,
            bytes = state.bytes,
            sinceLinkOpenMs = SystemClock.elapsedRealtime() - state.openedAtMs,
        )
    }

    private fun closeCurrent() {
        if (!currentOpen) return
        currentOpen = false
        runCatching { current.close() }
    }

    private fun closeCandidate() {
        val source = candidate ?: return
        candidate = null
        runCatching { source.close() }
    }

    private companion object {
        /**
         * How much is read from a link at a time. Decoupled from the
         * extractor's own request size because the splicer may emit fewer
         * bytes than it is handed (packets dropped at a seam) or more than one
         * call's worth at once (the random-access scan's hold), so the output
         * has to be buffered either way.
         */
        const val SCRATCH_BYTES = 32 * 1024

        const val SPLICEABLE_PENDING = "pending"

        val EMPTY = ByteArray(0)

        /**
         * media3 wraps a socket timeout in an `HttpDataSourceException`, so the
         * cause chain is what identifies one. Walked rather than unwrapped once
         * because a cache or a redirect layer can add a frame.
         */
        fun isReadTimeout(error: Throwable): Boolean {
            var cause: Throwable? = error
            var depth = 0
            while (cause != null && depth < 4) {
                if (cause is SocketTimeoutException) return true
                cause = cause.cause
                depth++
            }
            return false
        }
    }
}

/**
 * A plain growable byte queue between the splicer's sink and the extractor's
 * `read`.
 *
 * It exists because [TsSplicer.forwardCurrent]'s contract is "consume these
 * bytes before you return" — the arrays it hands over are reused — while
 * `DataSource.read` must fill the *caller's* buffer with at most what it asked
 * for. Bounded in practice by one 32 KiB read plus the splicer's hold buffer,
 * because `read` always drains before it fetches more — and allocated only for
 * a link that actually armed.
 */
private class OutputBuffer {
    private var data = ByteArray(64 * 1024)
    private var head = 0
    private var tail = 0

    val available: Int get() = tail - head

    fun write(src: ByteArray, offset: Int, length: Int) {
        if (length <= 0) return
        if (head == tail) {
            head = 0
            tail = 0
        }
        if (tail + length > data.size) {
            val kept = available
            if (kept + length <= data.size) {
                System.arraycopy(data, head, data, 0, kept)
            } else {
                var capacity = data.size
                while (capacity < kept + length) capacity *= 2
                val grown = ByteArray(capacity)
                System.arraycopy(data, head, grown, 0, kept)
                data = grown
            }
            head = 0
            tail = kept
        }
        System.arraycopy(src, offset, data, tail, length)
        tail += length
    }

    fun drainTo(dst: ByteArray, offset: Int, length: Int): Int {
        val taken = minOf(length, available)
        System.arraycopy(data, head, dst, offset, taken)
        head += taken
        if (head == tail) {
            head = 0
            tail = 0
        }
        return taken
    }
}
