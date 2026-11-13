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

/**
 * What a stitching `DataSource` tells the engine about the link it is reading.
 *
 * Every method is called on the **media3 loader thread**, so the implementation
 * owns the hop to wherever it reads player state or writes the exportable log.
 */
@UnstableApi
interface StitchHost {
    /** A link armed for stitching. [spliceable] is `pending` or `true`. */
    fun onStitchArmed(link: Int, spliceable: String)

    /** The splicer reached a verdict on [link]'s shape. */
    fun onStitchSpliceable(link: Int, spliceable: Boolean, reason: String)

    /**
     * An armed link's HTTP body ended, and this source — not media3's
     * `onLoadCompleted` — owns reporting it from here on. The host writes the
     * `stream source eof` line and starts the pre-resolve.
     */
    fun onStitchLinkEof(link: Int, bytes: Long, sinceLinkOpenMs: Long)

    /** A splice committed: [link] closed and [newLink] is now feeding the same decoder. */
    fun onStitchCommitted(link: Int, newLink: Int, info: SpliceInfo, durationMs: Long)

    /** The handover gave up on [link]; end of input follows immediately. */
    fun onStitchFallback(link: Int, reason: String, durationMs: Long)
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
 * same `stream source eof` line. That is the whole safety argument, and it is
 * why the unarmed path has no buffer, no parsing and no branch past the first
 * line of [read].
 *
 * ### Never two connections
 *
 * A single-connection account is the constraint the whole player is built
 * around. The candidate link is opened **after** the current body has returned
 * end of input *and* been closed, and it is closed again before end of input is
 * ever returned to the extractor. The one window this cannot police from here
 * is a candidate wedged inside a blocking socket read, which is why a candidate
 * carries its own short timeouts ([LiveStitchPolicy.CANDIDATE_READ_TIMEOUT_MS])
 * bounded by the deadline's cushion ([LiveStitchPolicy.STITCH_ABORT_AHEAD_MS]).
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

    private val listeners = ArrayList<TransferListener>(2)

    private var coordinator: StitchCoordinator? = null
    private var arming: StitchArming? = null
    private var link = 0

    private var splicer: TsSplicer? = null
    private val out = OutputBuffer()
    private val scratch = ByteArray(SCRATCH_BYTES)
    private val sink: (ByteArray, Int, Int) -> Unit = { array, offset, length ->
        out.write(array, offset, length)
    }

    /** The body currently being read. [upstream] until a splice promotes a candidate. */
    private var current: DataSource = upstream
    private var currentOpen = false
    private var candidate: DataSource? = null

    private var atLinkEnd = false
    private var finished = false
    private var verdictReported = false

    /**
     * Latched the first time this source reports a link EOF itself. From then
     * on the engine's `onLoadCompleted` path is suppressed for this load and
     * **every** later link's EOF is reported here — including one that turns
     * out not to be spliceable, which would otherwise lose its line entirely.
     */
    private var reportsEof = false

    private var linkOpenedAtMs = 0L
    private var linkBytes = 0L

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
        arming = co?.arm(
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
        val armed = arming ?: return length
        link = armed.link
        splicer = TsSplicer()
        linkOpenedAtMs = SystemClock.elapsedRealtime()
        linkBytes = 0L
        host.onStitchArmed(link, SPLICEABLE_PENDING)
        return length
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        // The unarmed path, and the only thing that runs on a stream this
        // feature has no business touching.
        if (arming == null) return current.read(buffer, offset, length)
        if (length == 0) return 0
        val splicer = this.splicer ?: return current.read(buffer, offset, length)
        while (true) {
            if (out.available > 0) return out.drainTo(buffer, offset, length)
            if (finished) return C.RESULT_END_OF_INPUT
            if (!atLinkEnd) {
                val read = current.read(scratch, 0, scratch.size)
                if (read == C.RESULT_END_OF_INPUT) {
                    atLinkEnd = true
                } else if (read > 0) {
                    linkBytes += read
                    splicer.forwardCurrent(scratch, 0, read, sink)
                    reportVerdict(splicer)
                }
                continue
            }
            handleLinkEnd(splicer)
        }
    }

    override fun getUri(): Uri? = current.uri ?: upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = current.responseHeaders

    override fun close() {
        arming?.let { coordinator?.finishHandover(it.session) }
        closeCandidate()
        if (current !== upstream) {
            runCatching { if (currentOpen) current.close() }
            currentOpen = false
        }
        // Always, even when never opened: media3 calls close() after a failed
        // open, and `DefaultHttpDataSource` is a no-op when it holds nothing.
        currentOpen = false
        upstream.close()
    }

    private fun resetForOpen() {
        arming = null
        coordinator = null
        splicer = null
        link = 0
        out.clear()
        candidate = null
        current = upstream
        currentOpen = false
        atLinkEnd = false
        finished = false
        verdictReported = false
        reportsEof = false
        linkBytes = 0L
        linkOpenedAtMs = 0L
    }

    // ── The handover ─────────────────────────────────────────────────────────

