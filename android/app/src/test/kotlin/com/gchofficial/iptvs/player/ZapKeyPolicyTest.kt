package com.gchofficial.iptvs.player

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val KEYCODE_3 = ZapKeyPolicy.KEYCODE_0 + 3
private const val KEYCODE_5 = ZapKeyPolicy.KEYCODE_0 + 5
private const val KEYCODE_7 = ZapKeyPolicy.KEYCODE_0 + 7

class ZapKeyPolicyTest {
    private fun decide(
        keyCode: Int,
        isLive: Boolean = true,
        controlsVisible: Boolean = false,
        digitsPending: Boolean = false,
        isRepeat: Boolean = false,
        quickListOpen: Boolean = false,
        // Defaults to the shipped setting, so every case below describes the
        // policy as it actually runs; the cases that pin the off state pass
        // `quickListEnabled = false` explicitly.
        quickListEnabled: Boolean = ZapKeyPolicy.QUICK_LIST_ENABLED,
    ) = ZapKeyPolicy.decide(
        keyCode = keyCode,
        isLive = isLive,
        controlsVisible = controlsVisible,
        digitsPending = digitsPending,
        isRepeat = isRepeat,
        quickListOpen = quickListOpen,
        quickListEnabled = quickListEnabled,
    )

    /**
     * [ZapKeyPolicy] mirrors the key codes as plain `Int`s so it stays
     * Android-free and testable — this is what stops a mirrored value from
     * drifting. `android.view.KeyEvent`'s codes are `static final int`
     * compile-time constants, so they inline into this unit test without a
     * device or a Robolectric shadow.
     */
    @Test
    fun `mirrored key codes match android KeyEvent`() {
        assertEquals(KeyEvent.KEYCODE_BACK, ZapKeyPolicy.KEYCODE_BACK)
        assertEquals(KeyEvent.KEYCODE_0, ZapKeyPolicy.KEYCODE_0)
        assertEquals(KeyEvent.KEYCODE_9, ZapKeyPolicy.KEYCODE_9)
        assertEquals(KeyEvent.KEYCODE_DPAD_UP, ZapKeyPolicy.KEYCODE_DPAD_UP)
        assertEquals(KeyEvent.KEYCODE_DPAD_DOWN, ZapKeyPolicy.KEYCODE_DPAD_DOWN)
        assertEquals(KeyEvent.KEYCODE_DPAD_LEFT, ZapKeyPolicy.KEYCODE_DPAD_LEFT)
        assertEquals(KeyEvent.KEYCODE_DPAD_RIGHT, ZapKeyPolicy.KEYCODE_DPAD_RIGHT)
        assertEquals(KeyEvent.KEYCODE_DPAD_CENTER, ZapKeyPolicy.KEYCODE_DPAD_CENTER)
        assertEquals(KeyEvent.KEYCODE_ENTER, ZapKeyPolicy.KEYCODE_ENTER)
        assertEquals(KeyEvent.KEYCODE_PAGE_UP, ZapKeyPolicy.KEYCODE_PAGE_UP)
        assertEquals(KeyEvent.KEYCODE_PAGE_DOWN, ZapKeyPolicy.KEYCODE_PAGE_DOWN)
        assertEquals(KeyEvent.KEYCODE_NUMPAD_0, ZapKeyPolicy.KEYCODE_NUMPAD_0)
        assertEquals(KeyEvent.KEYCODE_NUMPAD_9, ZapKeyPolicy.KEYCODE_NUMPAD_9)
        assertEquals(KeyEvent.KEYCODE_NUMPAD_ENTER, ZapKeyPolicy.KEYCODE_NUMPAD_ENTER)
        assertEquals(KeyEvent.KEYCODE_CHANNEL_UP, ZapKeyPolicy.KEYCODE_CHANNEL_UP)
        assertEquals(KeyEvent.KEYCODE_CHANNEL_DOWN, ZapKeyPolicy.KEYCODE_CHANNEL_DOWN)
        assertEquals(KeyEvent.KEYCODE_GUIDE, ZapKeyPolicy.KEYCODE_GUIDE)
        assertEquals(KeyEvent.KEYCODE_LAST_CHANNEL, ZapKeyPolicy.KEYCODE_LAST_CHANNEL)
    }

    @Test
    fun `VOD keeps every key it has today`() {
        for (code in listOf(
            ZapKeyPolicy.KEYCODE_DPAD_UP,
            ZapKeyPolicy.KEYCODE_CHANNEL_UP,
            KEYCODE_5,
            ZapKeyPolicy.KEYCODE_LAST_CHANNEL,
        )) {
            assertEquals(ZapKeyAction.None, decide(code, isLive = false).action)
        }
    }

