package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Drives the coordinator with **real threads**, because the thing worth pinning
 * is not an arithmetic rule but a rendezvous between media3's loader thread and
 * the Activity's main thread: who may wait, who may offer, and — the one that
 * bites — what happens when the session moves on while a loader is still parked
 * inside the monitor.
 */
class StitchCoordinatorTest {
    private val lines = mutableListOf<String>()
    private val coordinator = StitchCoordinator { line -> synchronized(lines) { lines.add(line) } }

    private val url = "http://portal.example/ch?token=TOKEN-ABC123"
    private val locator = LiveLocator(url, mapOf("User-Agent" to "MAG-250"))
    private val next = LiveLocator("http://portal.example/ch?token=TOKEN-DEF456", locator.headers)

    // ── Arming ───────────────────────────────────────────────────────────────

    @Test
    fun `a rotating provider's link arms`() {
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        val armed = coordinator.arm(url, 0L, contentTypeOther = true)
        assertNotNull(armed)
        assertEquals(1, armed!!.link)
    }

    @Test
    fun `a provider that has never rotated a locator never arms`() {
        // This is the whole of the Xtream/M3U/stable-URL exclusion: the native
        // side learns nothing about provider kinds, it only ever sees whether a
        // pre-resolve came back with a different URL.
        coordinator.noteLoad(url, isLive = true)
        assertNull(coordinator.arm(url, 0L, contentTypeOther = true))
    }

    @Test
    fun `everything else that is not the live progressive body is refused`() {
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        // A subtitle sidecar, or an HLS segment: a different URI.
        assertNull(coordinator.arm("http://portal.example/subs.srt", 0L, true))
        // A resumed range after a load error, not a fresh body.
        assertNull(coordinator.arm(url, 4096L, true))
        // A playlist/manifest container: media3 reads it in chunks, so there is
        // no single unbounded body to splice.
        assertNull(coordinator.arm(url, 0L, contentTypeOther = false))
    }

    @Test
    fun `VOD never arms`() {
        coordinator.noteLoad(url, isLive = false)
        coordinator.noteRotationProven()
        assertNull(coordinator.arm(url, 0L, true))
    }

    @Test
    fun `a zap withdraws the rotation proof`() {
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        coordinator.resetForZap()
        coordinator.noteLoad(url, isLive = true)
        assertNull(coordinator.arm(url, 0L, true))
    }

    @Test
    fun `a zap also withdraws the stand-down and the streaks`() {
        // A zap can cross sources. A session disabled because provider X's
        // stream has no IDR inside the skip budget would otherwise carry that
        // verdict onto provider Y for the rest of the Activity's life, with
        // nothing in an export to say why Y never stitched.
        armedForTest()
        coordinator.noteFallback(SpliceRejectReason.PMT_CHANGED.token)
        assertTrue(coordinator.noteFallback(SpliceRejectReason.NO_RAP.token))
        assertFalse(coordinator.enabled)

        coordinator.resetForZap()
        assertTrue(coordinator.enabled)
        assertEquals(0 to 0, coordinator.failureStreaks())
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        assertNotNull(coordinator.arm(url, 0L, true))
        // The stand-down line stays once *per disablement*: a later one is a
        // genuinely new verdict about a different provider, and says so.
        assertFalse(coordinator.noteFallback(SpliceRejectReason.PMT_CHANGED.token))
        assertTrue(coordinator.noteFallback(SpliceRejectReason.PMT_CHANGED.token))
        assertEquals(2, lines.size)
    }

    // ── The rendezvous ───────────────────────────────────────────────────────

    @Test
    fun `an offer reaches the waiting loader and is consumed exactly once`() {
        val armed = armedForTest()
        val entered = CountDownLatch(1)
        val got = AtomicReference<StitchHandover>()
        val loader = loaderThread(entered) { got.set(coordinator.awaitLocator(armed.session)) }
        awaitWaiting()
        assertTrue(coordinator.pendingHandover)
        assertTrue(coordinator.offer(next))
        loader.join(2_000)
        assertEquals(StitchHandover.Offered(next), got.get())
        // Evaluating, so a second locator has nowhere to go — the caller stores
        // it for the ordinary pre-resolved reconnect instead.
        assertFalse(coordinator.offer(next))
        assertTrue(coordinator.pendingHandover)
        coordinator.finishHandover(armed.session)
        assertFalse(coordinator.pendingHandover)
    }

