package com.gchofficial.iptvs.player

/**
 * Which Flutter renderer this process starts with.
 *
 * Impeller everywhere, **except** on a small runtime denylist of SoC models
 * that have been observed corrupting memory under it. Today that list has one
 * entry: the Realtek **RTD2875P** (TCL G10 class TV, Android 12, armeabi-v7a),
 * whose tombstones are `scudo::reportHeaderCorruption` aborts, a SIGILL inside
 * Skia's text layout and a corrupted chunk header inside BoringSSL's free —
 * three different memory managers as the victim, i.e. a stray write from
 * somewhere else. A hand-dispatched renderer-test APK carrying the build-time
 * `io.flutter.embedding.android.EnableImpeller=false` manifest opt-out stopped
 * them across several sources and streams, which is the evidence this denylist
 * encodes. See `docs/validation-baseline.md`, "Play vitals clusters".
 *
 * **Android-free and pure on purpose** — `MainActivity` reads
 * `Build.SOC_MODEL` and the merged manifest and hands the strings in, so the
 * rule itself is pinned by `RendererPolicyTest` without an instrumented
 * device.
 *
 * **Flutter-upgrade caveat.** The opt-out is deprecated: Flutter 3.47.9 warns
 * it "is going to go away in an upcoming Flutter release", and when it does,
 * `--enable-impeller=false` silently becomes a no-op — the app would keep
 * reporting `renderer=skia-gl` while running Impeller. Nothing here can detect
 * that. Re-check `FlutterEngineFlags.ENABLE_IMPELLER` (and that it is still
 * `allowedInRelease`) on every Flutter bump.
 */
object RendererPolicy {
    /** The wire/diagnostics name of Flutter's default renderer. */
    const val IMPELLER = "impeller"

    /** The wire/diagnostics name of the Skia OpenGL renderer. */
    const val SKIA_GL = "skia-gl"

    /** No rule fired; Flutter's own default is in charge. */
    const val REASON_DEFAULT = "default"

    /** The build carries an explicit `EnableImpeller` manifest entry. */
    const val REASON_MANIFEST = "manifest"

    /** A debug build was launched with the force-Skia intent extra. */
    const val REASON_FORCED_DEBUG = "forced-debug"

    /** Prefix of the reason a denylist hit produces (`soc:RTD2875P`). */
    const val REASON_SOC_PREFIX = "soc:"

    /**
     * The engine argument that turns Impeller off. Mirrors
     * `FlutterEngineFlags.ENABLE_IMPELLER.engineArgument` plus `false`; the
     * flag is `allowedInRelease`, which is why the same switch works on a
     * shipped build and not only under `flutter run`.
     */
    const val IMPELLER_OFF_ARG = "--enable-impeller=false"

    /**
     * SoC models that must not run Impeller, as `Build.SOC_MODEL` spells them.
     *
     * Matching is **exact** (case-insensitive, after trimming): `RTD2873` and
     * `RTD2875` are different parts and a prefix match would sweep in chips
     * nothing is known about. Keep this list tiny and evidence-backed — every
     * entry is an install that silently loses Impeller's rendering.
     */
    val DENYLIST: List<String> = listOf("RTD2875P")

    /**
     * The resolved renderer, why, and the engine argument (if any) that has to
     * ride on `FlutterActivity.getFlutterShellArgs()` to make it so.
     *
     * [shellArg] is null whenever the renderer needs no argument from us —
     * either because Impeller is simply the default, or because the *manifest*
     * already states the choice and adding a second, possibly contradictory,
     * `--enable-impeller=` would leave the outcome to the order of an
     * unordered set.
     */
    data class Decision(
        val renderer: String,
        val reason: String,
        val shellArg: String?,
    )

    /**
     * The canonical denylist entry [socModel] matches, or null.
     *
     * Null, blank and anything unknown are **not** matches: the denylist is an
     * opt-*out* of the default, so an unreadable SoC keeps Impeller.
     */
    fun denylistMatch(socModel: String?): String? {
        val trimmed = socModel?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        return DENYLIST.firstOrNull { it.equals(trimmed, ignoreCase = true) }
    }

    /**
     * Resolves the renderer for this launch.
     *
     * Precedence, strongest first:
     *
     *  1. **The manifest.** `manifestEnableImpeller` is the value of an
     *     `io.flutter.embedding.android.EnableImpeller` meta-data entry, or
     *     null when the build carries no such key (every ordinary build: the
     *     key name is rewritten to `…EnableImpeller.unset`, see
     *     `android/app/build.gradle.kts`). When it is present it is a
     *     deliberate build-time statement — today only `renderer-test-apk.yml`
     *     makes one — and this matcher stands aside entirely, contributing no
     *     argument. That keeps a future A/B build that pins Impeller *on*
     *     from being silently defeated by the denylist, and means we never
     *     have to know which of two contradictory `--enable-impeller=` values
     *     the engine would pick.
     *  2. **The debug force switch**, for CI. Caller-gated on
     *     `BuildConfig.DEBUG`; inert in every release build.
     *  3. **The SoC denylist.**
     *  4. Otherwise Impeller, with no argument.
     */
    fun decide(
        socModel: String?,
        manifestEnableImpeller: Boolean?,
        forceSkiaGl: Boolean,
    ): Decision {
        if (manifestEnableImpeller != null) {
            return Decision(
                renderer = if (manifestEnableImpeller) IMPELLER else SKIA_GL,
                reason = REASON_MANIFEST,
                shellArg = null,
            )
        }
        if (forceSkiaGl) {
            return Decision(SKIA_GL, REASON_FORCED_DEBUG, IMPELLER_OFF_ARG)
        }
        val matched = denylistMatch(socModel)
        if (matched != null) {
            return Decision(SKIA_GL, REASON_SOC_PREFIX + matched, IMPELLER_OFF_ARG)
        }
        return Decision(IMPELLER, REASON_DEFAULT, null)
    }
}