    @Test
    fun `dedicated remote keys act whether the chrome is up or not`() {
        for (visible in listOf(false, true)) {
            assertEquals(
                ZapKeyAction.ChannelUp,
                decide(ZapKeyPolicy.KEYCODE_CHANNEL_UP, controlsVisible = visible).action,
            )
            assertEquals(
                ZapKeyAction.ChannelDown,
                decide(ZapKeyPolicy.KEYCODE_CHANNEL_DOWN, controlsVisible = visible).action,
            )
            assertEquals(
                ZapKeyAction.ChannelUp,
                decide(ZapKeyPolicy.KEYCODE_PAGE_UP, controlsVisible = visible).action,
            )
            assertEquals(
                ZapKeyAction.ChannelDown,
                decide(ZapKeyPolicy.KEYCODE_PAGE_DOWN, controlsVisible = visible).action,
            )
            assertEquals(
                ZapKeyAction.PreviousChannel,
                decide(ZapKeyPolicy.KEYCODE_LAST_CHANNEL, controlsVisible = visible).action,
            )
        }
    }

    @Test
    fun `the arrows are only ours while the chrome is hidden`() {
        assertEquals(
            ZapKeyAction.ChannelUp,
            decide(ZapKeyPolicy.KEYCODE_DPAD_UP).action,
        )
        assertEquals(
            ZapKeyAction.ChannelDown,
            decide(ZapKeyPolicy.KEYCODE_DPAD_DOWN).action,
        )
        assertEquals(
            ZapKeyAction.PreviousChannel,
            decide(ZapKeyPolicy.KEYCODE_DPAD_RIGHT).action,
        )
        // With the bars on screen the D-pad belongs to the control row.
        for (code in listOf(
            ZapKeyPolicy.KEYCODE_DPAD_UP,
            ZapKeyPolicy.KEYCODE_DPAD_DOWN,
            ZapKeyPolicy.KEYCODE_DPAD_LEFT,
            ZapKeyPolicy.KEYCODE_DPAD_RIGHT,
        )) {
            assertEquals(
                ZapKeyAction.None,
                decide(code, controlsVisible = true).action,
            )
        }
    }

    @Test
    fun `holding channel up scans, holding last-channel does not toggle`() {
        // A held Up is how a user scans; the 600 ms settle in Dart is what
        // keeps that to one create_link.
        assertEquals(
            ZapKeyAction.ChannelUp,
            decide(ZapKeyPolicy.KEYCODE_DPAD_UP, isRepeat = true).action,
        )
        assertEquals(
            ZapKeyAction.ChannelUp,
            decide(ZapKeyPolicy.KEYCODE_CHANNEL_UP, isRepeat = true).action,
        )
        // Repeating these would flap between two channels / re-open a list.
        assertEquals(
            ZapKeyAction.Swallow,
            decide(ZapKeyPolicy.KEYCODE_DPAD_RIGHT, isRepeat = true).action,
        )
        assertEquals(
            ZapKeyAction.Swallow,
            decide(ZapKeyPolicy.KEYCODE_LAST_CHANNEL, isRepeat = true).action,
        )
    }

    @Test
    fun `digits come from both the number row and the numpad`() {
        for (digit in 0..9) {
            val row = decide(ZapKeyPolicy.KEYCODE_0 + digit)
            assertEquals(ZapKeyAction.Digit, row.action)
            assertEquals(digit, row.digit)
            assertEquals("zap:digit:$digit", row.command)

            val pad = decide(ZapKeyPolicy.KEYCODE_NUMPAD_0 + digit)
            assertEquals(ZapKeyAction.Digit, pad.action)
            assertEquals(digit, pad.digit)
        }
    }

    @Test
    fun `a held digit is swallowed, never stacked and never leaked`() {
        // Consumed, but with no command: letting the repeat through would type
        // the same digit four times, and returning None would drop it into the
        // Compose overlay's focus traversal.
        val decision = decide(KEYCODE_7, isRepeat = true)
        assertEquals(ZapKeyAction.Swallow, decision.action)
        assertTrue(decision.consumed)
        assertNull(decision.command)
    }

    @Test
    fun `digits work with the chrome up`() {
        val decision = decide(KEYCODE_3, controlsVisible = true)
        assertEquals(ZapKeyAction.Digit, decision.action)
        assertEquals(3, decision.digit)
    }