    @Test
    fun `an offer with nobody waiting is refused`() {
        armedForTest()
        assertFalse(coordinator.offer(next))
    }

    @Test
    fun `an abort wakes the loader with its reason`() {
        val armed = armedForTest()
        val got = AtomicReference<StitchHandover>()
        val loader = loaderThread { got.set(coordinator.awaitLocator(armed.session)) }
        awaitWaiting()
        coordinator.abort(LiveStitchPolicy.REASON_DEADLINE)
        loader.join(2_000)
        assertEquals(
            StitchHandover.Aborted(LiveStitchPolicy.REASON_DEADLINE),
            got.get(),
        )
    }

    @Test
    fun `a cancel wakes the loader and refuses every later offer`() {
        val armed = armedForTest()
        val got = AtomicReference<StitchHandover>()
        val loader = loaderThread { got.set(coordinator.awaitLocator(armed.session)) }
        awaitWaiting()
        coordinator.cancel()
        loader.join(2_000)
        assertEquals(
            StitchHandover.Aborted(LiveStitchPolicy.REASON_CANCELLED),
            got.get(),
        )
        // The single-use token must not be handed to a stream the session has
        // already replaced.
        assertFalse(coordinator.offer(next))
        assertEquals(LiveStitchPolicy.REASON_CANCELLED, coordinator.pollAbort(armed.session))
    }

    @Test
    fun `a stale loader finishing cannot strand the one that replaced it`() {
        // The real sequence: a loader is parked, a reload bumps the session,
        // the new load arms and parks — and only then does the old loader
        // unwind and call finishHandover. Clearing the slot there would leave
        // the new handover with nobody able to offer it anything.
        val stale = armedForTest()
        val staleGot = AtomicReference<StitchHandover>()
        val staleLoader = loaderThread { staleGot.set(coordinator.awaitLocator(stale.session)) }
        awaitWaiting()
        coordinator.noteLoad(url, isLive = true)
        staleLoader.join(2_000)

        val fresh = coordinator.arm(url, 0L, true)!!
        val freshGot = AtomicReference<StitchHandover>()
        val freshLoader = loaderThread { freshGot.set(coordinator.awaitLocator(fresh.session)) }
        awaitWaiting()
        coordinator.finishHandover(stale.session)
        assertTrue(coordinator.pendingHandover)
        assertTrue(coordinator.offer(next))
        freshLoader.join(2_000)
        assertEquals(StitchHandover.Offered(next), freshGot.get())
    }

    @Test
    fun `a stale load leaves no abort behind for the next waiter`() {
        // noteLoad/cancel end an outstanding handover through the token, never
        // through abortReason — a reason left standing would be consumed by the
        // next waiter before it had waited for anything.
        val stale = armedForTest()
        val loader = loaderThread { coordinator.awaitLocator(stale.session) }
        awaitWaiting()
        coordinator.noteLoad(url, isLive = true)
        loader.join(2_000)
        val fresh = coordinator.arm(url, 0L, true)!!
        val got = AtomicReference<StitchHandover>()
        val freshLoader = loaderThread { got.set(coordinator.awaitLocator(fresh.session)) }
        awaitWaiting()
        assertNull(got.get())
        assertTrue(coordinator.offer(next))
        freshLoader.join(2_000)
        assertEquals(StitchHandover.Offered(next), got.get())
    }

    @Test
    fun `awaiting on a session the coordinator has already left returns at once`() {
        val armed = armedForTest()
        coordinator.cancel()
        assertEquals(
            StitchHandover.Aborted(LiveStitchPolicy.REASON_CANCELLED),
            coordinator.awaitLocator(armed.session),
        )
    }

    @Test
    fun `pollAbort reports once and then clears`() {
        val armed = armedForTest()
        val loader = loaderThread { coordinator.awaitLocator(armed.session) }
        awaitWaiting()
        assertTrue(coordinator.offer(next))
        loader.join(2_000)
        assertNull(coordinator.pollAbort(armed.session))
        coordinator.abort(LiveStitchPolicy.REASON_DEADLINE)
        assertEquals(LiveStitchPolicy.REASON_DEADLINE, coordinator.pollAbort(armed.session))
        assertNull(coordinator.pollAbort(armed.session))
    }

