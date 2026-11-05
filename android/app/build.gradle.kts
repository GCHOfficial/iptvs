// Explicit, and it has to be: inside this script `java` resolves to the Kotlin
// DSL's `JavaPluginExtension` accessor, not to the `java.*` package, so a
// fully-qualified `java.util.Base64` fails to compile with "Unresolved
// reference 'util'". Used by `crashTestBuild` below.
import java.util.Base64

plugins {
    id("com.android.application")
    // Kotlin support is now supplied by Flutter's built-in Kotlin (AGP 9+); the
    // legacy org.jetbrains.kotlin.android (KGP) plugin is intentionally not applied.
    // The Compose compiler plugin still has to be applied for the native player's
    // Jetpack Compose controls (it hooks into AGP's built-in Kotlin compilation).
    id("org.jetbrains.kotlin.plugin.compose")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningEnvironment = mapOf(
    "IPTVS_ANDROID_KEYSTORE_PATH" to System.getenv("IPTVS_ANDROID_KEYSTORE_PATH"),
    "IPTVS_ANDROID_KEYSTORE_PASSWORD" to System.getenv("IPTVS_ANDROID_KEYSTORE_PASSWORD"),
    "IPTVS_ANDROID_KEY_ALIAS" to System.getenv("IPTVS_ANDROID_KEY_ALIAS"),
    "IPTVS_ANDROID_KEY_PASSWORD" to System.getenv("IPTVS_ANDROID_KEY_PASSWORD"),
)
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val missingReleaseSigningValues = releaseSigningEnvironment
    .filterValues { it.isNullOrBlank() }
    .keys
if (releaseTaskRequested && missingReleaseSigningValues.isNotEmpty()) {
    throw GradleException(
        "Release signing is not configured. Missing environment variables: " +
            missingReleaseSigningValues.sorted().joinToString(", "),
    )
}
val releaseSigningConfigured = missingReleaseSigningValues.isEmpty()

/**
 * Whether this is the **crash-test** build, read from the very same
 * `--dart-define=IPTVS_CRASH_TEST=true` that sets Dart's `kCrashTest`
 * (`lib/data/crash_test.dart`).
 *
 * The Flutter Gradle plugin hands the dart-defines straight through as the
 * `dart-defines` project property — a comma-joined list of base64-encoded
 * `KEY=VALUE` strings (`flutter_tools`' `encodeDartDefines`, consumed at
 * `FlutterPlugin.kt`'s `project.findProperty("dart-defines")`). Decoding it
 * here is what keeps Dart and Kotlin from disagreeing about whether this is a
 * crash-test build: **one flag, one source**. An environment variable beside
 * the define would have been the more conventional mirror of the signing
 * block above, and was rejected for exactly that reason — two switches that
 * can be set independently are two switches that will eventually disagree, and
 * the disagreement is silent.
 *
 * It fails **closed** in every uncertain case: an absent property, an
 * unparseable entry, or any value other than the literal `true` leaves this
 * false, which is the shipped behaviour. No release workflow passes the
 * define, so no distributable build can reach the `true` branch.
 */
val crashTestBuild: Boolean = run {
    val encoded = project.findProperty("dart-defines")?.toString().orEmpty()
    if (encoded.isEmpty()) {
        false
    } else {
        encoded.split(",").any { entry ->
            // `runCatching` rather than a `catch (_: …)`: the build script is
            // compiled by Gradle's *embedded* Kotlin, whose version moves with
            // the wrapper, and unnamed catch parameters are a recent addition.
            val decoded = runCatching {
                String(Base64.getDecoder().decode(entry.trim()), Charsets.UTF_8)
            }.getOrDefault("")
            decoded == "IPTVS_CRASH_TEST=true"
        }
    }
}

/**
 * The UUID that ties this build to its R8 mapping file, or `""` when the build
 * is not going to have one uploaded.
 *
 * Flutter's Gradle plugin shrinks **and obfuscates** every `--release`
 * APK/AAB, so Kotlin/Java frames reach Sentry renamed (`f5.run(r8-map-id-…)`).
 * Deobfuscating them needs two halves that agree on one identifier: this value
 * in the manifest, which sentry-java reads as `io.sentry.proguard-uuid` and
 * attaches to every event as a `proguard` debug image, and the matching
 * `tool/sentry_upload_proguard_mapping.sh --uuid` upload of
 * `build/app/outputs/mapping/<variant>/mapping.txt`. CI generates the UUID per
 * build and passes it here; nothing derives it, because the mapping file does
 * not exist yet when the manifest is merged.
 *
 * **Not the Sentry Gradle plugin**, which is banned (CLAUDE.md): it
 * instruments bytecode, turning `android.util.Log` into breadcrumbs and
 * auto-instrumenting HTTP — and our provider URLs carry credentials.
 *
 * An **environment variable** rather than the `dart-defines` property that
 * `crashTestBuild` above decodes, and that is not a contradiction: the rule
 * there is "one flag, one source" for a switch Dart *also* reads. This has no
 * Dart counterpart — Dart never sees it, so there is nothing for a second
 * switch to disagree with — and it matches the signing block's `System.getenv`
 * directly above, which is the other build input CI supplies and a local build
 * omits.
 *
 * It is **not a secret**: it ships inside the APK and rides on every event.
 *
 * Unset is the ordinary local/dev case and emits no usable meta-data (see
 * `AndroidManifest.xml`). Set-but-malformed throws, because that can only be a
 * broken workflow edit, and failing the build is how it gets noticed rather
 * than shipping a release whose crashes are permanently unreadable.
 */
/**
 * Renderer test builds only: switch Flutter's Impeller renderer off, so the
 * engine uses its Skia OpenGL renderer (still present in Flutter 3.47.9's
 * Android engine, behind the deprecated `io.flutter.embedding.android.
 * EnableImpeller` opt-out). Exists for one diagnosis: a TCL / Realtek RTD2875P
 * TV whose tombstones show heap corruption surfacing at random sites
 * (IPTVS-9/A/B). Only the dispatch-only `renderer-test-apk.yml` sets it; it
 * fails closed (anything but the literal `true` is off) and is loud when on.
 */
val iptvsDisableImpeller: Boolean =
    System.getenv("IPTVS_DISABLE_IMPELLER")?.trim() == "true"
if (iptvsDisableImpeller) {
    logger.lifecycle("iptvs: RENDERER-TEST build — Impeller is OFF (Skia OpenGL).")
}

val sentryProguardUuid: String = run {
    val raw = System.getenv("IPTVS_SENTRY_PROGUARD_UUID")?.trim().orEmpty()
    when {
        raw.isEmpty() -> ""
        !Regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$").matches(raw) ->
            throw GradleException(
                "IPTVS_SENTRY_PROGUARD_UUID is set but is not a UUID. Leave it unset for a " +
                    "local build; CI generates it with uuidgen.",
            )
        else -> raw.lowercase()
    }
}
if (sentryProguardUuid.isNotEmpty()) {
    logger.lifecycle("iptvs: R8 mapping UUID $sentryProguardUuid (upload it or Sentry can't deobfuscate).")
}

if (crashTestBuild) {
    // Loud on purpose: this flag adds a deliberate-crash surface to the app,
    // so an accidentally-on build should be obvious in the Gradle log rather
    // than discovered on a device. The value is a boolean; nothing is leaked.
    logger.lifecycle("iptvs: CRASH-TEST build — deliberate-crash actions are compiled in.")
}

android {
    namespace = "com.gchofficial.iptvs"
    // Deliberately ahead of `flutter.compileSdkVersion` (36 on Flutter 3.44.5).
    // androidx.core 1.19.0+ requires consumers to compile against 37, and raising
    // compileSdk is the intended response to `checkAarMetadata` rather than a
    // workaround: it only selects which android.jar we compile against. Runtime
    // behaviour is `targetSdk` (still Flutter's) and device reach is `minSdk` —
    // neither moves here. Flutter lists API 37 as supported for deployment
    // (CI-tested only to 36), so this is supported-but-less-travelled, not
    // unsupported. Drop the override once flutter.compileSdkVersion reaches 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The application ID is the app's stable public identity (and what the
        // system reports as the package name, e.g. in an HDMI-info overlay). It
        // matches the Kotlin `namespace`/package.
        applicationId = "com.gchofficial.iptvs.player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // libmpv (dev.jdtech.mpv:libmpv) requires API 26+; this also matches the
        // HDR window color-mode API used by the native player.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The Kotlin half of the crash-test gate. False in every shipped
        // build, so `MainActivity`'s `crashTestThrow` branch answers
        // `notImplemented()` and R8 folds the dead branch away. See
        // `crashTestBuild` above and `crash/CrashTest.kt`.
        buildConfigField("boolean", "CRASH_TEST", crashTestBuild.toString())

        // The two halves of the `io.sentry.proguard-uuid` meta-data in
        // `AndroidManifest.xml`. With no UUID the *key* is rewritten to a name
        // sentry-java never reads, which is how a build with no uploaded
        // mapping ends up attaching no proguard debug image at all — see the
        // comment on `sentryProguardUuid` above.
        manifestPlaceholders["iptvsSentryProguardUuidKey"] =
            if (sentryProguardUuid.isEmpty()) "io.sentry.proguard-uuid.unset" else "io.sentry.proguard-uuid"
        manifestPlaceholders["iptvsSentryProguardUuid"] =
            sentryProguardUuid.ifEmpty { "unset" }
        // The Impeller opt-out's key: the real one only on a renderer test
        // build, otherwise a name the Flutter embedding never reads.
        manifestPlaceholders["iptvsImpellerOptOutKey"] =
            if (iptvsDisableImpeller) "io.flutter.embedding.android.EnableImpeller"
            else "io.flutter.embedding.android.EnableImpeller.unset"
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("development") {
            dimension = "distribution"
            applicationIdSuffix = ".dev"
        }
        create("githubDirect") {
            dimension = "distribution"
            applicationIdSuffix = ".direct"
        }
        create("googlePlay") {
            dimension = "distribution"
        }
    }

    signingConfigs {
        // This fixed public key is for explicitly non-distributable debug builds.
        // Release builds never fall back to it.
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = file(releaseSigningEnvironment.getValue("IPTVS_ANDROID_KEYSTORE_PATH")!!)
                storePassword = releaseSigningEnvironment.getValue("IPTVS_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = releaseSigningEnvironment.getValue("IPTVS_ANDROID_KEY_ALIAS")
                keyPassword = releaseSigningEnvironment.getValue("IPTVS_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // A release task fails during configuration when any required value
            // is absent, so no distributable APK can silently use the debug key.
            signingConfig = signingConfigs.findByName("release")
        }
    }

    buildFeatures {
        // Jetpack Compose powers the native HDR player's control overlay.
        compose = true
        // Generates BuildConfig.DEBUG, used to no-op the native player's debug-only
        // lifecycle counters (player/DebugCounters.kt) and integration-test soak
        // auto-close in release builds — plus BuildConfig.CRASH_TEST, the Kotlin
        // half of the crash-test gate (see `crashTestBuild` above).
        buildConfig = true
    }

    androidResources {
        // Store the bundled Inter faces rather than deflating them.
        //
        // Flutter resolves a font family by asking the platform's
        // `AssetManager` for the typeface, and a *compressed* asset has to be
        // inflated into a heap buffer before Skia can parse it
        // (`_CompressedAsset::getBuffer` -> `zip_archive::Inflate`). That runs
        // on whichever thread first lays out text in that face — on Flutter
        // that is the UI thread, inside `TextPainter.layout`, which is exactly
        // where a Play-vitals ANR caught a set-top box (issue
        // bdf538f0eba8828130056d4994b1b559). Stored entries are `mmap`ped
        // instead, so the first text layout pays nothing.
        //
        // The three faces are ~1.2 MB raw and deflate to ~0.6 MB, and they are
        // packaged twice — once as `res/font/` for the native player's Compose
        // overlay and once inside `flutter_assets` for the Dart side — so this
        // costs roughly 1.3 MB of *installed* size. Play recompresses for
        // delivery, so the download cost is much smaller than that.
        //
        // This applies to both halves: AAPT2 stores matching entries under
        // `res/`, and the packaging task applies the same predicate to
        // `assets/` (and bundletool to the AAB via `BundleConfig`).
        noCompress += listOf("ttf", "otf")
    }

    packaging {
        jniLibs {
            // Both media_kit and dev.jdtech.mpv ship libmpv.so. We need the
            // dev.jdtech build (libplacebo / gpu-next) for Dolby Vision; as a direct
            // dependency it precedes the transitive media_kit one in the merge, so
            // pickFirst keeps ours. (libc++_shared can likewise appear twice.)
            pickFirsts += setOf("**/libmpv.so", "**/libc++_shared.so")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Declared explicitly because this module imports it directly — FileProvider
    // (`MainActivity`) and the WindowCompat/WindowInsetsControllerCompat edge-to-edge
    // APIs (`HdrPlayerActivity`). It also arrives transitively via media3/activity/
    // compose, and Gradle resolves to the highest request, so pinning here sets a
    // floor rather than overriding those; it just stops a direct source dependency
    // from resting on someone else's transitive graph.
    //
    // 1.19.0+ requires consumers to compile against API 37, which is why
    // `compileSdk` above is pinned to 37 rather than inherited. If that override
    // is ever reverted, this must go back to 1.18.0 or the build fails
    // `checkAarMetadata`. `androidx.core:core-ktx` is version-aligned with this
    // and follows automatically — it appears in that failure alongside `core`.
    implementation("androidx.core:core:1.19.1")

    // ExoPlayer/Media3 is the DEFAULT native-player engine: MediaCodec hardware
    // decode feeding a SurfaceView gives true HDR (HDR10/HDR10+/HLG/DV-P8) with the
    // compositor switching the panel into HDR — something mpv's GL render path can't
    // do on Android.
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.11.1")
    // DASH, for the same reason HLS is here: `DefaultMediaSourceFactory` picks
    // a `MediaSource.Factory` from the URI's inferred content type and loads it
    // **reflectively** (`Class.forName("…dash.DashMediaSource$Factory")`), so a
    // missing module is not a graceful "unsupported" — it is a
    // `ClassNotFoundException` wrapped in an `IllegalStateException` thrown out
    // of `setMediaItem`, i.e. a crash in `ExoPlayerEngine.load`. That shipped:
    // Play issue ef0b3cb0ad7e333376287b5673cfaeeb, 8 reports / 5 users on
    // vc10, all sharing the `DashMediaSource$Factory` signature — i.e. a
    // provider serving `.mpd`.
    //
    // **SmoothStreaming and RTSP are deliberately *not* added.** The same
    // reflective lookup covers `SsMediaSource$Factory` and
    // `RtspMediaSource$Factory`, but there is no evidence of either in the
    // vitals data, `.ism` is effectively extinct in IPTV, and ExoPlayer's RTSP
    // support is narrower than libmpv/FFmpeg's — so for those two the right
    // destination is the mpv fallback, not a second ExoPlayer module. What
    // makes that safe is the `try`/`catch` in `ExoPlayerEngine.load`, which
    // turns an unloadable media source into [ExoPlayerEngine.triggerFallback]
    // instead of a crash. Pinned by `MediaSourceModulesTest`.
    implementation("androidx.media3:media3-exoplayer-dash:1.11.1")
    implementation("androidx.media3:media3-ui:1.11.1")

    // libmpv (gpu-next / libplacebo) is the FALLBACK engine, used only when ExoPlayer
    // can't decode the video track — chiefly Dolby Vision Profile 5 (single-layer, no
    // HDR10 base) on non-DV hardware (e.g. Samsung Galaxy), which mpv software-reshapes
    // and tone-maps. Bundles the JNI wrapper (package `dev.jdtech.mpv`) + prebuilt
    // native libs; no NDK build.
    //
    // Vendored, libdovi-enabled build (libplacebo with Dolby Vision RPU reshaping) —
    // the stock `dev.jdtech.mpv:libmpv:1.0.0` is built WITHOUT libdovi, so DV P5
    // renders green/magenta. Built from a fork of libmpv-android; see
    // `libs/README.md` + `libs/fork/` for the recipe. The .aar is git-ignored (large).
    implementation(files("libs/libmpv-dovi.aar"))

    // Jetpack Compose for the native HDR player's control overlay. The BOM keeps
    // the androidx.compose.* artifacts on a single, mutually-compatible version.
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")

    testImplementation("junit:junit:4.13.2")
}
