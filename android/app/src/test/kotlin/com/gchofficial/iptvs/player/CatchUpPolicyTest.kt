package com.gchofficial.iptvs.player

import androidx.media3.common.MimeTypes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Catch-up is the only thing in the live-latency work that changes what the
 * viewer hears, so the whole of it is decided here, where a device is not
 * needed to prove it.
 *
 * Two properties carry most of the risk and are asserted everywhere below: the
 * speed is **never** below real time (slowing a live stream down would add the
 * delay this is supposed to remove), and every veto is a *forcing* condition —
 * a rule that only prevented *engaging* would leave a stream sped up through
 * the pause, the rebuffer or the handoff that came after it.
 */
class CatchUpPolicyTest {
    private val target = 15_000L // ExoBufferPolicy NORMAL's sustained cushion.

    private fun sample(
        nowMs: Long = 0L,
        aheadMs: Long,
        isLive: Boolean = true,
        isPlaying: Boolean = true,
        isBuffering: Boolean = false,
        reconnecting: Boolean = false,
        zapSettling: Boolean = false,
        inHandoffWindow: Boolean = false,
        sharedPreview: Boolean = false,
        engineManagesLiveOffset: Boolean = false,
        audio: String? = MimeTypes.AUDIO_AAC,
        actualSpeed: Float = CatchUpPolicy.SPEED,
    ) = CatchUpSample(
        nowMs = nowMs,
        aheadMs = aheadMs,
        targetMs = target,
        isLive = isLive,
        isPlaying = isPlaying,
        isBuffering = isBuffering,
        reconnecting = reconnecting,
        zapSettling = zapSettling,
        inHandoffWindow = inHandoffWindow,
        sharedPreview = sharedPreview,
        engineManagesLiveOffset = engineManagesLiveOffset,
        audioSampleMimeType = audio,
        actualSpeed = actualSpeed,
    )

    /** Engages a controller and returns it, asserting that it really did. */
    private fun engaged(c: CatchUpController = CatchUpController()): CatchUpController {
        val d = c.decide(sample(aheadMs = 40_000))
        assertTrue(d.changed)
        assertEquals(CatchUpPolicy.SPEED, d.speed, 0f)
        return c
    }

    // ── Hysteresis ──────────────────────────────────────────────────────────

    @Test
    fun `the engage threshold is the cushion plus the margin, exclusive`() {
        val c = CatchUpController()
        // Exactly at the threshold is not past it: the margin exists to clear
        // the loader's own overshoot, and sitting on the boundary is overshoot.
        val at = c.decide(sample(aheadMs = target + CatchUpPolicy.ENGAGE_MARGIN_MS))
        assertEquals(CatchUpPolicy.NORMAL_SPEED, at.speed, 0f)
        assertFalse(at.changed)
        assertFalse(at.catchingUp)

        val past = c.decide(sample(aheadMs = target + CatchUpPolicy.ENGAGE_MARGIN_MS + 1))
        assertEquals(CatchUpPolicy.SPEED, past.speed, 0f)
        assertTrue(past.changed)
        assertTrue(past.catchingUp)
    }

    @Test
    fun `it keeps running all the way back down to the cushion`() {
        val c = engaged()
        // Anywhere between the cushion and the engage threshold it stays on —
        // that gap is the hysteresis, and without it the speed would flip
        // several times a minute as the loader steers around minBufferMs.
        for (ahead in longArrayOf(24_000, 20_000, 15_001)) {
            val d = c.decide(sample(aheadMs = ahead))
            assertEquals("ahead=$ahead", CatchUpPolicy.SPEED, d.speed, 0f)
            assertFalse("ahead=$ahead", d.changed)
        }
        val off = c.decide(sample(aheadMs = target))
        assertEquals(CatchUpPolicy.NORMAL_SPEED, off.speed, 0f)
        assertTrue(off.changed)
        assertEquals(CatchUpPolicy.offLine(CatchUpVeto.IN_RANGE), off.log)
    }

    @Test
    fun `an unknown cushion neither engages nor disengages`() {
        val c = CatchUpController()
        assertFalse(c.decide(sample(aheadMs = -1)).catchingUp)
        engaged(c)
        // -1 is "the engine did not say", which is no reason to act either way.
        val d = c.decide(sample(aheadMs = -1))
        assertTrue(d.catchingUp)
        assertFalse(d.changed)
    }

