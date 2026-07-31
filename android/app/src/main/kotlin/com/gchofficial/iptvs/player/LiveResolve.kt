package com.gchofficial.iptvs.player

/**
 * A live playback locator: the stream URL plus the HTTP headers it needs.
 *
 * Never log one — provider URLs and their headers embed account credentials
 * (see CLAUDE.md "Secrets must never reach logs"). This type deliberately has
 * no `toString` override that would make it look safe to print; the Kotlin data
 * -class default prints both fields, so log *facts about* a locator (changed /
 * unchanged) rather than the locator itself.
 */
data class LiveLocator(val url: String, val headers: Map<String, String>)

/**
 * Pure parser for the Dart `resolveAgain` reply.
 *
 * The native live watchdog ([com.gchofficial.iptvs.HdrPlayerActivity]) can't
 * reload the URL it was launched with after a portal-side kill: Stalker
 * `create_link` locators carry single-use `play_token`s, so the dead URL stays
 * dead however many times it is retried. It therefore round-trips through the
 * `iptvs/native_hdr_player` MethodChannel to `PlayerScreen._freshLiveStream`,
 * which answers `{url, headers}`.
 *
 * Every failure shape collapses to "keep what we have", because a reload of the
 * current locator is the pre-existing behaviour and is never *worse* than not
 * reloading at all:
 *
 * - a null / non-map reply (no Flutter host, a superseded [ChannelHandlerOwner]
 *   token, an unmounted route, a platform error, `notImplemented`) → current;
 * - a reply whose `url` is missing, not a String, or blank → current, headers
 *   included (a reply we can't read a URL out of isn't trustworthy for the
 *   headers either);
 * - a missing / unreadable / **empty** header map → the current headers are
 *   kept rather than blanked. A MAG portal refuses a request without its
 *   `User-Agent`, so "absent means preserve" is the only safe rule here — the
 *   same shape as the cloud-sync `merge_preserving_nonempty` invariant.
 *
 * It never throws: this runs on the platform thread inside a MethodChannel
 * reply callback, where an exception would be swallowed and the reload lost.
 */
object ResolveAgainReply {
    fun parse(reply: Any?, current: LiveLocator): LiveLocator {
        val map = reply as? Map<*, *> ?: return current
        val url = (map["url"] as? String)?.takeIf { it.isNotBlank() } ?: return current
        return LiveLocator(url, headersFrom(map["headers"], current.headers))
    }

    /** Coerces a `Map<Object?, Object?>` from the channel codec, as MainActivity does. */
    private fun headersFrom(raw: Any?, current: Map<String, String>): Map<String, String> {
        val map = raw as? Map<*, *> ?: return current
        val parsed = map.entries.mapNotNull { entry ->
            val key = entry.key as? String
            val value = entry.value
            if (key.isNullOrBlank() || value == null) null else key to value.toString()
        }.toMap()
        return parsed.ifEmpty { current }
    }
}

/**
 * Single-flight settlement for the live re-resolve round trip.
 *
 * Two things must hold at once:
 *
 * 1. **At most one request in flight.** Provider accounts are single-connection,
 *    so the reconnect watchdog and a user-pressed "Go to live" must never issue
 *    two `create_link` calls concurrently. [begin] refuses while one is pending.
 * 2. **Exactly one settlement per request.** The Dart reply and the
 *    [TIMEOUT_MS] backstop race; whichever arrives first wins, and the loser is
 *    discarded by token comparison — so a late reply can neither re-trigger a
 *    reload nor settle the *next* request that has since begun.
 *
 * Deliberately Android-free so the plain-JUnit harness can pin it (see
 * `LiveResolveTest`); the Activity supplies the coroutine timer and the channel.
 */
class ResolveGate {
    private var issued = 0L
    private var pending = 0L

    /** True while a request is waiting for its reply or its timeout. */
    val inFlight: Boolean get() = pending != 0L

    /**
     * Opens the gate and returns the token identifying this request, or null
     * when one is already in flight (the caller must not start a second).
     */
    fun begin(): Long? {
        if (pending != 0L) return null
        pending = ++issued
        return pending
    }

    /**
     * True when [token] is the winner of its request's race — the gate closes
     * and the caller may apply the outcome. False for the loser (a reply that
     * lost to the timeout, a timeout that lost to the reply) and for any token
     * belonging to an already-settled request.
     */
    fun settle(token: Long): Boolean {
        if (pending == 0L || token != pending) return false
        pending = 0L
        return true
    }

    companion object {
        /**
         * Liveness backstop only — **not** reconnect timing policy (that stays
         * in [ReconnectPolicy], untouched).
         *
         * Deliberately generous: a premature fallback reloads the stale,
         * already-spent locator, which is strictly worse than waiting a little
         * longer for the fresh one. It exists so a Flutter host that never
         * answers (engine torn down mid-call, a wedged resolve) can't wedge the
         * watchdog forever. Bounded above by [ReconnectPolicy.MAX_BACKOFF_MS]
         * so a hung resolve never blocks reconnects for longer than the backoff
         * policy's own cap already allows between attempts.
         */
        const val TIMEOUT_MS = 10_000L
    }
}
