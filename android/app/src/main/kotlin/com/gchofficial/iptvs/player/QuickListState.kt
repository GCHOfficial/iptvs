package com.gchofficial.iptvs.player

/**
 * The in-player **quick list** as this surface sees it: a parsed, immutable
 * snapshot of one `setQuickList` push.
 *
 * Dart owns the list, the cursor and every decision
 * (`lib/player/live_zap_controller.dart`, `lib/player/zap_quick_list.dart`);
 * this side owns input and pixels. So there is nothing here to derive — the
 * payload is a **window** of at most 40 already formatted rows around the
 * cursor, with every state a renderer might otherwise recompute (`selected`,
 * `playing`, `archive`, `past`, `live`) arriving as a flag. A renderer prints;
 * it never formats, never re-derives, never paginates. The frozen contract is
 * in docs/player.md "The quick list (Phase 6)".
 *
 * Deliberately **Android-free** — plain data classes and one parser, no
 * `KeyEvent`, no Compose — so the plain-JUnit harness can pin it exactly as it
 * pins [ZapKeyPolicy] and [ReconnectPolicy]. The parser **never throws**: a
 * quick list that can crash the player is worse than one that draws nothing,
 * and this runs on a `MethodChannel` payload whose shape only Dart guarantees.
 */
enum class QuickListMode {
    Categories,
    Channels,
    Schedule,
    ;

    companion object {
        /** Unknown/absent reads as [Channels] — the mode the list opens on. */
        fun fromWire(name: String?): QuickListMode = when (name) {
            "categories" -> Categories
            "schedule" -> Schedule
            else -> Channels
        }
    }
}

/** What a row stands for, so the renderer can pick an affordance per row. */
enum class QuickListRowKind {
    Category,
    Channel,
    Programme,
    ;

    companion object {
        fun fromWire(name: String?): QuickListRowKind = when (name) {
            "category" -> Category
            "programme" -> Programme
            else -> Channel
        }
    }
}

/** One rendered row. Every string is final copy. */
data class QuickListRow(
    /** Absolute index in the full list, **not** in the window. */
    val index: Int,
    /**
     * Stable identity within the mode (a category id, a channel id, a
     * programme start in epoch ms). Opaque here; it exists so a pointer tap
     * can name a row rather than an index that may have moved.
     */
    val id: String,
    val label: String,
    val kind: QuickListRowKind,
    /** The dimmer second line: a now-playing title, or `HH:mm – HH:mm`. */
    val secondary: String? = null,
    /** `ON NOW` / `CATCH-UP`, or null. */
    val badge: String? = null,
    val selected: Boolean = false,
    /** Channels: the channel actually playing. Categories: the live range. */
    val playing: Boolean = false,
    /** Schedule: activating this row starts catch-up. */
    val archive: Boolean = false,
    /** Schedule: already ended. */
    val past: Boolean = false,
    /** Schedule: on air now. */
    val live: Boolean = false,
)

/** One whole `setQuickList` push. */
data class QuickListState(
    /**
     * Draw the list. **`false` is a tear-down instruction, not an absence** —
     * a closed list is still pushed, so an Activity that missed the open can
     * never be left drawing one.
     */
    val open: Boolean,
    val mode: QuickListMode,
    /** Panel title: the source, the category, or the channel. */
    val heading: String,
    /** The window — at most `kZapWindowRows` (40) rows, starting at [windowStart]. */
    val rows: List<QuickListRow>,
    /** Cursor position, **absolute** (an index into the full list). */
    val selectedIndex: Int,
    /** Absolute index of `rows.first()`. */
    val windowStart: Int,
    /** Size of the full list the window was cut from. Up to 250k. */
    val total: Int,
    /** A fetch is in flight. */
    val loading: Boolean = false,
    /** What to draw instead of rows when [total] is zero and nothing is loading. */
    val emptyLabel: String? = null,
    /** Bumped on every real change, so an animation restarts on one. */
    val revision: Int = 0,
) {
    /**
     * The cursor's offset inside [rows], or -1 when the window doesn't hold it
     * (only possible for an empty list, or a payload that contradicts itself).
     *
     * This — not a row's own `selected` flag — is what the renderer highlights
     * and scrolls to: a window that misses the cursor must draw *no*
     * highlight rather than one on the wrong row, which on a remote is
     * indistinguishable from a frozen screen.
     */
    val selectedInWindow: Int
        get() {
            val offset = selectedIndex - windowStart
            return if (offset >= 0 && offset < rows.size) offset else -1
        }

    /** Nothing to draw but [emptyLabel] (or the loading spinner). */
    val isEmpty: Boolean get() = total == 0

    companion object {
        /** What an Activity starts with, and what `open:false` parses to. */
        val closed = QuickListState(
            open = false,
            mode = QuickListMode.Channels,
            heading = "",
            rows = emptyList(),
            selectedIndex = 0,
            windowStart = 0,
            total = 0,
        )

        /**
         * Parses one `setQuickList` payload. Never throws, and tolerates every
         * optional key being absent — a malformed push degrades to [closed] or
         * to a blank row, never to an exception on the platform-channel thread.
         */
        fun fromPayload(args: Map<*, *>?): QuickListState {
            if (args == null) return closed
            if (args["open"] as? Boolean != true) return closed
            // Rows are mapped positionally and never dropped: `selectedInWindow`
            // is `selectedIndex - windowStart`, which only holds while the
            // window stays contiguous. A junk element becomes a blank row
            // rather than a hole that silently shifts the highlight.
            val rows = (args["rows"] as? List<*>).orEmpty().map { rowFromPayload(it) }
            val windowStart = intOf(args["windowStart"])?.coerceAtLeast(0) ?: 0
            val selectedIndex = intOf(args["selectedIndex"])?.coerceAtLeast(0) ?: windowStart
            return QuickListState(
                open = true,
                mode = QuickListMode.fromWire(args["mode"] as? String),
                heading = (args["heading"] as? String).orEmpty(),
                rows = rows,
                selectedIndex = selectedIndex,
                windowStart = windowStart,
                total = intOf(args["total"])?.coerceAtLeast(0) ?: rows.size,
                loading = args["loading"] as? Boolean ?: false,
                emptyLabel = (args["emptyLabel"] as? String)?.takeIf { it.isNotBlank() },
                revision = intOf(args["revision"]) ?: 0,
            )
        }

        private fun rowFromPayload(raw: Any?): QuickListRow {
            val map = raw as? Map<*, *> ?: return blankRow
            return QuickListRow(
                index = intOf(map["index"]) ?: 0,
                id = (map["id"] as? String).orEmpty(),
                label = (map["label"] as? String).orEmpty(),
                kind = QuickListRowKind.fromWire(map["kind"] as? String),
                secondary = (map["secondary"] as? String)?.takeIf { it.isNotBlank() },
                badge = (map["badge"] as? String)?.takeIf { it.isNotBlank() },
                selected = map["selected"] as? Boolean ?: false,
                playing = map["playing"] as? Boolean ?: false,
                archive = map["archive"] as? Boolean ?: false,
                past = map["past"] as? Boolean ?: false,
                live = map["live"] as? Boolean ?: false,
            )
        }

        private val blankRow = QuickListRow(
            index = 0,
            id = "",
            label = "",
            kind = QuickListRowKind.Channel,
        )

        /**
         * A platform channel hands integers back as `Int` or `Long` depending
         * on magnitude, so every numeric field goes through `Number`.
         */
        private fun intOf(value: Any?): Int? = (value as? Number)?.toInt()
    }
}
