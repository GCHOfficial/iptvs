package com.gchofficial.iptvs.crash

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the per-process renderer record that tags reports about *earlier*
 * processes (tombstones, ANR exit records, cached NDK envelopes).
 *
 * The bug it fixes: IPTVS-C, a 0.1.78 tombstone, was tagged `renderer=skia-gl`
 * by the later build that uploaded it — a value the crashing build could not
 * have set — and `docs/validation-baseline.md`'s RTD2875P recurrence rule reads
 * that tag.
 */
class RendererHistoryTest {
    @Test
    fun `reads the pid out of the real tombstone message`() {
        assertEquals(
            8762,
            RendererHistory.pidOf(
                "Fatal signal SIGILL (4), ILL_ILLOPC (1), pid = 8762 " +
                    "(com.gchofficial.iptvs.player.direct)",
            ),
        )
        assertEquals(
            8569,
            RendererHistory.pidOf(
                "Scudo ERROR: corrupted chunk header at address 0xf66d9ae0\n: " +
                    "Fatal signal SIGABRT (6), SI_QUEUE (-1), pid = 8569 (com.x)",
            ),
        )
        assertNull(RendererHistory.pidOf(null))
        assertNull(RendererHistory.pidOf("ANR"))
    }

    @Test
    fun `an earlier process is found by its own pid, with its own renderer`() {
        var lines = emptyList<String>()
        lines = RendererHistory.recorded(lines, 100, "impeller")
        lines = RendererHistory.recorded(lines, 200, "skia-gl")

        assertEquals("impeller", RendererHistory.lookup(lines, 100))
        assertEquals("skia-gl", RendererHistory.lookup(lines, 200))
    }

    @Test
    fun `a process that recorded nothing gets no tag rather than a guess`() {
        // The IPTVS-C shape: the crashing build predates the record.
        val lines = RendererHistory.recorded(emptyList(), 9000, "skia-gl")
        assertNull(RendererHistory.lookup(lines, 8762))
    }

    @Test
    fun `a reused pid takes the newest renderer`() {
        var lines = RendererHistory.recorded(emptyList(), 100, "impeller")
        lines = RendererHistory.recorded(lines, 100, "skia-gl")

        assertEquals(1, lines.size)
        assertEquals("skia-gl", RendererHistory.lookup(lines, 100))
    }

    @Test
    fun `the history is bounded and keeps the most recent processes`() {
        var lines = emptyList<String>()
        for (pid in 1..20) lines = RendererHistory.recorded(lines, pid, "impeller")

        assertEquals(RendererHistory.MAX_ENTRIES, lines.size)
        assertNull(RendererHistory.lookup(lines, 1))
        assertEquals("impeller", RendererHistory.lookup(lines, 20))
    }

    @Test
    fun `garbage lines are dropped, not trusted`() {
        val lines = RendererHistory.recorded(listOf("", "nonsense", "12"), 5, "impeller")

        assertEquals(listOf("5 impeller"), lines)
        assertNull(RendererHistory.lookup(listOf("7 "), 7))
    }

    @Test
    fun `every earlier-process mechanism the dashboard showed is covered`() {
        // Seen on IPTVS-5..-C, -G and -S.
        for (m in listOf("Tombstone", "TombstoneMerged", "AppExitInfo", "signalhandler")) {
            assertTrue(m, m in RendererHistory.EARLIER_PROCESS_MECHANISMS)
        }
        // A Java uncaught exception is captured in the crashing process itself.
        assertTrue("UncaughtExceptionHandler" !in RendererHistory.EARLIER_PROCESS_MECHANISMS)
    }
}
