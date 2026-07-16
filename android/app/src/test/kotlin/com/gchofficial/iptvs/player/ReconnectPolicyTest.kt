package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Test

class ReconnectPolicyTest {
    @Test
    fun `first attempt waits one stall interval`() {
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 0, force = false),
        )
    }

    @Test
    fun `backoff grows with each prior attempt`() {
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS * 2,
            ReconnectPolicy.minGapMs(priorAttempts = 1, force = false),
        )
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS * 3,
            ReconnectPolicy.minGapMs(priorAttempts = 2, force = false),
        )
    }

    @Test
    fun `backoff is capped at the maximum`() {
        assertEquals(
            ReconnectPolicy.MAX_BACKOFF_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 3, force = false),
        )
        assertEquals(
            ReconnectPolicy.MAX_BACKOFF_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 10, force = false),
        )
    }

    @Test
    fun `a forced reconnect always uses the base stall threshold`() {
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 5, force = true),
        )
    }
}
