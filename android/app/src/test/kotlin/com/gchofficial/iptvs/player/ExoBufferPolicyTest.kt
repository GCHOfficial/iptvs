package com.gchofficial.iptvs.player

import androidx.media3.common.C
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every invariant here is asserted for **every** preset, not for one tuning.
 *
 * That is the point of the file now that the durations are user-selectable: the
 * dangerous edit is no longer "someone changed a constant", it is "someone added
 * a preset that looks reasonable in isolation and quietly violates the stall
 * margin". `DefaultLoadControl.Builder.setBufferDurationsMs` asserts some of the
 * orderings itself, but only at build time on a real device — this catches them
 * on CI instead of as a native crash on the first Android open.
 */
class ExoBufferPolicyTest {
    private val presets = BufferPreset.entries

    /**
     * The whole point of the tuning: start playback well before media3's
     * 2500ms `DEFAULT_BUFFER_FOR_PLAYBACK_MS`, which was 2.5s of black on
     * every zap, EPG-grid play and preview start.
     */
    @Test
    fun `every preset beats the media3 start defaults`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.forPlaybackMs < 2_500)
            assertTrue("$preset", b.afterRebufferMs < 5_000)
        }
    }

    /**
     * Regression guard on the reason this can't simply be pushed up: a stream
     * stuck below the resume threshold stays in `STATE_BUFFERING`, and
     * `ReconnectPolicy.STALL_RECONNECT_MS` (8s) of that reloads the source. The
     * resume threshold must keep a wide margin under it, or ordinary underruns
     * become a reconnect loop.
     *
     * This is the constraint that shapes the presets: it caps the resume
     * threshold at 2 s, which is why "high" buys its stall resistance from the
     * sustained cushion instead of from the start gates.
     */
    @Test
    fun `every preset stays far below the stall reconnect threshold`() {
        val stall = ReconnectPolicy.STALL_RECONNECT_MS
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.forPlaybackMs * 4L <= stall)
            assertTrue("$preset", b.afterRebufferMs * 4L <= stall)
        }
    }

    /** …and equally can't be pushed so low that it micro-rebuffers instead. */
    @Test
    fun `every preset respects the anti-micro-rebuffer floor`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.forPlaybackMs >= ExoBufferPolicy.MIN_PLAYBACK_BUFFER_FLOOR_MS)
            assertTrue("$preset", b.afterRebufferMs >= ExoBufferPolicy.MIN_PLAYBACK_BUFFER_FLOOR_MS)
            // Resuming after an underrun should hold *more* than a cold start,
            // so a flapping connection doesn't restart into an immediate second
            // stall.
            assertTrue("$preset", b.afterRebufferMs >= b.forPlaybackMs)
        }
    }

    /**
     * `DefaultLoadControl.Builder.setBufferDurationsMs` itself asserts these
     * orderings at build time — catch a bad edit here rather than as a native
     * crash on the first Android open.
     */
    @Test
    fun `every preset brackets its playback thresholds`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.minBufferMs >= b.forPlaybackMs)
            assertTrue("$preset", b.minBufferMs >= b.afterRebufferMs)
            assertTrue("$preset", b.maxBufferMs >= b.minBufferMs)
        }
    }

    /**
     * The presets have to be ordered to mean anything: picking "high" must
     * actually hold more media than "normal", which must hold more than "low".
     * Asserted on the *sustained* cushion, because that is the axis the presets
     * move — see [ExoBufferPolicy.forPreset].
     */
    @Test
    fun `the sustained cushion grows with the preset`() {
        val low = ExoBufferPolicy.forPreset(BufferPreset.LOW)
        val normal = ExoBufferPolicy.forPreset(BufferPreset.NORMAL)
        val high = ExoBufferPolicy.forPreset(BufferPreset.HIGH)
        val max = ExoBufferPolicy.forPreset(BufferPreset.MAX)
        assertTrue(low.minBufferMs < normal.minBufferMs)
        assertTrue(normal.minBufferMs < high.minBufferMs)
        assertTrue(high.minBufferMs < max.minBufferMs)
        assertTrue(low.maxBufferMs < normal.maxBufferMs)
        assertTrue(normal.maxBufferMs < high.maxBufferMs)
        assertTrue(high.maxBufferMs < max.maxBufferMs)
    }

    /**
     * The forward invariant, written so it binds any *future* preset too.
     *
     * Without a byte ceiling, media3 bounds the allocation at `maxBufferMs x
     * bitrate` and nothing else — and IPTV bitrates are not ours to predict: a
     * preset that is 19 MB on an SD channel is 156 MB on a UHD one, on hardware
     * that is routinely a 2 GiB Android TV box. Only [BufferPreset.LOW]'s 25 s
     * is small enough for the duration to be its own bound, so every preset
     * above it must name a ceiling.
     *
     * This was the shipped failure mode in miniature: a byte cap was added for
     * MAX alone, as though the hazard were the two-minute ceiling rather than
     * the bitrate multiplying it.
     */
    @Test
    fun `every preset above low must cap its bytes`() {
        val low = ExoBufferPolicy.forPreset(BufferPreset.LOW)
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            if (b.maxBufferMs <= low.maxBufferMs) continue
            assertTrue("$preset must set a finite targetBufferBytes", b.targetBufferBytes > 0)
        }
    }

    /**
     * The *second* byte rule, and a much narrower one: past HIGH's depth, even
     * a player below `minBufferMs` must be held to the cap.
     *
     * In media3 1.11.1 `DefaultLoadControl.shouldContinueLoading`,
     * `prioritizeTimeOverSizeThresholds` is consulted only on the
     * `bufferedDurationUs < minBufferUs` branch; above `minBufferUs` the loader
     * stops on `bufferedDurationUs >= maxBufferUs || targetBufferSizeReached`
     * regardless of it. So the flag does not weaken the cap in steady state —
     * it decides whether a *starving* player may exceed it to reach a playable
     * cushion, which it should, right up until the depth being asked for is
     * itself the hazard.
     */
    @Test
    fun `a preset deeper than high must let the bytes decide`() {
        val high = ExoBufferPolicy.forPreset(BufferPreset.HIGH)
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            if (b.maxBufferMs <= high.maxBufferMs) continue
            assertTrue("$preset must not prioritize time over size", !b.prioritizeTimeOverSize)
        }
    }

    /**
     * The shallowest preset keeps media3 sizing the allocation from the
     * durations: 25 s is bounded by its own ceiling on any bitrate this app
     * meets, and `LOW` exists for zapping, where the extra bookkeeping buys
     * nothing.
     */
    @Test
    fun `low still lets the durations size the allocation`() {
        val b = ExoBufferPolicy.forPreset(BufferPreset.LOW)
        assertEquals(C.LENGTH_UNSET, b.targetBufferBytes)
        assertEquals(ExoBufferPolicy.PRIORITIZE_TIME_OVER_SIZE, b.prioritizeTimeOverSize)
    }

    /**
     * A byte cap must not be allowed to undercut the preset it is capping: a
     * ceiling that binds before the *start* gate would be a player that can
     * never begin. The check is deliberately crude — 1 MB per second of start
     * gate is ~8 Mbps, far above what any of these presets realistically has to
     * clear — but it would catch a ceiling entered in MB instead of MiB, or a
     * digit lost.
     */
    @Test
    fun `a byte cap always clears the preset's own start gate`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            if (b.targetBufferBytes == C.LENGTH_UNSET) continue
            val floorBytes = b.afterRebufferMs / 1_000 * 1024 * 1024
            assertTrue("$preset", b.targetBufferBytes > floorBytes)
        }
    }

    /**
     * The caps are ordered with the presets they belong to: picking a deeper
     * preset must never lower the ceiling that preset is allowed to reach.
     */
    @Test
    fun `the byte caps never shrink as the presets deepen`() {
        val normal = ExoBufferPolicy.forPreset(BufferPreset.NORMAL)
        val high = ExoBufferPolicy.forPreset(BufferPreset.HIGH)
        val max = ExoBufferPolicy.forPreset(BufferPreset.MAX)
        assertEquals(48 * 1024 * 1024, normal.targetBufferBytes)
        assertEquals(64 * 1024 * 1024, high.targetBufferBytes)
        assertEquals(64 * 1024 * 1024, max.targetBufferBytes)
        assertTrue(normal.targetBufferBytes <= high.targetBufferBytes)
        assertTrue(high.targetBufferBytes <= max.targetBufferBytes)
    }

    /**
     * …and the presets that existed before the caps keep **prioritising time**,
     * so a starving player still fills to a playable cushion exactly as every
     * shipped build has. The cap bounds the steady state; it must not move the
     * start behaviour.
     */
    @Test
    fun `the shipped presets still prioritise time over size`() {
        for (preset in listOf(BufferPreset.LOW, BufferPreset.NORMAL, BufferPreset.HIGH)) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertEquals("$preset", ExoBufferPolicy.PRIORITIZE_TIME_OVER_SIZE, b.prioritizeTimeOverSize)
        }
    }

    /**
     * An install that never touches the setting must play exactly as it did
     * before the setting existed — these four numbers are the previously
     * hardcoded tuning.
     */
    @Test
    fun `normal is the previously hardcoded tuning`() {
        val b = ExoBufferPolicy.forPreset(BufferPreset.NORMAL)
        assertEquals(15_000, b.minBufferMs)
        assertEquals(50_000, b.maxBufferMs)
        assertEquals(1_000, b.forPlaybackMs)
        assertEquals(2_000, b.afterRebufferMs)
    }

    /**
     * **The durations did not move when the byte caps arrived.** Pinned
     * explicitly because the cap and the durations are edited in the same
     * `Durations(...)` call, and the whole claim of the cap is that it changes
     * nothing on the bitrates this app actually meets.
     */
    @Test
    fun `the byte caps left every duration alone`() {
        val expected = mapOf(
            BufferPreset.LOW to listOf(8_000, 25_000, 750, 1_500),
            BufferPreset.NORMAL to listOf(15_000, 50_000, 1_000, 2_000),
            BufferPreset.HIGH to listOf(40_000, 90_000, 1_000, 2_000),
            BufferPreset.MAX to listOf(60_000, 120_000, 1_000, 2_000),
        )
        for ((preset, want) in expected) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertEquals(
                "$preset",
                want,
                listOf(b.minBufferMs, b.maxBufferMs, b.forPlaybackMs, b.afterRebufferMs),
            )
        }
    }

    /** Anything Dart sends that this build doesn't know falls back to normal. */
    @Test
    fun `an unknown preset name is normal`() {
        assertEquals(BufferPreset.NORMAL, BufferPreset.fromName(null))
        assertEquals(BufferPreset.NORMAL, BufferPreset.fromName(""))
        assertEquals(BufferPreset.NORMAL, BufferPreset.fromName("enormous"))
        assertEquals(BufferPreset.LOW, BufferPreset.fromName("low"))
        assertEquals(BufferPreset.LOW, BufferPreset.fromName("LOW"))
        assertEquals(BufferPreset.HIGH, BufferPreset.fromName("high"))
        assertEquals(BufferPreset.MAX, BufferPreset.fromName("max"))
        assertEquals(BufferPreset.MAX, BufferPreset.fromName("MAX"))
    }

    /**
     * The mpv fallback mirrors the same ordering, including `NORMAL` meaning
     * "leave mpv's own default alone".
     */
    @Test
    fun `the mpv cache depth mirrors the preset order`() {
        assertEquals(null, BufferPreset.NORMAL.mpvCacheSecs)
        val low = BufferPreset.LOW.mpvCacheSecs!!
        val high = BufferPreset.HIGH.mpvCacheSecs!!
        val max = BufferPreset.MAX.mpvCacheSecs!!
        assertTrue(low < high)
        assertTrue(high < max)
    }
}
