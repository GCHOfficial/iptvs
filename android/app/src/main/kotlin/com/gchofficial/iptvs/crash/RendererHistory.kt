package com.gchofficial.iptvs.crash

/**
 * Which Flutter renderer each recent process ran, so a crash report about an
 * **earlier** process carries that process's renderer rather than the current
 * one's.
 *
 * Tombstones, ANR exit records and cached NDK envelopes are all reported on
 * the *next* launch, through [NativeCrashScrubber]'s `beforeSend`. Tagging them
 * with the reporting process's renderer was wrong in a way that mattered:
 * IPTVS-C is a 0.1.78 crash (a build that could not set the tag at all)
 * reported as `renderer=skia-gl` because a later build uploaded it — and the
 * RTD2875P recurrence rule in `docs/validation-baseline.md` reads exactly that
 * tag. So each process records `pid renderer` at startup, and a report from an
 * earlier process is tagged only when its pid is found here; otherwise the tag
 * is left off rather than guessed.
 *
 * Pure: the file I/O lives in [NativeCrashScrubber], pinned by
 * `RendererHistoryTest`.
 */
internal object RendererHistory {
    /** Processes remembered. Pids recycle; a short history keeps a reuse unlikely. */
    const val MAX_ENTRIES = 8

    /**
     * Mechanisms whose event describes a process other than the one sending
     * it: Android 12+ tombstones (plain and merged with the NDK event), the
     * ApplicationExitInfo ANR, and sentry-native's signal handler, whose
     * envelope is written by the crashing process and sent by the next one.
     */
    val EARLIER_PROCESS_MECHANISMS =
        setOf("Tombstone", "TombstoneMerged", "AppExitInfo", "signalhandler")

    // The tombstone message's own phrasing:
    // "Fatal signal SIGILL (4), ILL_ILLOPC (1), pid = 8762 (com.…)".
    private val PID = Regex("""\bpid = (\d+)\b""")

    fun pidOf(message: String?): Int? =
        message?.let { PID.find(it)?.groupValues?.get(1)?.toIntOrNull() }

    /** [lines] with this process appended, replacing an older entry for the same pid. */
    fun recorded(lines: List<String>, pid: Int, renderer: String): List<String> =
        (lines.filter { entryPid(it) != null && entryPid(it) != pid } + "$pid $renderer")
            .takeLast(MAX_ENTRIES)

    fun lookup(lines: List<String>, pid: Int): String? =
        lines.lastOrNull { entryPid(it) == pid }
            ?.substringAfter(' ', "")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

    private fun entryPid(line: String): Int? =
        line.substringBefore(' ', "").toIntOrNull()
}
