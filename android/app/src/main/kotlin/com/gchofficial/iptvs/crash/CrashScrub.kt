package com.gchofficial.iptvs.crash

import java.io.File
import java.security.MessageDigest

/**
 * Pure, Android-free half of the native crash scrubber: redaction, the
 * fingerprint, and the shared send budget.
 *
 * Kept separate from [NativeCrashScrubber] so all of it runs in the plain
 * JUnit harness (`./gradlew :app:testDevelopmentDebugUnitTest`) — nothing here
 * touches `android.*`, `io.sentry.*`, or `org.json` (which on Android is a
 * stub that throws in unit tests).
 *
 * ## Why any of this exists in Kotlin
 *
 * `sentry_flutter` pushes Dart events *down* into the native SDK and nothing
 * comes back up, so the Dart `beforeSend` in `lib/data/crash_reporter.dart`
 * sees Dart events only. Android's Java/Kotlin uncaught exceptions, NDK signal
 * crashes and Android 12+ tombstones are captured and sent by the Java SDK and
 * never pass through it. A Java exception message routinely quotes the URL it
 * was fetching, and in this app that URL carries provider credentials — so the
 * Java side needs its own redaction, and the same quota cap, applied at the one
 * place every Java-side event goes through (`SentryClient.captureEvent` →
 * `beforeSend`, which sentry-java runs for cached outbox envelopes too).
 */
object CrashScrub {
    /**
     * Path segments that introduce IPTV credential/route material. Must stay
     * in step with `_kCredentialPathKeywords` in `lib/data/net.dart`: an
     * Xtream-style stream URL puts the username and password in the two
     * segments right after one of these, and those are usually too short to
     * trip the length/token heuristic below.
     */
    private val credentialPathKeywords =
        setOf("live", "movie", "movies", "series", "timeshift", "play")

    private val urlPattern = Regex("https?://\\S+", RegexOption.IGNORE_CASE)
    private val tokenShaped = Regex("^[A-Za-z0-9_-]{12,}$")

    /**
     * Credential-shaped `key=value` pairs, redacted wherever they appear.
     *
     * The URL pass above only fires on text containing a full `http(s)://`
     * locator, and a thrown provider message does not always carry one — an
     * ExoPlayer `InvalidResponseCodeException` can quote a bare
     * `player_api.php?username=…&password=…`, and an mpv line can quote a
     * query fragment on its own. This pass is deliberately narrow (a known key
     * name immediately followed by `=`) so it cannot mangle ordinary prose,
     * and it is applied last so it also catches anything the URL pass left.
     * Mirrored by `redactCredentialPairs` in `lib/data/crash_reporter.dart`.
     */
    private val credentialPairs = Regex(
        "(?i)\\b(user|username|pass|password|pw|pwd|token|auth|api_?key|key|mac|sn|device_?id|stream_?token|play_?token)=[^&\\s\"'<>]+",
    )

    /**
     * Removes credential-shaped material from free-form text.
     *
     * A deliberate re-implementation of Dart's `redactText`, **not** a literal
     * port: Dart leans on `Uri.tryParse`, whose behaviour on half-parsable
     * free text cannot be reproduced with `java.net.URI`. The contract this
     * side keeps is *at least as aggressive*, with the two rules that matter
     * identical — the whole query string goes, and a path segment goes if it
     * follows a route keyword or looks like a token. The canonical vectors are
     * asserted in both `CrashScrubTest` and `test/crash_reporting_test.dart`,
     * so the two cannot drift on the cases that carry credentials.
     *
     * Working on raw string splits rather than a URI parser is also the safer
     * failure mode here: nothing can throw, and text that is not a URL is left
     * recognisable instead of being rewritten into a mangled path.
     */
    fun redactText(text: String): String {
        if (text.isEmpty()) return text
        val urlsCleaned = if (urlPattern.containsMatchIn(text)) {
            urlPattern.replace(text) { match ->
                redactPathSegments(stripQuery(match.value))
            }
        } else {
            redactPathSegments(text)
        }
        return credentialPairs.replace(urlsCleaned) { match ->
            "${match.groupValues[1]}=<redacted>"
        }
    }

