pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 9.3.1 came in with #155 alongside androidx.core 1.19.0 and the
    // compileSdk 37 bump that library's `checkAarMetadata` demands, so it is
    // load-bearing rather than incidental.
    //
    // **AGP 9.3 needs JDK 21 to run release lint.** Its lint calls
    // `java.util.List.removeLast()`, which is `SequencedCollection` — added in
    // Java 21. On JDK 17 that throws `NoSuchMethodError` mid-analysis and
    // surfaces as `Unexpected failure during lint analysis of
    // UrlLauncher.java` out of `CommentDetector`, which reads like a bug in
    // url_launcher and is not one. Every workflow therefore pins
    // `java-version: '21'`; do not lower it while AGP is 9.3+.
    //
    // This was misdiagnosed twice. A comment here previously said to pin AGP
    // back to 9.2.1 "until the 9.3 lint regression is fixed upstream", and
    // #172 acted on it — reverting a needed dependency upgrade to work around
    // a JDK version mismatch. The give-away is that release lint passes on
    // 9.3.1 under a JDK 21 toolchain, which is what local builds use.
    id("com.android.application") version "9.3.1" apply false
    // Declared with `apply false` only to pin the Kotlin version that Flutter's
    // built-in Kotlin (AGP 9+) adopts. KGP is NOT applied to the app module — see
    // the plugins block in app/build.gradle.kts.
    id("org.jetbrains.kotlin.android") version "2.4.10" apply false
    // Compose compiler plugin (ships with Kotlin, so version == Kotlin version).
    // Distinct from KGP above; required for the native player's Compose controls.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10" apply false
}

include(":app")
