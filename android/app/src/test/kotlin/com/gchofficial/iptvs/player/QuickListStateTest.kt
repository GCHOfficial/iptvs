package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `setQuickList` payload parser, against the contract frozen in
 * docs/player.md "The quick list (Phase 6)".
 *
 * Two properties matter more than the field mapping. **It never throws** — it
 * runs on a platform-channel payload, and a quick list that can crash the
 * player is worse than one that draws nothing. And **the window stays
 * contiguous**, because the highlight is drawn at `selectedIndex -
 * windowStart`: a dropped row would silently shift it onto the wrong channel.
 */
class QuickListStateTest {
    private fun row(
        index: Int,
        label: String,
        kind: String = "channel",
        extra: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> = mapOf(
        "index" to index,
        "id" to "id$index",
        "label" to label,
        "kind" to kind,
    ) + extra

    private fun payload(vararg pairs: Pair<String, Any?>): Map<String, Any?> = mapOf(
        "open" to true,
        "mode" to "channels",
        "heading" to "All channels",
        "rows" to listOf(row(0, "1 · One"), row(1, "2 · Two")),
        "selectedIndex" to 1,
        "windowStart" to 0,
        "total" to 2,
        "loading" to false,
        "revision" to 7,
    ) + pairs

    @Test
    fun `a full payload round-trips field for field`() {
        val state = QuickListState.fromPayload(
            payload(
                "rows" to listOf(
                    row(
                        40,
                        "12 · BBC One",
                        extra = mapOf(
                            "secondary" to "The Six O'Clock News",
                            "badge" to "ON NOW",
                            "selected" to true,
                            "playing" to true,
                            "live" to true,
                        ),
                    ),
                    row(
                        41,
                        "16:00 – 17:00",
                        kind = "programme",
                        extra = mapOf("badge" to "CATCH-UP", "archive" to true, "past" to true),
                    ),
                ),
                "selectedIndex" to 40,
                "windowStart" to 40,
                "total" to 250_000,
            ),
        )

        assertTrue(state.open)
        assertEquals(QuickListMode.Channels, state.mode)
        assertEquals("All channels", state.heading)
        assertEquals(250_000, state.total)
        assertEquals(7, state.revision)
        assertFalse(state.loading)
        assertNull(state.emptyLabel)

        val first = state.rows[0]
        assertEquals(40, first.index)
        assertEquals("id40", first.id)
        assertEquals("12 · BBC One", first.label)
        assertEquals(QuickListRowKind.Channel, first.kind)
        assertEquals("The Six O'Clock News", first.secondary)
        assertEquals("ON NOW", first.badge)
        assertTrue(first.selected)
        assertTrue(first.playing)
        assertTrue(first.live)
        assertFalse(first.archive)
        assertFalse(first.past)

        val second = state.rows[1]
        assertEquals(QuickListRowKind.Programme, second.kind)
        assertEquals("CATCH-UP", second.badge)
        assertTrue(second.archive)
        assertTrue(second.past)
        assertFalse(second.live)
    }

    @Test
    fun `open false is a tear-down instruction, not an absence`() {
        // A closed list is still pushed, so a surface can never be left
        // drawing one it has stopped being told about.
        assertEquals(
            QuickListState.closed,
            QuickListState.fromPayload(payload("open" to false)),
        )
        assertEquals(QuickListState.closed, QuickListState.fromPayload(null))
        assertEquals(QuickListState.closed, QuickListState.fromPayload(emptyMap<String, Any?>()))
        assertFalse(QuickListState.closed.open)
    }

    @Test
    fun `every optional key may be absent`() {
        val state = QuickListState.fromPayload(
            mapOf("open" to true, "rows" to listOf(mapOf("label" to "Only a label"))),
        )
        assertTrue(state.open)
        assertEquals(QuickListMode.Channels, state.mode)
        assertEquals("", state.heading)
        assertEquals(0, state.selectedIndex)
        assertEquals(0, state.windowStart)
        // No `total`: the window itself is all there is.
        assertEquals(1, state.total)
        assertEquals(0, state.revision)
        assertFalse(state.loading)
        assertNull(state.emptyLabel)
        val only = state.rows.single()
        assertEquals("Only a label", only.label)
        assertEquals("", only.id)
        assertEquals(0, only.index)
        assertFalse(only.selected)
    }

    @Test
    fun `nothing in a malformed payload throws`() {
        // Wrong types everywhere, junk row elements, a null row, a string
        // where a bool belongs. Every one of these degrades.
        val junk = QuickListState.fromPayload(
            mapOf(
                "open" to true,
                "mode" to 3,
                "heading" to listOf(1, 2),
                "rows" to listOf("not a map", null, 42, mapOf("label" to 9)),
                "selectedIndex" to "nope",
                "windowStart" to -12,
                "total" to "many",
                "loading" to "yes",
                "emptyLabel" to "   ",
                "revision" to 2.5,
            ),
        )
        assertTrue(junk.open)
        assertEquals(QuickListMode.Channels, junk.mode)
        assertEquals("", junk.heading)
        // Rows are mapped positionally and never dropped, or the highlight
        // would land on a different row than the one Dart selected.
        assertEquals(4, junk.rows.size)
        assertEquals("", junk.rows[0].label)
        assertEquals(0, junk.windowStart)
        assertEquals(0, junk.selectedIndex)
        assertEquals(4, junk.total)
        assertFalse(junk.loading)
        // Blank is not a label.
        assertNull(junk.emptyLabel)
        assertEquals(2, junk.revision)

        assertEquals(QuickListState.closed, QuickListState.fromPayload(mapOf("open" to "true")))
    }

    @Test
    fun `numbers survive arriving as Long`() {
        // A platform channel widens integers by magnitude, so every numeric
        // field is read through Number rather than cast to Int.
        val state = QuickListState.fromPayload(
            payload(
                "selectedIndex" to 120_000L,
                "windowStart" to 119_980L,
                "total" to 250_000L,
                "revision" to 3L,
                "rows" to listOf(row(119_980, "a"), row(119_981, "b")),
            ),
        )
        assertEquals(120_000, state.selectedIndex)
        assertEquals(119_980, state.windowStart)
        assertEquals(250_000, state.total)
        assertEquals(3, state.revision)
        assertEquals(119_981, state.rows[1].index)
    }

    @Test
    fun `the highlight comes from the window offset`() {
        val state = QuickListState.fromPayload(
            payload(
                "rows" to listOf(row(10, "a"), row(11, "b"), row(12, "c")),
                "windowStart" to 10,
                "selectedIndex" to 12,
                "total" to 40,
            ),
        )
        assertEquals(2, state.selectedInWindow)

        // A window that does not contain the cursor draws no highlight at all
        // rather than one on the wrong row — on a remote, a highlight in the
        // wrong place is worse than none.
        val adrift = state.copy(selectedIndex = 39)
        assertEquals(-1, adrift.selectedInWindow)
        assertEquals(-1, QuickListState.closed.selectedInWindow)
    }

    @Test
    fun `an empty list carries its own label`() {
        val state = QuickListState.fromPayload(
            payload(
                "rows" to emptyList<Any?>(),
                "total" to 0,
                "selectedIndex" to 0,
                "emptyLabel" to "No guide for today",
                "mode" to "schedule",
            ),
        )
        assertTrue(state.isEmpty)
        assertEquals(QuickListMode.Schedule, state.mode)
        assertEquals("No guide for today", state.emptyLabel)
        assertEquals(-1, state.selectedInWindow)
    }

    @Test
    fun `modes and row kinds map from the wire, unknown falling back`() {
        assertEquals(QuickListMode.Categories, QuickListMode.fromWire("categories"))
        assertEquals(QuickListMode.Channels, QuickListMode.fromWire("channels"))
        assertEquals(QuickListMode.Schedule, QuickListMode.fromWire("schedule"))
        // A mode this build doesn't know reads as the one the list opens on,
        // which is always safe to draw.
        assertEquals(QuickListMode.Channels, QuickListMode.fromWire("something-new"))
        assertEquals(QuickListMode.Channels, QuickListMode.fromWire(null))

        assertEquals(QuickListRowKind.Category, QuickListRowKind.fromWire("category"))
        assertEquals(QuickListRowKind.Channel, QuickListRowKind.fromWire("channel"))
        assertEquals(QuickListRowKind.Programme, QuickListRowKind.fromWire("programme"))
        assertEquals(QuickListRowKind.Channel, QuickListRowKind.fromWire(null))
    }

    @Test
    fun `loading is a state of its own, not an empty list`() {
        val state = QuickListState.fromPayload(
            payload("rows" to emptyList<Any?>(), "total" to 0, "loading" to true),
        )
        assertTrue(state.loading)
        assertTrue(state.isEmpty)
        // Absent while loading, by contract — so the renderer shows a spinner
        // rather than "nothing here" over a fetch that is still running.
        assertNull(state.emptyLabel)
    }
}
