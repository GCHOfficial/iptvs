package com.gchofficial.iptvs.player

/**
 * What one key press means to in-player live zapping.
 *
 * [Swallow] is not [None]: it means the key **was** ours and must be consumed
 * without doing anything — a repeat of a key whose action makes no sense
 * repeated. Returning [None] there would leak a held digit into the Compose
 * overlay's focus traversal, which is the same class of bug the live tab's own
 * digit handler swallows repeats to avoid.
 */
enum class ZapKeyAction {
    None,
    Swallow,
    ChannelUp,
    ChannelDown,
    PreviousChannel,
    OpenList,
    Digit,
    Activate,
    Back,
}

/**
 * One key's outcome. [command] is the string to send to Dart on the shared zap
 * vocabulary (`lib/player/zap_command.dart`), or null when nothing is sent.
 */
data class ZapKeyDecision(val action: ZapKeyAction, val digit: Int = -1) {
    /** Whether `dispatchKeyEvent` must return true for this press. */
    val consumed: Boolean get() = action != ZapKeyAction.None

    val command: String?
        get() = when (action) {
            ZapKeyAction.ChannelUp -> "zap:up"
            ZapKeyAction.ChannelDown -> "zap:down"
            ZapKeyAction.PreviousChannel -> "zap:prev"
            ZapKeyAction.OpenList -> "zap:list"
            ZapKeyAction.Digit -> "zap:digit:$digit"
            ZapKeyAction.Activate -> "zap:activate"
            ZapKeyAction.Back -> "zap:back"
            ZapKeyAction.None, ZapKeyAction.Swallow -> null
        }

    companion object {
        val none = ZapKeyDecision(ZapKeyAction.None)
        val swallow = ZapKeyDecision(ZapKeyAction.Swallow)
    }
}

/**
 * Pure key policy for in-player channel zapping, consulted by
 * [com.gchofficial.iptvs.HdrPlayerActivity.dispatchKeyEvent] **before**
 * `super` — the same Activity-boundary placement Back already uses, and for
 * the same reason: one physical press must not be interpreted once here and
 * again by a focused Compose control.
 *
 * Deliberately **Android-free** (raw key codes as `Int`s, mirrored below) so
 * the plain-JUnit harness can pin it, exactly like [ReconnectPolicy] and
 * `PlayerBackPolicy`. `ZapKeyPolicyTest` asserts each mirrored constant equals
 * `android.view.KeyEvent`'s, so a typo here cannot ship silently.
 *
 * The state it needs is deliberately tiny, and all of it is already on this
 * side of the wire: **Dart owns the channel list and the cursor**
 * (`lib/player/live_zap_controller.dart`), so this decides only *which command
 * to send*, never where the cursor lands.
 */
object ZapKeyPolicy {
    // Mirrors of `android.view.KeyEvent`, pinned by test.
    const val KEYCODE_BACK = 4
    const val KEYCODE_0 = 7
    const val KEYCODE_9 = 16
    const val KEYCODE_DPAD_UP = 19
    const val KEYCODE_DPAD_DOWN = 20
    const val KEYCODE_DPAD_LEFT = 21
    const val KEYCODE_DPAD_RIGHT = 22
    const val KEYCODE_DPAD_CENTER = 23
    const val KEYCODE_ENTER = 66
    const val KEYCODE_PAGE_UP = 92
    const val KEYCODE_PAGE_DOWN = 93
    const val KEYCODE_NUMPAD_0 = 144
    const val KEYCODE_NUMPAD_9 = 153
    const val KEYCODE_NUMPAD_ENTER = 160
    const val KEYCODE_CHANNEL_UP = 166
    const val KEYCODE_CHANNEL_DOWN = 167
    const val KEYCODE_GUIDE = 172
    const val KEYCODE_LAST_CHANNEL = 229

    /**
     * Whether the quick list exists yet.
     *
     * Dart answers `zap:list` with "not consumed" until Phase 6 wires the
     * quick list, and `dispatchKeyEvent` cannot wait for that answer — it has
     * to return synchronously. So rather than consume Left and GUIDE into a
     * silent no-op (Left's present job, revealing the chrome, would simply
     * stop working), this flag keeps them out of the policy entirely until the
     * list is real. Phase 6 flips it; the behaviour on both settings is
     * already pinned by `ZapKeyPolicyTest`.
     */
    const val QUICK_LIST_ENABLED = false

