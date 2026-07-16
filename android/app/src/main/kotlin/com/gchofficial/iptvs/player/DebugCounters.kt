package com.gchofficial.iptvs.player

import com.gchofficial.iptvs.BuildConfig
import java.util.concurrent.atomic.AtomicInteger

/**
 * Debug-only lifecycle counters for the native player: playback engines, the
 * preview platform view, the fullscreen progress-ticker coroutine, and the
 * [SharedEngine]'s live engine slot. A Dart-driven integration-test soak reads
 * [snapshot] across repeated open/close cycles to assert nothing leaks (e.g. a
 * disposed preview still holding an `ExoPlayerEngine`).
 *
 * Every increment/decrement is a no-op unless [BuildConfig.DEBUG], and
 * [snapshot] returns an empty map in release builds — so this has zero
 * observable effect (and zero overhead beyond the flag check) outside debug
 * builds.
 */
object DebugCounters {
    private val exoEngines = AtomicInteger(0)
    private val mpvEngines = AtomicInteger(0)
    private val previewViews = AtomicInteger(0)
    private val progressTickers = AtomicInteger(0)
    private val sharedEngineLive = AtomicInteger(0)

    fun incExoEngine() {
        if (BuildConfig.DEBUG) exoEngines.incrementAndGet()
    }

    fun decExoEngine() {
        if (BuildConfig.DEBUG) exoEngines.decrementAndGet()
    }

    fun incMpvEngine() {
        if (BuildConfig.DEBUG) mpvEngines.incrementAndGet()
    }

    fun decMpvEngine() {
        if (BuildConfig.DEBUG) mpvEngines.decrementAndGet()
    }

    fun incPreviewView() {
        if (BuildConfig.DEBUG) previewViews.incrementAndGet()
    }

    fun decPreviewView() {
        if (BuildConfig.DEBUG) previewViews.decrementAndGet()
    }

    fun incProgressTicker() {
        if (BuildConfig.DEBUG) progressTickers.incrementAndGet()
    }

    fun decProgressTicker() {
        if (BuildConfig.DEBUG) progressTickers.decrementAndGet()
    }

    fun incSharedEngineLive() {
        if (BuildConfig.DEBUG) sharedEngineLive.incrementAndGet()
    }

    fun decSharedEngineLive() {
        if (BuildConfig.DEBUG) sharedEngineLive.decrementAndGet()
    }

    /** Empty in release builds (see class doc) — never exposes counts there. */
    fun snapshot(): Map<String, Int> {
        if (!BuildConfig.DEBUG) return emptyMap()
        return mapOf(
            "exoEngines" to exoEngines.get(),
            "mpvEngines" to mpvEngines.get(),
            "previewViews" to previewViews.get(),
            "progressTickers" to progressTickers.get(),
            "sharedEngineLive" to sharedEngineLive.get(),
        )
    }
}