    @Test
    fun `OK and Back are ours only while a number is half-typed`() {
        for (code in listOf(
            ZapKeyPolicy.KEYCODE_DPAD_CENTER,
            ZapKeyPolicy.KEYCODE_ENTER,
            ZapKeyPolicy.KEYCODE_NUMPAD_ENTER,
        )) {
            assertEquals(
                ZapKeyAction.Activate,
                decide(code, digitsPending = true).action,
            )
            assertEquals(ZapKeyAction.None, decide(code).action)
        }
        assertEquals(
            ZapKeyAction.Back,
            decide(ZapKeyPolicy.KEYCODE_BACK, digitsPending = true).action,
        )
        // Empty buffer: Back belongs to the Back ladder
        // (`nextPlayerBackAction`), which must keep peeling menu → info →
        // controls → exit exactly as before.
        assertEquals(ZapKeyAction.None, decide(ZapKeyPolicy.KEYCODE_BACK).action)
        assertEquals(
            ZapKeyAction.None,
            decide(ZapKeyPolicy.KEYCODE_BACK, digitsPending = true, isLive = false).action,
        )
    }

    @Test
    fun `OK with digits pending outranks the chrome's own OK`() {
        assertEquals(
            ZapKeyAction.Activate,
            decide(
                ZapKeyPolicy.KEYCODE_DPAD_CENTER,
                controlsVisible = true,
                digitsPending = true,
            ).action,
        )
    }

    @Test
    fun `the quick list is on, and Left opens it only with the chrome hidden`() {
        assertTrue(ZapKeyPolicy.QUICK_LIST_ENABLED)
        assertEquals(ZapKeyAction.OpenList, decide(ZapKeyPolicy.KEYCODE_DPAD_LEFT).action)
        // GUIDE is a dedicated key, so it is unambiguous with the chrome up.
        assertEquals(ZapKeyAction.OpenList, decide(ZapKeyPolicy.KEYCODE_GUIDE).action)
        assertEquals(
            ZapKeyAction.OpenList,
            decide(ZapKeyPolicy.KEYCODE_GUIDE, controlsVisible = true).action,
        )
        // Left is contested: with the bars up it belongs to the control row.
        assertEquals(
            ZapKeyAction.None,
            decide(ZapKeyPolicy.KEYCODE_DPAD_LEFT, controlsVisible = true).action,
        )
        // Holding either re-opens nothing.
        assertEquals(
            ZapKeyAction.Swallow,
            decide(ZapKeyPolicy.KEYCODE_DPAD_LEFT, isRepeat = true).action,
        )
        assertEquals(
            ZapKeyAction.Swallow,
            decide(ZapKeyPolicy.KEYCODE_GUIDE, isRepeat = true).action,
        )
    }

    @Test
    fun `the off switch still takes the quick list back out`() {
        // The one constant that removes the feature: with it false, Left and
        // GUIDE fall through and keep the jobs they had before Phase 6 rather
        // than becoming decided no-ops.
        for (open in listOf(false, true)) {
            assertEquals(
                ZapKeyAction.None,
                decide(
                    ZapKeyPolicy.KEYCODE_DPAD_LEFT,
                    quickListOpen = open,
                    quickListEnabled = false,
                ).action,
            )
            assertEquals(
                ZapKeyAction.None,
                decide(
                    ZapKeyPolicy.KEYCODE_GUIDE,
                    quickListOpen = open,
                    quickListEnabled = false,
                ).action,
            )
        }
        // And with it off the arrows keep their pre-Phase-6 meanings even if
        // something claimed the list was open.
        assertEquals(
            ZapKeyAction.ChannelUp,
            decide(
                ZapKeyPolicy.KEYCODE_DPAD_UP,
                quickListOpen = true,
                quickListEnabled = false,
            ).action,
        )
    }

    @Test
    fun `GUIDE toggles the list, chrome or no chrome`() {
        for (visible in listOf(false, true)) {
            assertEquals(
                ZapKeyAction.OpenList,
                decide(
                    ZapKeyPolicy.KEYCODE_GUIDE,
                    controlsVisible = visible,
                    quickListOpen = false,
                ).action,
            )
            assertEquals(
                ZapKeyAction.CloseList,
                decide(
                    ZapKeyPolicy.KEYCODE_GUIDE,
                    controlsVisible = visible,
                    quickListOpen = true,
                ).action,
            )
        }
    }

