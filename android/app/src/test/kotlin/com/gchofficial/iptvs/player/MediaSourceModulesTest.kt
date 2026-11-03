package com.gchofficial.iptvs.player

import org.junit.Assert.fail
import org.junit.Test

/**
 * Which media3 `MediaSource.Factory` modules are on the classpath — asserted by
 * the **exact reflective names** `DefaultMediaSourceFactory` looks up.
 *
 * `DefaultMediaSourceFactory.DelegateFactoryLoader.loadSupplier` picks a factory
 * for the URI's inferred content type and loads it with
 * `Class.forName("androidx.media3.exoplayer.<module>…$Factory")`. A missing
 * module is therefore not a graceful "this container is unsupported": it is a
 * `ClassNotFoundException`, wrapped into an `IllegalStateException` and thrown
 * out of `Player.setMediaItem` — i.e. out of [ExoPlayerEngine.load], which on a
 * cold open runs inside `HdrPlayerActivity.onCreate`. That is how a DASH
 * channel became an Activity-launch crash in Play vitals (issue
 * ef0b3cb0ad7e333376287b5673cfaeeb, 8 reports / 5 users on vc10).
 *
 * A Gradle dependency cannot be unit-tested directly, but its *consequence*
 * can: these names are the contract between build.gradle.kts and media3's
 * reflection, and nothing else in the suite compiles or loads them. The strings
 * are deliberately spelled out rather than derived from a class literal —
 * a class literal would be a compile-time dependency and would stop testing the
 * thing that actually broke.
 */
class MediaSourceModulesTest {

    /** Loads without initialising: presence on the classpath is the whole claim. */
    private fun isOnClasspath(name: String): Boolean = try {
        Class.forName(name, false, javaClass.classLoader)
        true
    } catch (expected: ClassNotFoundException) {
        false
    }

    @Test
    fun dashMediaSourceFactoryIsOnTheClasspath() {
        if (!isOnClasspath("androidx.media3.exoplayer.dash.DashMediaSource\$Factory")) {
            fail(
                "media3-exoplayer-dash is missing. DefaultMediaSourceFactory loads this " +
                    "class reflectively for any .mpd URI, so dropping the dependency " +
                    "turns every DASH channel back into a crash in ExoPlayerEngine.load.",
            )
        }
    }

    @Test
    fun hlsMediaSourceFactoryIsOnTheClasspath() {
        if (!isOnClasspath("androidx.media3.exoplayer.hls.HlsMediaSource\$Factory")) {
            fail("media3-exoplayer-hls is missing; every .m3u8 channel would crash on open.")
        }
    }

    @Test
    fun progressiveMediaSourceFactoryIsOnTheClasspath() {
        // The MPEG-TS path, and the only one DefaultMediaSourceFactory
        // instantiates directly rather than reflectively — asserted so this
        // file describes the whole set the app relies on.
        if (!isOnClasspath("androidx.media3.exoplayer.source.ProgressiveMediaSource\$Factory")) {
            fail("media3-exoplayer is missing its progressive media source.")
        }
    }

    /**
     * SmoothStreaming and RTSP are **deliberately absent**, and this records
     * that as a decision rather than an oversight.
     *
     * Both are reached by the same reflective lookup, so both would crash the
     * same way — except that [ExoPlayerEngine.load] now catches a failed media
     * source and routes it to the libmpv fallback, which plays both containers
     * (RTSP noticeably better than ExoPlayer does). There is no evidence of
     * either shape in the vitals data, and each module is dex weight on a
     * universal APK for a format IPTV panels have stopped serving.
     *
     * If one is ever added, delete the matching line here and say why in
     * docs/player.md — do not leave this test asserting an absence that is no
     * longer the intent.
     */
    @Test
    fun smoothStreamingAndRtspAreDeliberatelyAbsent() {
        for (name in listOf(
            "androidx.media3.exoplayer.smoothstreaming.SsMediaSource\$Factory",
            "androidx.media3.exoplayer.rtsp.RtspMediaSource\$Factory",
        )) {
            if (isOnClasspath(name)) {
                fail(
                    "$name is on the classpath. If that was intentional, update this test " +
                        "and docs/player.md; the mpv fallback was chosen for these two.",
                )
            }
        }
    }
}
