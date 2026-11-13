package com.gchofficial.iptvs.player

// ─────────────────────────────────────────────────────────────────────────────
// Shared constants. File-private rather than companion members so the parsing
// helpers and the small state classes below can all reach them.
// ─────────────────────────────────────────────────────────────────────────────

private const val PKT = 188
private const val SYNC = 0x47

/** How many packets' sync bytes must line up before a link is called TS. */
private const val ALIGN_PACKETS = 5

/** How far into a link a usable PMT must appear before the link is given up on. */
private const val PMT_SEARCH_BYTES = 2L * 1024 * 1024

/** How many packets of one video PES the random-access scan looks at. */
private const val RAP_SCAN_VIDEO_PACKETS = 4

/**
 * How many packets of *any* PID one scan attempt may hold.
 *
 * The hold exists because committing means emitting every packet from the
 * splice point on, and whether we commit is only known a few packets later. It
 * is bounded on packet count rather than on video packets alone because a
 * provider is free to interleave arbitrary padding between the video packets of
 * one PES, and an unbounded hold would be an unbounded allocation on a path
 * whose whole point is to survive a bad link.
 */
private const val RAP_SCAN_HOLD_PACKETS = 64

private const val PTS_MODULUS = 1L shl 33
private const val PTS_MASK = PTS_MODULUS - 1
private const val PTS_HALF = 1L shl 32
private const val NO_PTS = Long.MIN_VALUE
private const val TICKS_PER_MS = 90L

private const val STREAM_TYPE_H264 = 0x1B
private const val STREAM_TYPE_HEVC = 0x24
private const val PID_PAT = 0x0000
private const val MAX_SECTION_BYTES = 1024

/**
 * Stream types that carry *video*. Only H.264 and HEVC are spliceable; the rest
 * are listed so "exactly one video stream, and it is one we can splice" can be
 * told apart from "a PMT we failed to understand". A stream type this list does
 * not know is treated as non-video, which errs toward [SpliceRejectReason.UNSUPPORTED]
 * via the "no video at all" branch rather than toward a splice on a codec whose
 * NAL layout we would be guessing at.
 */
private val VIDEO_STREAM_TYPES = intArrayOf(
    0x01, // MPEG-1 video
    0x02, // MPEG-2 video
    0x10, // MPEG-4 part 2
    0x1B, // H.264
    0x21, // JPEG 2000
    0x24, // HEVC
    0x42, // AVS
    0xD1, // Dirac
    0xEA, // VC-1
)

/** Why a candidate link could not be spliced onto the one that ended. */
enum class SpliceRejectReason(val token: String) {
    /** Not 188-byte-aligned MPEG-TS (or the candidate's framing disagreed). */
    NOT_TS("not-ts"),

    /** TS, but not a shape this splicer handles — no PMT, or no single H.264/HEVC video PID. */
    UNSUPPORTED("unsupported"),

    /** The candidate's elementary-stream layout differs from the link that ended. */
    PMT_CHANGED("pmt"),

    /** The candidate's timeline is unrelated to the old one (renumbered PTS). */
    PTS_UNRELATED("pts-window"),

    /** The candidate starts *after* the old link ended by more than the gap bound. */
    GAP_TOO_LARGE("gap"),

    /** A usable splice point exists but it skips more programme content than allowed. */
    SKIP_TOO_LARGE("skip"),

    /** No random access point we splice safely appeared inside the skip budget. */
    NO_RAP("no-rap"),

    /** The candidate was searched for its whole byte budget without a verdict. */
    BUDGET("budget"),
}

/** What one committed splice cost, in the vocabulary the caller logs. */
data class SpliceInfo(
    /** New-link media dropped because the old link had already delivered it (`L - F`). */
    val overlapTrimmedMs: Long,
    /** Programme content no surface ever shows: `S - lastShown`. */
    val skippedMs: Long,
    /** Always 0 by construction — carried so the log line can state it. */
    val repeatedMs: Long,
    /** Candidate bytes discarded before the splice point. */
    val droppedBytes: Long,
    /** `"h264"` or `"hevc"`. */
    val codec: String,
)

/** The verdict on the bytes offered so far. */
sealed interface SpliceDecision {
    /** Nothing conclusive yet; keep feeding the candidate. */
    data object NeedMore : SpliceDecision

    /** The splice happened; [info] describes it. */
    data class Committed(val info: SpliceInfo) : SpliceDecision

    /** This candidate cannot be spliced. The caller falls back to a reload. */
    data class Rejected(val reason: SpliceRejectReason) : SpliceDecision
}

