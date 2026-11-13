package com.gchofficial.iptvs.player

import java.io.ByteArrayOutputStream
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the stitched handover's splicing brain.
 *
 * Two things are being asserted throughout, and they are not the same thing:
 *
 *  1. **A stream it cannot help is untouched.** Every passthrough case compares
 *     the concatenated sink output against the input byte for byte, because the
 *     fallback for everything this splicer refuses is the stream the player
 *     reads today.
 *  2. **A splice is legible to media3's `TsExtractor`.** That means the forced
 *     continuity discontinuity on the first packet of every PID (never equal —
 *     the extractor drops duplicates silently — and never +1, which would
 *     append to the truncated old PES), continuity from there on, no video
 *     delivered twice, and a splice point that is a real IDR.
 *
 * The fixtures are real transport streams built by [TsWriter] rather than
 * recorded ones, so each case states the exact shape it is about.
 */
class TsSplicerTest {

    // ── 1. Passthrough ───────────────────────────────────────────────────────

    @Test
    fun `an aligned link is forwarded byte for byte`() {
        val link = buildLink(startPts = 900_000, frames = 50)
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(link.bytes, 0, link.bytes.size, sink.fn)
        assertArrayEquals(link.bytes, sink.bytes())
        assertTrue(splicer.spliceable)
        assertNull(splicer.unsupportedReason)
    }

    @Test
    fun `a non-TS link is forwarded byte for byte, partial packets included`() {
        val link = buildLink(startPts = 900_000, frames = 20)
        // One byte of lead-in is all it takes: packet zero's sync byte is wrong.
        val junk = byteArrayOf(0x00) + link.bytes + ByteArray(37) { 0x5A }
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(junk, 0, 500, sink.fn)
        splicer.forwardCurrent(junk, 500, junk.size - 500, sink.fn)
        assertArrayEquals(junk, sink.bytes())
        assertFalse(splicer.spliceable)
        assertEquals(SpliceRejectReason.NOT_TS, splicer.unsupportedReason)
    }

    @Test
    fun `a stride the sync bytes do not survive drops to passthrough mid-stream`() {
        // The 192-byte (M2TS) shape: packet zero looks right and the next one
        // does not. Everything already forwarded was forwarded unmodified, so
        // the output is still byte-identical.
        val link = buildLink(startPts = 900_000, frames = 20)
        val shifted = link.bytes.copyOfRange(0, 188) +
            byteArrayOf(0, 0, 0, 0) +
            link.bytes.copyOfRange(188, link.bytes.size) +
            ByteArray(90) { 0x33 }
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(shifted, 0, shifted.size, sink.fn)
        assertArrayEquals(shifted, sink.bytes())
        assertFalse(splicer.spliceable)
        assertEquals(SpliceRejectReason.NOT_TS, splicer.unsupportedReason)
    }

    @Test
    fun `an MPEG-2 video PID is TS but not spliceable`() {
        val link = buildLink(startPts = 900_000, frames = 20, videoType = 0x02)
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(link.bytes, 0, link.bytes.size, sink.fn)
        assertArrayEquals(link.bytes, sink.bytes())
        assertFalse(splicer.spliceable)
        assertEquals(SpliceRejectReason.UNSUPPORTED, splicer.unsupportedReason)
    }

    @Test
    fun `two video streams in one PMT are not spliceable`() {
        // The anchor is "the video PID"; a program carrying two of them has no
        // single answer, so the splicer declines rather than picking one.
        val link = buildLink(startPts = 900_000, frames = 20, extraStream = 258 to 0x1B)
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(link.bytes, 0, link.bytes.size, sink.fn)
        assertArrayEquals(link.bytes, sink.bytes())
        assertFalse(splicer.spliceable)
        assertEquals(SpliceRejectReason.UNSUPPORTED, splicer.unsupportedReason)
    }

    @Test
    fun `a trailing partial packet is withheld, then discarded by endCurrent`() {
        val link = buildLink(startPts = 900_000, frames = 20)
        val whole = link.bytes.size
        val padded = link.bytes + ByteArray(100) { 0x7E }
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(padded, 0, padded.size, sink.fn)
        assertEquals(whole, sink.bytes().size)
        assertArrayEquals(link.bytes, sink.bytes())
        splicer.endCurrent()
        assertEquals(whole, sink.bytes().size)
    }

    @Test
    fun `a partial packet split across reads is forwarded once it completes`() {
        val link = buildLink(startPts = 900_000, frames = 20)
        val splicer = TsSplicer()
        val sink = Sink()
        // A boundary inside packet 3.
        splicer.forwardCurrent(link.bytes, 0, 600, sink.fn)
        assertEquals(3 * 188, sink.bytes().size)
        splicer.forwardCurrent(link.bytes, 600, link.bytes.size - 600, sink.fn)
        assertArrayEquals(link.bytes, sink.bytes())
    }

    // ── 2. The ordinary overlap splice ───────────────────────────────────────

