package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the renderer denylist.
 *
 * Two things make this worth a test rather than a glance: the match has to be
 * **exact** (a prefix match would sweep in neighbouring Realtek parts nobody
 * has evidence about), and the shipped default has to be Impeller for every
 * input shape that is not a hit — including the null `Build.SOC_MODEL` every
 * API-30-and-below device reports.
 */
class RendererPolicyTest {
    private fun decide(
        soc: String? = null,
        manifest: Boolean? = null,
        force: Boolean = false,
    ) = RendererPolicy.decide(
        socModel = soc,
        manifestEnableImpeller = manifest,
        forceSkiaGl = force,
    )

    @Test
    fun `the denylisted SoC gets Skia GL, named in the reason`() {
        val decision = decide(soc = "RTD2875P")
        assertEquals(RendererPolicy.SKIA_GL, decision.renderer)
        assertEquals("soc:RTD2875P", decision.reason)
        assertEquals(RendererPolicy.IMPELLER_OFF_ARG, decision.shellArg)
    }

    @Test
    fun `case and surrounding whitespace do not defeat the match`() {
        for (spelling in listOf("rtd2875p", "  RTD2875P  ", "Rtd2875P", "\tRTD2875p\n")) {
            val decision = decide(soc = spelling)
            assertEquals(
                "'$spelling' must match the denylist",
                RendererPolicy.SKIA_GL,
                decision.renderer,
            )
            // The reason always quotes the *canonical* entry, never the
            // device's own spelling — it rides into Sentry and the exportable
            // log, so it must be a value from this repo.
            assertEquals("soc:RTD2875P", decision.reason)
        }
    }

    @Test
    fun `a neighbouring or unrelated part keeps Impeller`() {
        for (soc in listOf("RTD2873", "RTD2875", "RTD2875PX", "XRTD2875P", "MT9655", "SM8450")) {
            val decision = decide(soc = soc)
            assertEquals(
                "'$soc' must not be denylisted",
                RendererPolicy.IMPELLER,
                decision.renderer,
            )
            assertEquals(RendererPolicy.REASON_DEFAULT, decision.reason)
            assertNull(decision.shellArg)
        }
    }

    @Test
    fun `a missing SoC model keeps Impeller`() {
        // null is what `Build.SOC_MODEL` is below API 31, and what the
        // caller substitutes there; blank is the shape a vendor can ship.
        for (soc in listOf(null, "", "   ", "\t\n")) {
            val decision = decide(soc = soc)
            assertEquals(RendererPolicy.IMPELLER, decision.renderer)
            assertEquals(RendererPolicy.REASON_DEFAULT, decision.reason)
            assertNull(decision.shellArg)
        }
        assertNull(RendererPolicy.denylistMatch(null))
        assertNull(RendererPolicy.denylistMatch("  "))
    }

    @Test
    fun `the debug force switch selects Skia GL on any device`() {
        val decision = decide(soc = "MT9655", force = true)
        assertEquals(RendererPolicy.SKIA_GL, decision.renderer)
        assertEquals(RendererPolicy.REASON_FORCED_DEBUG, decision.reason)
        assertEquals(RendererPolicy.IMPELLER_OFF_ARG, decision.shellArg)
    }

    @Test
    fun `an EnableImpeller manifest entry wins and contributes no argument`() {
        // The renderer-test APK's shape: the build already says Skia, so the
        // matcher must not add a second --enable-impeller= of its own.
        val off = decide(soc = "RTD2875P", manifest = false)
        assertEquals(RendererPolicy.SKIA_GL, off.renderer)
        assertEquals(RendererPolicy.REASON_MANIFEST, off.reason)
        assertNull(off.shellArg)

        // And a build that deliberately pins Impeller *on* is not overridden
        // by the denylist — that is the A/B this precedence exists to allow.
        val on = decide(soc = "RTD2875P", manifest = true, force = true)
        assertEquals(RendererPolicy.IMPELLER, on.renderer)
        assertEquals(RendererPolicy.REASON_MANIFEST, on.reason)
        assertNull(on.shellArg)
    }

    @Test
    fun `the denylist stays small and exactly spelled`() {
        // A guard against a casual edit: every entry has to be an uppercase
        // SoC model somebody has crash evidence for.
        assertEquals(listOf("RTD2875P"), RendererPolicy.DENYLIST)
    }
}