    @Test
    fun `the speed is never below real time`() {
        val c = CatchUpController()
        val samples = listOf(
            sample(aheadMs = -1),
            sample(aheadMs = 0),
            sample(aheadMs = 90_000),
            sample(aheadMs = 90_000, isBuffering = true),
            sample(aheadMs = 0, isPlaying = false),
        )
        for (s in samples) {
            assertTrue(c.decide(s).speed >= CatchUpPolicy.NORMAL_SPEED)
        }
    }

    // ── Logging ─────────────────────────────────────────────────────────────

    @Test
    fun `it logs on change only`() {
        val c = CatchUpController()
        assertNull(c.decide(sample(aheadMs = 20_000)).log)
        assertEquals(
            "live catchup on ahead=40000ms target=15000ms",
            c.decide(sample(aheadMs = 40_000)).log,
        )
        // Twice a second for the life of a session: a line per tick would bury
        // the export, and a setPlaybackSpeed per tick would drain the audio
        // processors for no change at all.
        assertNull(c.decide(sample(aheadMs = 39_000)).log)
        assertNull(c.decide(sample(aheadMs = 38_000)).log)
        assertEquals(
            "live catchup off reason=paused",
            c.decide(sample(aheadMs = 38_000, isPlaying = false)).log,
        )
        assertNull(c.decide(sample(aheadMs = 38_000, isPlaying = false)).log)
    }

    // ── Vetoes ──────────────────────────────────────────────────────────────

    @Test
    fun `every veto forces real time, not merely refuses to engage`() {
        val cases = listOf(
            CatchUpVeto.NOT_LIVE to sample(aheadMs = 40_000, isLive = false),
            CatchUpVeto.PREVIEW to sample(aheadMs = 40_000, sharedPreview = true),
            CatchUpVeto.ENGINE_LIVE to sample(aheadMs = 40_000, engineManagesLiveOffset = true),
            CatchUpVeto.AUDIO to sample(aheadMs = 40_000, audio = MimeTypes.AUDIO_E_AC3),
            CatchUpVeto.PAUSED to sample(aheadMs = 40_000, isPlaying = false),
            CatchUpVeto.BUFFERING to sample(aheadMs = 40_000, isBuffering = true),
            CatchUpVeto.RECONNECTING to sample(aheadMs = 40_000, reconnecting = true),
            CatchUpVeto.ZAP_SETTLING to sample(aheadMs = 40_000, zapSettling = true),
            CatchUpVeto.HANDOFF to sample(aheadMs = 40_000, inHandoffWindow = true),
        )
        for ((reason, vetoed) in cases) {
            // Engage first: the dangerous shape is a stream left running fast
            // *into* one of these, not one that never started.
            val c = engaged()
            val d = c.decide(vetoed)
            assertEquals(reason, CatchUpPolicy.NORMAL_SPEED, d.speed, 0f)
            assertTrue(reason, d.changed)
            assertFalse(reason, d.catchingUp)
            assertEquals("live catchup off reason=$reason", d.log)
            // …and recovering from it re-crosses the engage threshold rather
            // than resuming silently, so a flapping stream cannot toggle the
            // speed on every blip.
            assertFalse(c.decide(sample(aheadMs = 20_000)).catchingUp)
            assertTrue(c.decide(sample(aheadMs = 40_000)).catchingUp)
        }
    }

    @Test
    fun `a veto also refuses to engage in the first place`() {
        for (vetoed in listOf(
            sample(aheadMs = 40_000, isLive = false),
            sample(aheadMs = 40_000, isPlaying = false),
            sample(aheadMs = 40_000, isBuffering = true),
            sample(aheadMs = 40_000, reconnecting = true),
            sample(aheadMs = 40_000, zapSettling = true),
            sample(aheadMs = 40_000, inHandoffWindow = true),
            sample(aheadMs = 40_000, sharedPreview = true),
            sample(aheadMs = 40_000, engineManagesLiveOffset = true),
            sample(aheadMs = 40_000, audio = null),
        )) {
            assertFalse(CatchUpController().decide(vetoed).catchingUp)
        }
    }

    // ── The audio gate ──────────────────────────────────────────────────────

    @Test
    fun `audio the device decodes to PCM may be re-timed`() {
        for (mime in listOf(
            MimeTypes.AUDIO_AAC,
            MimeTypes.AUDIO_MPEG,
            MimeTypes.AUDIO_MPEG_L1,
            MimeTypes.AUDIO_MPEG_L2,
            MimeTypes.AUDIO_OPUS,
            MimeTypes.AUDIO_VORBIS,
            MimeTypes.AUDIO_FLAC,
            MimeTypes.AUDIO_RAW,
        )) {
            assertTrue(mime, CatchUpPolicy.audioAllowsSpeedUp(mime))
        }
    }

