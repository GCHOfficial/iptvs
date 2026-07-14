package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Test

class PlayerBackPolicyTest {
    @Test
    fun `Back peels exactly one player layer`() {
        assertEquals(
            PlayerBackAction.CloseMenu,
            nextPlayerBackAction(menuOpen = true, infoOpen = true, controlsVisible = true),
        )
        assertEquals(
            PlayerBackAction.CloseInfo,
            nextPlayerBackAction(menuOpen = false, infoOpen = true, controlsVisible = true),
        )
        assertEquals(
            PlayerBackAction.HideControls,
            nextPlayerBackAction(menuOpen = false, infoOpen = false, controlsVisible = true),
        )
        assertEquals(
            PlayerBackAction.Exit,
            nextPlayerBackAction(menuOpen = false, infoOpen = false, controlsVisible = false),
        )
    }

    @Test
    fun `duplicate Back callback from one press is ignored`() {
        val guard = PlayerBackGuard(duplicateWindowMs = 120L)

        assertEquals(true, guard.shouldHandle(1_000L))
        assertEquals(false, guard.shouldHandle(1_050L))
        assertEquals(true, guard.shouldHandle(1_120L))
    }
}