    @Test
    fun `an overlapping candidate splices at the first IDR past the old link`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val lastShown = one.frames[one.frames.size - 2].pts
        // 25 s of overlap: the candidate's timeline starts well before L.
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700)
        val r = splice(one.bytes, two.bytes)

        val decision = r.decision as SpliceDecision.Committed
        assertEquals(25_000L, decision.info.overlapTrimmedMs)
        assertEquals(0L, decision.info.repeatedMs)
        assertEquals(TsSplicer.CODEC_H264, decision.info.codec)

        val expectedS = two.frames.first { it.rap && TsSplicer.ptsDiff(it.pts, l) > 0 }.pts
        val emitted = parse(r.after)
        val firstVideo = emitted.first { it.pid == VIDEO_PID && it.pusi }
        assertEquals(expectedS, firstVideo.pts)
        // Nothing at all is emitted before the splice point: the first packet
        // out is S's own, and everything ahead of it is counted as dropped.
        assertEquals(VIDEO_PID, emitted.first().pid)
        assertEquals(expectedS, emitted.first().pts)
        val spliceIndex = parse(two.bytes).indexOfFirst {
            it.pid == VIDEO_PID && it.pusi && it.pts == expectedS
        }
        assertEquals(spliceIndex * 188L, decision.info.droppedBytes)
        // Nothing else is lost: with audio arriving at the splice point there
        // is nothing for the catch-up filter to drop, so every candidate byte
        // from S onward is forwarded.
        assertEquals(two.bytes.size - decision.info.droppedBytes, r.after.size.toLong())

        // Rule 4: the frame at L is discarded at the seam, so the skip is
        // measured from the *second-to-last* PUSI, not from L.
        assertEquals(
            TsSplicer.ptsDiff(expectedS, lastShown) / 90,
            decision.info.skippedMs,
        )
        assertTrue("skipped=${decision.info.skippedMs}", decision.info.skippedMs in 1..1040)

        // Nothing already delivered is delivered again.
        for (p in emitted) {
            if (p.pid == VIDEO_PID && p.pusi) {
                assertTrue("re-delivered pts=${p.pts}", TsSplicer.ptsDiff(p.pts!!, l) > 0)
            }
        }
    }

    @Test
    fun `every PID resumes on a forced discontinuity and stays continuous after it`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700)
        val r = splice(one.bytes, two.bytes)
        assertTrue(r.decision is SpliceDecision.Committed)

        val before = parse(r.before)
        val after = parse(r.after)
        val lastCcBefore = HashMap<Int, Int>()
        for (p in before) lastCcBefore[p.pid] = p.cc

        val seen = HashSet<Int>()
        val running = HashMap<Int, Int>()
        for (p in after) {
            if (seen.add(p.pid)) {
                val old = lastCcBefore[p.pid]
                assertNotNull("pid ${p.pid} was never seen before the splice", old)
                assertEquals(
                    "pid=${p.pid} first CC after the splice",
                    (old!! + 2) and 0x0F,
                    p.cc,
                )
            } else {
                assertEquals(
                    "pid=${p.pid} continuity after the splice",
                    (running[p.pid]!! + 1) and 0x0F,
                    p.cc,
                )
            }
            running[p.pid] = p.cc
        }
        // All four PIDs of the fixture reappear: video, audio, PAT and PMT.
        assertEquals(setOf(0, PMT_PID, VIDEO_PID, AUDIO_PID), seen)
    }

    @Test
    fun `audio that lags video in the mux is dropped until it reaches the splice point`() {
        // The filter only has work to do when a PES PID's packets *after* the
        // splice point still carry media from before it, which is exactly a mux
        // that writes audio a few frames behind video. Without `audioLag` the
        // fixture's audio arrives at the splice point already, and the filter
        // would be untested.
        val one = buildLink(startPts = 900_000, frames = 650, audioLag = 3)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700, audioLag = 3)
        val r = splice(one.bytes, two.bytes)
        assertTrue(r.decision is SpliceDecision.Committed)

        val after = parse(r.after)
        val s = after.first { it.pid == VIDEO_PID && it.pusi }.pts!!
        val firstAudio = after.first { it.pid == AUDIO_PID }
        assertTrue("audio must resume at a PES start", firstAudio.pusi)
        assertTrue(
            "audio pts=${firstAudio.pts} before S=$s",
            TsSplicer.ptsDiff(firstAudio.pts!!, s) >= 0,
        )
        // The three lagging frames really were in the stream, and really were
        // dropped rather than merely absent from the fixture.
        val candidateAudioAfterS = parse(two.bytes)
            .dropWhile { !(it.pid == VIDEO_PID && it.pusi && it.pts == s) }
            .filter { it.pid == AUDIO_PID && it.pts != null }
        assertTrue(
            "fixture must offer stale audio after S",
            candidateAudioAfterS.take(3).any { TsSplicer.ptsDiff(it.pts!!, s) < 0 },
        )
        for (p in after) {
            if (p.pid == AUDIO_PID && p.pts != null) {
                assertTrue("stale audio pts=${p.pts}", TsSplicer.ptsDiff(p.pts, s) >= 0)
            }
        }
    }

    @Test
    fun `a PMT carrying descriptors is parsed and spliced`() {
        // Real provider PMTs are never the bare 5-byte-per-stream shape the
        // other fixtures use. If the descriptor-length arithmetic were wrong
        // the video PID would be read out of a descriptor body and the whole
        // feature would silently never engage, which is the failure this pins.
        val info = descriptor(0x05, 4) + descriptor(0x0E, 3)
        val es = descriptor(0x52, 1)
        val one = buildLink(startPts = 900_000, frames = 650, programInfo = info, esInfo = es)
        val l = one.frames.last().pts
        val two = buildLink(
            startPts = l - 25_000 * 90,
            frames = 700,
            programInfo = info,
            esInfo = es,
        )
        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed
        assertEquals(25_000L, decision.info.overlapTrimmedMs)
        assertEquals(TsSplicer.CODEC_H264, decision.info.codec)
    }

    @Test
    fun `a PMT that spans several packets is assembled before it is read`() {
        val info = descriptor(0xFF, 255) + descriptor(0xFE, 141)
        val one = buildLink(startPts = 900_000, frames = 650, programInfo = info)
        // The fixture must really exercise the continuation path.
        assertTrue(
            "PMT must not fit one packet",
            parse(one.bytes).count { it.pid == PMT_PID && !it.pusi } > 0,
        )
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700, programInfo = info)
        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed
        assertEquals(25_000L, decision.info.overlapTrimmedMs)
    }

    @Test
    fun `an IDR a few packets into its PES is still found`() {
        // A real video PES is many packets and the slice header follows the
        // parameter sets, so the scan has to read across packet boundaries of
        // the same PES rather than only the one carrying the PES header.
        val one = buildLink(startPts = 900_000, frames = 650, rapPadBytes = 400)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700, rapPadBytes = 400)
        // The fixture must really split the RAP across packets.
        val perPes = parse(two.bytes)
            .dropWhile { !(it.pid == VIDEO_PID && it.pusi) }
            .drop(1)
            .takeWhile { !(it.pid == VIDEO_PID && it.pusi) }
            .count { it.pid == VIDEO_PID }
        assertTrue("fixture RAP PES must span packets", perPes >= 2)

        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed
        val expectedS = two.frames.first { it.rap && TsSplicer.ptsDiff(it.pts, l) > 0 }.pts
        assertEquals(expectedS, parse(r.after).first { it.pid == VIDEO_PID && it.pusi }.pts)
        assertEquals(25_000L, decision.info.overlapTrimmedMs)
    }

    @Test
    fun `an IDR beyond the scan window is not found`() {
        // The honest statement of the bound: the scan reads the first four
        // packets of a PES, so a slice header further in than that is missed and
        // the candidate is refused rather than spliced somewhere unsafe.
        val one = buildLink(startPts = 900_000, frames = 650, rapPadBytes = 1200)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700, rapPadBytes = 1200)
        val r = splice(one.bytes, two.bytes)
        assertEquals(SpliceDecision.Rejected(SpliceRejectReason.NO_RAP), r.decision)
        assertEquals(0, r.after.size)
    }

    @Test
    fun `a candidate that loses alignment inside the probe window never commits`() {
        // Everything a commit needs — PAT, PMT, an eligible IDR — is inside the
        // first four packets. The fifth breaks the framing, and confirming the
        // framing over all five is what stops the splice from happening on a
        // stream that is not 188-byte TS.
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val w = TsWriter()
        w.pat(PMT_PID)
        w.pmt(PMT_PID, listOf(VIDEO_PID to 0x1B, AUDIO_PID to 0x03))
        val pts = (l + 3600) and PTS_MASK
        w.pes(VIDEO_PID, 0xE0, pts, videoEs(0x1B, rap = true, rapKind = RAP_IDR), unbounded = true)
        w.pes(AUDIO_PID, 0xC0, pts, ByteArray(20) { 0x11 }, unbounded = false)
        val two = w.bytes() + ByteArray(2_000) { 0x5B }
        assertEquals(4 * 188, w.bytes().size)

        val r = splice(one.bytes, two)
        assertEquals(SpliceDecision.Rejected(SpliceRejectReason.NOT_TS), r.decision)
        assertEquals(0, r.after.size)
    }

    // ── 3. The refusals ──────────────────────────────────────────────────────

    @Test
    fun `a gap inside the bound still splices`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l + 500 * 90, frames = 100)
        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed
        // Nothing to trim — the candidate starts after the old link stopped.
        assertEquals(0L, decision.info.overlapTrimmedMs)
        assertEquals(540L, decision.info.skippedMs)
    }

    @Test
    fun `a gap past the bound is refused`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l + 2_000 * 90, frames = 100)
        val r = splice(one.bytes, two.bytes)
        assertEquals(
            SpliceDecision.Rejected(SpliceRejectReason.GAP_TOO_LARGE),
            r.decision,
        )
        assertEquals(0, r.after.size)
    }

    @Test
    fun `a splice point past the skip bound is refused as a skip, not as a missing RAP`() {
        // The two tokens mean different things and both have to stay reachable:
        // here a usable IDR *is* found, and it is refused only because of how
        // much programme content it would jump over. `NO_RAP` is the case where
        // the scan found nothing it would splice at inside the same budget.
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l + 900 * 90, frames = 100)
        val r = splice(one.bytes, two.bytes, TsSplicer(maxSkipMs = 500))
        assertEquals(
            SpliceDecision.Rejected(SpliceRejectReason.SKIP_TOO_LARGE),
            r.decision,
        )
        assertEquals(0, r.after.size)
    }

    @Test
    fun `a renumbered timeline is refused as unrelated`() {
        val one = buildLink(startPts = 900_000 + 200_000 * 90, frames = 650)
        val l = one.frames.last().pts
        // 200 s "behind" is past the 120 s overlap bound: not the same timeline.
        val two = buildLink(startPts = l - 200_000 * 90, frames = 200)
        val r = splice(one.bytes, two.bytes)
        assertEquals(
            SpliceDecision.Rejected(SpliceRejectReason.PTS_UNRELATED),
            r.decision,
        )
        assertEquals(0, r.after.size)
    }

    @Test
    fun `a changed elementary-stream layout is refused`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 200, extraStream = 300 to 0x06)
        val r = splice(one.bytes, two.bytes)
        assertEquals(
            SpliceDecision.Rejected(SpliceRejectReason.PMT_CHANGED),
            r.decision,
        )
        assertEquals(0, r.after.size)
    }

    @Test
    fun `an HEVC stream whose only random access points are CRA finds no splice point`() {
        // CRA's leading pictures reference frames from the link that ended, so
        // it is deliberately not accepted; the scan then runs out of skip budget.
        val one = buildLink(startPts = 900_000, frames = 650, videoType = 0x24)
        val l = one.frames.last().pts
        val two = buildLink(
            startPts = l - 25_000 * 90,
            frames = 700,
            videoType = 0x24,
            rapKind = RAP_CRA,
        )
        val r = splice(one.bytes, two.bytes)
        assertEquals(
            SpliceDecision.Rejected(SpliceRejectReason.NO_RAP),
            r.decision,
        )
        assertEquals(0, r.after.size)
    }

    @Test
    fun `a candidate whose IDR is further away than the skip bound is refused`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        // A 5 s GOP: the first IDR past L is four seconds of programme away.
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700, gop = 125)
        val r = splice(one.bytes, two.bytes)
        assertEquals(
            SpliceDecision.Rejected(SpliceRejectReason.NO_RAP),
            r.decision,
        )
    }

    @Test
    fun `a byte budget that runs out before any verdict is refused`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700)
        val splicer = TsSplicer(maxCandidateBytes = 4_000)
        val sink = Sink()
        splicer.forwardCurrent(one.bytes, 0, one.bytes.size, sink.fn)
        splicer.endCurrent()
        val after = Sink()
        var decision: SpliceDecision = SpliceDecision.NeedMore
        var p = 0
        while (p < two.bytes.size && decision is SpliceDecision.NeedMore) {
            val n = minOf(1880, two.bytes.size - p)
            decision = splicer.offerCandidate(two.bytes, p, n, after.fn)
            p += n
        }
        assertEquals(SpliceDecision.Rejected(SpliceRejectReason.BUDGET), decision)
        assertEquals(0, after.bytes().size)
    }

    @Test
    fun `a candidate that is not TS is refused without emitting`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(one.bytes, 0, one.bytes.size, sink.fn)
        splicer.endCurrent()
        val after = Sink()
        val junk = ByteArray(4_000) { 0x11 }
        val decision = splicer.offerCandidate(junk, 0, junk.size, after.fn)
        assertEquals(SpliceDecision.Rejected(SpliceRejectReason.NOT_TS), decision)
        assertEquals(0, after.bytes().size)
        // Sticky until abandoned, and the current link is untouched.
        assertEquals(decision, splicer.offerCandidate(junk, 0, junk.size, after.fn))
        splicer.abandonCandidate()
        assertTrue(splicer.spliceable)
    }

    @Test
    fun `a link that was never spliceable never attempts a splice`() {
        val one = buildLink(startPts = 900_000, frames = 20, videoType = 0x02)
        val two = buildLink(startPts = 900_000, frames = 20, videoType = 0x02)
        val splicer = TsSplicer()
        val sink = Sink()
        splicer.forwardCurrent(one.bytes, 0, one.bytes.size, sink.fn)
        splicer.endCurrent()
        val after = Sink()
        val decision = splicer.offerCandidate(two.bytes, 0, two.bytes.size, after.fn)
        assertEquals(SpliceDecision.Rejected(SpliceRejectReason.UNSUPPORTED), decision)
        assertEquals(0, after.bytes().size)
    }

    // ── 4. Codec and ordering corners ────────────────────────────────────────

    @Test
    fun `an HEVC IDR commits and reports hevc`() {
        val one = buildLink(startPts = 900_000, frames = 650, videoType = 0x24)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700, videoType = 0x24)
        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed
        assertEquals(TsSplicer.CODEC_HEVC, decision.info.codec)
        val expectedS = two.frames.first { it.rap && TsSplicer.ptsDiff(it.pts, l) > 0 }.pts
        assertEquals(expectedS, parse(r.after).first { it.pid == VIDEO_PID && it.pusi }.pts)
    }

    @Test
    fun `reordered B-frame timestamps do not make a non-IDR the splice point`() {
        // Decode order I P B B with presentation order I B B P: several frames
        // past L arrive before the next IDR does, and none of them may be
        // chosen — only a NAL-confirmed IDR is a splice point.
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildReorderedLink(startPts = l - 25_000 * 90, gops = 200)
        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed

        val chosen = parse(r.after).first { it.pid == VIDEO_PID && it.pusi }.pts!!
        val frame = two.frames.first { it.pts == chosen }
        assertTrue("the splice point must be a RAP", frame.rap)
        assertTrue(TsSplicer.ptsDiff(chosen, l) > 0)
        // And at least one earlier-in-decode-order frame past L was passed over.
        val passedOver = two.frames.indexOfFirst { TsSplicer.ptsDiff(it.pts, l) > 0 }
        val chosenAt = two.frames.indexOfFirst { it.pts == chosen }
        assertTrue("nothing was passed over", chosenAt > passedOver)
        assertTrue(decision.info.skippedMs > 0)
    }

    @Test
    fun `a splice across the 33-bit PTS wrap is read as continuous`() {
        // L sits just past the wrap; the candidate's overlap is still before it.
        val one = buildLink(startPts = PTS_MODULUS - 600 * 3600, frames = 650)
        val l = one.frames.last().pts
        assertTrue("fixture must wrap", l < 600 * 3600)
        val two = buildLink(startPts = (l - 25_000 * 90) and PTS_MASK, frames = 700)
        val r = splice(one.bytes, two.bytes)
        val decision = r.decision as SpliceDecision.Committed
        assertEquals(25_000L, decision.info.overlapTrimmedMs)
        assertTrue(decision.info.skippedMs in 1..1040)
        val expectedS = two.frames.first { it.rap && TsSplicer.ptsDiff(it.pts, l) > 0 }.pts
        assertEquals(expectedS, parse(r.after).first { it.pid == VIDEO_PID && it.pusi }.pts)
    }

    @Test
    fun `ptsDiff is wrap-aware in both directions`() {
        assertEquals(90L, TsSplicer.ptsDiff(90, 0))
        assertEquals(-90L, TsSplicer.ptsDiff(0, 90))
        // One tick either side of the wrap.
        assertEquals(1L, TsSplicer.ptsDiff(0, PTS_MASK))
        assertEquals(-1L, TsSplicer.ptsDiff(PTS_MASK, 0))
        // Half the circle is the fold point, and it folds to the negative side.
        assertEquals(-(1L shl 32), TsSplicer.ptsDiff((1L shl 32), 0))
    }

    // ── 5. Successive splices, and chunking ──────────────────────────────────

    @Test
    fun `a second splice onto a spliced link also commits`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l1 = one.frames.last().pts
        val two = buildLink(startPts = l1 - 25_000 * 90, frames = 700)
        val splicer = TsSplicer()

        val s1 = Sink()
        splicer.forwardCurrent(one.bytes, 0, one.bytes.size, s1.fn)
        splicer.endCurrent()

        val s2 = Sink()
        val first = feedCandidate(splicer, two.bytes, s2.fn)
        assertTrue("first splice: $first", first is SpliceDecision.Committed)
        splicer.endCurrent()
        assertTrue(splicer.spliceable)

        val emittedFromTwo = parse(s2.bytes())
        val l2 = emittedFromTwo.last { it.pid == VIDEO_PID && it.pusi }.pts!!
        val three = buildLink(startPts = (l2 - 25_000 * 90) and PTS_MASK, frames = 700)

        val s3 = Sink()
        val second = feedCandidate(splicer, three.bytes, s3.fn)
        assertTrue("second splice: $second", second is SpliceDecision.Committed)

        // The second seam's discontinuity is computed against the counters the
        // *first* splice emitted, not against the candidate link's own.
        val lastCc = HashMap<Int, Int>()
        for (p in emittedFromTwo) lastCc[p.pid] = p.cc
        val seen = HashSet<Int>()
        for (p in parse(s3.bytes())) {
            if (seen.add(p.pid)) {
                assertEquals("pid=${p.pid}", (lastCc[p.pid]!! + 2) and 0x0F, p.cc)
            }
        }
        assertTrue(seen.contains(VIDEO_PID))
        assertTrue(seen.contains(AUDIO_PID))
    }

    @Test
    fun `arbitrary chunk boundaries produce an identical byte stream`() {
        val one = buildLink(startPts = 900_000, frames = 650)
        val l = one.frames.last().pts
        val two = buildLink(startPts = l - 25_000 * 90, frames = 700)

        val whole = splice(one.bytes, two.bytes)
        assertTrue(whole.decision is SpliceDecision.Committed)

        val rng = Random(20_261_113)
        repeat(4) {
            val splicer = TsSplicer()
            val before = Sink()
            var p = 0
            while (p < one.bytes.size) {
                val n = minOf(1 + rng.nextInt(997), one.bytes.size - p)
                splicer.forwardCurrent(one.bytes, p, n, before.fn)
                p += n
            }
            splicer.endCurrent()
            val after = Sink()
            var decision: SpliceDecision = SpliceDecision.NeedMore
            var q = 0
            while (q < two.bytes.size) {
                val n = minOf(1 + rng.nextInt(997), two.bytes.size - q)
                if (decision is SpliceDecision.Committed) {
                    splicer.forwardCurrent(two.bytes, q, n, after.fn)
                } else {
                    decision = splicer.offerCandidate(two.bytes, q, n, after.fn)
                }
                q += n
            }
            assertEquals(whole.decision, decision)
            assertArrayEquals(whole.before, before.bytes())
            assertArrayEquals(whole.after, after.bytes())
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────────────

private const val PMT_PID = 0x1000
private const val VIDEO_PID = 0x0100
private const val AUDIO_PID = 0x0101
private const val PTS_MODULUS = 1L shl 33
private const val PTS_MASK = PTS_MODULUS - 1
private const val RAP_IDR = 0
private const val RAP_CRA = 1

private class Sink {
    private val out = ByteArrayOutputStream()
    val fn: (ByteArray, Int, Int) -> Unit = { a, o, l -> out.write(a, o, l) }
    fun bytes(): ByteArray = out.toByteArray()
}

/** One descriptor: tag, length, and [len] body bytes. */
private fun descriptor(tag: Int, len: Int): ByteArray =
    byteArrayOf(tag.toByte(), len.toByte()) + ByteArray(len) { (it and 0x7F).toByte() }

private data class Frame(val pts: Long, val rap: Boolean)

private class Built(val bytes: ByteArray, val frames: List<Frame>)

private class Spliced(val decision: SpliceDecision, val before: ByteArray, val after: ByteArray)

/** Forwards [one], ends it, then feeds [two] as a candidate in 4 KiB chunks. */
private fun splice(one: ByteArray, two: ByteArray, splicer: TsSplicer = TsSplicer()): Spliced {
    val before = Sink()
    splicer.forwardCurrent(one, 0, one.size, before.fn)
    splicer.endCurrent()
    val after = Sink()
    val decision = feedCandidate(splicer, two, after.fn)
    return Spliced(decision, before.bytes(), after.bytes())
}

private fun feedCandidate(
    splicer: TsSplicer,
    link: ByteArray,
    sink: (ByteArray, Int, Int) -> Unit,
): SpliceDecision {
    var decision: SpliceDecision = SpliceDecision.NeedMore
    var p = 0
    while (p < link.size) {
        val n = minOf(4096, link.size - p)
        if (decision is SpliceDecision.Committed) {
            splicer.forwardCurrent(link, p, n, sink)
        } else {
            decision = splicer.offerCandidate(link, p, n, sink)
            if (decision is SpliceDecision.Rejected) return decision
        }
        p += n
    }
    return decision
}

/**
 * One link: PAT + PMT every [psiEvery] frames, then one video PES and one audio
 * PES per frame, each small enough to fit a single packet.
 */
private fun buildLink(
    startPts: Long,
    frames: Int,
    frameTicks: Long = 3600,
    gop: Int = 25,
    psiEvery: Int = 25,
    videoType: Int = 0x1B,
    rapKind: Int = RAP_IDR,
    extraStream: Pair<Int, Int>? = null,
    audioLag: Int = 0,
    programInfo: ByteArray = ByteArray(0),
    esInfo: ByteArray = ByteArray(0),
    rapPadBytes: Int = 0,
): Built {
    val w = TsWriter()
    val streams = mutableListOf(VIDEO_PID to videoType, AUDIO_PID to 0x03)
    extraStream?.let { streams.add(it) }
    val list = ArrayList<Frame>(frames)
    for (f in 0 until frames) {
        if (f % psiEvery == 0) {
            w.pat(PMT_PID)
            w.pmt(PMT_PID, streams, programInfo, esInfo)
        }
        val pts = (startPts + f * frameTicks) and PTS_MASK
        val rap = f % gop == 0
        list.add(Frame(pts, rap))
        w.pes(VIDEO_PID, 0xE0, pts, videoEs(videoType, rap, rapKind, rapPadBytes), unbounded = true)
        if (f >= audioLag) {
            val audioPts = (startPts + (f - audioLag) * frameTicks) and PTS_MASK
            w.pes(AUDIO_PID, 0xC0, audioPts, ByteArray(20) { 0x11 }, unbounded = false)
        }
    }
    return Built(w.bytes(), list)
}

/**
 * A link whose decode order is I P B B per group, so presentation timestamps
 * are not monotonic inside a group.
 */
private fun buildReorderedLink(startPts: Long, gops: Int, frameTicks: Long = 3600): Built {
    val w = TsWriter()
    val streams = listOf(VIDEO_PID to 0x1B, AUDIO_PID to 0x03)
    val list = ArrayList<Frame>(gops * 4)
    for (g in 0 until gops) {
        if (g % 6 == 0) {
            w.pat(PMT_PID)
            w.pmt(PMT_PID, streams)
        }
        val base = startPts + g * 4 * frameTicks
        // Decode order, with presentation order 0, 1, 2, 3.
        val order = listOf(0L to true, 3L to false, 1L to false, 2L to false)
        for ((slot, rap) in order) {
            val pts = (base + slot * frameTicks) and PTS_MASK
            list.add(Frame(pts, rap))
            w.pes(VIDEO_PID, 0xE0, pts, videoEs(0x1B, rap, RAP_IDR), unbounded = true)
            w.pes(AUDIO_PID, 0xC0, pts, ByteArray(20) { 0x11 }, unbounded = false)
        }
    }
    return Built(w.bytes(), list)
}

/**
 * Annex-B elementary bytes: an access delimiter, parameter sets on a RAP, a
 * slice. [padBytes] inserts a filler NAL ahead of the slice, which pushes the
 * slice header into a later packet of the same PES.
 */
private fun videoEs(videoType: Int, rap: Boolean, rapKind: Int, padBytes: Int = 0): ByteArray {
    val out = ByteArrayOutputStream()
    fun nal(vararg header: Int) {
        out.write(byteArrayOf(0, 0, 0, 1))
        for (b in header) out.write(b)
        out.write(byteArrayOf(0x80.toByte(), 0x01, 0x02))
    }
    fun filler(type: Int) {
        if (padBytes <= 0) return
        out.write(byteArrayOf(0, 0, 0, 1))
        out.write(type)
        // Filler payload is 0xFF, which cannot contain a start code.
        out.write(ByteArray(padBytes) { 0xFF.toByte() })
    }
    if (videoType == 0x24) {
        nal(0x46, 0x01) // AUD (35)
        if (rap) {
            nal(0x40, 0x01) // VPS (32)
            nal(0x42, 0x01) // SPS (33)
            nal(0x44, 0x01) // PPS (34)
            filler(0x4C) // FD_NUT (38)
            nal(if (rapKind == RAP_IDR) 0x26 else 0x2A, 0x01) // IDR_W_RADL (19) / CRA_NUT (21)
        } else {
            nal(0x02, 0x01) // TRAIL_R (1)
        }
    } else {
        nal(0x09, 0x10) // AUD
        if (rap) {
            nal(0x67, 0x42, 0x00) // SPS
            nal(0x68, 0xCE) // PPS
            filler(0x0C) // filler data
            nal(0x65, 0x88) // IDR slice
        } else {
            nal(0x61, 0x9A) // non-IDR slice
        }
    }
    return out.toByteArray()
}

/** Writes well-formed 188-byte transport packets with running continuity counters. */
private class TsWriter {
    private val out = ByteArrayOutputStream()
    private val cc = HashMap<Int, Int>()

    fun bytes(): ByteArray = out.toByteArray()

    private fun nextCc(pid: Int): Int {
        val next = ((cc[pid] ?: 15) + 1) and 0x0F
        cc[pid] = next
        return next
    }

    /** One packet carrying [len] payload bytes, stuffed out with an adaptation field. */
    fun packet(pid: Int, pusi: Boolean, payload: ByteArray, from: Int, len: Int) {
        val p = ByteArray(188)
        p[0] = 0x47
        p[1] = (((if (pusi) 0x40 else 0x00) or ((pid shr 8) and 0x1F)).toByte())
        p[2] = (pid and 0xFF).toByte()
        val counter = nextCc(pid)
        val stuffing = 184 - len
        val payloadStart: Int
        if (stuffing > 0) {
            p[3] = (0x30 or counter).toByte()
            p[4] = (stuffing - 1).toByte()
            if (stuffing >= 2) {
                p[5] = 0
                for (i in 6 until 4 + stuffing) p[i] = 0xFF.toByte()
            }
            payloadStart = 4 + stuffing
        } else {
            p[3] = (0x10 or counter).toByte()
            payloadStart = 4
        }
        System.arraycopy(payload, from, p, payloadStart, len)
        out.write(p)
    }

    /** A PSI section, split across packets when it does not fit in one. */
    fun section(pid: Int, section: ByteArray) {
        val first = minOf(183, section.size)
        val head = ByteArray(1 + first)
        head[0] = 0 // pointer_field
        System.arraycopy(section, 0, head, 1, first)
        packet(pid, pusi = true, payload = head, from = 0, len = head.size)
        var p = first
        while (p < section.size) {
            val n = minOf(184, section.size - p)
            packet(pid, pusi = false, payload = section, from = p, len = n)
            p += n
        }
    }

    fun pat(pmtPid: Int) {
        val body = ByteArray(9)
        body[0] = 0x00 // transport_stream_id
        body[1] = 0x01
        body[2] = 0xC1.toByte() // version 0, current
        body[3] = 0x00 // section_number
        body[4] = 0x00 // last_section_number
        body[5] = 0x00 // program_number 1
        body[6] = 0x01
        body[7] = (0xE0 or ((pmtPid shr 8) and 0x1F)).toByte()
        body[8] = (pmtPid and 0xFF).toByte()
        section(0, psiSection(0x00, body))
    }

    fun pmt(
        pmtPid: Int,
        streams: List<Pair<Int, Int>>,
        programInfo: ByteArray = ByteArray(0),
        esInfo: ByteArray = ByteArray(0),
    ) {
        val body = ByteArray(9 + programInfo.size + streams.size * (5 + esInfo.size))
        body[0] = 0x00 // program_number 1
        body[1] = 0x01
        body[2] = 0xC1.toByte()
        body[3] = 0x00
        body[4] = 0x00
        body[5] = (0xE0 or ((VIDEO_PID shr 8) and 0x1F)).toByte() // PCR PID
        body[6] = (VIDEO_PID and 0xFF).toByte()
        body[7] = (0xF0 or ((programInfo.size shr 8) and 0x0F)).toByte()
        body[8] = (programInfo.size and 0xFF).toByte()
        System.arraycopy(programInfo, 0, body, 9, programInfo.size)
        var i = 9 + programInfo.size
        for ((pid, type) in streams) {
            body[i] = type.toByte()
            body[i + 1] = (0xE0 or ((pid shr 8) and 0x1F)).toByte()
            body[i + 2] = (pid and 0xFF).toByte()
            body[i + 3] = (0xF0 or ((esInfo.size shr 8) and 0x0F)).toByte()
            body[i + 4] = (esInfo.size and 0xFF).toByte()
            System.arraycopy(esInfo, 0, body, i + 5, esInfo.size)
            i += 5 + esInfo.size
        }
        section(pmtPid, psiSection(0x02, body))
    }

    fun pes(pid: Int, streamId: Int, pts: Long, es: ByteArray, unbounded: Boolean) {
        val header = ByteArray(14)
        header[0] = 0
        header[1] = 0
        header[2] = 1
        header[3] = streamId.toByte()
        val packetLength = if (unbounded) 0 else 3 + 5 + es.size
        header[4] = ((packetLength shr 8) and 0xFF).toByte()
        header[5] = (packetLength and 0xFF).toByte()
        header[6] = 0x80.toByte() // '10' marker, no scrambling
        header[7] = 0x80.toByte() // PTS only
        header[8] = 5
        header[9] = (0x21 or (((pts shr 30) and 0x07).toInt() shl 1)).toByte()
        header[10] = ((pts shr 22) and 0xFF).toByte()
        header[11] = ((((pts shr 15) and 0x7F).toInt() shl 1) or 1).toByte()
        header[12] = ((pts shr 7) and 0xFF).toByte()
        header[13] = ((((pts and 0x7F).toInt()) shl 1) or 1).toByte()
        val unit = header + es
        var p = 0
        var first = true
        while (p < unit.size) {
            val n = minOf(184, unit.size - p)
            packet(pid, pusi = first, payload = unit, from = p, len = n)
            p += n
            first = false
        }
    }

    private fun psiSection(tableId: Int, body: ByteArray): ByteArray {
        val sectionLength = body.size + 4
        val s = ByteArray(3 + sectionLength)
        s[0] = tableId.toByte()
        s[1] = (0xB0 or ((sectionLength shr 8) and 0x0F)).toByte()
        s[2] = (sectionLength and 0xFF).toByte()
        System.arraycopy(body, 0, s, 3, body.size)
        val crc = mpegCrc32(s, 0, s.size - 4)
        s[s.size - 4] = ((crc shr 24) and 0xFF).toByte()
        s[s.size - 3] = ((crc shr 16) and 0xFF).toByte()
        s[s.size - 2] = ((crc shr 8) and 0xFF).toByte()
        s[s.size - 1] = (crc and 0xFF).toByte()
        return s
    }
}

private fun mpegCrc32(d: ByteArray, from: Int, len: Int): Int {
    var crc = -1
    for (i in from until from + len) {
        crc = crc xor ((d[i].toInt() and 0xFF) shl 24)
        repeat(8) {
            crc = if (crc < 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1
        }
    }
    return crc
}

// ─────────────────────────────────────────────────────────────────────────────
// Reading back what was emitted
// ─────────────────────────────────────────────────────────────────────────────

private data class Pkt(val pid: Int, val pusi: Boolean, val cc: Int, val pts: Long?)

private fun parse(bytes: ByteArray): List<Pkt> {
    val out = ArrayList<Pkt>(bytes.size / 188)
    var p = 0
    while (p + 188 <= bytes.size) {
        require((bytes[p].toInt() and 0xFF) == 0x47) { "emitted stream lost alignment at $p" }
        val b1 = bytes[p + 1].toInt() and 0xFF
        val b2 = bytes[p + 2].toInt() and 0xFF
        val b3 = bytes[p + 3].toInt() and 0xFF
        val pid = ((b1 and 0x1F) shl 8) or b2
        val pusi = (b1 and 0x40) != 0
        var pts: Long? = null
        if ((b3 and 0x10) != 0) {
            val po = if ((b3 and 0x20) != 0) p + 5 + (bytes[p + 4].toInt() and 0xFF) else p + 4
            val end = p + 188
            if (pusi && po + 14 <= end &&
                bytes[po].toInt() == 0 && bytes[po + 1].toInt() == 0 &&
                (bytes[po + 2].toInt() and 0xFF) == 1 && (bytes[po + 7].toInt() and 0xC0) != 0
            ) {
                val b0 = bytes[po + 9].toInt() and 0xFF
                val c1 = bytes[po + 10].toInt() and 0xFF
                val c2 = bytes[po + 11].toInt() and 0xFF
                val c3 = bytes[po + 12].toInt() and 0xFF
                val c4 = bytes[po + 13].toInt() and 0xFF
                pts = ((b0 and 0x0E).toLong() shl 29) or
                    (c1.toLong() shl 22) or
                    ((c2 and 0xFE).toLong() shl 14) or
                    (c3.toLong() shl 7) or
                    ((c4 and 0xFE).toLong() shr 1)
            }
        }
        out.add(Pkt(pid, pusi, b3 and 0x0F, pts))
        p += 188
    }
    require(p == bytes.size) { "emitted stream had a partial packet" }
    return out
}
