package com.gchofficial.iptvs.crash

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Java-side crash scrubber's pure half.
 *
 * The redaction vectors here are deliberately the same ones asserted in
 * `test/crash_reporting_test.dart`: a crash report is the one payload this app
 * sends to a third party, and the Dart and Java paths must agree about what
 * never leaves the device. The budget vectors pin the shared file grammar, so
 * the two readers cannot drift apart silently.
 */
class CrashScrubTest {
    // Credentials written as `user=`/`pw=` rather than the literal
    // `username=…&password=…` pair, which trips GitGuardian on every PR that
    // adds one (CLAUDE.md "Testing notes"). The parser under test does not
    // care which key name it sees.
    private val queryUrl = "http://panel.example.com:8080/get.php?user=alice&pw=hunter2"
    private val pathUrl = "http://panel.example.com:8080/live/alice/hunter2/4821.ts"

    @Test
    fun `a query string never survives`() {
        val out = CrashScrub.redactText("HTTP 403 fetching $queryUrl")
        assertFalse(out.contains("alice"))
        assertFalse(out.contains("hunter2"))
        assertTrue(out.contains("panel.example.com:8080"))
        assertTrue(out.contains("<redacted>"))
    }

    @Test
    fun `credential path segments go, the stream id stays`() {
        val out = CrashScrub.redactText("Source error: $pathUrl")
        assertFalse(out.contains("alice"))
        assertFalse(out.contains("hunter2"))
        // The filename is the one useful part of the path and carries no
        // secret, so it must survive.
        assertTrue(out.contains("4821.ts"))
        assertTrue(out.contains("panel.example.com"))
    }

    @Test
    fun `every URL in one line is redacted, not just the first`() {
        val out = CrashScrub.redactText("redirect $queryUrl -> $pathUrl")
        assertFalse(out.contains("alice"))
        assertFalse(out.contains("hunter2"))
    }

    @Test
    fun `a bare credential pair with no scheme is still redacted`() {
        // ExoPlayer and mpv both quote fragments without a scheme.
        val out = CrashScrub.redactText("player_api.php?user=alice&pw=hunter2 failed")
        assertFalse(out.contains("alice"))
        assertFalse(out.contains("hunter2"))
    }

    @Test
    fun `token-shaped path segments are redacted on length alone`() {
        val out = CrashScrub.redactText("http://h/vod/aVeryLongOpaqueToken12345/x.mkv")
        assertFalse(out.contains("aVeryLongOpaqueToken12345"))
    }

    @Test
    fun `ordinary prose is left alone`() {
        val text = "Decoder init failed: MediaCodec, no such codec"
        assertEquals(text, CrashScrub.redactText(text))
    }

    @Test
    fun `the fingerprint is stable and discriminating`() {
        val a = CrashScrub.fingerprint("IllegalStateException", listOf("a:b", "c:d"))
        assertEquals(a, CrashScrub.fingerprint("IllegalStateException", listOf("a:b", "c:d")))
        assertNotEquals(a, CrashScrub.fingerprint("IllegalStateException", listOf("a:b", "c:e")))
        assertNotEquals(a, CrashScrub.fingerprint("IOException", listOf("a:b", "c:d")))
        assertEquals(32, a.length)
    }

    @Test
    fun `the budget file round-trips through the shared grammar`() {
        val state = CrashBudgetState().apply {
            dayStartMs = 1000
            dayCount = 3
            monthStartMs = 500
            monthCount = 7
            sessionId = 99
            sessionCount = 2
            starts = 1
            seen["abc123"] = 42
        }
        val parsed = CrashBudgetState.parse(state.encode())
        assertEquals(1000L, parsed.dayStartMs)
        assertEquals(3, parsed.dayCount)
        assertEquals(500L, parsed.monthStartMs)
        assertEquals(7, parsed.monthCount)
        assertEquals(99L, parsed.sessionId)
        assertEquals(2, parsed.sessionCount)
        assertEquals(1, parsed.starts)
        assertEquals(42L, parsed.seen["abc123"])
    }

    @Test
    fun `a file written by Dart parses here`() {
        // Byte-for-byte what `CrashBudgetState.encode()` emits on the Dart
        // side. If either writer changes shape this fails on both sides.
        val fromDart =
            "v=1\nday=1000,3\nmonth=500,7\nsession=99,2\nstarts=1\nfp=abc123,42\n"
        val parsed = CrashBudgetState.parse(fromDart)
        assertEquals(3, parsed.dayCount)
        assertEquals(42L, parsed.seen["abc123"])
    }

    @Test
    fun `an unknown version starts fresh rather than honouring counters`() {
        val parsed = CrashBudgetState.parse("v=99\nday=1000,19\n")
        assertEquals(0, parsed.dayCount)
        assertEquals(0L, parsed.dayStartMs)
    }

    @Test
    fun `the same fingerprint is admitted once per day`() {
        val budget = CrashBudgetFile(tempFile()) { 0L }
        assertTrue(budget.admit("fp-a"))
        assertFalse(budget.admit("fp-a"))
        assertTrue(budget.admit("fp-b"))
    }

    @Test
    fun `the session cap stops a loop inside one launch`() {
        var now = 0L
        val budget = CrashBudgetFile(tempFile()) { now }
        repeat(CrashBudgetFile.MAX_PER_SESSION) { i ->
            assertTrue("event $i", budget.admit("fp-$i"))
        }
        assertFalse(budget.admit("fp-overflow"))
        // Still refused later in the same session, even once de-duplication
        // would have let a new fingerprint through.
        now += 60_000
        assertFalse(budget.admit("fp-later"))
    }

    private fun tempFile(): File =
        Files.createTempDirectory("crash-budget").resolve("budget").toFile()
}