/**
 * The splicing brain behind the **stitched handover**: it turns two separate
 * HTTP bodies into one byte stream that media3's `TsExtractor` reads as a single
 * uninterrupted transport stream.
 *
 * ### The shape it exists for
 *
 * A Stalker provider closes each live MPEG-TS link after sending a ~20–30 s
 * backlog at ~6x real time plus 6–18 s of real time. Today the player drains the
 * cushion, reaches `STATE_ENDED` and reloads — roughly two seconds of frozen
 * picture per cycle even with the pre-resolved locator of
 * [LiveFastReconnectPolicy] removing the round trip, because a reload is a new
 * `MediaSource`, a new extractor and a new wait for an IDR. The only way to get
 * that to zero is for the player never to learn the link closed: a wrapping
 * `DataSource` opens the next (pre-resolved) link and splices it into the same
 * byte stream, and this class decides where the seam goes and what has to be
 * rewritten so the extractor reads across it.
 *
 * This class is deliberately Android-free and media3-free so the plain-JUnit
 * harness can pin it (`TsSplicerTest`), exactly like [ReconnectPolicy],
 * [StreamEofPolicy] and [LiveFastReconnectPolicy]. It performs no I/O, starts no
 * threads, logs nothing (the caller owns the exported line) and is **not
 * thread-safe** — one owner thread, the `DataSource`'s loader thread.
 *
 * ### What it relies on in media3's `TsExtractor`, and why
 *
 * The splice is made legible to the extractor through the **continuity
 * counter**, not through the adaptation field's `discontinuity_indicator`. That
 * is a deliberate reading of what `TsExtractor.read` actually does per packet
 * (media3 1.11.x): outside HLS mode it takes `continuityCounter = header & 0xF`,
 * looks up `previousCounter` (defaulting to `continuityCounter - 1`, so a PID's
 * first packet always reads as continuous), and then
 *
 *  - `previousCounter == continuityCounter` → **duplicate**: the packet is
 *    skipped *silently*. A splice that left the counter unchanged would have its
 *    first PES-start packet eaten.
 *  - `continuityCounter != (previousCounter + 1) & 0xF` → **discontinuity**:
 *    `payloadReader.seek()`, which puts the PES reader back into
 *    "find a header" state and discards whatever truncated unit it was holding.
 *  - otherwise the packet is appended to the unit in progress — which, across a
 *    splice, would glue our first new PES onto the truncated last old one.
 *
 * So the first packet emitted for each PID after the splice is rewritten to
 * `(lastForwardedCc + 2) & 0xF`: never equal (duplicate), never +1 (append).
 * `discontinuity_indicator` is left alone because setting it may require growing
 * an adaptation field, i.e. resizing a packet — and the extractor does not read
 * it for this purpose anyway. Note that media3 only records a counter for
 * packets that carry payload (`payloadReader` is null otherwise), so this class
 * mirrors that: the "last CC forwarded" is the last one on a payload-carrying
 * packet, and the rewrite anchors on the first payload-carrying packet emitted.
 *
 * ### The splice anchor, and why there are two of them
 *
 * At the close, the extractor is mid-PES on every PID: the last video PES began
 * at the last PUSI and was never terminated, because a video PES in TS is
 * unbounded (`PES_packet_length == 0`) and media3's `PesReader` only finishes a
 * unit when the *next* PUSI arrives. Forcing a continuity discontinuity makes it
 * `seek()` instead, which throws that unit away. Therefore:
 *
 *  - **`L`** — the last video PUSI's PTS — is the last media the old link
 *    *delivered*. It is what the overlap is trimmed against, because anything at
 *    or before it arrived once already.
 *  - **`lastShown`** — the *second-to-last* video PUSI's PTS — is the last frame
 *    the viewer actually sees. It is what `skippedMs` is measured from, because
 *    the frame at `L` is discarded at the seam.
 *
 * Both are decode-order anchors (PUSI order), so with B-frames `lastShown` can
 * carry a *larger* PTS than `L`; `skippedMs` is clamped at zero for that reason
 * and is an estimate to within one reorder depth.
 *
 * ### What it will not do
 *
 * It only ever splices at an **IDR** (H.264 `nal_unit_type` 5, HEVC
 * `IDR_W_RADL`/`IDR_N_LP` = 19/20), confirmed by scanning the Annex-B NAL units
 * of the candidate PES. HEVC CRA/BLA and a bare `random_access_indicator` are
 * refused: an open GOP's leading pictures reference frames from the *other*
 * link, which the decoder no longer has, so the splice would be visibly correct
 * in the log and visibly broken on screen. And when the current link is not a
 * shape it understands it does not splice at all — it degrades to a byte-exact
 * pipe, which is the same stream the player reads today.
 */