    @Test
    fun `the gate matches the mime type media3 actually hands over`() {
        // `Format.sampleMimeType` is normalised through
        // `MimeTypes.normalizeMimeType`, which ASCII-lowercases — so media3's
        // own `AUDIO_MPEG_L2` constant ("audio/mpeg-L2") arrives as
        // "audio/mpeg-l2". A set built from the constants and compared
        // case-sensitively would silently refuse MPEG-1 Layer II, which is what
        // a large share of DVB-sourced IPTV carries.
        assertTrue(CatchUpPolicy.audioAllowsSpeedUp("audio/mpeg-l2"))
        assertTrue(CatchUpPolicy.audioAllowsSpeedUp("audio/mpeg-l1"))
        assertTrue(CatchUpPolicy.audioAllowsSpeedUp("AUDIO/MP4A-LATM"))
        assertTrue(CatchUpPolicy.audioAllowsSpeedUp(" audio/mpeg "))
    }

    @Test
    fun `encoded audio bound for a receiver is refused`() {
        // Passthrough: media3 will not re-time what it is not decoding, so the
        // request would be ignored — or, on a device that applied it to the
        // video clock alone, it would desync a stream that was playing fine.
        for (mime in listOf(
            MimeTypes.AUDIO_AC3,
            MimeTypes.AUDIO_E_AC3,
            MimeTypes.AUDIO_E_AC3_JOC,
            MimeTypes.AUDIO_AC4,
            MimeTypes.AUDIO_DTS,
            MimeTypes.AUDIO_DTS_HD,
            MimeTypes.AUDIO_TRUEHD,
        )) {
            assertFalse(mime, CatchUpPolicy.audioAllowsSpeedUp(mime))
        }
    }

    @Test
    fun `an unknown or absent codec fails closed`() {
        assertFalse(CatchUpPolicy.audioAllowsSpeedUp(null))
        assertFalse(CatchUpPolicy.audioAllowsSpeedUp(""))
        assertFalse(CatchUpPolicy.audioAllowsSpeedUp("   "))
        assertFalse(CatchUpPolicy.audioAllowsSpeedUp("audio/x-tomorrows-codec"))
        // Not a prefix match: a block-list mistake here is a desync, an
        // allow-list mistake is only a delay that stays.
        assertFalse(CatchUpPolicy.audioAllowsSpeedUp("audio/mpeg-l2x"))
    }

    // ── The read-back ───────────────────────────────────────────────────────

    @Test
    fun `a speed that never took disables catch-up for the session`() {
        val c = engaged()
        // Before the verification is due, the engine's own answer is still the
        // synchronous echo of the request — proof of nothing.
        val early = c.decide(
            sample(
                nowMs = CatchUpPolicy.VERIFY_AFTER_MS - 1,
                aheadMs = 40_000,
                actualSpeed = CatchUpPolicy.NORMAL_SPEED,
            ),
        )
        assertTrue(early.catchingUp)
        assertFalse(c.disabledForSession)

        val verdict = c.decide(
            sample(
                nowMs = CatchUpPolicy.VERIFY_AFTER_MS,
                aheadMs = 40_000,
                actualSpeed = CatchUpPolicy.NORMAL_SPEED,
            ),
        )
        assertEquals(CatchUpPolicy.NORMAL_SPEED, verdict.speed, 0f)
        assertTrue(verdict.changed)
        assertEquals("live catchup off reason=unsupported", verdict.log)
        assertTrue(c.disabledForSession)

        // …and it never tries again, however healthy the stream looks. The
        // thing that failed is the device's audio path, not the channel.
        val later = c.decide(sample(nowMs = 60_000, aheadMs = 90_000))
        assertFalse(later.catchingUp)
        assertNull(later.log)
    }

    @Test
    fun `a speed that took is believed and not re-probed`() {
        val c = engaged()
        val ok = c.decide(sample(nowMs = CatchUpPolicy.VERIFY_AFTER_MS, aheadMs = 40_000))
        assertTrue(ok.catchingUp)
        assertFalse(c.disabledForSession)
        // A transient 1.0 read long after the verification (a decoder re-init,
        // a track change) must not retire a feature that demonstrably works.
        val muchLater = c.decide(
            sample(nowMs = 60_000, aheadMs = 40_000, actualSpeed = CatchUpPolicy.NORMAL_SPEED),
        )
        assertTrue(muchLater.catchingUp)
        assertFalse(c.disabledForSession)
    }

