package com.gchofficial.iptvs

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.crash.CrashTest
import com.gchofficial.iptvs.crash.NativeCrashScrubber
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.isTelevisionDevice
import com.gchofficial.iptvs.player.BufferPreset
import com.gchofficial.iptvs.player.RendererPolicy
import com.gchofficial.iptvs.player.SharedEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var nativeHdrChannel: MethodChannel
    private lateinit var previewChannel: MethodChannel
    private lateinit var updatesChannel: MethodChannel
    private lateinit var deviceChannel: MethodChannel
    private var pendingInstallPermissionResult: MethodChannel.Result? = null

    /**
     * Answers the `iptvs/device` channel's `isTelevision`, which two Dart
     * callers use: the pairing screen's suggested device label, and — since it
     * decides the *layout* — the wide/narrow choice resolved at boot
     * (`device_class.dart`, `isWideLayout`).
     *
     * Shared with `HdrPlayerActivity`'s ten-foot player chrome via
     * [isTelevisionDevice], deliberately: the two must never disagree about
     * what kind of device this is.
     */
    private fun sentryProguardUuid(): String? = try {
        val info = packageManager.getApplicationInfo(
            packageName,
            android.content.pm.PackageManager.GET_META_DATA,
        )
        info.metaData?.getString("io.sentry.proguard-uuid")
            ?.takeIf { PROGUARD_UUID_SHAPE.matches(it) }
    } catch (e: Exception) {
        null
    }

    private fun isTelevision(): Boolean = isTelevisionDevice(this)

    /**
     * The SoC model this device reports, or null below API 31 where the
     * property does not exist.
     *
     * `Build.SOC_MODEL` is `UNKNOWN` ("unknown") rather than null on a device
     * that declines to answer; [RendererPolicy] treats anything that is not an
     * exact denylist entry as "keep Impeller", so that needs no special case.
     */
    private fun socModel(): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null

    /**
     * The value of an `io.flutter.embedding.android.EnableImpeller` meta-data
     * entry in the **merged** manifest, or null when the build carries no such
     * key.
     *
     * Ordinary builds carry the inert `…EnableImpeller.unset` key instead
     * (`iptvsImpellerOptOutKey` in `android/app/build.gradle.kts`), so this is
     * null everywhere except a hand-dispatched `renderer-test-apk.yml` build.
     *
     * Read the same way `FlutterLoader.ensureInitializationComplete` reads it —
     * via `Bundle.get` and the value's own string form — because aapt2 types
     * `android:value="false"` as a *boolean*, while a placeholder-substituted
     * value can arrive as a String. Reading it with `getBoolean` alone would
     * silently see the default for the String form.
     */
    private fun manifestEnableImpeller(): Boolean? = try {
        val info = packageManager.getApplicationInfo(
            packageName,
            PackageManager.GET_META_DATA,
        )
        info.metaData?.get(FLUTTER_ENABLE_IMPELLER_KEY)?.let { value ->
            when (value) {
                is Boolean -> value
                else -> value.toString().trim().equals("true", ignoreCase = true)
            }
        }
    } catch (e: Exception) {
        // An unreadable manifest must not decide the renderer; fall through to
        // the ordinary rules.
        null
    }

    /**
     * Debug-only CI switch: `adb shell am start … --ez iptvsForceSkiaGl true`
     * makes this launch run on Skia GL whatever the SoC says, so
     * `tool/android_tv_emulator_check.sh` can exercise the fallback renderer
     * on an emulator that is not on the denylist.
     *
     * Gated on [BuildConfig.DEBUG], so a release build ignores the extra
     * entirely — this Activity is exported, and a renderer any caller can
     * switch is not something to ship.
     */
    private fun forceSkiaGlRequested(): Boolean =
        BuildConfig.DEBUG && intent?.getBooleanExtra(EXTRA_FORCE_SKIA_GL, false) == true

    /**
     * Adds `--enable-impeller=false` when this device is on the renderer
     * denylist (see [RendererPolicy]).
     *
     * **This is the one hook that reaches the engine.** In Flutter 3.47.9
     * `FlutterActivityAndFragmentDelegate.setUpFlutterEngine` builds the engine
     * with `new FlutterEngineGroup(context, host.getFlutterShellArgs()
     * .toArray())`, whose constructor calls `FlutterLoader
     * .ensureInitializationComplete(context, dartVmArgs)` — and `EnableImpeller`
     * is `allowedInRelease`, so the flag is honoured on a shipped build and not
     * just under `flutter run`. That path is only taken because this app
     * overrides neither `getCachedEngineId` nor `provideFlutterEngine` and runs
     * no custom `Application`, so no FlutterLoader exists before this call.
     *
     * The args are only consulted on the *first* initialisation in a process;
     * a later Activity recreation re-computes the same decision and it is
     * ignored, which is harmless because the decision is deterministic.
     */
    override fun getFlutterShellArgs(): FlutterShellArgs {
        val decision = RendererPolicy.decide(
            socModel = socModel(),
            manifestEnableImpeller = manifestEnableImpeller(),
            forceSkiaGl = forceSkiaGlRequested(),
        )
        rendererDecision = decision
        val args = super.getFlutterShellArgs()
        decision.shellArg?.let { args.add(it) }
        return args
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = WeakReference(this)
    }

    override fun onStop() {
        super.onStop()
        // Back-exit safety net: leaving the app must never strand the shared
        // preview engine playing audio behind the launcher. Dart also stops it
        // on lifecycle-pause, but the engine is process-global and outlives the
        // Flutter UI, so the finishing Activity enforces it too. Not adopted =
        // not owned by a fullscreen HdrPlayerActivity.
        if (isFinishing && !SharedEngine.adoptedByFullscreen) {
            SharedEngine.invalidate()
        }
    }

    override fun onDestroy() {
        if (instance?.get() === this) instance = null
        pendingInstallPermissionResult?.success(false)
        pendingInstallPermissionResult = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The live preview's video surface (a TextureView the shared ExoPlayer
        // engine renders into) — embedded in the Flutter channel list.
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "iptvs/preview_view",
            PreviewViewFactory(),
        )

        // Drives the shared preview engine (see SharedEngine). Separate channel
        // from the fullscreen player's because each channel has one Dart-side
        // method-call handler, and PlayerScreen owns the other one.
        previewChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_preview",
        )
        previewChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }
                    val headers = (args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>())
                        .entries.mapNotNull { entry ->
                            val key = entry.key as? String
                            if (key.isNullOrBlank()) null else key to entry.value.toString()
                        }.toMap()
                    SharedEngine.onPreviewError = { message ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "error", "message" to message),
                        )
                    }
                    SharedEngine.onPreviewUnsupported = { reason ->
                        // `reason` is an EngineFallbackReason (video|audio|…).
                        // Dart's handling is identical either way — it reopens
                        // the preview on media_kit — but the exported log says
                        // which half of the stream the native engine lost.
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "unsupported", "reason" to reason),
                        )
                    }
                    SharedEngine.onPreviewLost = { unsupported ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "lost", "unsupported" to unsupported),
                        )
                    }
                    SharedEngine.openPreview(
                        this,
                        url,
                        headers,
                        args["muted"] as? Boolean ?: true,
                        BufferPreset.fromName(args["bufferPreset"] as? String),
                    )
                    result.success(true)
                }

                "play" -> {
                    SharedEngine.playPreview()
                    result.success(true)
                }

                "pause" -> {
                    SharedEngine.pausePreview()
                    result.success(true)
                }

                "setVolume" -> {
                    val args = call.arguments as? Map<*, *>
                    val volume = (args?.get("volume") as? Number)?.toFloat()
                    if (volume != null) SharedEngine.setPreviewVolume(volume.coerceIn(0f, 1f))
                    result.success(true)
                }

                "stop" -> {
                    SharedEngine.stopPreview()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        nativeHdrChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_hdr_player",
        )
        nativeHdrChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }

                    val headers = args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val headerPairs = headers.entries.mapNotNull { entry ->
                        val key = entry.key as? String
                        if (key.isNullOrBlank()) null else key to entry.value.toString()
                    }
                    val subtitles = args["subtitles"] as? List<*> ?: emptyList<Any>()
                    val subtitleRows = subtitles.mapNotNull { entry ->
                        val map = entry as? Map<*, *> ?: return@mapNotNull null
                        val url = map["url"] as? String
                        if (url.isNullOrBlank()) {
                            null
                        } else {
                            Triple(
                                url,
                                map["label"]?.toString() ?: "",
                                map["language"]?.toString() ?: "",
                            )
                        }
                    }
                    fun epochMs(key: String): Long = (args[key] as? Number)?.toLong() ?: -1L
                    val intent = Intent(this, HdrPlayerActivity::class.java).apply {
                        putExtra(HdrPlayerActivity.EXTRA_URL, url)
                        putExtra(HdrPlayerActivity.EXTRA_TITLE, args["title"] as? String ?: "")
                        putExtra(HdrPlayerActivity.EXTRA_IS_LIVE, args["isLive"] as? Boolean ?: false)
                        // Seamless handoff: adopt the shared preview engine already
                        // playing this stream instead of reloading it.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ADOPT_SHARED,
                            args["adoptShared"] as? Boolean ?: false,
                        )
                        // Per-source buffering. Without this the Activity reads
                        // a null extra and builds every fullscreen engine on
                        // NORMAL, so the setting only ever reached the preview.
                        putExtra(
                            HdrPlayerActivity.EXTRA_BUFFER_PRESET,
                            args["bufferPreset"] as? String,
                        )
                        putExtra(HdrPlayerActivity.EXTRA_ASPECT, args["aspect"] as? String)
                        // VOD resume point (ms), 0 = play from the top.
                        putExtra(
                            HdrPlayerActivity.EXTRA_RESUME_MS,
                            (args["resumeMs"] as? Number)?.toLong() ?: 0L,
                        )
                        // Favorite toggle (live channels): whether to show the
                        // star, and its seed state from the Dart favorites store.
                        putExtra(
                            HdrPlayerActivity.EXTRA_CAN_FAVORITE,
                            args["canFavorite"] as? Boolean ?: false,
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_IS_FAVORITE,
                            args["isFavorite"] as? Boolean ?: false,
                        )
                        // Whether this route has a LiveZapController behind it.
                        // Constant for the life of the route, so it rides the
                        // open Intent rather than a live channel — the Android
                        // twin of the Windows overlay's `zapEnabled` key on
                        // setControlState. Fails closed: absent means no zap
                        // affordance, never a button that does nothing.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ZAP_ENABLED,
                            args["zapEnabled"] as? Boolean ?: false,
                        )
                        (args["sourceName"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_SOURCE_NAME, it)
                        }
                        // Debug-only integration-test soak: lets a test cycle the
                        // native Activity unattended. Never read outside a debug
                        // build (see HdrPlayerActivity), so gate it here too rather
                        // than carry it onto a release-build intent for no reason.
                        if (BuildConfig.DEBUG) {
                            (args["soakAutoCloseMs"] as? Number)?.toLong()?.let {
                                putExtra(HdrPlayerActivity.EXTRA_SOAK_AUTOCLOSE_MS, it)
                            }
                        }
                        // Live EPG now/next snapshot (epoch ms passed as doubles).
                        (args["epgNowTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_START, epochMs("epgNowStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_STOP, epochMs("epgNowStopMs"))
                            (args["epgNowDesc"] as? String)?.let { d ->
                                putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_DESC, d)
                            }
                        }
                        (args["epgNextTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_START, epochMs("epgNextStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_STOP, epochMs("epgNextStopMs"))
                        }
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_KEYS,
                            ArrayList(headerPairs.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_VALUES,
                            ArrayList(headerPairs.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_URLS,
                            ArrayList(subtitleRows.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LABELS,
                            ArrayList(subtitleRows.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LANGUAGES,
                            ArrayList(subtitleRows.map { it.third }),
                        )
                    }
                    startActivityForResult(intent, REQUEST_NATIVE_PLAYER)
                    result.success(true)
                }

                // ── Live zapping (Dart → the running player Activity) ────
                //
                // Dart owns the channel list, the cursor and the resolve (see
                // `lib/player/live_zap_controller.dart`); these two are the
                // only things it asks the native side to *do*. The channel
                // handler has to live here — a MethodChannel is registered
                // once per process — so both forward to the live Activity,
                // the mirror of `logPlaybackDiagnostic` going the other way.
                //
                // Both are no-ops with no Activity up: a zap that arrives
                // after the player closed has nothing to apply, and answering
                // `false` rather than erroring keeps a late push off Dart's
                // error path.
                "zapTo" -> {
                    val args = call.arguments as? Map<*, *>
                    val player = HdrPlayerActivity.instance?.get()
                    if (args == null || player == null) {
                        result.success(mapOf("engineRebuilt" to false))
                    } else {
                        result.success(player.applyZap(args))
                    }
                }

                "setZapBanner" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        HdrPlayerActivity.instance?.get()?.applyZapBanner(args)
                    }
                    result.success(true)
                }

                // The quick list's row window, routed exactly like the banner
                // beside it. Every push is forwarded, including the closing
                // one: `open:false` is a tear-down instruction, not an
                // absence (`HdrPlayerActivity.applyQuickList`).
                "setQuickList" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        HdrPlayerActivity.instance?.get()?.applyQuickList(args)
                    }
                    result.success(true)
                }

                // Debug-only lifecycle counters for an integration-test soak
                // (see DebugCounters); empty map in a release build.
                "debugCounters" -> result.success(DebugCounters.snapshot())

                else -> result.notImplemented()
            }
        }

        // Device form factor, read once while pairing so the device can suggest
        // its own name ("Android TV" vs "Android") to the web panel. Outbound
        // only — Dart never registers a handler here, so this is not a
        // ChannelHandlerOwner case.
        deviceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/device",
        )
        deviceChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevision())

                // Which Flutter renderer this process started with, and why
                // (`RendererPolicy`). Read once at boot so the exportable
                // diagnostics log says it on every report, and so Dart can put
                // it on the Sentry scope. Outbound only, like `isTelevision`,
                // and never blocking: the decision was taken before the engine
                // existed, so this is a field read.
                "renderer" -> result.success(
                    (rendererDecision ?: RendererPolicy.decide(null, null, false)).let {
                        mapOf("renderer" to it.renderer, "reason" to it.reason)
                    },
                )

                // The R8 mapping UUID this build was stamped with
                // (`io.sentry.proguard-uuid`, from `build.gradle.kts`), read
                // back out of the *merged* manifest so Dart can hand it to
                // `SentryFlutterOptions.proguardUuid`. Without that, the
                // plugin's `configureAndroidOptions` assigns the Dart value
                // (null) over the one sentry-android read from this manifest,
                // and every Java/Kotlin event goes out naming no mapping.
                // Returns null when absent (dev/PR builds carry the `.unset`
                // key instead) or not UUID-shaped.
                "sentryProguardUuid" -> result.success(sentryProguardUuid())

                // Crash reporting: put this app's redaction and send budget on
                // the **Java** SDK's event path. Dart's `beforeSend` sees only
                // Dart events — Java/Kotlin uncaught exceptions, NDK crashes
                // and Android 12+ tombstones are captured and sent by the Java
                // SDK and never cross back up. Called by
                // `CrashReporter._installNativeScrubber` as soon as
                // `SentryFlutter.init` returns, which is the first moment the
                // native options object exists. See `crash/NativeCrashScrubber`.
                "installCrashScrubber" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("budgetPath") as? String
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Missing budget path", null)
                    } else {
                        // The renderer rides in here rather than being read
                        // back from Dart: this is the callback that sees every
                        // Java/NDK/tombstone event, and it must be able to tag
                        // one even if the Dart scope sync has not run yet.
                        result.success(
                            NativeCrashScrubber.install(
                                path,
                                rendererDecision?.renderer,
                            ),
                        )
                    }
                }

                // Crash-test build only: throw an uncaught RuntimeException on
                // the Android main thread, with a fake provider URL in its
                // message. Proves two things a Dart exception cannot —
                // sentry-java's UncaughtExceptionHandlerIntegration captures
                // it at all, and `NativeCrashScrubber` (not Dart's
                // `beforeSend`, which never sees a Java event) is what redacts
                // the URL.
                //
                // `BuildConfig.CRASH_TEST` comes from the same
                // `--dart-define=IPTVS_CRASH_TEST=true` that sets Dart's
                // `kCrashTest`, decoded in `build.gradle.kts`. It is false in
                // every shipped build, so this answers `notImplemented()` and
                // R8 removes the branch — and no Dart code calls it there
                // either, since the Diagnostics section is gated on the same
                // const.
                "crashTestThrow" -> {
                    if (!BuildConfig.CRASH_TEST) {
                        result.notImplemented()
                    } else {
                        // Reply *first*, then post. Throwing inline would not
                        // be uncaught at all: `MethodChannel`'s incoming
                        // handler wraps `onMethodCall` in a try/catch and
                        // turns the exception into an error reply, which is
                        // the opposite of what this is testing. Posting to the
                        // main looper lets it escape to the default uncaught
                        // handler, which is where Sentry is hooked.
                        result.success(true)
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            throw RuntimeException(CrashTest.message())
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }

        // In-app update: launches the system package installer for a
        // downloaded release APK, and the "install unknown apps" settings.
        updatesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/updates",
        )
        updatesChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path") as? String
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Missing APK path", null)
                        return@setMethodCallHandler
                    }
                    val apk = File(path)
                    try {
                        verifyUpdateApk(apk)
                    } catch (e: SecurityException) {
                        result.error("invalid_update", e.message, null)
                        return@setMethodCallHandler
                    }
                    // minSdk 26 → canRequestPackageInstalls() always applies.
                    if (!packageManager.canRequestPackageInstalls()) {
                        result.success("needs_permission")
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apk,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_ACTIVITY_NEW_TASK,
                            )
                        }
                        startActivity(intent)
                        result.success("launched")
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }

                "requestInstallPermission" -> {
                    if (pendingInstallPermissionResult != null) {
                        result.error("settings_active", "Install settings are already open", null)
                        return@setMethodCallHandler
                    }
                    try {
                        pendingInstallPermissionResult = result
                        startActivityForResult(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                            REQUEST_INSTALL_PERMISSION,
                        )
                    } catch (e: Exception) {
                        pendingInstallPermissionResult = null
                        result.error("settings_failed", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Asks the Dart player route for a freshly resolved live locator and hands
     * the raw reply to [onReply] — `{url, headers}` on success, **null** for
     * every failure shape (no channel yet, no/superseded Dart handler, an
     * unmounted route, a platform error, `notImplemented`). The caller decides
     * the fallback; see [com.gchofficial.iptvs.player.ResolveAgainReply].
     *
     * Exists because [HdrPlayerActivity] is a separate Activity with no Flutter
     * engine of its own: this MethodChannel lives here, and both Activities run
     * on the same process main thread, which is where MethodChannel calls and
     * their replies must happen.
     *
     * The reply is never logged: a Dart-side resolve error message can embed
     * the provider URL, and therefore credentials.
     */
    fun requestFreshLiveLocator(onReply: (Any?) -> Unit) {
        if (!::nativeHdrChannel.isInitialized) {
            onReply(null)
            return
        }
        nativeHdrChannel.invokeMethod(
            "resolveAgain",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) = onReply(result)

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                    onReply(null)

                override fun notImplemented() = onReply(null)
            },
        )
    }

    /**
     * Relays a short, credential-free note from [HdrPlayerActivity] into Dart's
     * exportable diagnostics log (`playback` scope).
     *
     * The seamless preview→fullscreen handoff either adopts the shared engine or
     * silently reloads the stream, and until now that outcome existed only in
     * logcat — unreachable for a user reporting "it reconnects when I go
     * fullscreen" from a TV. Dart already logs which handoff it *asked* for
     * (`fullscreen open decision=…`); this is the other half, what the Activity
     * actually did. Fire-and-forget: a missing channel or handler is not worth
     * reacting to.
     *
     * **Never pass anything derived from a URL, header or provider reply** —
     * this text is exported verbatim.
     */
    /**
     * Inbound half of the zap wire contract: one member of the shared command
     * vocabulary (`lib/player/zap_command.dart`), sent by
     * [HdrPlayerActivity]'s key policy.
     *
     * Fire-and-forget by design — the native side names a *command*, never a
     * channel, and holds no cursor to reconcile against a reply.
     */
    fun requestZap(command: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeZap", mapOf("command" to command))
    }

    fun logPlaybackDiagnostic(note: String) {
        if (!::nativeHdrChannel.isInitialized) return
        nativeHdrChannel.invokeMethod("nativeDiagnostic", mapOf("note" to note))
    }

    /**
     * Fails closed unless [apk] is a cache-owned APK for this exact application
     * and is signed by the same certificate as the installed build. Dart has
     * already verified the signed release-manifest digest; this native check
     * prevents a wrong-package or wrong-signer APK reaching Package Installer.
     */
    @Suppress("DEPRECATION")
    private fun verifyUpdateApk(apk: File) {
        val cachePath = cacheDir.canonicalFile.toPath()
        val apkPath = apk.canonicalFile.toPath()
        if (!apk.isFile || !apkPath.startsWith(cachePath)) {
            throw SecurityException("Update APK is outside the application cache")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apkPath.toString(), flags)
            ?: throw SecurityException("Update APK package metadata is unreadable")
        if (candidate.packageName != packageName) {
            throw SecurityException("Update APK package identity does not match")
        }
        val installed = packageManager.getPackageInfo(packageName, flags)
        val candidateSigners = signerDigests(candidate)
        val installedSigners = signerDigests(installed)
        if (candidateSigners.isEmpty() || candidateSigners != installedSigners) {
            throw SecurityException("Update APK signing certificate does not match")
        }
    }

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners ?: emptyArray()
        } else {
            info.signatures ?: emptyArray()
        }
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString(separator = "") { byte ->
                    (byte.toInt() and 0xff).toString(16).padStart(2, '0')
                }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL_PERMISSION) {
            pendingInstallPermissionResult?.success(packageManager.canRequestPackageInstalls())
            pendingInstallPermissionResult = null
            return
        }
        if (requestCode == REQUEST_NATIVE_PLAYER && ::nativeHdrChannel.isInitialized) {
            // Relay the final VOD position (see HdrPlayerActivity.finish) so the
            // Dart side can persist the resume point, plus the final favorite
            // state so the channel list reflects an in-player toggle on return.
            // Null args = live with no favorite change / legacy.
            val positionMs = data?.getLongExtra(HdrPlayerActivity.RESULT_POSITION_MS, -1L) ?: -1L
            val durationMs = data?.getLongExtra(HdrPlayerActivity.RESULT_DURATION_MS, -1L) ?: -1L
            val map = buildMap<String, Any> {
                if (positionMs >= 0L && durationMs > 0L) {
                    put("positionMs", positionMs)
                    put("durationMs", durationMs)
                }
                data?.takeIf { it.hasExtra(HdrPlayerActivity.RESULT_FAVORITE) }?.let { result ->
                    put("favorite", result.getBooleanExtra(HdrPlayerActivity.RESULT_FAVORITE, false))
                }
                data?.getStringExtra(HdrPlayerActivity.RESULT_ASPECT)?.let {
                    put("aspect", it)
                }
            }
            nativeHdrChannel.invokeMethod("nativeClosed", if (map.isEmpty()) null else map)
        }
    }

    companion object {
        /** A canonical UUID, as `build.gradle.kts` validates it before stamping. */
        private val PROGUARD_UUID_SHAPE =
            Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

        /**
         * Set while a MainActivity exists. Lets [HdrPlayerActivity] move the
         * *main* task behind its PiP window (once an Activity enters PiP it lives
         * in its own pinned task, so it can't move this one from there).
         */
        var instance: WeakReference<MainActivity>? = null
            private set

        private const val REQUEST_NATIVE_PLAYER = 4120
        private const val REQUEST_INSTALL_PERMISSION = 4121

        /**
         * The Flutter embedding's build-time Impeller opt-out key, as
         * `FlutterEngineFlags.ENABLE_IMPELLER.metadataKey` spells it.
         */
        private const val FLUTTER_ENABLE_IMPELLER_KEY =
            "io.flutter.embedding.android.EnableImpeller"

        /**
         * Debug-only intent extra forcing the Skia GL renderer
         * (`--ez iptvsForceSkiaGl true`). See [forceSkiaGlRequested].
         */
        const val EXTRA_FORCE_SKIA_GL = "iptvsForceSkiaGl"

        /**
         * The renderer this process resolved, set by [getFlutterShellArgs]
         * before the engine exists and read afterwards by the `iptvs/device`
         * channel and by the native crash scrubber.
         *
         * Process-static rather than per-Activity: the engine is initialised
         * once per process, so the decision belongs to the process.
         */
        @Volatile
        var rendererDecision: RendererPolicy.Decision? = null
            private set
    }
}