    @Test
    fun `with the list open the arrows move the cursor, chrome or no chrome`() {
        for (visible in listOf(false, true)) {
            fun open(code: Int, repeat: Boolean = false) = decide(
                code,
                controlsVisible = visible,
                quickListOpen = true,
                isRepeat = repeat,
            )
            // Up moves the *highlight* up — the opposite sign to the channel
            // keys, which keep meaning "the next channel".
            assertEquals("zap:move:-1", open(ZapKeyPolicy.KEYCODE_DPAD_UP).command)
            assertEquals("zap:move:1", open(ZapKeyPolicy.KEYCODE_DPAD_DOWN).command)
            assertEquals(ZapKeyAction.Back, open(ZapKeyPolicy.KEYCODE_DPAD_LEFT).action)
            assertEquals(ZapKeyAction.Descend, open(ZapKeyPolicy.KEYCODE_DPAD_RIGHT).action)
            for (ok in listOf(
                ZapKeyPolicy.KEYCODE_DPAD_CENTER,
                ZapKeyPolicy.KEYCODE_ENTER,
                ZapKeyPolicy.KEYCODE_NUMPAD_ENTER,
            )) {
                assertEquals(ZapKeyAction.Activate, open(ok).action)
            }
            // Back peels one rung off Dart's mode stack, ahead of the
            // player's own ladder — with no digit buffer behind it.
            assertEquals(ZapKeyAction.Back, open(ZapKeyPolicy.KEYCODE_BACK).action)

            // A held arrow scans the list (the cursor clamps, so it settles);
            // the one-shot keys are swallowed.
            assertEquals(
                ZapKeyAction.MoveDown,
                open(ZapKeyPolicy.KEYCODE_DPAD_DOWN, repeat = true).action,
            )
            for (code in listOf(
                ZapKeyPolicy.KEYCODE_DPAD_LEFT,
                ZapKeyPolicy.KEYCODE_DPAD_RIGHT,
                ZapKeyPolicy.KEYCODE_DPAD_CENTER,
                ZapKeyPolicy.KEYCODE_BACK,
            )) {
                assertEquals(ZapKeyAction.Swallow, open(code, repeat = true).action)
            }
        }
    }

    @Test
    fun `the dedicated keys keep their own meaning with the list open`() {
        // `zap:up`/`zap:down` mean "the next channel" in both states; Dart
        // reads them as one row in list order while the list is up. Digits
        // likewise stay digits — Dart moves the cursor with them.
        assertEquals(
            ZapKeyAction.ChannelUp,
            decide(ZapKeyPolicy.KEYCODE_CHANNEL_UP, quickListOpen = true).action,
        )
        assertEquals(
            ZapKeyAction.ChannelDown,
            decide(ZapKeyPolicy.KEYCODE_PAGE_DOWN, quickListOpen = true).action,
        )
        assertEquals(
            ZapKeyAction.PreviousChannel,
            decide(ZapKeyPolicy.KEYCODE_LAST_CHANNEL, quickListOpen = true).action,
        )
        val digit = decide(KEYCODE_5, quickListOpen = true)
        assertEquals(ZapKeyAction.Digit, digit.action)
        assertEquals(5, digit.digit)
        // And nothing at all is claimed on VOD, list flag or not.
        assertEquals(
            ZapKeyAction.None,
            decide(ZapKeyPolicy.KEYCODE_DPAD_UP, isLive = false, quickListOpen = true).action,
        )
    }

    @Test
    fun `an unrelated key is still not claimed with the list open`() {
        // The list is a readout over a running player, not a modal: volume
        // and the media keys keep working while it is up.
        for (code in listOf(24, 25, 85, 126, 127)) {
            assertEquals(
                ZapKeyAction.None,
                decide(code, quickListOpen = true).action,
            )
        }
    }

    @Test
    fun `commands are exactly the shared vocabulary`() {
        // These strings are parsed by one function on the Dart side
        // (`parseZapCommand`); a typo here is a key that silently does
        // nothing.
        assertEquals("zap:up", ZapKeyDecision(ZapKeyAction.ChannelUp).command)
        assertEquals("zap:down", ZapKeyDecision(ZapKeyAction.ChannelDown).command)
        assertEquals("zap:prev", ZapKeyDecision(ZapKeyAction.PreviousChannel).command)
        assertEquals("zap:list", ZapKeyDecision(ZapKeyAction.OpenList).command)
        assertEquals("zap:close", ZapKeyDecision(ZapKeyAction.CloseList).command)
        assertEquals("zap:move:-1", ZapKeyDecision(ZapKeyAction.MoveUp).command)
        assertEquals("zap:move:1", ZapKeyDecision(ZapKeyAction.MoveDown).command)
        assertEquals("zap:descend", ZapKeyDecision(ZapKeyAction.Descend).command)
        assertEquals("zap:activate", ZapKeyDecision(ZapKeyAction.Activate).command)
        assertEquals("zap:back", ZapKeyDecision(ZapKeyAction.Back).command)
        assertEquals("zap:digit:4", ZapKeyDecision(ZapKeyAction.Digit, 4).command)
        assertNull(ZapKeyDecision.none.command)
        assertNull(ZapKeyDecision.swallow.command)
        assertFalse(ZapKeyDecision.none.consumed)
        assertTrue(ZapKeyDecision.swallow.consumed)
    }

    @Test
    fun `an unrelated key is never claimed`() {
        // Media keys keep reaching onKeyDown, volume keys keep reaching the
        // system, and letters keep reaching Compose.
        for (code in listOf(24, 25, 85, 86, 87, 88, 89, 90, 126, 127, 29, 111)) {
            assertEquals(
                ZapKeyAction.None,
                decide(code, digitsPending = true).action,
            )
        }
    }
}