    // ── The session rule ─────────────────────────────────────────────────────

    @Test
    fun `two structural failures stand the path down, once`() {
        armedForTest()
        assertFalse(coordinator.noteFallback(SpliceRejectReason.PMT_CHANGED.token))
        assertTrue(coordinator.enabled)
        assertTrue(coordinator.noteFallback(SpliceRejectReason.NO_RAP.token))
        assertFalse(coordinator.enabled)
        assertEquals(listOf("live stitch disabled failures=2 reason=no-rap"), lines)
        // Written once: a later fallback adds nothing.
        assertFalse(coordinator.noteFallback(SpliceRejectReason.NO_RAP.token))
        assertEquals(1, lines.size)
        // And a disabled session never arms again.
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        assertNull(coordinator.arm(url, 0L, true))
    }

    @Test
    fun `transient failures are tolerated four deep`() {
        armedForTest()
        repeat(LiveStitchPolicy.MAX_CONSECUTIVE_TRANSIENT_FAILURES - 1) {
            assertFalse(coordinator.noteFallback(LiveStitchPolicy.REASON_OPEN_FAILED))
        }
        assertTrue(coordinator.enabled)
        assertTrue(coordinator.noteFallback(LiveStitchPolicy.REASON_CANDIDATE_EOF))
        assertFalse(coordinator.enabled)
        assertEquals(listOf("live stitch disabled failures=4 reason=candidate-eof"), lines)
    }

    @Test
    fun `a deadline is not held against the session`() {
        armedForTest()
        repeat(10) { assertFalse(coordinator.noteFallback(LiveStitchPolicy.REASON_DEADLINE)) }
        assertTrue(coordinator.enabled)
        assertEquals(0 to 0, coordinator.failureStreaks())
    }

    @Test
    fun `a commit restores the session's patience in full`() {
        armedForTest()
        coordinator.noteFallback(SpliceRejectReason.PMT_CHANGED.token)
        coordinator.noteFallback(LiveStitchPolicy.REASON_OPEN_FAILED)
        assertEquals(1 to 1, coordinator.failureStreaks())
        coordinator.noteCommit()
        assertEquals(0 to 0, coordinator.failureStreaks())
        assertFalse(coordinator.noteFallback(SpliceRejectReason.PMT_CHANGED.token))
        assertTrue(coordinator.enabled)
    }

    @Test
    fun `a report from a superseded load is not current`() {
        // The guard every loader-to-main callback passes. The loader thread can
        // be seconds behind — parked in a socket read, or unwinding a handover
        // a zap already cancelled — and a stale fallback that re-armed the EOF
        // gate would fire a `create_link` against a body that is **open**.
        val stale = armedForTest()
        assertTrue(coordinator.isCurrent(stale.session))
        coordinator.cancel()
        assertFalse(coordinator.isCurrent(stale.session))
        val fresh = coordinator.arm(url, 0L, true)!!
        assertTrue(coordinator.isCurrent(fresh.session))
        coordinator.noteLoad(url, isLive = true)
        assertFalse(coordinator.isCurrent(fresh.session))
    }

    @Test
    fun `links are numbered across a session, commits included`() {
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        assertEquals(1, coordinator.arm(url, 0L, true)!!.link)
        assertEquals(2, coordinator.nextLink())
        assertEquals(3, coordinator.nextLink())
        coordinator.noteLoad(url, isLive = true)
        assertEquals(4, coordinator.arm(url, 0L, true)!!.link)
    }

    // ── Harness ──────────────────────────────────────────────────────────────

    private fun armedForTest(): StitchArming {
        coordinator.noteLoad(url, isLive = true)
        coordinator.noteRotationProven()
        return coordinator.arm(url, 0L, contentTypeOther = true)!!
    }

    private fun loaderThread(started: CountDownLatch? = null, body: () -> Unit): Thread =
        Thread {
            started?.countDown()
            body()
        }.also { it.isDaemon = true; it.start() }

    /**
     * Waits for the loader thread to actually be parked inside the monitor.
     * Polling `pendingHandover` is enough: it is set under the same lock the
     * waiter holds, before it waits.
     */
    private fun awaitWaiting() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
        while (!coordinator.pendingHandover && System.nanoTime() < deadline) {
            Thread.sleep(1)
        }
        assertTrue("loader never parked", coordinator.pendingHandover)
    }
}