    /** Replaces a URL's query/fragment with a single `<redacted>` marker. */
    private fun stripQuery(url: String): String {
        val cut = url.indexOfFirst { it == '?' || it == '#' }
        return if (cut < 0) url else url.substring(0, cut) + "?<redacted>"
    }

    private fun redactPathSegments(value: String): String {
        val schemeEnd = value.indexOf("://")
        val prefixEnd: Int
        if (schemeEnd >= 0) {
            // Keep `scheme://host[:port]` verbatim: a hostname is not a
            // credential, and an unrecognisable host makes a report useless.
            val hostEnd = value.indexOf('/', schemeEnd + 3)
            prefixEnd = if (hostEnd < 0) value.length else hostEnd
        } else {
            prefixEnd = 0
        }
        if (prefixEnd >= value.length) return value
        val prefix = value.substring(0, prefixEnd)
        val rest = value.substring(prefixEnd)
        if (!rest.contains('/')) return value

        val segments = rest.split('/')
        val redactByStructure = BooleanArray(segments.size)
        for (i in segments.indices) {
            if (segments[i].lowercase() in credentialPathKeywords) {
                var j = i + 1
                // Never the final segment — that is the stream id / filename,
                // which carries no secret and is the one useful part.
                while (j <= i + 2 && j < segments.size - 1) {
                    redactByStructure[j] = true
                    j++
                }
            }
        }
        val cleaned = segments.mapIndexed { i, segment ->
            val looksSecret =
                segment.length > 18 || tokenShaped.matches(segment)
            if (looksSecret || redactByStructure[i]) "<redacted>" else segment
        }
        return prefix + cleaned.joinToString("/")
    }

    /** How many frames identify a fault. Mirrors Dart's `kFingerprintFrames`. */
    const val FINGERPRINT_FRAMES = 3

    /**
     * Picks the frames that identify a fault, **innermost first**.
     *
     * ## The order is the whole point
     *
     * Sentry stores stack frames **outermost first**: sentry-java builds them
     * from `Throwable.getStackTrace()` and then calls `Collections.reverse`
     * (`SentryStackTraceFactory.getStackFrames`), so `frames.first()` is the
     * process entry point and `frames.last()` is the throw site. Taking "the
     * first three" therefore takes `com.android.internal.os.ZygoteInit.main`,
     * `RuntimeInit$MethodAndArgsCaller.run` and `Method.invoke` — the same
     * three for **every** uncaught main-thread exception this app can throw.
     * One fingerprint for all of them means the budget's de-duplication drops
     * every main-thread crash but the first in any 24 h window.
     *
     * ## Why the in-app preference is not enough on its own
     *
     * On Android no frame is ever marked in-app. sentry-java decides `isInApp`
     * from `inAppIncludes`, whose only entry is the one
     * `AndroidOptionsInitializer.readDefaultOptionValues` adds: the
     * **applicationId** (`com.gchofficial.iptvs.player[.dev|.direct]`). This
     * app's classes are under the **namespace** `com.gchofficial.iptvs`, which
     * is not a prefix of it; there are no default excludes; so `isInApp`
     * returns `null` for app and framework frames alike. R8 would break a
     * prefix match anyway — shipped app classes are renamed (`f5.run`). The
     * fallback has to be the *innermost* frames.
     *
     * [frames] is the event's frames in Sentry order (outermost first), each
     * paired with its `isInApp`. Returns at most [FINGERPRINT_FRAMES] ids: the
     * innermost in-app ones if there are any, otherwise the innermost of all.
     */
    fun fingerprintFrames(frames: List<Pair<String, Boolean?>>): List<String> {
        val innermostFirst = frames.asReversed()
        val inApp = innermostFirst.filter { it.second == true }
        val chosen = if (inApp.isNotEmpty()) inApp else innermostFirst
        return chosen.take(FINGERPRINT_FRAMES).map { it.first }
    }