    /**
     * The current link's body ended. Either splice the next one in behind it,
     * or give up and let the ordinary reconnect have the stream.
     *
     * Leaves the source in exactly one of two states: [finished] (end of input
     * follows), or reading a freshly promoted link.
     */
    private fun handleLinkEnd(splicer: TsSplicer) {
        // Before anything else can open a connection.
        closeCurrent()
        splicer.endCurrent()
        val blocked = blockedReason(splicer)
        if (blocked != null) {
            // Nothing to splice here. When this source already owns the EOF
            // reporting for the load, the line is still ours to write —
            // otherwise media3's own `onLoadCompleted` writes it, exactly as it
            // does on every unarmed stream today.
            if (reportsEof) reportLinkEof()
            giveUp(blocked, SystemClock.elapsedRealtime())
            return
        }
        reportLinkEof()
        val session = arming!!.session
        val startedAtMs = SystemClock.elapsedRealtime()
        val handover = try {
            coordinator!!.awaitLocator(session)
        } catch (e: InterruptedException) {
            // media3's Loader interrupts this thread on cancel. Restore the
            // flag and hand the extractor loop the exception it expects.
            Thread.currentThread().interrupt()
            throw InterruptedIOException("stitch handover interrupted")
        }
        when (handover) {
            is StitchHandover.Aborted -> giveUp(handover.reason, startedAtMs)
            is StitchHandover.Offered -> evaluate(splicer, handover.locator, startedAtMs)
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
    private fun blockedReason(splicer: TsSplicer): String? {
        if (!splicer.spliceable) {
            return splicer.unsupportedReason?.token ?: SpliceRejectReason.UNSUPPORTED.token
        }
        val probe = splicer.offerCandidate(EMPTY, 0, 0, sink)
        if (probe is SpliceDecision.Rejected) {
            splicer.abandonCandidate()
            return probe.reason.token
        }
        return null
    }

    private fun evaluate(splicer: TsSplicer, locator: LiveLocator, startedAtMs: Long) {
        val source = try {
            val built = candidateFactory(locator.headers)
            for (listener in listeners) built.addTransferListener(listener)
            built.open(DataSpec.Builder().setUri(Uri.parse(locator.url)).build())
            built
        } catch (e: IOException) {
            giveUp(LiveStitchPolicy.REASON_OPEN_FAILED, startedAtMs)
            return
        }
        candidate = source
        var candidateBytes = 0L
        while (true) {
            coordinator!!.pollAbort(arming!!.session)?.let { reason ->
                giveUp(reason, startedAtMs)
                return
            }
            val read = try {
                source.read(scratch, 0, scratch.size)
            } catch (e: IOException) {
                // A candidate that stalled past its own read timeout is a
                // candidate that never delivered; the same answer as an early
                // end of body, and the same (transient) weight against the
                // session.
                giveUp(LiveStitchPolicy.REASON_CANDIDATE_EOF, startedAtMs)
                return
            }
            if (read == C.RESULT_END_OF_INPUT) {
                giveUp(LiveStitchPolicy.REASON_CANDIDATE_EOF, startedAtMs)
                return
            }
            if (read <= 0) continue
            candidateBytes += read
            when (val decision = splicer.offerCandidate(scratch, 0, read, sink)) {
                is SpliceDecision.NeedMore -> Unit
                is SpliceDecision.Rejected -> {
                    giveUp(decision.reason.token, startedAtMs)
                    return
                }
                is SpliceDecision.Committed -> {
                    commit(decision.info, source, candidateBytes, startedAtMs)
                    return
                }
            }
        }
    }

    /** The candidate becomes the link being read; the stream never noticed. */
    private fun commit(
        info: SpliceInfo,
        source: DataSource,
        candidateBytes: Long,
        startedAtMs: Long,
    ) {
        val closed = link
        val session = arming!!.session
        candidate = null
        current = source
        currentOpen = true
        atLinkEnd = false
        // Everything the splicer emitted before the splice point was dropped,
        // but the bytes were still delivered by *this* body — so the next
        // `stream source eof` line counts them, as an honest "what this HTTP
        // connection carried".
        linkBytes = candidateBytes
        linkOpenedAtMs = SystemClock.elapsedRealtime()
        val promoted = coordinator!!.nextLink()
        link = promoted
        // Established by the commit itself: the candidate's layout had to match
        // the link it replaced, which was spliceable by definition.
        verdictReported = true
        coordinator!!.finishHandover(session)
        coordinator!!.noteCommit()
        host.onStitchCommitted(
            link = closed,
            newLink = promoted,
            info = info,
            durationMs = SystemClock.elapsedRealtime() - startedAtMs,
        )
    }

    /** Abandon the handover and let the ordinary reconnect take the stream. */
    private fun giveUp(reason: String, startedAtMs: Long) {
        splicer?.abandonCandidate()
        closeCandidate()
        arming?.let { coordinator?.finishHandover(it.session) }
        finished = true
        host.onStitchFallback(link, reason, SystemClock.elapsedRealtime() - startedAtMs)
        coordinator?.noteFallback(reason)
    }

    // ── Bookkeeping ──────────────────────────────────────────────────────────

    private fun reportVerdict(splicer: TsSplicer) {
        if (verdictReported) return
        val unsupported = splicer.unsupportedReason
        if (unsupported != null) {
            verdictReported = true
            host.onStitchSpliceable(link, false, unsupported.token)
        } else if (splicer.spliceable) {
            verdictReported = true
            host.onStitchSpliceable(link, true, LiveStitchPolicy.REASON_NONE)
        }
    }

    private fun reportLinkEof() {
        reportsEof = true
        host.onStitchLinkEof(
            link = link,
            bytes = linkBytes,
            sinceLinkOpenMs = SystemClock.elapsedRealtime() - linkOpenedAtMs,
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
    }
}

/**
 * A plain growable byte queue between the splicer's sink and the extractor's
 * `read`.
 *
 * It exists because [TsSplicer.forwardCurrent]'s contract is "consume these
 * bytes before you return" — the arrays it hands over are reused — while
 * `DataSource.read` must fill the *caller's* buffer with at most what it asked
 * for. Bounded in practice by one [StitchingDataSource.SCRATCH_BYTES] chunk
 * plus the splicer's hold buffer, because `read` always drains before it fetches
 * more.
 */
private class OutputBuffer {
    private var data = ByteArray(64 * 1024)
    private var head = 0
    private var tail = 0

    val available: Int get() = tail - head

    fun clear() {
        head = 0
        tail = 0
    }

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
