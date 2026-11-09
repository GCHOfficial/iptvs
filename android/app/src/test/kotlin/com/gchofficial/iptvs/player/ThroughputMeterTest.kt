package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ThroughputMeterTest {
    private val interval = ThroughputMeter.DEFAULT_INTERVAL_MS

    @Test
    fun `the first call only opens the window`() {
        val meter = ThroughputMeter()
        meter.onBytesTransferred(10_000)
        assertNull(meter.sampleKbps(nowMs = 1_000))
    }

    @Test
    fun `nothing is emitted before the interval elapses`() {
        val meter = ThroughputMeter()
        meter.sampleKbps(nowMs = 1_000)
        meter.onBytesTransferred(10_000)
        assertNull(meter.sampleKbps(nowMs = 1_000 + interval - 1))
    }

    @Test
    fun `a steady 2000kbps link reports its rate`() {
        val meter = ThroughputMeter()
        meter.sampleKbps(nowMs = 0)
        // 2000kbps for `interval` ms, in bytes: kbps * interval / 8.
        val bytes = 2_000L * interval / 8L
        meter.onBytesTransferred(bytes)
        assertEquals(2_000L, meter.sampleKbps(nowMs = interval))
    }

    @Test
    fun `a window with no bytes at all reports zero, not nothing`() {
        // The headline case: a stalled stream where nothing is arriving must
        // still produce a line, distinguishable from "no window ready yet".
        val meter = ThroughputMeter()
        meter.sampleKbps(nowMs = 0)
        assertEquals(0L, meter.sampleKbps(nowMs = interval))
    }

    @Test
    fun `the window keeps running across multiple ticks with no bytes`() {
        val meter = ThroughputMeter()
        meter.sampleKbps(nowMs = 0)
        assertNull(meter.sampleKbps(nowMs = 500))
        assertNull(meter.sampleKbps(nowMs = 1_000))
        assertEquals(0L, meter.sampleKbps(nowMs = interval))
    }

    @Test
    fun `a closed window starts the next one from the close instant`() {
        val meter = ThroughputMeter()
        meter.sampleKbps(nowMs = 0)
        meter.onBytesTransferred(100) // 800 bits over 5s is well under 1kbps, floors to 0
        assertEquals(0L, meter.sampleKbps(nowMs = interval))
        meter.onBytesTransferred(2_000L * interval / 8L)
        assertEquals(2_000L, meter.sampleKbps(nowMs = interval * 2))
    }

    @Test
    fun `bytes recorded before the window opens are not lost`() {
        // onBytesTransferred can race ahead of the first sampleKbps call on a
        // fast-opening stream; nothing here should silently drop them.
        val meter = ThroughputMeter()
        meter.onBytesTransferred(1_000)
        meter.sampleKbps(nowMs = 0) // opens the window
        meter.onBytesTransferred(2_000L * interval / 8L - 1_000)
        assertEquals(2_000L, meter.sampleKbps(nowMs = interval))
    }
}