    /**
     * An opaque, stable identity for one fault.
     *
     * Same shape as Dart's `crashFingerprint` — exception type plus the
     * innermost frames [fingerprintFrames] picked — so a crash that produces
     * both a Dart and a Java event is not de-duplicated across the two (they
     * are genuinely different reports), but the *same* Java crash repeating
     * is. The two languages share one budget file, so the rules must not
     * drift apart.
     */
    fun fingerprint(type: String?, frames: List<String>): String {
        val joined =
            (listOf(type ?: "error") + frames.take(FINGERPRINT_FRAMES)).joinToString("|")
        val digest = MessageDigest.getInstance("SHA-256").digest(joined.toByteArray())
        return digest.joinToString("") { byte ->
            (byte.toInt() and 0xff).toString(16).padStart(2, '0')
        }.substring(0, 32)
    }
}

/**
 * The on-disk send budget, shared with Dart (`lib/data/crash_budget.dart`).
 *
 * Line-oriented `key=value` ASCII rather than JSON, because this class has to
 * parse in a plain JVM unit test and `org.json` is an always-throwing stub
 * there. Every value is a decimal integer or a `[0-9a-f]{32}` hash, so there is
 * nothing to escape and the two parsers cannot disagree about quoting. The
 * grammar and every constant below must stay in step with the Dart side; the
 * `v=` line is the version both halves check.
 */
class CrashBudgetState {
    var dayStartMs: Long = 0
    var dayCount: Int = 0
    var monthStartMs: Long = 0
    var monthCount: Int = 0
    var sessionId: Long = 0
    var sessionCount: Int = 0
    var starts: Int = 0
    val seen: MutableMap<String, Long> = LinkedHashMap()

    fun encode(): String {
        val out = StringBuilder()
        out.append("v=").append(FORMAT_VERSION).append('\n')
        out.append("day=").append(dayStartMs).append(',').append(dayCount).append('\n')
        out.append("month=").append(monthStartMs).append(',').append(monthCount).append('\n')
        out.append("session=").append(sessionId).append(',').append(sessionCount).append('\n')
        out.append("starts=").append(starts).append('\n')
        for ((key, at) in seen) {
            out.append("fp=").append(key).append(',').append(at).append('\n')
        }
        return out.toString()
    }

    companion object {
        const val FORMAT_VERSION = 1

        fun parse(raw: String): CrashBudgetState {
            val state = CrashBudgetState()
            var sawVersion = false
            for (line in raw.split('\n')) {
                val trimmed = line.trim()
                if (trimmed.isEmpty()) continue
                val eq = trimmed.indexOf('=')
                if (eq <= 0) continue
                val key = trimmed.substring(0, eq)
                val value = trimmed.substring(eq + 1)
                when (key) {
                    "v" -> {
                        if (value.toIntOrNull() != FORMAT_VERSION) return CrashBudgetState()
                        sawVersion = true
                    }
                    "day" -> pair(value)?.let {
                        state.dayStartMs = it.first
                        state.dayCount = it.second.toInt()
                    }
                    "month" -> pair(value)?.let {
                        state.monthStartMs = it.first
                        state.monthCount = it.second.toInt()
                    }
                    "session" -> pair(value)?.let {
                        state.sessionId = it.first
                        state.sessionCount = it.second.toInt()
                    }
                    "starts" -> state.starts = value.toIntOrNull() ?: 0
                    "fp" -> {
                        val parts = value.split(',')
                        val at = if (parts.size == 2) parts[1].toLongOrNull() else null
                        if (at != null && parts[0].isNotEmpty()) state.seen[parts[0]] = at
                    }
                }
            }
            // No recognisable version line means a future or broken writer.
            // Starting fresh re-arms the caps from now, which is the safe
            // reading — the alternative honours counters we cannot interpret.
            return if (sawVersion) state else CrashBudgetState()
        }

        private fun pair(value: String): Pair<Long, Long>? {
            val parts = value.split(',')
            if (parts.size != 2) return null
            val a = parts[0].toLongOrNull() ?: return null
            val b = parts[1].toLongOrNull() ?: return null
            return a to b
        }
    }
}