    /**
     * @param keyCode the `android.view.KeyEvent` key code.
     * @param isLive zapping is live-only; VOD keeps every key it has today.
     * @param controlsVisible with the chrome up, the D-pad belongs to the
     *   control row — the arrows are the only keys this changes, because they
     *   are the only ambiguous ones.
     * @param digitsPending a channel number is half-typed. Read from the
     *   **native** mirror of `setZapBanner`'s `digits`, not from a round trip
     *   to Dart: this decision is synchronous. The worst a stale mirror can do
     *   is let one Back press peel a control layer instead of clearing the
     *   buffer, which is recoverable; waiting on a reply would mean returning
     *   "not consumed" for a key that is about to be consumed, which is not.
     * @param isRepeat `KeyEvent.repeatCount > 0`.
     */
    fun decide(
        keyCode: Int,
        isLive: Boolean,
        controlsVisible: Boolean,
        digitsPending: Boolean,
        isRepeat: Boolean,
        quickListEnabled: Boolean = QUICK_LIST_ENABLED,
    ): ZapKeyDecision {
        if (!isLive) return ZapKeyDecision.none

        digitOf(keyCode)?.let { digit ->
            // A held digit key must not stack the same number four times, and
            // must not fall through to the overlay either.
            if (isRepeat) return ZapKeyDecision.swallow
            return ZapKeyDecision(ZapKeyAction.Digit, digit)
        }

        when (keyCode) {
            // Unambiguous by construction: a dedicated remote key means one
            // thing whether the chrome is up or not.
            KEYCODE_CHANNEL_UP, KEYCODE_PAGE_UP ->
                return ZapKeyDecision(ZapKeyAction.ChannelUp)
            KEYCODE_CHANNEL_DOWN, KEYCODE_PAGE_DOWN ->
                return ZapKeyDecision(ZapKeyAction.ChannelDown)
            KEYCODE_LAST_CHANNEL ->
                // Holding it would toggle back and forth; one press, one swap.
                return if (isRepeat) {
                    ZapKeyDecision.swallow
                } else {
                    ZapKeyDecision(ZapKeyAction.PreviousChannel)
                }
            KEYCODE_GUIDE -> return if (!quickListEnabled) {
                ZapKeyDecision.none
            } else if (isRepeat) {
                ZapKeyDecision.swallow
            } else {
                ZapKeyDecision(ZapKeyAction.OpenList)
            }
        }

        // OK commits a half-typed number early, and Back clears it — both
        // *above* their ordinary meanings, and only while there is a number to
        // act on. Back in particular must fall through to the Back ladder
        // (`nextPlayerBackAction`) the moment the buffer is empty.
        if (digitsPending) {
            when (keyCode) {
                KEYCODE_DPAD_CENTER, KEYCODE_ENTER, KEYCODE_NUMPAD_ENTER ->
                    return if (isRepeat) {
                        ZapKeyDecision.swallow
                    } else {
                        ZapKeyDecision(ZapKeyAction.Activate)
                    }
                KEYCODE_BACK ->
                    return if (isRepeat) {
                        ZapKeyDecision.swallow
                    } else {
                        ZapKeyDecision(ZapKeyAction.Back)
                    }
            }
        }

        // The arrows are the contested keys: with the chrome up they walk the
        // control row, so zapping only claims them while it is hidden.
        if (controlsVisible) return ZapKeyDecision.none
        return when (keyCode) {
            // Up is the next *higher* channel, i.e. the next row down the
            // launch list. Repeats are allowed on purpose: holding the key is
            // how a user scans, and the 600 ms settle in Dart is what keeps
            // that to one `create_link`.
            KEYCODE_DPAD_UP -> ZapKeyDecision(ZapKeyAction.ChannelUp)
            KEYCODE_DPAD_DOWN -> ZapKeyDecision(ZapKeyAction.ChannelDown)
            KEYCODE_DPAD_RIGHT -> if (isRepeat) {
                ZapKeyDecision.swallow
            } else {
                ZapKeyDecision(ZapKeyAction.PreviousChannel)
            }
            KEYCODE_DPAD_LEFT -> if (!quickListEnabled) {
                ZapKeyDecision.none
            } else if (isRepeat) {
                ZapKeyDecision.swallow
            } else {
                ZapKeyDecision(ZapKeyAction.OpenList)
            }
            else -> ZapKeyDecision.none
        }
    }

    private fun digitOf(keyCode: Int): Int? = when (keyCode) {
        in KEYCODE_0..KEYCODE_9 -> keyCode - KEYCODE_0
        in KEYCODE_NUMPAD_0..KEYCODE_NUMPAD_9 -> keyCode - KEYCODE_NUMPAD_0
        else -> null
    }
}