class TsSplicer(
    private val maxOverlapMs: Long = 120_000,
    private val maxGapMs: Long = 1_000,
    private val maxSkipMs: Long = 2_000,
    private val maxCandidateBytes: Long = 64L * 1024 * 1024,
) {
    companion object {
        /** One transport packet. */
        const val PACKET_SIZE = PKT

        const val CODEC_H264 = "h264"
        const val CODEC_HEVC = "hevc"

        /**
         * `a - b` on a 33-bit 90 kHz clock, as a signed tick count in
         * `[-2^32, 2^32)`.
         *
         * Every PTS comparison in this class goes through here. A live stream
         * wraps roughly every 26.5 hours and a provider that reconnects is
         * exactly as likely to do it across the wrap as anywhere else; a plain
         * `<` would read the wrap as a 26-hour backward jump and reject a
         * perfectly good candidate as [SpliceRejectReason.PTS_UNRELATED].
         *
         * It also does the other half of the job: a candidate whose timestamps
         * were *renumbered* lands at an arbitrary point on the circle, so the
         * same signed difference that forgives the wrap is what detects the
         * renumbering — anything further than the gap bound forward or the
         * overlap bound back is not the same timeline.
         */
        fun ptsDiff(a: Long, b: Long): Long {
            val d = (a - b) and PTS_MASK
            return if (d >= PTS_HALF) d - PTS_MODULUS else d
        }
    }

    // ── Public surface ───────────────────────────────────────────────────────

    /**
     * True once the current link has been confirmed as 188-byte-aligned TS with
     * a parsed PMT carrying exactly one H.264 or HEVC video PID. Only then may a
     * splice be attempted.
     */
    val spliceable: Boolean
        get() = !passthrough && current.videoPid >= 0 && current.layout != null

    /** Why not, once decided (null while undecided or when [spliceable]). */
    var unsupportedReason: SpliceRejectReason? = null
        private set

    // ── Current-link state ───────────────────────────────────────────────────

    private val current = Link()

    /**
     * Once set, every byte is forwarded exactly as received and nothing is
     * parsed. The flag is checked before anything else on the hot path, which
     * is the whole cost of the splicer for a stream it cannot help.
     */
    private var passthrough = false

    private var ended = false
    private var currentBytes = 0L

    /**
     * How many packets of the current link have had their sync byte checked.
     *
     * The contract is "sync at 0, 188, 376, … for the first five packets", and
     * that is what this counts — but **lazily, without buffering those 940
     * bytes**. It can be lazy because both branches emit the same bytes: an
     * aligned link forwards whole packets unmodified, and a misaligned one
     * forwards everything raw, so forwarding a packet before the fifth sync
     * byte has been seen cannot produce an output a later verdict would have to
     * take back. The only byte that is ever withheld is a *trailing partial
     * packet*, which [endCurrent] discards — the extractor discards a truncated
     * packet at end of input too.
     */
    private var alignProbed = 0
    private var alignConfirmed = false

    private val carry = ByteArray(PKT)
    private var carryLen = 0
    private val scratch = ByteArray(PKT)

    /** Frozen by [endCurrent]: see the class KDoc for why there are two. */
    private var anchorL = NO_PTS
    private var anchorLastShown = NO_PTS

    /**
     * Per-PID rewriting state for the link that is current *because of* a
     * splice. [ccTarget] holds the forced-discontinuity value each PID's first
     * emitted payload packet must carry; [ccOffset] is the constant that keeps
     * every later packet of that PID continuous behind it; [dropUntil] is the
     * "this PID has not caught up to the splice point yet" filter. All three
     * survive across [forwardCurrent] calls and die at the next commit.
     */
    private val ccTarget = HashMap<Int, Int>()
    private val ccOffset = HashMap<Int, Int>()
    private val dropUntil = HashMap<Int, Long>()

    // Run coalescing: consecutive unmodified packets from one caller buffer go
    // to the sink as a single call, so an untouched link costs one sink call per
    // read rather than one per 188 bytes.
    private var runArr: ByteArray? = null
    private var runStart = 0
    private var runEnd = 0

    // ── Candidate state ──────────────────────────────────────────────────────

    private var cand = Link()
    private var candAlignLen = 0
    private val candAlign = ByteArray(ALIGN_PACKETS * PKT)
    private var candAligned = false
    private val candCarry = ByteArray(PKT)
    private var candCarryLen = 0
    private var candBytes = 0L
    private var candPackets = 0L
    private var candF = NO_PTS
    private var candLayoutChecked = false
    private var candRejection: SpliceDecision.Rejected? = null

    private val hold = ByteArray(RAP_SCAN_HOLD_PACKETS * PKT)
    private var holdCount = 0
    private var holding = false
    private var holdPts = NO_PTS
    private var holdVideoPackets = 0
    private var holdSkipTooLarge = false
    private var holdDropped = 0L
    private val nal = ByteArray(RAP_SCAN_VIDEO_PACKETS * PKT)
    private var nalLen = 0

    // ── Forwarding the current link ──────────────────────────────────────────

    /**
     * Bytes read from the current link. Emits the bytes to forward to the
     * extractor via [sink].
     *
     * While the current link is the *first* one, output is byte-identical to
     * input save for a trailing partial packet held back until it completes.
     * After a commit, each packet additionally carries its PID's splice CC
     * offset, and packets of a PID that has not yet reached the splice point are
     * dropped.
     *
     * **[sink] must consume the bytes before it returns** — the arrays handed to
     * it are the caller's own buffer, this splicer's 188-byte scratch packet, or
     * its hold buffer, and all three are reused.
     */
    fun forwardCurrent(input: ByteArray, offset: Int, length: Int, sink: (ByteArray, Int, Int) -> Unit) {
        if (length <= 0) return
        if (passthrough) {
            sink(input, offset, length)
            return
        }
        var p = offset
        val end = offset + length
        if (carryLen > 0) {
            val take = minOf(PKT - carryLen, end - p)
            System.arraycopy(input, p, carry, carryLen, take)
            carryLen += take
            p += take
            if (carryLen < PKT) return
            carryLen = 0
            if (!handlePacket(carry, 0, sink)) {
                // Misaligned: handlePacket emitted nothing, so the raw packet
                // goes out here and the rest of the chunk follows it below.
                sink(carry, 0, PKT)
            }
        }
        while (!passthrough && end - p >= PKT) {
            if (!handlePacket(input, p, sink)) break
            p += PKT
        }
        flushRun(sink)
        if (passthrough) {
            if (p < end) sink(input, p, end - p)
            return
        }
        if (end > p) {
            System.arraycopy(input, p, carry, 0, end - p)
            carryLen = end - p
        }
    }

    /**
     * The current link hit end of input. Drops any withheld partial trailing
     * packet and freezes the splice anchor.
     *
     * The partial is dropped rather than forwarded because a truncated TS packet
     * is not a packet: the extractor's own loop would leave it unparsed at end of
     * input, and passing it on would only desynchronise the first packet of the
     * link we are about to splice in.
     */
    fun endCurrent() {
        carryLen = 0
        ended = true
        anchorL = current.lastVideoPts
        anchorLastShown = if (current.prevVideoPts != NO_PTS) current.prevVideoPts else current.lastVideoPts
    }

    // ── Evaluating and committing a candidate ────────────────────────────────

    /**
     * Bytes from a candidate next link. Emits nothing until
     * [SpliceDecision.Committed]; on Committed it has already emitted the
     * spliced packets from the splice point through the end of this chunk, and
     * the caller continues with [forwardCurrent] for that link's further bytes.
     *
     * A rejection is sticky until [abandonCandidate] — the same reason is
     * returned for any further bytes of a candidate already ruled out.
     */
    fun offerCandidate(
        input: ByteArray,
        offset: Int,
        length: Int,
        sink: (ByteArray, Int, Int) -> Unit,
    ): SpliceDecision {
        candRejection?.let { return it }
        if (!spliceable) return rejectCandidate(unsupportedReason ?: SpliceRejectReason.UNSUPPORTED)
        // A splice without a frozen anchor would be a splice onto a link that is
        // still running, or onto one that never carried a video PTS at all.
        if (!ended || anchorL == NO_PTS) return rejectCandidate(SpliceRejectReason.UNSUPPORTED)
        if (length <= 0) return SpliceDecision.NeedMore

        candBytes += length
        if (candBytes > maxCandidateBytes) return rejectCandidate(SpliceRejectReason.BUDGET)

        var p = offset
        val end = offset + length

        // The candidate emits nothing before the splice point, so unlike the
        // current link it can afford to buffer the whole alignment window and
        // decide up front. That keeps a commit from ever happening on a link
        // whose framing has not been confirmed.
        if (!candAligned) {
            val take = minOf(candAlign.size - candAlignLen, end - p)
            System.arraycopy(input, p, candAlign, candAlignLen, take)
            candAlignLen += take
            p += take
            if (candAlignLen < candAlign.size) return SpliceDecision.NeedMore
            for (i in 0 until ALIGN_PACKETS) {
                if ((candAlign[i * PKT].toInt() and 0xFF) != SYNC) {
                    return rejectCandidate(SpliceRejectReason.NOT_TS)
                }
            }
            candAligned = true
            for (i in 0 until ALIGN_PACKETS) {
                when (val d = candPacket(candAlign, i * PKT, sink)) {
                    is SpliceDecision.Committed -> {
                        val restFrom = (i + 1) * PKT
                        if (restFrom < candAlign.size) {
                            forwardCurrent(candAlign, restFrom, candAlign.size - restFrom, sink)
                        }
                        if (p < end) forwardCurrent(input, p, end - p, sink)
                        resetCandidate()
                        return d
                    }
                    is SpliceDecision.Rejected -> return rejectCandidate(d.reason)
                    else -> Unit
                }
            }
        }

        if (candCarryLen > 0) {
            val take = minOf(PKT - candCarryLen, end - p)
            System.arraycopy(input, p, candCarry, candCarryLen, take)
            candCarryLen += take
            p += take
            if (candCarryLen < PKT) return SpliceDecision.NeedMore
            candCarryLen = 0
            if ((candCarry[0].toInt() and 0xFF) != SYNC) return rejectCandidate(SpliceRejectReason.NOT_TS)
            when (val d = candPacket(candCarry, 0, sink)) {
                is SpliceDecision.Committed -> {
                    if (p < end) forwardCurrent(input, p, end - p, sink)
                    resetCandidate()
                    return d
                }
                is SpliceDecision.Rejected -> return rejectCandidate(d.reason)
                else -> Unit
            }
        }

        while (end - p >= PKT) {
            if ((input[p].toInt() and 0xFF) != SYNC) return rejectCandidate(SpliceRejectReason.NOT_TS)
            val d = candPacket(input, p, sink)
            p += PKT
            when (d) {
                is SpliceDecision.Committed -> {
                    if (p < end) forwardCurrent(input, p, end - p, sink)
                    resetCandidate()
                    return d
                }
                is SpliceDecision.Rejected -> return rejectCandidate(d.reason)
                else -> Unit
            }
        }
        if (end > p) {
            System.arraycopy(input, p, candCarry, 0, end - p)
            candCarryLen = end - p
        }
        return SpliceDecision.NeedMore
    }

    /**
     * Throw away candidate state (rejected, aborted, or the `DataSource` is
     * closing). Current-link state — including the frozen anchor — is kept, so a
     * second candidate can be offered against the same ended link.
     */
    fun abandonCandidate() {
        resetCandidate()
        candRejection = null
    }

    // ── Current-link packet pipeline ─────────────────────────────────────────

    /** Returns false when the packet is not TS-aligned; the caller then emits it raw. */
    private fun handlePacket(src: ByteArray, off: Int, sink: (ByteArray, Int, Int) -> Unit): Boolean {
        if ((src[off].toInt() and 0xFF) != SYNC) {
            goPassthrough(SpliceRejectReason.NOT_TS, sink)
            return false
        }
        if (!alignConfirmed) {
            alignProbed++
            if (alignProbed >= ALIGN_PACKETS) alignConfirmed = true
        }
        currentBytes += PKT
        emitCurrent(src, off, sink)
        if (!passthrough && current.unsupported) {
            goPassthrough(SpliceRejectReason.UNSUPPORTED, sink)
        } else if (!passthrough && current.videoPid < 0 && currentBytes > PMT_SEARCH_BYTES) {
            // A link whose PMT never arrived (or never named a video stream) is
            // not going to start making sense; stop parsing it.
            goPassthrough(SpliceRejectReason.UNSUPPORTED, sink)
        }
        return true
    }

    private fun goPassthrough(reason: SpliceRejectReason, sink: (ByteArray, Int, Int) -> Unit) {
        flushRun(sink)
        passthrough = true
        unsupportedReason = reason
    }

    private fun emitCurrent(src: ByteArray, off: Int, sink: (ByteArray, Int, Int) -> Unit) {
        val b1 = src[off + 1].toInt() and 0xFF
        val b2 = src[off + 2].toInt() and 0xFF
        val b3 = src[off + 3].toInt() and 0xFF
        val pid = ((b1 and 0x1F) shl 8) or b2
        val pusi = (b1 and 0x40) != 0
        val hasPayload = (b3 and 0x10) != 0
        val cc = b3 and 0x0F

        // 1. The post-splice catch-up filter.
        val threshold = dropUntil[pid]
        if (threshold != null) {
            if (!pusi || !hasPayload) return
            val po = payloadOffset(src, off)
            if (po < 0) return
            val pesEnd = off + PKT
            if (startsPes(src, po, pesEnd)) {
                val pts = readPts(src, po, pesEnd)
                // No PTS to compare against is not a reason to keep dropping: a
                // PUSI is the start of a unit, which is the only place this PID
                // can safely resume.
                if (pts != NO_PTS && ptsDiff(pts, threshold) < 0) return
            }
            dropUntil.remove(pid)
        }

        // 2. The continuity rewrite.
        if (hasPayload) {
            val target = ccTarget.remove(pid)
            if (target != null) ccOffset[pid] = (target - cc) and 0x0F
        }
        val offs = ccOffset[pid] ?: 0
        var outSrc = src
        var outOff = off
        var outCc = cc
        if (offs != 0) {
            System.arraycopy(src, off, scratch, 0, PKT)
            outCc = (cc + offs) and 0x0F
            scratch[3] = ((b3 and 0xF0) or outCc).toByte()
            outSrc = scratch
            outOff = 0
        }

        // 3. Track what the extractor is now holding — from the bytes as
        //    *emitted*, so the next splice's forced discontinuity is computed
        //    against the counter the extractor actually saw.
        track(current, outSrc, outOff, pid, pusi, hasPayload, outCc)

        // 4. Emit.
        if (outSrc === scratch) {
            flushRun(sink)
            sink(scratch, 0, PKT)
        } else {
            emitRaw(src, off, PKT, sink)
        }
    }

    private fun emitRaw(a: ByteArray, off: Int, len: Int, sink: (ByteArray, Int, Int) -> Unit) {
        if (runArr === a && runEnd == off) {
            runEnd = off + len
            return
        }
        flushRun(sink)
        runArr = a
        runStart = off
        runEnd = off + len
    }

    private fun flushRun(sink: (ByteArray, Int, Int) -> Unit) {
        val a = runArr ?: return
        runArr = null
        sink(a, runStart, runEnd - runStart)
    }

    // ── Candidate packet pipeline ────────────────────────────────────────────

    private fun candPacket(src: ByteArray, off: Int, sink: (ByteArray, Int, Int) -> Unit): SpliceDecision? {
        candPackets++
        val b1 = src[off + 1].toInt() and 0xFF
        val b2 = src[off + 2].toInt() and 0xFF
        val b3 = src[off + 3].toInt() and 0xFF
        val pid = ((b1 and 0x1F) shl 8) or b2
        val pusi = (b1 and 0x40) != 0
        val hasPayload = (b3 and 0x10) != 0
        val cc = b3 and 0x0F

        track(cand, src, off, pid, pusi, hasPayload, cc)

        if (!candLayoutChecked && cand.layout != null) {
            candLayoutChecked = true
            // Layout equality covers the codec too: the current link's layout
            // contains exactly one video stream and it is one we splice, so a
            // candidate that matches it does as well.
            if (cand.layout != current.layout) return SpliceDecision.Rejected(SpliceRejectReason.PMT_CHANGED)
        }

        val isVideo = cand.videoPid >= 0 && pid == cand.videoPid

        if (isVideo && pusi) {
            // A new video PES ends whatever scan was running: the PES we were
            // holding carried no IDR in its first packets.
            if (holding) failHold()?.let { return it }
            // Read *this* packet's PTS rather than the link's running
            // `lastVideoPts`: a PES that carries no PTS would otherwise be
            // judged against the previous PES's, i.e. spliced at a timestamp
            // belonging to a different frame.
            val po = payloadOffset(src, off)
            val pts = if (po >= 0 && startsPes(src, po, off + PKT)) readPts(src, po, off + PKT) else NO_PTS
            if (pts != NO_PTS) {
                if (candF == NO_PTS) {
                    candF = pts
                    windowVerdict(pts)?.let { return it }
                }
                if (ptsDiff(pts, anchorL) > 0) return startHold(src, off, pts, sink)
            }
            return null
        }

        if (holding) {
            appendHold(src, off)
            if (isVideo) {
                appendNal(src, off, pesStart = false)
                if (scanRap()) return commit(sink)
                holdVideoPackets++
                if (holdVideoPackets >= RAP_SCAN_VIDEO_PACKETS) return failHold()
            }
            if (holdCount >= RAP_SCAN_HOLD_PACKETS) return failHold()
        }
        return null
    }

    /**
     * The first candidate video PTS against the old link's last one: is this the
     * same timeline, and did it start close enough to where the old one stopped?
     */
    private fun windowVerdict(f: Long): SpliceDecision.Rejected? {
        val d = ptsDiff(f, anchorL)
        if (d > maxGapMs * TICKS_PER_MS) return SpliceDecision.Rejected(SpliceRejectReason.GAP_TOO_LARGE)
        if (-d > maxOverlapMs * TICKS_PER_MS) return SpliceDecision.Rejected(SpliceRejectReason.PTS_UNRELATED)
        return null
    }

    private fun startHold(
        src: ByteArray,
        off: Int,
        pts: Long,
        sink: (ByteArray, Int, Int) -> Unit,
    ): SpliceDecision? {
        holding = true
        holdCount = 0
        nalLen = 0
        holdPts = pts
        holdVideoPackets = 1
        holdDropped = (candPackets - 1) * PKT.toLong()
        // Noted now, judged when the PES's verdict is in: a PES this far past
        // the last shown frame is one we would not splice at even if it *is* a
        // RAP, and one that is not a RAP at this distance means the search has
        // run out of budget rather than merely needing more bytes. Keeping both
        // outcomes distinct is what lets an export tell "this stream's GOPs are
        // too long" from "this stream has no IDRs at all".
        holdSkipTooLarge = ptsDiff(pts, anchorLastShown) > maxSkipMs * TICKS_PER_MS
        appendHold(src, off)
        appendNal(src, off, pesStart = true)
        if (scanRap()) return commit(sink)
        if (holdVideoPackets >= RAP_SCAN_VIDEO_PACKETS) return failHold()
        return null
    }

    private fun failHold(): SpliceDecision? {
        val exhausted = holdSkipTooLarge
        holding = false
        holdCount = 0
        nalLen = 0
        holdVideoPackets = 0
        if (exhausted) return SpliceDecision.Rejected(SpliceRejectReason.NO_RAP)
        return null
    }

    private fun appendHold(src: ByteArray, off: Int) {
        if (holdCount >= RAP_SCAN_HOLD_PACKETS) return
        System.arraycopy(src, off, hold, holdCount * PKT, PKT)
        holdCount++
    }

    private fun appendNal(src: ByteArray, off: Int, pesStart: Boolean) {
        val po = payloadOffset(src, off)
        if (po < 0) return
        val end = off + PKT
        var s = po
        if (pesStart) {
            if (end - po < 9) return
            val headerLen = src[po + 8].toInt() and 0xFF
            s = po + 9 + headerLen
            if (s >= end) return
        }
        val n = minOf(end - s, nal.size - nalLen)
        if (n <= 0) return
        System.arraycopy(src, s, nal, nalLen, n)
        nalLen += n
    }

    /**
     * Whether the bytes collected so far contain an IDR.
     *
     * Annex-B start codes only: the three-byte `00 00 01` also matches the
     * four-byte form one byte in. Emulation prevention (`00 00 03`) means a
     * start code cannot occur inside a NAL payload, so this does not need to
     * parse past the headers it finds.
     */
    private fun scanRap(): Boolean {
        val hevc = cand.videoStreamType == STREAM_TYPE_HEVC
        var i = 0
        while (i + 3 < nalLen) {
            if (nal[i].toInt() == 0 && nal[i + 1].toInt() == 0 && (nal[i + 2].toInt() and 0xFF) == 1) {
                val h = nal[i + 3].toInt() and 0xFF
                if (hevc) {
                    val type = (h shr 1) and 0x3F
                    // IDR_W_RADL / IDR_N_LP. CRA (21) and BLA (16–18) are
                    // deliberately not accepted: their leading pictures
                    // reference frames from the link that just ended.
                    if (type == 19 || type == 20) return true
                } else {
                    if ((h and 0x1F) == 5) return true
                }
                i += 3
            } else {
                i++
            }
        }
        return false
    }

    private fun commit(sink: (ByteArray, Int, Int) -> Unit): SpliceDecision {
        if (holdSkipTooLarge) return SpliceDecision.Rejected(SpliceRejectReason.SKIP_TOO_LARGE)
        val s = holdPts
        val info = SpliceInfo(
            overlapTrimmedMs = maxOf(0L, ptsDiff(anchorL, candF)) / TICKS_PER_MS,
            skippedMs = maxOf(0L, ptsDiff(s, anchorLastShown)) / TICKS_PER_MS,
            repeatedMs = 0L,
            droppedBytes = holdDropped,
            codec = cand.codec,
        )
        promote(s)
        val packets = holdCount
        for (i in 0 until packets) {
            if (passthrough) {
                flushRun(sink)
                sink(hold, i * PKT, (packets - i) * PKT)
                break
            }
            if (!handlePacket(hold, i * PKT, sink)) {
                sink(hold, i * PKT, (packets - i) * PKT)
                break
            }
        }
        flushRun(sink)
        return SpliceDecision.Committed(info)
    }

    /**
     * The candidate becomes the current link.
     *
     * The forced-discontinuity targets are taken from the **old** link's last
     * forwarded counters before they are cleared, and every elementary stream
     * except the video one gets a "drop until you reach the splice point"
     * filter: the old link already delivered their media up to roughly `L`, and
     * re-delivering it would make the extractor emit samples the renderer has
     * already played. Non-elementary PIDs (PAT, PMT, SI, null) carry no PTS and
     * resume at the commit point.
     */
    private fun promote(s: Long) {
        ccTarget.clear()
        ccOffset.clear()
        dropUntil.clear()
        for ((pid, cc) in current.lastCc) ccTarget[pid] = (cc + 2) and 0x0F
        val layout = cand.layout
        if (layout != null) {
            for (entry in layout) {
                val pid = entry shr 8
                if (pid != cand.videoPid) dropUntil[pid] = s
            }
        }
        current.adopt(cand)
        cand = Link()
        passthrough = false
        alignConfirmed = true
        alignProbed = ALIGN_PACKETS
        carryLen = 0
        currentBytes = 0L
        ended = false
        anchorL = NO_PTS
        anchorLastShown = NO_PTS
    }

    private fun rejectCandidate(reason: SpliceRejectReason): SpliceDecision.Rejected {
        val r = SpliceDecision.Rejected(reason)
        candRejection = r
        return r
    }

    private fun resetCandidate() {
        cand = Link()
        candAlignLen = 0
        candAligned = false
        candCarryLen = 0
        candBytes = 0L
        candPackets = 0L
        candF = NO_PTS
        candLayoutChecked = false
        candRejection = null
        holding = false
        holdCount = 0
        holdVideoPackets = 0
        holdSkipTooLarge = false
        holdPts = NO_PTS
        holdDropped = 0L
        nalLen = 0
    }

    // ── Shared TS bookkeeping ────────────────────────────────────────────────

    private fun track(
        link: Link,
        src: ByteArray,
        off: Int,
        pid: Int,
        pusi: Boolean,
        hasPayload: Boolean,
        cc: Int,
    ) {
        if (!hasPayload) return
        // Mirrors media3: only a payload-carrying packet advances a PID's
        // continuity counter, so only those count as "the last CC forwarded".
        link.lastCc[pid] = cc
        val po = payloadOffset(src, off)
        if (po < 0) return
        val end = off + PKT
        when (pid) {
            PID_PAT -> if (link.patSection.feed(src, po, end, pusi)) {
                val pmtPid = parsePat(link.patSection.data, link.patSection.length)
                if (pmtPid >= 0) link.pmtPid = pmtPid
            }
            link.pmtPid -> if (link.pmtSection.feed(src, po, end, pusi)) {
                parsePmt(link.pmtSection.data, link.pmtSection.length, link)
            }
            else -> if (pusi && startsPes(src, po, end)) {
                val pts = readPts(src, po, end)
                if (pts != NO_PTS) {
                    link.lastPesPts[pid] = pts
                    if (pid == link.videoPid) {
                        link.prevVideoPts = link.lastVideoPts
                        link.lastVideoPts = pts
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TS parsing helpers. File-private and allocation-free (the section assembler
// owns one fixed buffer per PID it follows).
// ─────────────────────────────────────────────────────────────────────────────

/** The elementary-stream layout and running state of one link. */
private class Link {
    var pmtPid = -1
    var videoPid = -1
    var videoStreamType = -1

    /** Sorted `(pid shl 8) or streamType`, the comparison key for a PMT change. */
    var layout: List<Int>? = null

    /** A PMT was parsed and it is not a shape this splicer handles. */
    var unsupported = false

    val lastCc = HashMap<Int, Int>()
    val lastPesPts = HashMap<Int, Long>()
    var lastVideoPts = NO_PTS
    var prevVideoPts = NO_PTS
    val patSection = Section()
    val pmtSection = Section()

    val codec: String
        get() = when (videoStreamType) {
            STREAM_TYPE_H264 -> TsSplicer.CODEC_H264
            STREAM_TYPE_HEVC -> TsSplicer.CODEC_HEVC
            else -> ""
        }

    /**
     * Take [other]'s *structure* and nothing else. The running state is reset
     * because the candidate accumulated it from packets that were dropped: the
     * counters and PTS anchors that matter from here on are the ones the
     * extractor is about to be handed.
     */
    fun adopt(other: Link) {
        pmtPid = other.pmtPid
        videoPid = other.videoPid
        videoStreamType = other.videoStreamType
        layout = other.layout
        unsupported = other.unsupported
        lastCc.clear()
        lastPesPts.clear()
        lastVideoPts = NO_PTS
        prevVideoPts = NO_PTS
        patSection.reset()
        pmtSection.reset()
    }
}

/**
 * Assembles one PSI section across packets.
 *
 * Bounded by the format: `section_length` is 12 bits and the longest legal
 * section is 1021 bytes of body, so one fixed 1024-byte buffer holds any of
 * them. Only the first section in a packet is taken, and the tail of a section
 * that a `pointer_field` skips over is dropped — PAT and PMT repeat several
 * times a second, so the next copy serves.
 */
private class Section {
    val data = ByteArray(MAX_SECTION_BYTES)
    var length = 0
        private set
    private var want = -1

    fun reset() {
        length = 0
        want = -1
    }

    /** Returns true when [data] now holds one complete section of [length] bytes. */
    fun feed(src: ByteArray, from: Int, to: Int, pusi: Boolean): Boolean {
        var p = from
        if (pusi) {
            if (p >= to) return false
            val pointer = src[p].toInt() and 0xFF
            p += 1 + pointer
            length = 0
            want = -1
            if (p >= to) return false
        } else if (want < 0) {
            return false
        }
        val n = minOf(to - p, data.size - length)
        if (n <= 0) return false
        System.arraycopy(src, p, data, length, n)
        length += n
        if (want < 0) {
            if (length < 3) return false
            want = 3 + (((data[1].toInt() and 0x0F) shl 8) or (data[2].toInt() and 0xFF))
            if (want > data.size) {
                reset()
                return false
            }
        }
        if (length < want) return false
        length = want
        want = -1
        return true
    }
}

/** Offset of this packet's payload, or -1 when it carries none. */
private fun payloadOffset(src: ByteArray, off: Int): Int {
    val b3 = src[off + 3].toInt() and 0xFF
    if ((b3 and 0x10) == 0) return -1
    if ((b3 and 0x20) == 0) return off + 4
    val afLen = src[off + 4].toInt() and 0xFF
    val start = off + 5 + afLen
    return if (start >= off + PKT) -1 else start
}

private fun startsPes(src: ByteArray, p: Int, end: Int): Boolean =
    end - p >= 4 &&
        src[p].toInt() == 0 &&
        src[p + 1].toInt() == 0 &&
        (src[p + 2].toInt() and 0xFF) == 1

/** The 33-bit PTS of a PES whose header starts at [p], or [NO_PTS]. */
private fun readPts(src: ByteArray, p: Int, end: Int): Long {
    if (end - p < 14) return NO_PTS
    val streamId = src[p + 3].toInt() and 0xFF
    // Stream ids that carry no optional PES header at all.
    if (streamId == 0xBC || streamId == 0xBE || streamId == 0xBF || streamId == 0xF0 ||
        streamId == 0xF1 || streamId == 0xF2 || streamId == 0xF8 || streamId == 0xFF
    ) {
        return NO_PTS
    }
    if ((src[p + 6].toInt() and 0xC0) != 0x80) return NO_PTS
    if ((src[p + 7].toInt() and 0xC0) == 0) return NO_PTS
    val b0 = src[p + 9].toInt() and 0xFF
    val b1 = src[p + 10].toInt() and 0xFF
    val b2 = src[p + 11].toInt() and 0xFF
    val b3 = src[p + 12].toInt() and 0xFF
    val b4 = src[p + 13].toInt() and 0xFF
    return ((b0 and 0x0E).toLong() shl 29) or
        (b1.toLong() shl 22) or
        ((b2 and 0xFE).toLong() shl 14) or
        (b3.toLong() shl 7) or
        ((b4 and 0xFE).toLong() shr 1)
}

/** The first non-zero program's PMT PID, or -1. */
private fun parsePat(d: ByteArray, len: Int): Int {
    if (len < 12) return -1
    if ((d[0].toInt() and 0xFF) != 0x00) return -1
    if ((d[5].toInt() and 0x01) == 0) return -1
    val sectionLength = ((d[1].toInt() and 0x0F) shl 8) or (d[2].toInt() and 0xFF)
    val end = minOf(len, 3 + sectionLength - 4)
    var i = 8
    while (i + 4 <= end) {
        val program = ((d[i].toInt() and 0xFF) shl 8) or (d[i + 1].toInt() and 0xFF)
        val pid = ((d[i + 2].toInt() and 0x1F) shl 8) or (d[i + 3].toInt() and 0xFF)
        if (program != 0) return pid
        i += 4
    }
    return -1
}

/**
 * Fills [link]'s layout and video selection from a PMT section.
 *
 * The CRC is deliberately not verified: media3's own `TsExtractor` does not
 * verify it either, and a splicer that disagreed with the extractor about which
 * PMTs are real would be building its model of the stream from a different
 * stream than the one being played.
 */
private fun parsePmt(d: ByteArray, len: Int, link: Link) {
    if (len < 16) return
    if ((d[0].toInt() and 0xFF) != 0x02) return
    if ((d[5].toInt() and 0x01) == 0) return
    val sectionLength = ((d[1].toInt() and 0x0F) shl 8) or (d[2].toInt() and 0xFF)
    val end = minOf(len, 3 + sectionLength - 4)
    val programInfoLength = ((d[10].toInt() and 0x0F) shl 8) or (d[11].toInt() and 0xFF)
    var i = 12 + programInfoLength
    val entries = ArrayList<Int>()
    var videoPid = -1
    var videoType = -1
    var videoCount = 0
    while (i + 5 <= end) {
        val type = d[i].toInt() and 0xFF
        val pid = ((d[i + 1].toInt() and 0x1F) shl 8) or (d[i + 2].toInt() and 0xFF)
        val esInfoLength = ((d[i + 3].toInt() and 0x0F) shl 8) or (d[i + 4].toInt() and 0xFF)
        entries.add((pid shl 8) or type)
        if (VIDEO_STREAM_TYPES.contains(type)) {
            videoCount++
            if (videoCount == 1) {
                videoPid = pid
                videoType = type
            }
        }
        i += 5 + esInfoLength
    }
    if (entries.isEmpty()) return
    entries.sort()
    link.layout = entries
    if (videoCount == 1 && (videoType == STREAM_TYPE_H264 || videoType == STREAM_TYPE_HEVC)) {
        link.videoPid = videoPid
        link.videoStreamType = videoType
        link.unsupported = false
    } else {
        link.videoPid = -1
        link.videoStreamType = -1
        link.unsupported = true
    }
}