/**
 * Why one more event was *not* sent.
 *
 * Mirrors Dart's `CrashBudgetOutcome`; [label] is what gets logged, and the
 * four refusal words must stay spelled the same on both sides because one
 * install's log carries lines from both.
 */
enum class CrashBudgetOutcome(val label: String) {
    ADMITTED("admitted"),
    DUPLICATE("duplicate"),
    SESSION("session"),
    DAY("day"),
    MONTH("month"),
    ;

    val isAdmitted: Boolean
        get() = this == ADMITTED
}

/** File-backed [CrashBudgetState]; see the Dart `CrashBudget` for the rules. */
class CrashBudgetFile(
    private val file: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private fun read(): CrashBudgetState =
        try {
            if (file.isFile) CrashBudgetState.parse(file.readText()) else CrashBudgetState()
        } catch (_: Exception) {
            CrashBudgetState()
        }

    private fun write(state: CrashBudgetState) {
        try {
            val temp = File(file.parentFile, file.name + ".tmp")
            temp.parentFile?.mkdirs()
            temp.writeText(state.encode())
            if (!temp.renameTo(file)) {
                file.delete()
                temp.renameTo(file)
            }
        } catch (_: Exception) {
            // Losing the write loses budget accounting, not the process.
        }
    }

    private fun rotate(state: CrashBudgetState, nowMs: Long) {
        if (nowMs - state.dayStartMs >= DAY_WINDOW_MS) {
            state.dayStartMs = nowMs
            state.dayCount = 0
        }
        if (nowMs - state.monthStartMs >= MONTH_WINDOW_MS) {
            state.monthStartMs = nowMs
            state.monthCount = 0
        }
        state.seen.entries.removeAll { nowMs - it.value >= DEDUP_WINDOW_MS }
    }

    /** Whether one more event may be sent, charging it to every cap when so. */
    fun admit(fingerprint: String): Boolean = check(fingerprint).isAdmitted

    /** [admit] with the reason, for the one log line a refusal leaves behind. */
    fun check(fingerprint: String): CrashBudgetOutcome {
        val nowMs = clock()
        val state = read()
        rotate(state, nowMs)

        if (fingerprint.isNotEmpty() && state.seen.containsKey(fingerprint)) {
            write(state)
            return CrashBudgetOutcome.DUPLICATE
        }
        if (state.sessionCount >= MAX_PER_SESSION) return CrashBudgetOutcome.SESSION
        if (state.dayCount >= MAX_PER_DAY) return CrashBudgetOutcome.DAY
        if (state.monthCount >= MAX_PER_MONTH) return CrashBudgetOutcome.MONTH

        state.sessionCount += 1
        state.dayCount += 1
        state.monthCount += 1
        if (fingerprint.isNotEmpty()) {
            state.seen[fingerprint] = nowMs
            while (state.seen.size > MAX_FINGERPRINTS) {
                val oldest = state.seen.minByOrNull { it.value }?.key ?: break
                state.seen.remove(oldest)
            }
        }
        write(state)
        return CrashBudgetOutcome.ADMITTED
    }

    companion object {
        const val MAX_PER_SESSION = 5
        const val MAX_PER_DAY = 20
        const val MAX_PER_MONTH = 60
        const val MAX_FINGERPRINTS = 64
        const val DAY_WINDOW_MS = 24L * 60 * 60 * 1000
        const val MONTH_WINDOW_MS = 30L * 24 * 60 * 60 * 1000
        const val DEDUP_WINDOW_MS = 24L * 60 * 60 * 1000
    }
}
