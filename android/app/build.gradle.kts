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

android {
    namespace = "com.gchofficial.iptvs"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The application ID is the app's stable public identity (and what the
        // system reports as the package name, e.g. in an HDMI-info overlay). It
        // matches the Kotlin `namespace`/package.
        applicationId = "com.gchofficial.iptvs"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // libmpv (dev.jdtech.mpv:libmpv) requires API 26+; this also matches the
        // HDR window color-mode API used by the native player.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Point the auto-created `debug` config at a fixed, committed keystore
        // instead of each machine's/CI runner's ephemeral ~/.android/debug.keystore.
        // That keeps the signing key identical across every CI build, so a new APK
        // installs over the previous one on a test device without an uninstall
        // (a per-run ephemeral key changes the signature → Android refuses the
        // update silently, leaving the old app running). Standard debug creds.
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // No release keystore yet: sign release with the (now fixed) debug key
            // so CI `--release` builds need no secrets and update in place on devices.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        // Jetpack Compose powers the native HDR player's control overlay.
        compose = true
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
    // ExoPlayer/Media3 is the DEFAULT native-player engine: MediaCodec hardware
    // decode feeding a SurfaceView gives true HDR (HDR10/HDR10+/HLG/DV-P8) with the
    // compositor switching the panel into HDR — something mpv's GL render path can't
    // do on Android.
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")

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
    val composeBom = platform("androidx.compose:compose-bom:2026.06.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
}
