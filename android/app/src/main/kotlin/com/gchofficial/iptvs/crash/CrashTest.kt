package com.gchofficial.iptvs.crash

/**
 * The Kotlin half of the crash-test build's payload: a fake provider URL and
 * the exception message that quotes it.
 *
 * Pure and Android-free, so it runs in the plain JUnit harness beside
 * [CrashScrub] — which is the point. A crash test that quotes a URL the
 * redaction already ignores would "pass" while proving nothing, so
 * `CrashTestTest` asserts [message] against [CrashScrub.redactText] with the
 * same vectors `test/crash_reporting_test.dart` uses on the Dart twin
 * (`lib/data/crash_test.dart`, `crashTestLocator`).
 *
 * This object is compiled into every build and is harmless there: it builds a
 * string and nothing else. The *throw* lives in `MainActivity` behind
 * `BuildConfig.CRASH_TEST`, which is false unless the dispatch-only
 * `crash-test-apk.yml` workflow passed
 * `--dart-define=IPTVS_CRASH_TEST=true`.
 *
 * Nothing in here is a real credential. `crashtest-example`,
 * `not-a-real-secret` and `not-a-real-token` are the strings to grep a Sentry
 * event for: if any of them survives into the dashboard, the Java-side
 * scrubbing is broken. Assembled from parts rather than written as one
 * literal, so the source never carries a credential-shaped pair (CLAUDE.md
 * "Testing notes" — GitGuardian flags those on every PR that adds one).
 */
object CrashTest {
    private const val HOST = "panel.example.com"
    private const val USER = "crashtest-example"
    private const val PASS = "not-a-real-secret"
    private const val TOKEN = "not-a-real-token"

    /** The fake locator, carrying credentials in both shapes the scrub handles. */
    fun locator(): String =
        "http://$HOST:8080/" +
            listOf("live", USER, PASS, "4821.ts").joinToString("/") +
            "?token=$TOKEN"

    /** The message of the uncaught [RuntimeException] the crash test throws. */
    fun message(): String =
        "iptvs crash test (uncaught Kotlin exception) while fetching ${locator()}"
}
