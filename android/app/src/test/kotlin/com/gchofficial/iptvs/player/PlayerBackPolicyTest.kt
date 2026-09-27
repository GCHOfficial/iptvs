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

    @Test
    fun `the digit rung sits above this ladder, not inside it`() {
        // Back clears a half-typed channel number first, but that rung is
        // ZapKeyPolicy's — it is only reachable through key dispatch, and a
        // copy here would make one press peel two layers on that path.
        assertEquals(
            ZapKeyAction.Back,
            ZapKeyPolicy.decide(
                keyCode = ZapKeyPolicy.KEYCODE_BACK,
                isLive = true,
                controlsVisible = true,
                digitsPending = true,
                isRepeat = false,
            ).action,
        )
        // With nothing to clear, Back is the ladder's again — unchanged.
        assertEquals(
            ZapKeyAction.None,
            ZapKeyPolicy.decide(
                keyCode = ZapKeyPolicy.KEYCODE_BACK,
                isLive = true,
                controlsVisible = true,
                digitsPending = false,
                isRepeat = false,
            ).action,
        )
        assertEquals(
            PlayerBackAction.HideControls,
            nextPlayerBackAction(menuOpen = false, infoOpen = false, controlsVisible = true),
        )
    }
}
