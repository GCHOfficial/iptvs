package com.gchofficial.iptvs.crash

import io.sentry.Breadcrumb
import io.sentry.ScopesAdapter
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import java.io.File

/**
 * Puts this app's redaction and send budget on the **Java** SDK's event path.
 *
 * `sentry_flutter` configures and starts `SentryAndroid` from Dart over JNI
 * and, at the end of that configuration, assigns its own
 * `SentryOptions.beforeSend` (a callback that only adds `event.origin` tags).
 * The Dart `beforeSend` is never forwarded, so without this class three event
 * sources leave the device unredacted and uncapped:
 *
 *  * Java/Kotlin uncaught exceptions — the dangerous one. An ExoPlayer or
 *    `HttpURLConnection` failure quotes the URL it was fetching, and in this
 *    app that URL carries the provider's username and password.
 *  * NDK signal crashes, written to the outbox by sentry-native and
 *    re-captured on the next start.
 *  * Android 12+ tombstones.
 *
 * All three reach `SentryClient.captureEvent`, which calls `beforeSend` with
 * **no exemption for cached events** — so replacing that one callback is a
 * complete choke point for the Java side. We re-implement the plugin's origin
 * tagging rather than chaining to it, because the plugin's callback is a
 * private assignment with no accessor to wrap.
 *
 * The alternative the Sentry docs point at — `autoInitializeNativeSdk = false`
 * plus a Kotlin `Application` init — was rejected deliberately: it would need
 * the DSN in Gradle as a second source of truth, and `sentry_flutter` installs
 * its `FileSystemTransport` regardless of that flag, so a Gradle-side DSN that
 * failed to resolve would silently drop **every Dart event** as well. The
 * residual cost of installing here instead is one method-channel round trip
 * after `SentryFlutter.init`: an outbox envelope flushed inside that window
 * carries the plugin's callback. That is bounded by `maxCacheItems` (5, set on
 * the Dart side) and is structurally credential-free — a cached native event is
 * frames plus a scope whose breadcrumbs Dart's `beforeBreadcrumb` already
 * scrubbed before they were synced to the native scope.
 */
object NativeCrashScrubber {
    @Volatile
    private var installed = false

    /**
     * Installs the callbacks. Idempotent; returns false only if the Sentry
     * Android SDK is not running, in which case there is nothing to guard.
     */
    @Synchronized
    fun install(budgetPath: String): Boolean {
        if (installed) return true
        val options: SentryOptions = ScopesAdapter.getInstance().options
        if (options.dsn.isNullOrEmpty()) return false

        val budget = CrashBudgetFile(File(budgetPath))

        options.beforeBreadcrumb =
            SentryOptions.BeforeBreadcrumbCallback { crumb, _ -> scrub(crumb) }

        options.beforeSend =
            SentryOptions.BeforeSendCallback { event, _ ->
                val scrubbed = scrub(event)
                if (budget.admit(fingerprintOf(scrubbed))) scrubbed else null
            }

        installed = true
        return true
    }

    /**
     * Re-implements the two tags `SentryFlutterPlugin.setupBeforeSend` adds,
     * so replacing its callback does not silently change how events are
     * labelled in the dashboard.
     */
    private fun tagOrigin(event: SentryEvent) {
        when (event.sdk?.name) {
            "sentry.dart.flutter" -> {
                event.setTag("event.origin", "flutter")
                event.setTag("event.environment", "dart")
            }
            "sentry.java.android.flutter" -> {
                event.setTag("event.origin", "android")
                event.setTag("event.environment", "java")
            }
            "sentry.native.android.flutter" -> {
                event.setTag("event.origin", "android")
                event.setTag("event.environment", "native")
            }
        }
    }

    private fun scrub(event: SentryEvent): SentryEvent {
        tagOrigin(event)

        event.message?.let { message ->
            message.formatted = message.formatted?.let(CrashScrub::redactText)
            message.message = message.message?.let(CrashScrub::redactText)
            message.params = message.params?.map(CrashScrub::redactText)
        }
        event.logger = event.logger?.let(CrashScrub::redactText)
        event.transaction = event.transaction?.let(CrashScrub::redactText)
        // The device's own hostname. Nothing here needs it, so drop rather
        // than redact.
        event.serverName = null
        event.request = null
        event.user = null

        event.exceptions?.forEach { exception ->
            exception.value = exception.value?.let(CrashScrub::redactText)
            // `type` and `module` are class names: they cannot carry a URL and
            // redacting them would wreck Sentry's grouping.
            exception.stacktrace?.frames?.forEach { frame ->
                frame.contextLine = frame.contextLine?.let(CrashScrub::redactText)
            }
        }
        event.threads?.forEach { thread ->
            thread.stacktrace?.frames?.forEach { frame ->
                frame.contextLine = frame.contextLine?.let(CrashScrub::redactText)
            }
        }

        event.tags?.let { tags ->
            // `setTags` copies, so building a new map is safe while iterating.
            event.tags = tags.mapValues { (_, value) -> CrashScrub.redactText(value) }
        }
        event.extras?.let { extras ->
            // Rebuilt explicitly rather than with `mapValues`: `setExtras`
            // takes a non-null-valued map, and `scrubValue` is nullable.
            val rebuilt = HashMap<String, Any>(extras.size)
            for ((key, value) in extras) {
                val cleaned = scrubValue(value)
                if (cleaned != null) rebuilt[key] = cleaned
            }
            event.extras = rebuilt
        }
        event.breadcrumbs?.forEach { scrub(it) }
        return event
    }

    private fun scrub(crumb: Breadcrumb): Breadcrumb {
        crumb.message = crumb.message?.let(CrashScrub::redactText)
        crumb.category = crumb.category?.let(CrashScrub::redactText)
        val data = crumb.data
        if (data.isNotEmpty()) {
            // `getData()` hands back the live map; collect first so the
            // rewrite does not mutate what it is iterating.
            for ((key, value) in data.entries.toList()) {
                crumb.setData(key, scrubValue(value))
            }
        }
        return crumb
    }

    private fun scrubValue(value: Any?): Any? =
        when (value) {
            is String -> CrashScrub.redactText(value)
            is List<*> -> value.map { scrubValue(it) }
            is Map<*, *> -> value.entries.associate { (k, v) -> k.toString() to scrubValue(v) }
            else -> value
        }

    private fun fingerprintOf(event: SentryEvent): String {
        val exception = event.exceptions?.firstOrNull()
        val frames = exception?.stacktrace?.frames.orEmpty()
        val inApp = frames.filter { it.isInApp == true }
        val chosen = (if (inApp.isNotEmpty()) inApp else frames).take(3)
        return CrashScrub.fingerprint(
            exception?.type ?: event.message?.formatted ?: "error",
            chosen.map { "${it.module ?: ""}:${it.function ?: ""}" },
        )
    }
}
