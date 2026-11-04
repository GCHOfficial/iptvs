package com.gchofficial.iptvs.crash

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the crash-test build's Kotlin payload against the scrubber it is meant
 * to exercise.
 *
 * Without this the crash test could quietly stop proving anything: a fake URL
 * written in a shape `CrashScrub.redactText` happens to ignore would still
 * produce an event, a reviewer would see "no credentials in the dashboard",
 * and the conclusion would be wrong. The Dart twin
 * (`crashTestLocator`/`crashTestMessage` in `lib/data/crash_test.dart`) is
 * pinned the same way in `test/crash_reporting_test.dart`.
 */
class CrashTestTest {
    @Test
    fun `the fake locator carries both credential shapes`() {
        val locator = CrashTest.locator()
        // The Xtream-style path pair …
        assertTrue(locator.contains("/live/crashtest-example/not-a-real-secret/"))
        // … and a query parameter, which a different rule has to catch.
        assertTrue(locator.contains("token=not-a-real-token"))
    }

    @Test
    fun `the thrown message is fully scrubbed`() {
        val out = CrashScrub.redactText(CrashTest.message())
        assertFalse(out.contains("crashtest-example"))
        assertFalse(out.contains("not-a-real-secret"))
        assertFalse(out.contains("not-a-real-token"))
        // An unrecognisable report is a useless one: the host must survive, or
        // the crash test cannot tell a scrubbed event from a mangled one.
        assertTrue(out.contains("panel.example.com:8080"))
        assertTrue(out.contains("iptvs crash test"))
    }
}
