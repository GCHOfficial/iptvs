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
    // Keep AGP 9.2.1 until the 9.3 lint regression in CommentDetector is
    // fixed upstream. AGP 9.3 crashes release lint on url_launcher_android
    // with NoSuchMethodError: java.util.List.removeLast() under JDK 17.
    id("com.android.application") version "9.2.1" apply false
    // Declared with `apply false` only to pin the Kotlin version that Flutter's
    // built-in Kotlin (AGP 9+) adopts. KGP is NOT applied to the app module — see
    // the plugins block in app/build.gradle.kts.
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // Compose compiler plugin (ships with Kotlin, so version == Kotlin version).
    // Distinct from KGP above; required for the native player's Compose controls.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.0" apply false
}

include(":app")