    @Test
    fun `the session verdict survives a reset`() {
        val c = engaged()
        c.decide(
            sample(
                nowMs = CatchUpPolicy.VERIFY_AFTER_MS,
                aheadMs = 40_000,
                actualSpeed = CatchUpPolicy.NORMAL_SPEED,
            ),
        )
        assertTrue(c.disabledForSession)
        c.reset()
        // A zap is not new evidence about the device's audio path, and
        // re-probing on every channel change would mean a repeated half-second
        // of sped-up-then-not audio for a user whose hardware never allows it.
        assertFalse(c.decide(sample(nowMs = 90_000, aheadMs = 90_000)).catchingUp)
        assertTrue(c.disabledForSession)
    }

    @Test
    fun `each engagement is verified on its own`() {
        val c = engaged()
        // Verified good, then stood down and re-engaged: the second engagement
        // gets its own read-back, which is what catches a mid-session switch to
        // a passthrough audio track.
        c.decide(sample(nowMs = CatchUpPolicy.VERIFY_AFTER_MS, aheadMs = 40_000))
        c.decide(sample(nowMs = 2_000, aheadMs = target))
        c.decide(sample(nowMs = 3_000, aheadMs = 40_000))
        val verdict = c.decide(
            sample(
                nowMs = 3_000 + CatchUpPolicy.VERIFY_AFTER_MS,
                aheadMs = 40_000,
                actualSpeed = CatchUpPolicy.NORMAL_SPEED,
            ),
        )
        assertTrue(c.disabledForSession)
        assertEquals(CatchUpPolicy.NORMAL_SPEED, verdict.speed, 0f)
    }

    // ── Reset ───────────────────────────────────────────────────────────────

    @Test
    fun `a reset returns to real time and forgets the engagement`() {
        val c = engaged()
        assertEquals(CatchUpPolicy.SPEED, c.appliedSpeed, 0f)
        c.reset()
        assertEquals(CatchUpPolicy.NORMAL_SPEED, c.appliedSpeed, 0f)
        // The next stream re-earns it from scratch — including the log line,
        // so an export shows catch-up starting on the new channel rather than
        // appearing to have run continuously across the zap.
        val d = c.decide(sample(aheadMs = 40_000))
        assertTrue(d.changed)
        assertEquals("live catchup on ahead=40000ms target=15000ms", d.log)
    }

    // ── The target ──────────────────────────────────────────────────────────

    @Test
    fun `the target is the preset's own cushion`() {
        // A user who picks a deeper preset is asking to watch further behind
        // live; catch-up recovers only the delay they did not ask for, so the
        // threshold moves with the preset rather than being a constant.
        for (preset in BufferPreset.entries) {
            val cushion = ExoBufferPolicy.forPreset(preset).minBufferMs.toLong()
            val c = CatchUpController()
            assertFalse(
                "$preset",
                c.decide(
                    CatchUpSample(
                        nowMs = 0,
                        aheadMs = cushion + CatchUpPolicy.ENGAGE_MARGIN_MS,
                        targetMs = cushion,
                        isLive = true,
                        isPlaying = true,
                        isBuffering = false,
                        reconnecting = false,
                        zapSettling = false,
                        inHandoffWindow = false,
                        sharedPreview = false,
                        engineManagesLiveOffset = false,
                        audioSampleMimeType = MimeTypes.AUDIO_AAC,
                        actualSpeed = CatchUpPolicy.SPEED,
                    ),
                ).catchingUp,
            )
        }
    }

    /**
     * The engage threshold must stay reachable: a preset whose loader stops
     * filling before the threshold could never engage, and catch-up would be
     * silently dead on it.
     */
    @Test
    fun `every preset can reach the engage threshold`() {
        for (preset in BufferPreset.entries) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue(
                "$preset",
                b.maxBufferMs > b.minBufferMs + CatchUpPolicy.ENGAGE_MARGIN_MS,
            )
        }
    }

    @Test
    fun `the speed is the contract's, and above real time`() {
        assertEquals(1.05f, CatchUpPolicy.SPEED, 0f)
        assertEquals(1.0f, CatchUpPolicy.NORMAL_SPEED, 0f)
        assertTrue(CatchUpPolicy.SPEED > CatchUpPolicy.NORMAL_SPEED)
    }
}
